// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

interface IRateObserver {
    function observe() external;
}

/// @notice Reads StocksStaking's published redemption rate at whatever moment it is poked. Stands in for any
/// third-party integrator (a lending market pricing TST collateral, a vault, an aggregator) that treats
/// `quoteRedeem` as the authoritative stock-per-TST rate.
contract RedemptionRateObserver is IRateObserver {
    StocksStaking public staking;
    uint256 public probe;
    uint256 public observations;
    uint256 public maxObservedStockOut;
    uint256 public minObservedStockOut = type(uint256).max;

    function configure(StocksStaking staking_, uint256 probe_) external {
        staking = staking_;
        probe = probe_;
    }

    /// @dev Records the highest and lowest rate seen across EVERY callback. redeem() pays out in two transfers
    /// (the redeemer's stockOut and then the protocol's cut), so the callback fires more than once, and the
    /// claim under test is about every intermediate state, not just one of them.
    function observe() external override {
        (uint256 stockOut,,) = staking.quoteRedeem(probe);
        observations++;
        if (stockOut > maxObservedStockOut) maxObservedStockOut = stockOut;
        if (stockOut < minObservedStockOut) minObservedStockOut = stockOut;
    }
}

/// @notice A stock token with a transfer callback, used to obtain control DURING StocksStaking.redeem()'s
/// payout. `hookBefore` selects whether the callback fires before or after balances move, which is the
/// difference between the two realistic token designs (a pre-transfer hook vs. an ERC777-style
/// tokensReceived that fires once balances have settled).
contract CallbackStock is ERC20 {
    address public observer;
    address public watched;
    bool public hookBefore;

    constructor() ERC20("Callback stock", "CBS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address observer_, address watched_, bool hookBefore_) external {
        observer = observer_;
        watched = watched_;
        hookBefore = hookBefore_;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool fire = observer != address(0) && from == watched;
        if (fire && hookBefore) IRateObserver(observer).observe();
        super._update(from, to, value);
        if (fire && !hookBefore) IRateObserver(observer).observe();
    }
}

/// @notice Round 23 (2026-10-01, user-directed: work the standard published audit-finding taxonomy -- the
/// kind catalogued on Solodit -- class by class against this codebase). Most classes were already closed by
/// rounds 1-22 and are recorded in AUDIT.md rather than retested here. This file carries the two classes the
/// sweep found genuinely UNCOVERED. The first (read-only reentrancy on the redemption rate) was fixed in
/// round 26 and its tests now pin the fixed behaviour; the second (no deadline) remains informational.
///
/// Round 10 did check read-only reentrancy, but only against `StocksHook.getReserves()` and the price
/// accumulator, and correctly concluded those are live Uniswap state with no on-chain consumer. It never
/// looked at `StocksStaking`'s redemption rate -- which is the far more dangerous shape, and precisely the
/// shape that made Curve's `get_virtual_price` the canonical $73M case: an independently COMPUTED ratio of
/// two values the contract itself mutates, published through a view that no reentrancy guard protects
/// (OpenZeppelin's `nonReentrant` does not cover view functions).
contract StocksAuditR23SoloditTest is Test {
    MockERC20 tst;
    CallbackStock stock;
    MockHookV5 hook;
    StocksStaking staking;
    RedemptionRateObserver observer;
    PoolKey poolKey;

    address governor = address(0x6046);
    address redeemer = address(0xBEEF);
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 constant DURATION = 30 days;
    uint256 constant TREASURY = 100_000e18;
    uint256 constant SUPPLY = 1_000_000e18;
    uint256 constant PROBE = 1_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new CallbackStock();
        hook = new MockHookV5(stock, tst, 1 hours, 1);

        staking = new StocksStaking(
            address(tst), address(stock), DURATION, governor, address(hook), address(this)
        );

        bool tstIsCurrency0 = address(tst) < address(stock);
        poolKey = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(poolKey);

        stock.mint(address(staking), TREASURY);
        tst.mint(redeemer, SUPPLY);

        observer = new RedemptionRateObserver();
        observer.configure(staking, PROBE);

        vm.prank(redeemer);
        tst.approve(address(staking), type(uint256).max);
    }

    function _rate() internal view returns (uint256 stockOut) {
        (stockOut,,) = staking.quoteRedeem(PROBE);
    }

    // ============================================================
    // Class: read-only reentrancy (NOT previously covered for the redemption rate)
    // ============================================================

    /// @notice FIXED in round 26 (was: Low, latent, found in round 23).
    ///
    /// `redeem()` moves the two inputs of its own published rate in SEPARATE external calls, and the views that
    /// publish that rate (`quoteRedeem` / `redeemableStock`: treasury balance over `nonBurnedSupply()`) are not
    /// covered by `nonReentrant`. The original order burned the TST first:
    ///
    ///     tstToken.safeTransferFrom(msg.sender, BURN_ADDRESS, tstAmount);  // denominator dropped here
    ///     stockToken.safeTransfer(msg.sender, stockOut);                   // numerator dropped here
    ///     if (protocolCut > 0) stockToken.safeTransfer(protocol, protocolCut);
    ///
    /// so between those calls the supply had already shrunk while the stock was still in the treasury, and the
    /// published rate was transiently HIGHER than any rate ever settled. Measured in round 23 on this exact
    /// scenario: 99.999e18 mid-call against a settled 90.8e18, 1,013 bps too high. The loss would have landed on
    /// whoever trusted the quote at that instant (a lending market valuing TST collateral, say). It was never
    /// reachable with the attested tokens, which have no transfer callbacks.
    ///
    /// The fix pays the stock out first and burns last. Every intermediate state now has the numerator leading
    /// the denominator, so the rate reads at or BELOW the rate before the redemption, which is itself at or
    /// below the settled one. These tests observe every callback during the payout, with the callback placed
    /// both before and after balances move, and pin that nothing above the pre-redemption rate is ever seen.
    function test_R23_ReadOnlyReentrancy_RateIsNeverOverstatedMidRedeem_PreTransferCallback() public {
        stock.arm(address(observer), address(staking), true); // callback fires before balances move

        uint256 rateBefore = _rate();

        vm.prank(redeemer);
        staking.redeem(100_000e18, 0);

        uint256 rateAfter = _rate();
        console.log("rate before   (stock wei per 1000 TST):", rateBefore);
        console.log("highest seen DURING the redemption:    ", observer.maxObservedStockOut());
        console.log("lowest seen DURING the redemption:     ", observer.minObservedStockOut());
        console.log("rate after    (stock wei per 1000 TST):", rateAfter);

        assertEq(observer.observations(), 2, "sanity: both payout transfers were observed");
        assertLe(observer.maxObservedStockOut(), rateBefore, "no mid-redeem state reads above the pre-redeem rate");
        assertLe(observer.maxObservedStockOut(), rateAfter, "nor above the rate that is finally settled");
        assertLt(observer.minObservedStockOut(), rateBefore, "the window still exists, it now errs low");

        // The settled rate itself only ever rises for those who stay: that is the intended behaviour.
        assertGe(rateAfter, rateBefore, "settled rate must not fall for remaining holders");
    }

    /// @notice The same with the callback firing AFTER balances settle (the ERC777 `tokensReceived` shape):
    /// both observations now see stock that has already left against a supply that has not yet shrunk.
    function test_R23_ReadOnlyReentrancy_RateIsNeverOverstatedMidRedeem_PostTransferCallback() public {
        stock.arm(address(observer), address(staking), false);

        uint256 rateBefore = _rate();

        vm.prank(redeemer);
        staking.redeem(100_000e18, 0);

        uint256 rateAfter = _rate();
        console.log("highest seen DURING (post-transfer callback):", observer.maxObservedStockOut());
        console.log("rate before / after:", rateBefore, rateAfter);

        assertEq(observer.observations(), 2, "sanity: both payout transfers were observed");
        assertLt(observer.maxObservedStockOut(), rateBefore, "every post-transfer state reads below the pre-redeem rate");
        assertLt(observer.maxObservedStockOut(), rateAfter, "and below the settled rate");
    }

    /// @notice Whatever share of the supply is redeemed, and wherever the callback sits, no observable state
    /// during the payout reads above the rate from before the redemption.
    function testFuzz_R23_ReadOnlyReentrancy_NoRedemptionSizeOverstatesTheRate(uint256 amount, bool hookBefore) public {
        amount = bound(amount, 1e18, SUPPLY - PROBE); // leave enough supply for the probe quote to be valid
        stock.arm(address(observer), address(staking), hookBefore);

        uint256 rateBefore = _rate();
        vm.prank(redeemer);
        staking.redeem(amount, 0);

        assertGt(observer.observations(), 0, "sanity: the payout was observed");
        assertLe(observer.maxObservedStockOut(), rateBefore, "never above the pre-redeem rate");
        assertLe(observer.maxObservedStockOut(), _rate(), "never above the settled rate");
    }

    /// @notice The reordering pays nothing for free: if the burn fails, the payout is undone with it.
    function test_R23_RedeemWithoutAllowance_RevertsAndPaysNothing() public {
        vm.prank(redeemer);
        tst.approve(address(staking), 0);

        uint256 treasuryBefore = stock.balanceOf(address(staking));
        vm.prank(redeemer);
        vm.expectRevert();
        staking.redeem(100_000e18, 0);

        assertEq(stock.balanceOf(redeemer), 0, "the redeemer keeps no stock when the burn fails");
        assertEq(stock.balanceOf(address(staking)), treasuryBefore, "the treasury is untouched");
        assertEq(tst.balanceOf(BURN), 0, "nothing was burned");
    }

    /// @notice Control: with no callback at all (the real, currently-attested token shape) there is no
    /// observable intermediate state in the first place.
    function test_R23_Control_WithNoTransferCallback_NoObservableWindowExists() public {
        uint256 rateBefore = _rate();

        vm.prank(redeemer);
        staking.redeem(100_000e18, 0);

        assertEq(observer.observations(), 0, "no callback armed means the rate was never read mid-call");
        assertGe(_rate(), rateBefore, "settled rate still only rises for those who stay");
    }

    // ============================================================
    // Class: missing deadline / expiry on user-facing value transfers
    // ============================================================

    /// @notice FINDING (Informational). None of the user-facing value-moving entry points takes a deadline:
    /// `StocksCurve.buy`, `StocksCurve.sell` and `StocksStaking.redeem` all take a slippage bound and nothing
    /// else (`grep -rn "deadline" src/` returns no hits anywhere in the codebase). A transaction that sits in
    /// the mempool -- or is deliberately withheld by a block builder -- can therefore be executed at ANY later
    /// time, at whatever rate prevails then.
    ///
    /// Severity is genuinely Informational rather than Medium here, and the reason is worth recording
    /// precisely rather than hand-waving: the user's `minStockOut` / `minTstOut` still bounds the outcome in
    /// absolute token terms whenever the trade executes, so there is no path to executing below the floor the
    /// user signed for. What a deadline would additionally buy is protection against a stale order filling at
    /// a rate that is above the user's floor but far below the market rate they would get by resubmitting.
    /// For redemption specifically that exposure is unusually small, because the rate is monotonically
    /// non-decreasing for holders who stay (asserted above), so a delayed redemption fills at a rate at least
    /// as good as the one quoted. Demonstrated rather than argued.
    function test_R23_NoDeadlineParameter_AStaleRedemptionStillExecutesAYearLater() public {
        uint256 quotedAtSigningTime = _rate();

        // The user's transaction is withheld for a year, then mined unchanged.
        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.prank(redeemer);
        uint256 got = staking.redeem(PROBE, quotedAtSigningTime);

        assertGe(got, quotedAtSigningTime, "a year-stale redemption still honours the signed floor");
        console.log("quoted a year earlier:", quotedAtSigningTime);
        console.log("actually received now:", got);
        console.log("CONFIRMED: no deadline exists, but the signed slippage floor still bounds the outcome");
    }
}
