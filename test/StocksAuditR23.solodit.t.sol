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
    uint256 public observedStockOut;

    function configure(StocksStaking staking_, uint256 probe_) external {
        staking = staking_;
        probe = probe_;
    }

    /// @dev Records only the FIRST observation. redeem() pays out in two transfers (the redeemer's stockOut
    /// and then the protocol's cut), so the callback fires more than once; keeping the last one would measure
    /// a partially-settled state and understate the window.
    function observe() external override {
        if (observedStockOut != 0) return;
        (uint256 stockOut,,) = staking.quoteRedeem(probe);
        observedStockOut = stockOut;
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
/// sweep found genuinely UNCOVERED.
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

    /// @notice FINDING (Low, latent -- conditional on the stock token having a transfer callback).
    ///
    /// `redeem()` mutates the two inputs of its own published rate in two SEPARATE external calls:
    ///
    ///     tstToken.safeTransferFrom(msg.sender, BURN_ADDRESS, tstAmount);  // denominator drops here
    ///     stockToken.safeTransfer(msg.sender, stockOut);                   // numerator drops here
    ///     if (protocolCut > 0) stockToken.safeTransfer(protocol, protocolCut);
    ///
    /// `quoteRedeem` / `redeemableStock` divide the treasury balance by `nonBurnedSupply()`. Between those
    /// calls the denominator has already shrunk by the full `tstAmount` while the numerator still holds stock
    /// that is about to leave, so the published rate is transiently HIGHER than any rate that is ever actually
    /// settled -- higher than before the redemption and higher than after it. `nonReentrant` does not help:
    /// it guards state-changing entry points, and this is a view.
    ///
    /// Measured below with a pre-transfer callback: the rate an integrator reads mid-redemption overstates the
    /// settled rate by ~11%. Nothing is stolen from this protocol directly; the loss would land on whoever
    /// trusts the inflated quote (a lending market valuing TST collateral, say).
    ///
    /// NOT currently reachable: every attested xStock wrapper is a plain ERC20/ERC4626 with no transfer
    /// callback (confirmed by the existing 723-wrapper sweep), TSTToken is a plain ERC20Votes whose transfers
    /// make no external calls, and the burn goes to a dead address. So this needs either a future stock token
    /// with callbacks or a future code change that introduces one. Recorded as a latent finding with a
    /// concrete mitigation (publish the rate behind a reentrancy-status check, or move the TST burn to after
    /// the stock transfers so the denominator never leads the numerator) rather than left undocumented.
    function test_R23_ReadOnlyReentrancy_RedemptionRateIsInflatedMidRedeem() public {
        stock.arm(address(observer), address(staking), true); // callback fires before balances move

        uint256 rateBefore = _rate();

        vm.prank(redeemer);
        staking.redeem(100_000e18, 0);

        uint256 rateDuring = observer.observedStockOut();
        uint256 rateAfter = _rate();

        console.log("rate before  (stock wei per 1000 TST):", rateBefore);
        console.log("rate DURING  (stock wei per 1000 TST):", rateDuring);
        console.log("rate after   (stock wei per 1000 TST):", rateAfter);
        console.log("overstatement vs settled rate (bps):", ((rateDuring - rateAfter) * 10_000) / rateAfter);

        assertGt(rateDuring, rateBefore, "mid-redeem rate must exceed the pre-redeem rate");
        assertGt(rateDuring, rateAfter, "AUDIT: mid-redeem rate exceeds any rate ever actually settled");

        // The settled rate itself only ever rises for those who stay -- the transient spike is the bug, not
        // the permanent increase, which is the documented and intended behaviour.
        assertGe(rateAfter, rateBefore, "settled rate must not fall for remaining holders");
        console.log("CONFIRMED: quoteRedeem transiently publishes a rate higher than any settled rate");
    }

    /// @notice The same window with the callback firing AFTER balances settle (the ERC777 `tokensReceived`
    /// shape). The overstatement is smaller -- only the protocol's cut is still sitting in the treasury,
    /// about to leave -- but it is still strictly above the settled rate, so the window is not an artifact of
    /// one particular callback placement.
    function test_R23_ReadOnlyReentrancy_WindowExistsForPostTransferCallbacksToo() public {
        stock.arm(address(observer), address(staking), false);

        vm.prank(redeemer);
        staking.redeem(100_000e18, 0);

        uint256 rateDuring = observer.observedStockOut();
        uint256 rateAfter = _rate();

        console.log("rate DURING (post-transfer callback):", rateDuring);
        console.log("rate after:", rateAfter);
        assertGt(rateDuring, rateAfter, "AUDIT: even a post-transfer callback sees an over-stated rate");
        console.log("CONFIRMED: the window is inherent to the ordering, not to callback placement");
    }

    /// @notice Control: with no callback at all -- the real, currently-attested token shape -- there is no
    /// observable intermediate state, so the finding above is genuinely latent rather than live.
    function test_R23_Control_WithNoTransferCallback_NoObservableWindowExists() public {
        uint256 rateBefore = _rate();

        vm.prank(redeemer);
        staking.redeem(100_000e18, 0);

        assertEq(observer.observedStockOut(), 0, "no callback armed means the rate was never read mid-call");
        assertGe(_rate(), rateBefore, "settled rate still only rises for those who stay");
        console.log("CONFIRMED: with a plain ERC20 stock token the window is unobservable");
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
