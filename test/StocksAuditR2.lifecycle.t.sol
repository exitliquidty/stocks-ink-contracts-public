// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 2, whole-lifecycle scenarios on the real stack: two launches that share one stock token, donating
/// to a curve before graduation, and a search for value stranded anywhere after a full life.
contract StocksAuditR2LifecycleTest is StocksRedemptionAdversarialTest {
    using PoolIdLibrary for PoolKey;

    struct Second {
        IERC20 tst;
        StocksCurve curve;
    }

    function _launchSecond(uint256 price) internal returns (Second memory b) {
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        (address token, address curveAddr) =
            factory.createCurve("Second", "TWO", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        b.tst = IERC20(token);
        b.curve = StocksCurve(curveAddr);
        vm.warp(vm.getBlockTimestamp() + 61); // past the snipe window
    }

    function _buyOnCurve(address who, StocksCurve c, uint256 stockIn) internal returns (uint256 tstOut) {
        vm.startPrank(who);
        stock.approve(address(c), type(uint256).max);
        tstOut = c.buy(stockIn, 0);
        vm.stopPrank();
    }

    function _swap(PoolKey memory k, address who, bool tstIs0, bool buyingTst, uint256 amountIn) internal {
        bool zeroForOne = buyingTst ? !tstIs0 : tstIs0;
        vm.startPrank(who);
        IERC20 inToken = IERC20(Currency.unwrap(zeroForOne ? k.currency0 : k.currency1));
        inToken.approve(address(swapRouter), amountIn);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------ isolation

    /// @notice Two launches share the same stock token and the same hook. Everything one pool does (swaps, a TWAMM
    /// liquidation, its treasury being funded and redeemed against) must leave the other pool's reserves, price, treasury
    /// and orders exactly as they were.
    function test_TwoPoolsSharingAStock_AreFullyIsolated() public {
        Second memory b = _launchSecond(200e18);
        stock.transfer(holder, 500e18);
        _buyOnCurve(holder, b.curve, 45e18); // pushes it past the graduation target
        b.curve.graduate();
        StocksStaking stakingB = StocksStaking(b.curve.staking());
        PoolKey memory keyB = StocksPoolView(b.curve.pair()).poolKey();
        bool bTstIs0 = Currency.unwrap(keyB.currency0) == address(b.tst);

        (uint112 bR0, uint112 bR1,) = hook.getReserves(keyB.toId());
        uint256 bTreasury = stock.balanceOf(address(stakingB));
        uint256 bSupply = stakingB.nonBurnedSupply();

        // heavy activity on pool A: swaps both ways, a funded treasury, a liquidation, a redemption
        vm.warp(_now() + 2 days);
        _buyTst(trader, 20e18);
        _fundTreasury(200e18);
        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(curve.governor());
        staking.liquidateTreasury(_minLiqIntervals1);
        vm.warp(_now() + 3 hours);
        _buyTst(trader, 5e18);
        vm.warp(_now() + 7 hours);
        hook.executeTWAMMOrders(key);
        staking.claimLiquidatedTst();
        _redeem(holder, tst.balanceOf(holder) / 4);

        (uint112 bR0After, uint112 bR1After,) = hook.getReserves(keyB.toId());
        assertEq(bR0After, bR0, "pool B's protocol reserve0 untouched by pool A's activity");
        assertEq(bR1After, bR1, "pool B's protocol reserve1 untouched by pool A's activity");
        assertEq(stock.balanceOf(address(stakingB)), bTreasury, "pool B's treasury untouched");
        assertEq(stakingB.nonBurnedSupply(), bSupply, "pool B's supply untouched");

        // and the other way round: activity on B must not move A
        (uint112 aR0, uint112 aR1,) = hook.getReserves(key.toId());
        uint256 aTreasury = stock.balanceOf(address(staking));
        uint256 aSupply = staking.nonBurnedSupply();
        stock.transfer(address(stakingB), 100e18);
        stakingB.notifyRewardAmount();
        stock.transfer(trader, 50e18);
        _swap(keyB, trader, bTstIs0, true, 10e18);
        uint256 _minLiqIntervals2 = stakingB.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(b.curve.governor());
        stakingB.liquidateTreasury(_minLiqIntervals2);
        vm.warp(_now() + 5 hours);
        hook.executeTWAMMOrders(keyB);
        (uint112 aR0After, uint112 aR1After,) = hook.getReserves(key.toId());
        assertEq(aR0After, aR0, "pool A's reserve0 untouched by pool B's activity");
        assertEq(aR1After, aR1, "pool A's reserve1 untouched by pool B's activity");
        assertEq(stock.balanceOf(address(staking)), aTreasury, "pool A's treasury untouched");
        assertEq(staking.nonBurnedSupply(), aSupply, "pool A's supply untouched");
    }

    // ------------------------------------------------------------------------------------ graduation donations

    /// @notice Graduation seeds the pool with ALL the stock the curve holds but prices the TST side from the stock it
    /// COLLECTED. A donor who sends extra stock to the curve just before graduation therefore skews the pool's opening
    /// price in TST's favour, and could hope to sell TST bought earlier into that skew for a profit. Checked for donations
    /// from nothing to a full graduation target: the donor must always lose.
    function test_DonatingStockToTheCurve_BeforeGraduation_NeverProfitsTheDonor() public {
        uint256[6] memory donations = [uint256(0), 1e18, 5e18, 20e18, 40e18, 200e18];
        uint256 poolStockWithoutDonation;
        for (uint256 i = 0; i < donations.length; i++) {
            uint256 snap = vm.snapshotState();
            Second memory b = _launchSecond(200e18);
            address donor = address(0xD00);
            stock.transfer(donor, 1_000e18);
            uint256 startStock = stock.balanceOf(donor);

            uint256 got = _buyOnCurve(donor, b.curve, 41e18); // reaches the target on its own
            if (donations[i] > 0) {
                vm.prank(donor);
                stock.transfer(address(b.curve), donations[i]);
            }
            uint256 poolStockBefore = stock.balanceOf(address(pm));
            b.curve.graduate();
            PoolKey memory kB = StocksPoolView(b.curve.pair()).poolKey();
            bool tstIs0 = Currency.unwrap(kB.currency0) == address(b.tst);
            // graduation seeds the pool with everything the curve holds, so a donation lands in the POOL (not the treasury)
            uint256 poolStockGained = stock.balanceOf(address(pm)) - poolStockBefore;
            if (i == 0) poolStockWithoutDonation = poolStockGained;
            else assertApproxEqAbs(poolStockGained, poolStockWithoutDonation + donations[i], 1e6, "the donation is seeded into the pool");
            assertLt(stock.balanceOf(address(StocksStaking(b.curve.staking()))), 1e15, "and none of it went to the treasury");
            _swap(kB, donor, tstIs0, false, got);

            int256 net = int256(stock.balanceOf(donor)) - int256(startStock);
            console.log("donation (stock wei) and donor's net result:", donations[i]);
            console.logInt(net);
            assertLt(net, 0, "donating and selling into the skew never profits");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------------------------ stranded value

    /// @notice After a complete life (curve, graduation, trades, a funded treasury, a liquidation, a redemption, claims)
    /// the plumbing contracts must hold nothing: no stock or TST stranded in the factory, graduator, governor or curve.
    function test_AfterAFullLife_NothingIsStrandedInThePlumbing() public {
        vm.warp(_now() + 2 days);
        _buyTst(trader, 30e18);
        _fundTreasury(150e18);
        uint256 _minLiqIntervals3 = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(curve.governor());
        staking.liquidateTreasury(_minLiqIntervals3);
        vm.warp(_now() + 4 hours);
        _buyTst(trader, 3e18);
        vm.warp(_now() + 9 hours);
        staking.claimLiquidatedTst();
        _redeem(holder, tst.balanceOf(holder) / 3);
        vm.prank(staker);
        staking.claim();

        address[5] memory plumbing =
            [address(factory), address(graduator), curve.governor(), address(curve), address(swapRouter)];
        string[5] memory names = ["factory", "graduator", "governor", "curve", "swap router"];
        for (uint256 i = 0; i < plumbing.length; i++) {
            console.log(names[i]);
            console.log("  stock:", stock.balanceOf(plumbing[i]));
            console.log("  tst:  ", tst.balanceOf(plumbing[i]));
            assertEq(stock.balanceOf(plumbing[i]), 0, "no stock stranded");
            // the curve keeps no TST either once graduated (the unsold part was burned or seeded)
            assertEq(tst.balanceOf(plumbing[i]), 0, "no TST stranded");
        }
        // the hook holds only stock still owed to the order or the protocol reserve, never more than the pool books
        (uint112 r0, uint112 r1,) = hook.getReserves(key.toId());
        console.log("hook reserve0/1:", uint256(r0), uint256(r1));
    }

    /// @notice The economics a launch is registered with are exactly the documented ones: a 10% flywheel, of which the
    /// protocol keeps 20% (2% of the trade), and the hook's small reserve buffer. Pinned so a change to any constant is caught.
    function test_TheRegisteredEconomics_AreExactlyTheDocumentedOnes() public view {
        assertEq(hook.feeBps(key.toId()), 1000, "10% flywheel registered for the pool");
        assertEq(curve.FEE_BPS(), 1000, "the curve registers a 10% flywheel");
        assertEq(hook.PROTOCOL_FEE_SHARE_BPS(), 2000, "the protocol keeps 20% of the flywheel");
        assertEq(graduator.HOOK_TST_RESERVE_WEI(), 100e18, "100 TST reserve buffer");
        assertEq(graduator.HOOK_STOCK_RESERVE_WEI(), 1e12, "1e12 stock reserve buffer");
        assertEq(graduator.MIN_TST_SEED_SUPPLY_BPS(), 100, "the pool is seeded with at least 1% of the supply");
        assertEq(curve.QUORUM_NUMERATOR(), 10, "10% quorum");
        assertEq(curve.SNIPE_WINDOW(), 60, "60 second snipe window");
        assertEq(curve.MAX_SNIPE_BUY_BPS(), 500, "5% per-address cap in the window");
        assertEq(curve.CURVE_SUPPLY(), 800_000_000e18, "80% of the supply is sold on the curve");
        assertEq(curve.VIRTUAL_RESERVE_DIVISOR(), 3);
        // AuditAgent finding #8 (2026-09-30): lowered from 9,900 to 9,700 -- at 99%, `remaining`
        // (8,000,000e18 TST) was already below the graduator's 10,000,000e18 TST minimum seed, so the
        // sold-out path was mathematically guaranteed to revert SeedTooSmall at its own trigger point.
        // See test/AuditAgentVerify.soldoutSeedConflict.t.sol.
        assertEq(curve.SOLDOUT_THRESHOLD_BPS(), 9_700);
        assertEq(curve.PRICE_MAX_AGE(), 5 minutes);
    }

    // ------------------------------------------------------------------------------------ shared-stock reserve solvency

    /// @notice Fund-custody deep dive: `test_TwoPoolsSharingAStock_AreFullyIsolated` above proves pool-level state
    /// (AMM reserves, treasury, supply) is isolated when two pools share a stock token. What it does NOT directly
    /// check: `StocksGraduator.HOOK_STOCK_RESERVE_WEI` is a fixed amount (1e12 wei) transferred to the hook PER
    /// GRADUATION, but the hook holds it as one undifferentiated ERC20 balance of the shared stock token -- not a
    /// per-pool-earmarked sub-account. If two pools share that stock token, their two reserve contributions sit in
    /// the SAME pot. The real question: can heavy, adversarial TWAMM activity on ONE pool (maximizing rounding-
    /// shortfall exposure) ever draw the hook's shared stock-token balance down far enough that the OTHER pool's
    /// own, completely unrelated, legitimate TWAMM obligations become under-collateralized?
    function test_HeavyTwammStressOnOnePool_NeverUnderminesAnotherPoolsSharedStockReserve() public {
        Second memory b = _launchSecond(200e18);
        stock.transfer(holder, 500e18);
        _buyOnCurve(holder, b.curve, 45e18);
        b.curve.graduate();
        PoolKey memory keyB = StocksPoolView(b.curve.pair()).poolKey();
        bool bTstIs0 = Currency.unwrap(keyB.currency0) == address(b.tst);

        // Pool B: one small, completely ordinary TWAMM order SELLING TST FOR STOCK -- the direction whose
        // claimant is owed the SHARED stock currency, the actual thing at risk of cross-pool depletion. Bought
        // honestly on pool B's own real pool first (not the curve -- already graduated).
        address bUser = address(0xB05E);
        stock.transfer(bUser, 100e18);
        _swap(keyB, bUser, bTstIs0, true, 20e18); // buy TST with stock on pool B
        uint256 bTstHeld = b.tst.balanceOf(bUser);
        vm.startPrank(bUser);
        b.tst.approve(address(hook), type(uint256).max);
        (, ITWAMM.OrderKey memory bOrderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: keyB, zeroForOne: bTstIs0, duration: 24 hours, amountIn: bTstHeld})
        );
        vm.stopPrank();

        // Pool A: adversarial, maximally fragmented TWAMM activity, same SELL-TST-FOR-STOCK direction so its
        // claimant is owed the SHARED stock currency too -- many tiny staggered orders across many distinct
        // expiration intervals, deliberately shaped to maximize rounding-shortfall exposure (the same shape
        // round 14's gas-griefing finding used), all executed via real catch-ups over real elapsed time.
        address aAttacker = address(0xA77AC4);
        stock.transfer(aAttacker, 1_000e18);
        _swap(key, aAttacker, tstIsCurrency0, true, 500e18); // buy a large TST stash with stock on pool A
        vm.startPrank(aAttacker);
        tst.approve(address(hook), type(uint256).max);
        for (uint256 i = 1; i <= 30; i++) {
            hook.submitOrder(
                ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e15})
            );
            vm.warp(_now() + 1 hours);
            hook.executeTWAMMOrders(key);
        }
        vm.stopPrank();
        vm.warp(_now() + 35 hours);
        hook.executeTWAMMOrders(key);

        // Pool B's order runs its own course, unrelated to any of the above, and must still be exactly, fully
        // claimable -- the real, load-bearing test of "reserve isolation" that matters for fund custody.
        vm.warp(_now() + 24 hours);
        hook.executeTWAMMOrders(keyB);
        vm.prank(bUser);
        hook.sync(ITWAMM.SyncParams({key: keyB, orderKey: bOrderKey}));

        Currency stockCurrency = Currency.wrap(address(stock));
        uint256 bOwedStockBeforeClaim = hook.tokensOwed(stockCurrency, bUser);
        console.log("pool B's claimant owed (stock wei), before claiming:", bOwedStockBeforeClaim);
        assertGt(bOwedStockBeforeClaim, 0, "sanity: pool B's order must actually be owed real stock");

        vm.prank(bUser);
        (uint256 claimed0, uint256 claimed1) = hook.claimTokensByPoolKey(keyB);
        uint256 stockClaimed = bTstIs0 ? claimed1 : claimed0;
        console.log("pool B's real, uninterfered claim from its own order (stock wei):", stockClaimed);
        assertEq(stockClaimed, bOwedStockBeforeClaim, "pool B's claim paid out exactly what was owed, unaffected by pool A's stress");

        // The actual load-bearing global solvency check, computed across BOTH pools' known claimants for the
        // SHARED stock currency -- exactly invariant_HookBacksWhatItOwes's own shape, extended to a real
        // two-pool, shared-token scenario under maximal one-sided adversarial stress. Checked BEFORE bUser's
        // claim above too (already implicitly, since the claim succeeded and paid exactly what was owed) and
        // again here afterward, to also confirm the hook is still solvent going forward for pool A's own
        // still-live claimants.
        uint256 totalOwedStock = hook.tokensOwed(stockCurrency, address(staking)) + hook.tokensOwed(stockCurrency, aAttacker)
            + hook.tokensOwed(stockCurrency, bUser) + hook.tokensOwed(stockCurrency, address(this));
        uint256 hookStockBalance = stock.balanceOf(address(hook));
        console.log("hook's shared stock balance, total owed across both pools (after B's claim):", hookStockBalance, totalOwedStock);
        assertLe(totalOwedStock, hookStockBalance + 1e12, "the hook's shared stock reserve still backs everything owed across both pools");
    }
}
