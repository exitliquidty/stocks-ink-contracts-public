// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract AdvMockStock is ERC20 {
    constructor() ERC20("Adversarial stock", "ADV") {
        _mint(msg.sender, type(uint128).max);
    }
}

/// @dev A flash-loan style attacker. Inside a single Uniswap v4 unlock it borrows TST straight out of the pool
/// manager, redeems it against the treasury, and tries to use the stock it got to buy the TST back and repay.
contract FlashRedeemAttacker is IUnlockCallback {
    IPoolManager public pm;
    StocksStaking public staking;
    IERC20 public tst;
    IERC20 public stock;
    PoolKey public key;
    bool public tstIsCurrency0;
    uint256 public stockRedeemed;

    constructor(IPoolManager pm_, StocksStaking staking_, IERC20 tst_, IERC20 stock_, PoolKey memory key_, bool tstIs0_) {
        pm = pm_;
        staking = staking_;
        tst = tst_;
        stock = stock_;
        key = key_;
        tstIsCurrency0 = tstIs0_;
    }

    function attack(uint256 borrowTst) external {
        pm.unlock(abi.encode(borrowTst));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only pool manager");
        uint256 x = abi.decode(data, (uint256));
        Currency tstC = Currency.wrap(address(tst));
        Currency stockC = Currency.wrap(address(stock));

        pm.take(tstC, address(this), x); // flash-borrow x TST
        tst.approve(address(staking), x);
        uint256 out = staking.redeem(x, 0); // burn it and take the stock
        stockRedeemed = out;

        // try to buy the TST back with the stock and repay the pool manager
        stock.approve(address(pm), type(uint256).max);
        bool zeroForOne = !tstIsCurrency0;
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(out),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // settle the stock we spent...
        pm.sync(stockC);
        stock.transfer(address(pm), out);
        pm.settle();
        // ...and whatever TST is still owed after the swap, out of our own (empty) pocket
        int256 tstDelta = TransientStateLibrary.currencyDelta(pm, address(this), tstC);
        if (tstDelta < 0) {
            pm.sync(tstC);
            tst.transfer(address(pm), uint256(-tstDelta));
            pm.settle();
        } else if (tstDelta > 0) {
            pm.take(tstC, address(this), uint256(tstDelta));
        }
        return "";
    }
}

/// @notice Attacks on in-kind redemption against the REAL production stack (real factory, hook, graduator,
/// staking, TWAMM and a real Uniswap v4 PoolManager): a flash-loan attempt, the intended arbitrage and what it does
/// to everyone else, splitting a redemption into many pieces, dust spam, and manipulating the rate from outside.
contract StocksRedemptionAdversarialTest is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    PoolManager pm;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    PoolSwapTest swapRouter;
    AdvMockStock stock;
    IERC20 tst;
    StocksCurve curve;
    StocksStaking staking;
    PoolKey key;
    bool tstIsCurrency0;
    address protocol = address(0xFEED);
    address staker = address(0x57A6);
    address holder = address(0xB16);
    address trader = address(0x7A1);

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        stock = new AdvMockStock();
        TokenMetadataRegistry registry = new TokenMetadataRegistry();
        address governorFactory = address(new StocksGovernorFactory());
        address curveDeployer = address(new StocksCurveFactory());
        address stakingFactory = address(new StocksStakingFactory());

        uint256 nonceAtStart = vm.getNonce(address(this));
        address predictedGraduator = vm.computeCreateAddress(address(this), nonceAtStart + 1);
        address predictedFactory = vm.computeCreateAddress(address(this), nonceAtStart + 2);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(address(pm)), predictedGraduator, uint256(1 hours));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(IPoolManager(address(pm)), predictedGraduator, 1 hours);
        require(address(hook) == hookAddress, "hook address mismatch");
        graduator = new StocksGraduator(IPoolManager(address(pm)), hook, predictedFactory);
        factory = new StocksLaunchFactory(
            vm.addr(SIGNER_KEY), protocol, address(hook), governorFactory, stakingFactory, curveDeployer,
            address(graduator), address(registry), 8_000e18, 1 days, 365 days, 1 days, 3 days, 25
        );
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));

        uint256 price = 200e18;
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        (address token, address curveAddr) =
            factory.createCurve("Adv", "ADV", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        tst = IERC20(token);
        curve = StocksCurve(curveAddr);
        vm.warp(vm.getBlockTimestamp() + 61);

        // the holder buys most of the curve, the staker a bit; then it graduates
        stock.transfer(holder, 1_000e18);
        stock.transfer(staker, 1_000e18);
        stock.transfer(trader, 1_000_000e18);
        vm.startPrank(holder);
        stock.approve(curveAddr, type(uint256).max);
        curve.buy(30e18, 0);
        vm.stopPrank();
        vm.startPrank(staker);
        stock.approve(curveAddr, type(uint256).max);
        curve.buy(12e18, 0);
        vm.stopPrank();
        curve.graduate();
        staking = StocksStaking(curve.staking());
        key = StocksPoolView(curve.pair()).poolKey();
        tstIsCurrency0 = Currency.unwrap(key.currency0) == token;

        // the staker stakes everything it has, so there are earned rewards to protect
        uint256 stakerTst = tst.balanceOf(staker);
        vm.startPrank(staker);
        tst.approve(address(staking), stakerTst);
        staking.stake(stakerTst);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------ helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _fundTreasury(uint256 amount) internal {
        stock.transfer(address(staking), amount);
        staking.notifyRewardAmount();
    }

    function _buyTst(address who, uint256 stockIn) internal returns (uint256 got) {
        uint256 before = tst.balanceOf(who);
        vm.startPrank(who);
        stock.approve(address(swapRouter), stockIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !tstIsCurrency0,
                amountSpecified: -int256(stockIn),
                sqrtPriceLimitX96: !tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        got = tst.balanceOf(who) - before;
    }

    function _redeem(address who, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        out = staking.redeem(amount, 0);
        vm.stopPrank();
    }

    function _rate() internal view returns (uint256) {
        return (staking.redeemableStock() * 1e27) / staking.nonBurnedSupply();
    }

    /// @dev Stock per TST the pool would charge for a small buy, in 1e27 units (the pool's marginal price).
    function _poolPrice() internal view returns (uint256) {
        return (stock.balanceOf(address(pm)) * 1e27) / tst.balanceOf(address(pm));
    }

    // ------------------------------------------------------------------------------------ flash loans

    /// @dev A flash-loan attacker borrows TST from the pool manager, redeems it, and tries to buy it back with
    /// the stock it received. The treasury rate is far below the pool price here, so the stock it gets cannot
    /// buy back what it borrowed: the whole transaction must fail and nothing changes.
    function test_FlashBorrowedTst_CannotBeRedeemedAndRepaid_WhenTheRateIsBelowThePrice() public {
        vm.warp(_now() + 3 days);
        _fundTreasury(20e18); // a treasury worth far less than the pool
        assertLt(_rate(), _poolPrice(), "precondition: the pool sells TST above the redemption rate");

        FlashRedeemAttacker atk = new FlashRedeemAttacker(IPoolManager(address(pm)), staking, tst, stock, key, tstIsCurrency0);
        uint256 treasuryBefore = stock.balanceOf(address(staking));
        uint256 supplyBefore = staking.nonBurnedSupply();
        uint256 borrow = tst.balanceOf(address(pm)) / 10;

        vm.expectRevert();
        atk.attack(borrow);

        assertEq(stock.balanceOf(address(staking)), treasuryBefore, "the treasury is untouched");
        assertEq(staking.nonBurnedSupply(), supplyBefore, "nothing was burned");
    }

    // -------------------------------------------------------------------- the intended arbitrage

    /// @dev When the treasury is worth MORE per TST than the pool charges, buying from the pool and redeeming is
    /// profitable: that is the floor working. It must not hurt anyone else.
    function test_Arbitrage_WhenThePoolIsBelowTheRate_IsProfitable_AndHarmsNobody() public {
        vm.warp(_now() + 10 days);
        _fundTreasury(5_000e18); // treasury worth vastly more per TST than the pool price
        assertGt(_rate(), _poolPrice() * 2, "precondition: the pool is well below the redemption rate");

        uint256 stakerEarnedBefore = staking.pendingReward(staker);
        uint256 rateBefore = _rate();
        uint256 holderTstBefore = tst.balanceOf(holder);
        uint256 holderClaimBefore = (tst.balanceOf(holder) * staking.redeemableStock()) / staking.nonBurnedSupply();

        address arb = address(0xA2B);
        stock.transfer(arb, 10e18);
        uint256 stockBefore = stock.balanceOf(arb);
        uint256 bought = _buyTst(arb, 10e18);
        uint256 out = _redeem(arb, bought);
        assertGt(out + 0, 10e18, "the arbitrage is profitable when the pool is below the rate");
        console.log("arbitrage: spent 10 stock, redeemed", out / 1e15, "thousandths");

        // ...and it costs everyone else nothing
        assertEq(staking.pendingReward(staker), stakerEarnedBefore, "stakers' earned rewards are untouched");
        assertGe(_rate() + 1e12, rateBefore, "the rate per TST for the remaining holders did not fall");
        assertEq(tst.balanceOf(holder), holderTstBefore, "other holders' TST is untouched");
        uint256 holderClaimAfter = (tst.balanceOf(holder) * staking.redeemableStock()) / staking.nonBurnedSupply();
        assertGe(holderClaimAfter + 1e12, holderClaimBefore, "a passive holder's claim on the treasury did not shrink");
        assertGt(stock.balanceOf(arb), stockBefore - 1, "the arbitrageur ends with more stock than it started");
    }

    /// @dev Buying at or above the rate and redeeming always loses money.
    function test_BuyThenRedeem_AtOrAboveTheRate_AlwaysLoses() public {
        vm.warp(_now() + 3 days);
        _fundTreasury(1e15); // a tiny treasury: the rate is far below the pool price
        address x = address(0xC01);
        stock.transfer(x, 5e18);
        uint256 before = stock.balanceOf(x);
        uint256 bought = _buyTst(x, 5e18);
        (uint256 q,,) = staking.quoteRedeem(bought);
        assertLt(q, 5e18 / 10, "redeeming what was bought returns a small fraction of what was paid");
        if (q > 0) _redeem(x, bought);
        assertLt(stock.balanceOf(x), before, "a loss");
    }

    // ------------------------------------------------------------------- splitting and dust

    /// @dev Splitting a redemption into pieces lets the redeemer win back a share of their OWN retained cost (it stays in
    /// the treasury and lifts the rate for the pieces that follow, like for any other holder). That is bounded: the
    /// continuous limit is (0.9 / 0.92) * (1 - (1 - f)^0.92) / f times the single-shot payout, which grows with f
    /// and peaks at 1.087x for a holder of the whole supply. This checks the real contract, piece by piece, against an
    /// independent integer reference of the same arithmetic (exact), and against that 1.087x ceiling.
    function test_SplittingARedemptionIntoManyPieces_MatchesTheReferenceAndStaysUnderTheCeiling() public {
        vm.warp(_now() + 3 days);
        _fundTreasury(1_000e18);
        uint256 supply = staking.nonBurnedSupply();
        uint256 redeemable = staking.redeemableStock();
        uint256 total = tst.balanceOf(holder);
        (uint256 single,,) = staking.quoteRedeem(total);

        uint256 pieceSize = total / 50;
        uint256 got;
        for (uint256 i; i < 50; ++i) got += _redeem(holder, pieceSize);

        // independent reference: the same integer arithmetic, run outside the contract
        uint256 r = redeemable;
        uint256 sp = supply;
        uint256 ref;
        for (uint256 i; i < 50; ++i) {
            uint256 gross = (r * pieceSize) / sp;
            uint256 cost = (gross * 1_000 + 9_999) / 10_000; // ceil
            uint256 prot = (gross * 200) / 10_000;
            ref += gross - cost;
            r -= (gross - cost) + prot;
            sp -= pieceSize;
        }
        assertEq(got, ref, "the contract pays exactly what the reference arithmetic says, piece by piece");
        assertGe(got + 1e9, single, "splitting never pays less than one shot");
        assertLe(got, (single * 10_871) / 10_000, "and never more than 1.087x one shot (the whole-supply limit)");
    }

    /// @dev many tiny redemptions cannot beat the formula or leak value through rounding
    function test_DustSpam_CannotLeakValueThroughRounding() public {
        vm.warp(_now() + 3 days);
        _fundTreasury(500e18);
        uint256 redeemableBefore = staking.redeemableStock();
        uint256 supplyBefore = staking.nonBurnedSupply();
        uint256 total = tst.balanceOf(holder);
        uint256 piece = 1e15; // dust-sized pieces
        uint256 got;
        uint256 done;
        for (uint256 i; i < 300; ++i) {
            vm.startPrank(holder);
            tst.approve(address(staking), piece);
            try staking.redeem(piece, 0) returns (uint256 out) {
                got += out;
                ++done;
            } catch {}
            vm.stopPrank();
        }
        // whatever it paid is bounded by the pro rata gross of what was redeemed, with the cost taken
        uint256 redeemedTst = done * piece;
        uint256 grossBound = (redeemableBefore * redeemedTst) / supplyBefore;
        assertLe(got, grossBound + 1e9, "dust redemptions never pay more than the pro rata share");
        assertEq(tst.balanceOf(holder), total - redeemedTst, "exactly the redeemed TST was burned");
    }

    // ------------------------------------------------------------------------------------------ gas

    function test_RedeemGas_IsSmall() public {
        vm.warp(_now() + 3 days);
        _fundTreasury(500e18);
        uint256 amt = tst.balanceOf(holder) / 4;
        vm.startPrank(holder);
        tst.approve(address(staking), amt);
        uint256 g = gasleft();
        staking.redeem(amt, 0);
        uint256 used = g - gasleft();
        vm.stopPrank();
        console.log("gas: redeem:", used);
        assertLt(used, 250_000, "a redemption fits comfortably inside a block");
    }

    // -------------------------------------------------------------- rate cannot be moved from outside

    function test_TradersMovingThePoolCannotMoveTheRate() public {
        vm.warp(_now() + 2 days);
        _fundTreasury(300e18);
        uint256 r0 = _rate();
        address t1 = address(0x77);
        stock.transfer(t1, 200e18);
        _buyTst(t1, 100e18); // pushes TST out of the pool
        // a swap only ever ADDS to the treasury (the cost it pays) and never changes supply, so the rate can only rise
        assertGe(_rate() + 1e9, r0, "trading against the pool never lowers the rate");
    }

    function test_TwapOrOracleFreeByConstruction_TheQuoteDependsOnlyOnTreasuryAndSupply() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(200e18);
        (uint256 q1,,) = staking.quoteRedeem(1_000_000e18);
        // move a lot of stock and TST around in the pool
        address t = address(0x88);
        stock.transfer(t, 500e18);
        _buyTst(t, 400e18);
        (uint256 q2,,) = staking.quoteRedeem(1_000_000e18);
        // the only difference between q1 and q2 is what the swap paid into the treasury (it can only go up)
        assertGe(q2 + 1e9, q1, "trading never lowers what a redemption pays");
    }
}
