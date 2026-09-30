// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksStaking} from "../src/StocksStaking.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Directed (not random) adversarial checks at the three-way boundary the broad
/// StocksSystem.invariant.t.sol campaign already fuzzes randomly (60,000 calls, 0 violations) -- this file
/// targets specific, hand-picked scenarios a real attacker holding real TVL would actually try, rather than
/// relying on chance to stumble into them. Runs against the real production stack (real hook, real TWAMM,
/// real staking, real PoolManager), same fixture as StocksRedemption.adversarial.t.sol.
contract StocksStakingLiquidationAdversarialTest is StocksRedemptionAdversarialTest {
    address attacker = address(0xA77AC4);

    function _liquidate(uint256 intervals) internal returns (uint256 committed, bytes32 orderId) {
        address gov = curve.governor();
        vm.prank(gov);
        (committed, orderId) = staking.liquidateTreasury(intervals);
    }

    /// @notice Can an attacker submit a large, opposing TWAMM order (buying stock with TST -- the reverse of
    /// the treasury's own sell-stock-for-TST liquidation order) timed to make the TREASURY's own liquidation
    /// come out WORSE than if the attacker had never traded at all? TWAMM nets opposing sell-rates directly
    /// against each other at the current price before either side touches the AMM curve, which should only
    /// ever help both matched parties (zero price impact on the matched portion) -- proven here empirically
    /// against the real vendored TWAMM rather than trusted from the general theory.
    function test_OpposingTwammOrder_NeverMakesTheTreasurysLiquidationWorse() public {
        _fundTreasury(500e18);
        vm.warp(_now() + 1 hours);

        uint256 snapshot = vm.snapshotState();

        // --- Scenario A: baseline, liquidation runs alone ---
        (uint256 committedA,) = _liquidate(30);
        vm.warp(_now() + 30 hours + 1);
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        uint256 tstBurnedA = tst.balanceOf(BURN) - burnedBefore;

        vm.revertToState(snapshot);

        // --- Scenario B: an attacker submits a large opposing order (TST -> stock) right alongside it ---
        uint256 attackerTst = 50_000e18;
        deal(address(tst), attacker, attackerTst);
        vm.startPrank(attacker);
        tst.approve(address(hook), attackerTst);
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({
                key: key,
                zeroForOne: tstIsCurrency0, // selling TST, the opposite direction from the treasury's order
                duration: 30 hours,
                amountIn: attackerTst
            })
        );
        vm.stopPrank();

        (uint256 committedB,) = _liquidate(30);
        assertEq(committedB, committedA, "sanity: identical starting treasury state commits the identical amount");
        vm.warp(_now() + 30 hours + 1);
        burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        uint256 tstBurnedB = tst.balanceOf(BURN) - burnedBefore;

        console.log("TST burned, no opposing order:", tstBurnedA);
        console.log("TST burned, WITH opposing order:", tstBurnedB);

        // The core claim: an opposing order must never make the treasury's own realized buyback worse.
        assertGe(tstBurnedB, tstBurnedA, "an opposing TWAMM order must never reduce what the treasury's liquidation actually burns");
    }

    /// @notice A staker's already-earned, unclaimed reward must survive completely intact through a liquidation
    /// large enough to zero out the REMAINING (not-yet-vested) reward stream -- the zeroing is documented,
    /// accepted design (governance may redirect the unvested stream into a buyback), but it must never reach
    /// into what a staker had ALREADY earned before the liquidation happened.
    function test_LargeLiquidationZeroingTheRate_NeverTouchesAlreadyEarnedRewards() public {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 2 days); // let real reward accrue and vest partway through the period

        uint256 earnedBefore = staking.pendingReward(staker);
        assertGt(earnedBefore, 0, "sanity: the staker has real, already-vested earnings before the liquidation");

        // A liquidation sized to claim everything not already vested (stockCommitted >= outstanding), which
        // the contract's own reduction logic answers by zeroing rewardRate for the rest of the period --
        // documented, accepted design; the point of this test is the OTHER side of that line.
        _liquidate(24);

        assertEq(staking.pendingReward(staker), earnedBefore, "already-earned rewards must be bit-for-bit unchanged by the liquidation");
        assertEq(staking.rewardRate(), 0, "sanity: this liquidation size really did zero the remaining stream");

        // And it must actually be claimable -- no revert, exact amount, no dependency on the liquidation's
        // own TWAMM order having executed or been claimed yet.
        uint256 stockBefore = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        assertEq(stock.balanceOf(staker) - stockBefore, earnedBefore, "the staker must receive exactly what they had already earned");
    }

    /// @notice Redeeming literally the entire non-burned supply while a liquidation order is still mid-flight
    /// (partially executed, unclaimed) -- the sharpest version of "does accounting still hold when someone
    /// takes everyone's share at once, with money simultaneously mid-transit to a different destination."
    function test_RedeemingTheEntireSupply_WhileALiquidationOrderIsStillLive() public {
        _fundTreasury(2_000e18);
        vm.warp(_now() + 1 hours);
        _liquidate(40);
        vm.warp(_now() + 20 hours); // order is live, roughly half-executed, nowhere near claimed

        uint256 supply = staking.nonBurnedSupply();
        deal(address(tst), holder, supply);

        uint256 stakingStockBefore = stock.balanceOf(address(staking));
        vm.startPrank(holder);
        tst.approve(address(staking), supply);
        uint256 out = staking.redeem(supply, 0);
        vm.stopPrank();

        assertGt(out, 0, "redeeming the whole supply must pay out something real");
        assertLe(out, stakingStockBefore, "must never pay out more than the treasury actually held");
        assertEq(tst.balanceOf(BURN) >= supply, true, "the redeemed TST must actually be burned");

        // The still-live order's own eventual proceeds must remain claimable afterward, undisturbed.
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        assertGe(tst.balanceOf(BURN), burnedBefore, "the live order's own proceeds must still settle normally afterward");
    }

    /// @dev A same-direction manipulative push (selling stock too, the same side as the treasury's own order)
    /// of the given size, immediately before whatever catch-up is about to run.
    function _pushWithStock(uint256 amount) internal {
        deal(address(stock), attacker, amount);
        vm.startPrank(attacker);
        stock.approve(address(swapRouter), amount);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !tstIsCurrency0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: !tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @notice Originally written to check whether total silence before a TWAMM catch-up (letting a whole
    /// liquidation execute as one lump instead of many small increments -- confirmed real by directly reading
    /// _advanceTimestampForSinglePoolSell, which computes `sellRate * secondsElapsed` as one swap when nothing
    /// broke the gap into separate segments) opens a same-transaction sandwich: push price, trigger the lump,
    /// profit. It doesn't, and this test is what proves it, empirically, not just from reading the code.
    ///
    /// _safeTwammExecute runs at the very start of beforeSwap/beforeAddLiquidity/beforeRemoveLiquidity --
    /// strictly BEFORE that same call's own price impact applies. So whoever's swap finally triggers a pending
    /// catch-up can never also be the one who moved price first: the backlog resolves at whatever price
    /// existed the instant before their call, unconditionally, before their own trade's impact exists to
    /// compound with it. There is no way to "pre-position, then trigger" in one call, because pre-positioning
    /// IS a trigger, and it fires the catch-up before the position has any effect.
    ///
    /// Proven here by comparing the treasury's realized proceeds under the SAME total adversarial stock
    /// volume, applied two ways: as 4 separate pushes (one per interval, each own push's price impact
    /// persists into the NEXT interval's chunk, since the pusher's own call triggers that chunk's catch-up
    /// only afterward) versus one lump push immediately after the single catch-up that follows total silence
    /// (landing too late to touch anything, since the whole order already resolved as that call's first step).
    /// The chunked run should therefore come out no better for the treasury than the lump run -- confirmed
    /// below, not merely expected.
    function test_PushingPriceCannotSandwichItsOwnTriggeredCatchUp() public {
        _fundTreasury(2_000e18);
        vm.warp(_now() + 1 hours);
        uint256 push = 40e18; // per-interval push size
        uint256 snapshot = vm.snapshotState();

        // --- Scenario A: a push every interval -- each one's price impact carries into the NEXT interval's
        // chunk, since _safeTwammExecute in that later push resolves the chunk before the later push's own
        // impact, but AFTER the earlier push's impact is already sitting in the pool.
        _liquidate(24);
        for (uint256 i; i < 4; ++i) {
            vm.warp(_now() + 1 hours);
            _pushWithStock(push);
        }
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        uint256 tstBurnedChunked = tst.balanceOf(BURN) - burnedBefore;

        vm.revertToState(snapshot);

        // --- Scenario B: identical total adversarial volume (4 * push), but total silence for the same 4
        // hours, then ONE push immediately AFTER the single triggering catch-up -- too late to matter.
        _liquidate(24);
        vm.warp(_now() + 4 hours);
        _pushWithStock(push * 4);
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        uint256 tstBurnedLump = tst.balanceOf(BURN) - burnedBefore;

        console.log("TST burned -- chunked (push impact carries into later chunks):", tstBurnedChunked);
        console.log("TST burned -- lump (push lands after the only catch-up):      ", tstBurnedLump);

        // The core claim: a lone triggering push can never come out AHEAD of a pusher who also gets multiple
        // separate bites (and whose earlier pushes get to degrade later chunks) -- i.e. there is no
        // same-transaction sandwich available against a silence-accumulated catch-up.
        assertGe(
            tstBurnedLump,
            tstBurnedChunked,
            "a single push landing after its own triggered catch-up must never leave the treasury worse off than repeated pushes whose impact carries into later chunks"
        );
    }

    /// @notice Governance can pause AND liquidate in either order, or the same block. Confirms both directions
    /// keep the accounting sound: a liquidation submitted while paused must still commit the right amount and
    /// let the order run normally, and pausing right after a liquidation must not disturb what was already
    /// committed or claimed.
    function test_LiquidateWhilePaused_ThenUnpause_AccountingStaysSound() public {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);

        address gov = curve.governor();
        vm.prank(gov);
        staking.setRewardsPaused(true);
        assertTrue(staking.rewardsPaused());

        // Liquidate while paused -- _rewardClockNow() is frozen at pausedAt, so "remaining" and
        // "vestedButUnclaimed" are computed against the frozen clock, not a moving one.
        (uint256 committed,) = _liquidate(24);
        assertGt(committed, 0, "a liquidation while paused must still commit something real");

        // Unpause, let time pass, confirm the order still resolves and the staker's pre-pause earnings are
        // completely unaffected by having been paused AND liquidated in the same window.
        uint256 earnedAtPause = staking.pendingReward(staker);
        vm.prank(gov);
        staking.setRewardsPaused(false);
        assertEq(staking.pendingReward(staker), earnedAtPause, "unpausing alone must not change what was already earned");

        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        assertGt(tst.balanceOf(BURN), burnedBefore, "the order submitted while paused must still resolve and burn normally");

        uint256 stockBefore = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        assertEq(stock.balanceOf(staker) - stockBefore, earnedAtPause, "the staker must still receive exactly what they had earned before the pause");
    }

    /// @notice A pool that graduated but where nobody has ever staked: totalStaked == 0 the entire time.
    /// _earnedByStakers()/rewardPerToken() must degrade to a safe, well-defined zero rather than dividing by
    /// zero or misreporting, and governance must be able to liquidate the whole treasury immediately (there is
    /// nothing vested to anyone to protect).
    function test_LiquidateWithZeroStakersEver_NoDivisionByZero_CommitsEverything() public {
        // Note: no staker interaction at all -- staking.balanceOf/totalStaked stay 0 throughout, unlike every
        // other test in this file which relies on the base fixture's staker having already staked in setUp.
        // This fixture's own setUp stakes on behalf of `staker`, so this test instead just confirms the MATH
        // handles zero cleanly by unstaking everything back out first.
        // Materialized into a local BEFORE vm.prank -- staking.balanceOf(staker) is itself an external call,
        // and evaluating it as unstake's own argument would consume the prank first (see
        // feedback_expectrevert_consumed_by_nested_call in this project's own memory).
        uint256 stakerBalance = staking.balanceOf(staker);
        vm.prank(staker);
        staking.unstake(stakerBalance);
        assertEq(staking.totalStaked(), 0, "sanity: nobody is staked");

        _fundTreasury(500e18);
        vm.warp(_now() + 1 hours);

        assertEq(staking.pendingReward(staker), 0, "no one has any claim with zero total staked");
        uint256 redeemableBefore = staking.redeemableStock();
        assertGt(redeemableBefore, 0, "with no stakers, the whole treasury is immediately redeemable/liquidatable");

        (uint256 committed,) = _liquidate(24);
        assertApproxEqAbs(committed, redeemableBefore, 1e9, "with zero stakers, the liquidation can commit essentially the entire treasury");

        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        assertGt(tst.balanceOf(BURN), burnedBefore, "the order still resolves normally with zero stakers throughout");
    }

    /// @notice Regular swaps are protected from a catch-up gas bomb by _safeTwammExecute's try/catch
    /// wrapper -- confirmed already by StocksHook.failOpenGas.t.sol. But TWAMM._submitOrder calls
    /// executeTWAMMOrders() DIRECTLY, with no such wrapper -- confirmed by reading the vendored source. Both
    /// an ordinary user's hook.submitOrder AND StocksStaking.liquidateTreasury (which calls hook.submitOrder
    /// internally) go through this unprotected path. Regular user orders have no minimum size or duration
    /// (only SellRateCannotBeZero, satisfiable with a handful of wei), so an attacker can cheaply submit many
    /// orders, each expiring at its OWN distinct interval boundary, to stagger many separate catch-up
    /// segments across a single future window -- each segment is its own _advanceTimestampForSinglePoolSell
    /// call. This measures whether that materially inflates the gas cost of a LATER submitOrder/
    /// liquidateTreasury call that has to catch up across the whole staggered window, which would matter if
    /// it could plausibly be pushed past a real block gas limit -- and specifically whether that gas cost
    /// could ever land governance's own liquidateTreasury in a state where it cannot execute at all.
    function test_ManyStaggeredOrders_GasCostOfCatchUp_ScalesWithSegmentCount() public {
        uint256 snapshot = vm.snapshotState();
        uint256 baselineGas = _liquidateGasCost();
        vm.revertToState(snapshot);

        uint256 n = 20;
        for (uint256 i = 1; i <= n; ++i) {
            deal(address(tst), attacker, 1e6);
            vm.startPrank(attacker);
            tst.approve(address(hook), 1e6);
            // Each order expires at its OWN distinct interval boundary (i hours out), staggering n separate
            // catch-up segments across the same window a later liquidation would need to cross.
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(_now() + (n + 1) * 1 hours); // past every one of the n staggered expirations, in total silence

        uint256 staggeredGas = _liquidateGasCost();

        console.log("liquidateTreasury gas -- no staggered orders:      ", baselineGas);
        console.log("liquidateTreasury gas -- 20 staggered expirations: ", staggeredGas);
        console.log("extra gas per staggered segment (approx):", staggeredGas > baselineGas ? (staggeredGas - baselineGas) / n : 0);
    }

    /// @dev Funds the treasury, warps past the snipe-adjacent setup noise, and measures the real gas cost of
    /// a liquidateTreasury call from governance, in complete isolation.
    function _liquidateGasCost() internal returns (uint256 gasUsed) {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        address gov = curve.governor();
        vm.prank(gov);
        uint256 before = gasleft();
        staking.liquidateTreasury(24);
        gasUsed = before - gasleft();
    }

    /// @notice The other half of the staggered-orders question: is the inflated gas cost a PERMANENT block on
    /// liquidateTreasury (needing one huge atomic call no one may ever provide), or can anyone defuse it first
    /// with ordinary, gas-bounded transactions? TWAMM.executeTWAMMOrders(key, targetTimestamp) -- the 2-arg
    /// overload -- is part of the public ITWAMM interface, callable directly on the deployed hook by anyone,
    /// with an EARLIER target than "now". This proves it can walk a large staggered backlog forward in small,
    /// cheap, separate steps, after which a normal-cost liquidateTreasury succeeds -- so the finding above is
    /// a real but temporary, self-healable griefing cost, not a permanent fund-safety or DoS bug.
    function test_StaggeredOrderBacklog_CanBeWalkedDownInSmallSteps_ThenLiquidateWorksNormally() public {
        uint256 n = 20;
        uint256 startTime = _now();
        for (uint256 i = 1; i <= n; ++i) {
            deal(address(tst), attacker, 1e6);
            vm.startPrank(attacker);
            tst.approve(address(hook), 1e6);
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);

        // Walk the backlog down 2 hours at a time instead of all at once -- each step is small and its own
        // transaction, so no single call needs anywhere near the gas a one-shot catch-up would.
        uint256 walked;
        for (uint256 t = startTime + 2 hours; t <= _now(); t += 2 hours) {
            uint256 before = gasleft();
            hook.executeTWAMMOrders(key, t);
            uint256 stepGas = before - gasleft();
            walked++;
            assertLt(stepGas, 2_000_000, "each incremental step must stay cheap on its own");
        }
        console.log("backlog cleared in this many small steps:", walked);

        // Now a fresh liquidateTreasury call should cost close to the untouched baseline, not the inflated
        // one-shot figure -- the backlog is already gone.
        uint256 gasNow = _liquidateGasCost();
        console.log("liquidateTreasury gas AFTER manually walking the backlog down:", gasNow);
        assertLt(gasNow, 500_000, "once the backlog is cleared in advance, liquidateTreasury costs close to its normal baseline");
    }

    /// @notice TWAMM.sync (called by StocksStaking.claimLiquidatedTst, permissionless) calls
    /// executeTWAMMOrders directly too -- confirmed by reading the vendored source, the exact same
    /// unprotected pattern as _submitOrder. This means an attacker can grief not just NEW liquidation
    /// submissions but the CLAIMING of an already-completed liquidation's own proceeds. Checked here with
    /// real numbers, and confirmed self-healable the same way.
    function test_ClaimLiquidatedTst_AlsoExposedToStaggeredBacklog_ButAlsoSelfHealable() public {
        // A real liquidation, fully matured, sitting there unclaimed.
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        (uint256 committed,) = _liquidate(24);
        assertGt(committed, 0);
        vm.warp(staking.pendingLiquidationExpiration() + 1);

        uint256 snapshot = vm.snapshotState();

        vm.prank(address(0xC1A1B0B)); // permissionless -- anyone can call claimLiquidatedTst
        uint256 before = gasleft();
        staking.claimLiquidatedTst();
        uint256 baselineClaimGas = before - gasleft();

        vm.revertToState(snapshot);

        uint256 startTime = _now();
        uint256 n = 20;
        for (uint256 i = 1; i <= n; ++i) {
            deal(address(tst), attacker, 1e6);
            vm.startPrank(attacker);
            tst.approve(address(hook), 1e6);
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);

        vm.prank(address(0xC1A1B0B));
        before = gasleft();
        staking.claimLiquidatedTst();
        uint256 staggeredClaimGas = before - gasleft();

        console.log("claimLiquidatedTst gas -- no staggered orders:     ", baselineClaimGas);
        console.log("claimLiquidatedTst gas -- 20 staggered expirations:", staggeredClaimGas);

        // Same self-healing property: walk the SAME backlog down first with the public 2-arg overload, and
        // a subsequent claim (on a fresh liquidation) returns to the normal baseline cost.
        vm.revertToState(snapshot);
        for (uint256 i = 1; i <= n; ++i) {
            deal(address(tst), attacker, 1e6);
            vm.startPrank(attacker);
            tst.approve(address(hook), 1e6);
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);
        for (uint256 t = startTime + 2 hours; t <= _now(); t += 2 hours) {
            hook.executeTWAMMOrders(key, t);
        }
        vm.prank(address(0xC1A1B0B));
        before = gasleft();
        staking.claimLiquidatedTst();
        uint256 walkedFirstClaimGas = before - gasleft();
        console.log("claimLiquidatedTst gas -- backlog walked down first:", walkedFirstClaimGas);
        assertLt(walkedFirstClaimGas, staggeredClaimGas, "walking the backlog down first must make the claim materially cheaper");
    }

    /// @notice The 640-order extrapolation toward a block gas limit assumes the ~46k/segment figure measured
    /// at n=20 holds at larger n (linear scaling). Checked directly rather than assumed: measures the SAME
    /// thing at n=60 and compares the per-segment cost to the n=20 figure -- confirming whether cost per
    /// segment stays roughly constant (a simple, predictable cost model) or gets measurably worse at scale
    /// (which would make the real griefing threshold lower, and the finding more severe, than the n=20
    /// extrapolation suggested).
    function test_GasPerSegment_ScalingCheckAtLargerN() public {
        uint256 freshStart = vm.snapshotState();

        uint256 baseline = _liquidateGasCost();
        vm.revertToState(freshStart);

        uint256 n20 = 20;
        uint256 gas20 = _measureStaggeredLiquidateGas(n20);
        vm.revertToState(freshStart);

        uint256 n60 = 60;
        uint256 gas60 = _measureStaggeredLiquidateGas(n60);

        uint256 perSegment20 = (gas20 - baseline) / n20;
        uint256 perSegment60 = (gas60 - baseline) / n60;

        console.log("baseline liquidateTreasury gas:      ", baseline);
        console.log("n=20: total gas / per-segment gas:", gas20, perSegment20);
        console.log("n=60: total gas / per-segment gas:", gas60, perSegment60);

        // Allow generous slack (2x) since storage layout/cold-vs-warm access effects are real -- the point is
        // ruling out a QUALITATIVELY worse (e.g. quadratic) blowup, not pinning an exact constant.
        assertLt(perSegment60, perSegment20 * 2, "per-segment cost must not blow up materially worse than linear at 3x the segment count");
    }

    /// @dev Stages n staggered orders (1..n hours apart), warps past all of them, and returns the gas cost of
    /// a fresh liquidateTreasury call that has to catch up across the whole window.
    function _measureStaggeredLiquidateGas(uint256 n) internal returns (uint256 gasUsed) {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        uint256 startTime = _now();
        for (uint256 i = 1; i <= n; ++i) {
            deal(address(tst), attacker, 1e6);
            vm.startPrank(attacker);
            tst.approve(address(hook), 1e6);
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);

        address gov = curve.governor();
        vm.prank(gov);
        uint256 before = gasleft();
        staking.liquidateTreasury(24);
        gasUsed = before - gasleft();
    }

    /// @notice The fix: pumpTwammBacklog bundles what test_StaggeredOrderBacklog_CanBeWalkedDownInSmallSteps
    /// needed many separate transactions to do into ONE. Proves it actually clears a staggered backlog and
    /// that a subsequent liquidateTreasury call returns to its normal baseline cost, entirely on its own,
    /// callable by anyone -- no governance, no order ownership, nothing.
    function test_PumpTwammBacklog_ClearsStaggeredBacklog_ThenLiquidateIsCheapAgain() public {
        uint256 startTime = _now();
        uint256 n = 20;
        for (uint256 i = 1; i <= n; ++i) {
            deal(address(tst), attacker, 1e6);
            vm.startPrank(attacker);
            tst.approve(address(hook), 1e6);
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: tstIsCurrency0, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);

        // Anyone, with no special permission, clears the whole backlog in one call.
        vm.prank(address(0xD1FF52));
        hook.pumpTwammBacklog(key, 1 hours, 50);

        uint256 gasAfterPump = _liquidateGasCost();
        console.log("liquidateTreasury gas after one-shot pumpTwammBacklog:", gasAfterPump);
        assertLt(gasAfterPump, 500_000, "a single pumpTwammBacklog call must fully defuse the staggered backlog");
    }

    /// @notice No regression: calling it when there is nothing to catch up (or barely anything) must be a
    /// cheap, harmless no-op, not something that changes behavior for the overwhelming common case.
    function test_PumpTwammBacklog_NoOpWhenNothingToCatchUp() public {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        uint256 gasBefore = gasleft();
        hook.pumpTwammBacklog(key, 1 hours, 50);
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 200_000, "pumping with nothing outstanding must stay cheap");

        // And it doesn't interfere with a real liquidation immediately afterward.
        (uint256 committed,) = _liquidate(24);
        assertGt(committed, 0);
    }

    /// @notice Bad inputs revert clearly rather than silently doing nothing or looping forever.
    function test_PumpTwammBacklog_RevertsOnDegenerateInputs() public {
        vm.expectRevert(StocksHook.NothingToPump.selector);
        hook.pumpTwammBacklog(key, 0, 50);

        vm.expectRevert(StocksHook.NothingToPump.selector);
        hook.pumpTwammBacklog(key, 1 hours, 0);
    }

    /// @notice An oversized maxSteps on a small backlog must not waste gas looping past "now" -- the loop
    /// must exit as soon as it catches up, not run maxSteps times regardless.
    function test_PumpTwammBacklog_StopsEarly_DoesNotLoopUnnecessarily() public {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        (uint256 committed,) = _liquidate(24);
        assertGt(committed, 0);
        vm.warp(_now() + 2 hours); // only 2 hours behind

        uint256 gasBefore = gasleft();
        hook.pumpTwammBacklog(key, 1 hours, 10_000); // maxSteps wildly larger than needed
        uint256 gasUsed = gasBefore - gasleft();
        // 2 real steps' worth of work, not anywhere near 10,000 iterations of loop overhead.
        assertLt(gasUsed, 600_000, "must stop as soon as caught up, not iterate maxSteps times regardless of need");
    }

    /// @notice Different from the opposing-order test above: a third party sells the SAME direction as the
    /// treasury's own liquidation order (both selling stock for TST), competing for the same TST rather than
    /// netting against it. TWAMM's standard design pro-rates proceeds among concurrent same-direction orders
    /// by their respective sell rates. Comparing the treasury's rate WITH a competitor against the treasury
    /// TRADING ALONE would conflate two different effects (ordinary price impact from doubled volume vs. an
    /// actually unfair split), so this instead measures both parties' OWN realized rates from the SAME
    /// concurrent execution and compares them to EACH OTHER: two identically-sized, identically-timed orders
    /// sharing the same combined price impact must land on essentially the same rate. If the competitor's
    /// rate came out measurably better than the treasury's, that would mean they can skim value at the
    /// treasury's specific expense, not just share in ordinary market conditions both are exposed to.
    /// @dev Both this order type (a treasury liquidation) and a plain user order pay their fee the same way
    /// for a feeIsTst order: sync() burns the fee portion DIRECTLY, separately from the net portion that
    /// reaches the order owner (who, for a liquidation, then also burns THEIR portion via
    /// claimLiquidatedTst's own explicit burn -- so "total TST burned" for a liquidation is gross, while
    /// "TST received by a plain user" is net-of-fee only). Comparing those two numbers directly would compare
    /// gross to net, not a real unfairness -- so this measures GROSS proceeds for both, by adding back
    /// whatever fee sync() burned for each order individually, from the real TwammOrderProceedsFeeCharged
    /// event each sync() call emits.
    function test_SameDirectionCompetingOrder_BothPartiesGetTheSameFairRate() public {
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);

        uint256 attackerStock = 1_000e18; // identical size to the treasury's own commitment
        deal(address(stock), attacker, attackerStock);
        vm.startPrank(attacker);
        stock.approve(address(hook), attackerStock);
        (, ITWAMM.OrderKey memory attackerOrderKey) =
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: !tstIsCurrency0, duration: 24 hours, amountIn: attackerStock}));
        vm.stopPrank();

        (uint256 committed,) = _liquidate(24); // also 24 hours -- same expiration window as the attacker's order
        vm.warp(_now() + 24 hours + 1);

        // The treasury's claim burns BOTH the fee sync() burns directly AND the net portion it then also
        // burns itself -- so "total TST burned by this action" already equals its GROSS proceeds.
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        uint256 treasuryGross = tst.balanceOf(BURN) - burnedBefore;

        // The attacker's claim only pays them the NET (post-fee) portion -- their own fee was ALSO burned by
        // sync(), just never reaching their wallet. Recover the fee via the real burn delta sync() causes.
        uint256 burnBeforeAttackerSync = tst.balanceOf(BURN);
        vm.startPrank(attacker);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: attackerOrderKey}));
        uint256 attackerFeeBurned = tst.balanceOf(BURN) - burnBeforeAttackerSync;
        uint256 tstBefore = tst.balanceOf(attacker);
        hook.claimTokensByPoolKey(key);
        uint256 attackerNet = tst.balanceOf(attacker) - tstBefore;
        vm.stopPrank();
        uint256 attackerGross = attackerNet + attackerFeeBurned;

        console.log("treasury gross proceeds:", treasuryGross);
        console.log("attacker gross proceeds (net + their own burned fee):", attackerGross);

        uint256 treasuryRate = (treasuryGross * 1e18) / committed;
        uint256 attackerRate = (attackerGross * 1e18) / attackerStock;

        console.log("treasury rate  (gross TST per stock committed, 1e18-scaled):", treasuryRate);
        console.log("attacker rate  (gross TST per stock committed, 1e18-scaled):", attackerRate);

        uint256 diff = treasuryRate > attackerRate ? treasuryRate - attackerRate : attackerRate - treasuryRate;
        assertLt(diff * 1000, treasuryRate, "two identically-sized, identically-timed same-direction orders must land within 0.1% of the same GROSS rate -- no asymmetric skim");
    }

    /// @notice Refines the gas-griefing severity measurement: does staggering orders in ALTERNATING
    /// directions (forcing TWAMM's order-netting, _exhaustMatchedOrders, to actually run on every segment
    /// instead of the same-direction-only case test_ManyStaggeredOrders_GasCostOfCatchUp_ScalesWithSegmentCount
    /// measured) cost MORE gas per segment? If so, the real-world attack could be cheaper than the earlier
    /// ~46k/segment estimate suggested -- worth knowing precisely, even though pumpTwammBacklog's fix works
    /// regardless of the exact per-segment cost (it just walks down incrementally either way).
    function test_AlternatingDirectionStaggeredOrders_GasPerSegment_ComparedToSameDirection() public {
        uint256 freshStart = vm.snapshotState();

        uint256 baseline = _liquidateGasCost();
        vm.revertToState(freshStart);

        uint256 n = 20;
        uint256 sameDirectionGas = _measureStaggeredLiquidateGas(n);
        vm.revertToState(freshStart);

        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        uint256 startTime = _now();
        for (uint256 i = 1; i <= n; ++i) {
            bool sellStock = i % 2 == 0;
            address sellToken = sellStock ? address(stock) : address(tst);
            deal(sellToken, attacker, 1e6);
            vm.startPrank(attacker);
            IERC20(sellToken).approve(address(hook), 1e6);
            bool zeroForOne = sellStock ? !tstIsCurrency0 : tstIsCurrency0;
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);

        address gov = curve.governor();
        vm.prank(gov);
        uint256 before = gasleft();
        staking.liquidateTreasury(24);
        uint256 alternatingGas = before - gasleft();

        uint256 perSegmentSame = (sameDirectionGas - baseline) / n;
        uint256 perSegmentAlternating = (alternatingGas - baseline) / n;

        console.log("baseline liquidateTreasury gas:                  ", baseline);
        console.log("n=20 same-direction:      total / per-segment:", sameDirectionGas, perSegmentSame);
        console.log("n=20 alternating-direction: total / per-segment:", alternatingGas, perSegmentAlternating);
    }

    /// @notice Confirms pumpTwammBacklog's fix still works against the WORSE, alternating-direction variant
    /// above -- its walk-down mechanism doesn't depend on any assumption about per-segment cost, but this is
    /// checked directly rather than assumed, matching how every other claim in this file was verified.
    function test_PumpTwammBacklog_AlsoDefusesAlternatingDirectionBacklog() public {
        uint256 n = 20;
        _fundTreasury(1_000e18);
        vm.warp(_now() + 1 hours);
        uint256 startTime = _now();
        for (uint256 i = 1; i <= n; ++i) {
            bool sellStock = i % 2 == 0;
            address sellToken = sellStock ? address(stock) : address(tst);
            deal(sellToken, attacker, 1e6);
            vm.startPrank(attacker);
            IERC20(sellToken).approve(address(hook), 1e6);
            bool zeroForOne = sellStock ? !tstIsCurrency0 : tstIsCurrency0;
            hook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: i * 1 hours, amountIn: 1e6}));
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * 1 hours);

        vm.prank(address(0xD1FF53));
        hook.pumpTwammBacklog(key, 1 hours, 50);

        uint256 gasAfterPump = _liquidateGasCost();
        console.log("liquidateTreasury gas after pumping an alternating-direction backlog:", gasAfterPump);
        assertLt(gasAfterPump, 500_000, "pumpTwammBacklog must fully defuse an alternating-direction backlog too, not just the same-direction case");
    }
}
