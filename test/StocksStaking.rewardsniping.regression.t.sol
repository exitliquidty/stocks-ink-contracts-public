// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Regression tests for audit finding F-2 (reward sniping).
///
/// The bug: `_notifyReward` used to fold a mid-period inflow in with `rewardRate += reward / remaining`,
/// streaming it over only the time LEFT in the period. Late in a cycle that compressed a big inflow into
/// a short window, and with no stake lock a large stake could join one second after it and take almost all
/// of it (measured: 3,003 of a 3,003 inflow to a stake holding one day; the honest staker fell from 3,999
/// to 996).
///
/// The fix: an inflow that is MATERIAL (at least 1/100 of what is still left to stream) restarts the full
/// reward period, spreading the inflow AND the unstreamed leftover over a full `rewardsDuration` (the
/// standard Synthetix rule). Immaterial inflows keep the old behavior, so dust donations still cannot keep
/// resetting the clock, which is the griefing that an earlier audit round removed the restart to prevent.
contract StocksStakingRewardSnipingRegressionTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address honest = address(0xA11CE);
    address whale = address(0xB16);
    address attacker = address(0xBAD);

    uint256 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new MockERC20("Stock", "STK");
        hook = new MockHookV5(stock, tst, 1 hours, 1);
        staking = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));

        bool tstIsCurrency0 = address(tst) < address(stock);
        poolKey = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(poolKey);
        tst.mint(address(hook), 1_000_000_000e18);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _stake(address who, uint256 amount) internal {
        tst.mint(who, amount);
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _inflow(uint256 amount) internal {
        stock.mint(address(staking), amount);
        staking.notifyRewardAmount();
    }

    function _leftover() internal view returns (uint256) {
        uint256 pf = staking.periodFinish();
        return _now() >= pf ? 0 : (pf - _now()) * staking.rewardRate();
    }

    /// @dev A 1,000 stock inflow starts a 30-day period; a big 3,000 inflow lands `remaining` before it
    /// ends; if `sniper`, a whale with 100x the honest stake joins one second later. Everyone claims one
    /// second after the ORIGINAL period end. Returns what each ended up with.
    function _runCycle(bool sniper, uint256 whaleStake, uint256 remaining)
        internal
        returns (uint256 honestReward, uint256 whaleReward)
    {
        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(1_000e18);

        vm.warp(t0 + DURATION - remaining);
        _inflow(3_000e18);
        if (sniper) {
            vm.warp(_now() + 1);
            _stake(whale, whaleStake);
        }

        vm.warp(t0 + DURATION + 1);
        vm.prank(honest);
        staking.claim();
        honestReward = stock.balanceOf(honest);
        if (sniper) {
            vm.prank(whale);
            staking.claim();
            whaleReward = stock.balanceOf(whale);
        }
    }

    // ================= the sniping scenarios (before the fix: 3,003 and 2,970) =================

    function test_LateInflow_HoldingADay_SniperNowGetsOnlyItsProRataShare() public {
        uint256 id = vm.snapshotState();
        (uint256 honestAlone,) = _runCycle(false, 0, 1 days);
        vm.revertToState(id);
        (uint256 honestWithSniper, uint256 sniperGot) = _runCycle(true, 100_000e18, 1 days);

        console.log("sniper reward, holding 100x the stake for a day (was 3003):", sniperGot / 1e18);
        console.log("honest reward without the sniper:", honestAlone / 1e18);
        console.log("honest reward with the sniper:   ", honestWithSniper / 1e18);

        // 3,000 spread over 30 days is 100/day; the whale holds ~99% of the stake for one day.
        assertLt(sniperGot, 110e18, "the sniper only gets its pro-rata share of a 30-day spread");
        assertGt(sniperGot, 90e18, "sanity: it still earns something for the day it held");
        // Before the fix the honest staker lost ~3,000 to the sniper; now it loses only what the sniper's day
        // of staking legitimately earns (about 100), and the two amounts match.
        uint256 honestLoss = honestAlone - honestWithSniper;
        assertLt(honestLoss, 110e18, "the honest staker loses ~100, not ~3,000");
        assertApproxEqAbs(honestLoss, sniperGot, 2e18, "what the honest staker lost is exactly what the sniper earned");
    }

    function test_LateInflow_HoldingAnHour_SniperGetsAlmostNothing() public {
        (, uint256 sniperGot) = _runCycle(true, 100_000e18, 1 hours);
        console.log("sniper reward holding ~1 hour (was 2970):", sniperGot / 1e18);
        assertLt(sniperGot, 10e18);
    }

    // ================= how the rule behaves =================

    function test_MaterialInflow_RestartsPeriod_AndSpreadsInflowPlusLeftover() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);

        uint256 leftover = _leftover();
        uint256 reward = 1_000e18; // 1,000 against ~667 left: material
        _inflow(reward);

        assertEq(staking.periodFinish(), _now() + DURATION, "a material inflow restarts the full period");
        assertApproxEqAbs(
            staking.rewardRate(), (reward + leftover) / DURATION, 1, "rate spreads inflow + leftover over the full duration"
        );
    }

    function test_ImmaterialInflow_KeepsPeriodFinish_AndUsesTheRemainingWindow() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);

        uint256 pfBefore = staking.periodFinish();
        uint256 rateBefore = staking.rewardRate();
        uint256 leftover = _leftover();
        uint256 remaining = pfBefore - _now();
        uint256 reward = leftover / 200; // 0.5% of what is left: immaterial
        _inflow(reward);

        assertEq(staking.periodFinish(), pfBefore, "an immaterial inflow never moves periodFinish");
        assertEq(staking.rewardRate(), rateBefore + reward / remaining, "it is streamed over the remaining window");
    }

    function test_Threshold_ExactlyOneHundredthOfLeftover_IsMaterial_OneWeiLess_IsNot() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);

        uint256 pfBefore = staking.periodFinish();
        uint256 leftover = _leftover();
        uint256 exact = leftover / 100;
        while (exact * 100 < leftover) exact++; // the smallest inflow with reward * 100 >= leftover

        uint256 id = vm.snapshotState();
        _inflow(exact);
        assertEq(staking.periodFinish(), _now() + DURATION, "at the threshold it restarts");
        vm.revertToState(id);

        _inflow(exact - 1);
        assertEq(staking.periodFinish(), pfBefore, "one wei below the threshold it does not");
    }

    function test_InflowAfterPeriodFinish_StillStartsAFreshPeriod() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(staking.periodFinish() + 1 days);

        _inflow(500e18);
        assertEq(staking.periodFinish(), _now() + DURATION);
        assertEq(staking.rewardRate(), 500e18 / DURATION);
    }

    // ================= the griefing the restart was originally removed to stop =================

    function test_DustSpam_CannotDragTheStreamOrDiluteTheRate() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        uint256 originalFinish = staking.periodFinish();

        for (uint256 i; i < 500; i++) {
            vm.warp(_now() + 1 hours);
            stock.mint(address(staking), 1); // 1 wei donation
            vm.prank(attacker);
            staking.notifyRewardAmount();
        }

        assertEq(staking.periodFinish(), originalFinish, "500 dust donations never moved periodFinish");
        vm.warp(originalFinish);
        assertApproxEqAbs(staking.pendingReward(honest), 1_000e18, 1e12, "everything vests on the ORIGINAL schedule");
    }

    /// @dev Griefing with MATERIAL donations is possible but costs real value each time: every restart needs a
    /// donation of at least 1% of what is left, and every donated wei goes to the stakers.
    function test_MaterialDonationGriefing_CostsRealValueEveryTime() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        uint256 donated;
        uint256 restarts;
        for (uint256 i; i < 20; i++) {
            vm.warp(_now() + 1 days);
            uint256 need = _leftover() / 100 + 1;
            uint256 pfBefore = staking.periodFinish();
            stock.mint(address(staking), need);
            donated += need;
            staking.notifyRewardAmount();
            if (staking.periodFinish() != pfBefore) restarts++;
        }
        assertEq(restarts, 20, "each donation of just over 1% of the leftover restarts the period");
        assertGt(donated, 100e18, "but 20 restarts cost over 10% of the stream, all of which the stakers keep");
    }

    // ================= accounting stays sound =================

    function test_InflowWithNoStakers_ThenStakerJoins_NothingIsOverPaid() public {
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);
        _inflow(2_000e18); // material: restart, still nobody staked
        vm.warp(_now() + 5 days);
        _stake(honest, 1_000e18);
        vm.warp(_now() + DURATION + 1);

        vm.prank(honest);
        staking.claim();
        assertLe(stock.balanceOf(honest), 3_000e18, "cannot claim more than was ever added");
    }

    function test_PauseThenResume_WithARestartInBetween_ConservesEverything() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 5 days);

        vm.prank(governor);
        staking.setRewardsPaused(true);
        vm.warp(_now() + 3 days);
        _inflow(2_000e18); // lands while paused: not recognized until resume
        vm.warp(_now() + 2 days);
        vm.prank(governor);
        staking.setRewardsPaused(false); // resume: the pending inflow is recognized, a material one restarts

        vm.warp(_now() + 2 * DURATION);
        vm.prank(honest);
        staking.claim();
        uint256 got = stock.balanceOf(honest);
        assertLe(got, 3_000e18, "never more than the 3,000 ever added");
        assertGe(got, 3_000e18 - 1e13, "and everything vests: only rounding dust stays behind");
    }

    function test_ManyInflows_AllEventuallyVest_AndNeverOverpay() public {
        _stake(honest, 1_000e18);
        uint256 added;
        for (uint256 i; i < 40; i++) {
            uint256 amount = (i % 7 + 1) * 37e18;
            _inflow(amount);
            added += amount;
            vm.warp(_now() + (i % 5 + 1) * 1 days);
        }
        vm.warp(_now() + DURATION + 1); // no further inflows: the tail must fully vest within one duration
        vm.prank(honest);
        staking.claim();
        uint256 got = stock.balanceOf(honest);
        assertLe(got, added, "never overpays");
        // Each restart floors the spread once, so at most ~DURATION wei of dust per inflow stays behind.
        assertGe(got + 40 * DURATION, added, "everything else vests: only rounding dust stays behind");
    }

    function test_LiquidationAfterARestart_SweepsOnlyTheUnvested_AndVestedStaysClaimable() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);
        _inflow(1_000e18); // material: restart, ~1,667 now streams over 30 days

        vm.warp(_now() + 6 days);
        uint256 vested = staking.pendingReward(honest);
        assertGt(vested, 0);

        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(governor);
        (uint256 committed,) = staking.liquidateTreasury(_minLiqIntervals1);
        assertGt(committed, 0, "the unvested part is liquidatable");

        // Everything already vested is untouched and claimable; the stream is wound down to nothing.
        assertApproxEqAbs(staking.pendingReward(honest), vested, 1e12, "vested rewards untouched by the liquidation");
        assertEq(staking.rewardRate(), 0, "the unvested stream is fully committed, so the rate drops to 0");
        vm.prank(honest);
        staking.claim();
        assertApproxEqAbs(stock.balanceOf(honest), vested, 1e12);
    }

    // ================= randomized =================

    /// @dev For ANY sequence of inflow sizes and gaps: a material inflow leaves a stream that pays out over a
    /// full duration (never compressed) and never creates rate out of thin air; an immaterial one leaves
    /// periodFinish untouched and adds exactly reward / remaining.
    function testFuzz_EveryInflow_FollowsTheRule(uint256 seed) public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        for (uint256 i; i < 25; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(_now() + 1 + (r % 3 days));
            uint256 reward = 1 + ((r >> 64) % 5_000e18);

            uint256 pfBefore = staking.periodFinish();
            uint256 rateBefore = staking.rewardRate();
            bool active = _now() < pfBefore;
            uint256 leftover = _leftover();
            uint256 remaining = active ? pfBefore - _now() : 0;

            _inflow(reward);

            if (!active) {
                assertEq(staking.periodFinish(), _now() + DURATION);
                assertEq(staking.rewardRate(), reward / DURATION);
            } else if (reward * 100 >= leftover) {
                assertEq(staking.periodFinish(), _now() + DURATION, "material: full restart");
                assertLe(staking.rewardRate() * DURATION, reward + leftover, "never streams more than inflow + leftover");
                assertGe(staking.rewardRate() * DURATION + DURATION, reward + leftover, "and loses at most one rounding step");
            } else {
                assertEq(staking.periodFinish(), pfBefore, "immaterial: period untouched");
                assertEq(staking.rewardRate(), rateBefore + reward / remaining, "immaterial: old rule");
            }
        }
    }

    /// @dev A stake that joins right after any late inflow can earn at most the stream's time-share:
    /// (inflow + leftover) * holdTime / duration, whatever the inflow size, timing and whale size.
    function testFuzz_SniperEarnsAtMostTheTimeShare(uint256 seed) public {
        uint256 lateBy = 1 hours + (uint256(keccak256(abi.encode(seed, "late"))) % 20 days);
        uint256 inflow = 100e18 + (uint256(keccak256(abi.encode(seed, "in"))) % 10_000e18);
        uint256 whaleStake = 1_000e18 + (uint256(keccak256(abi.encode(seed, "w"))) % 10_000_000e18);

        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(t0 + DURATION - lateBy);

        uint256 leftoverBefore = _leftover();
        _inflow(inflow);
        vm.warp(_now() + 1);
        _stake(whale, whaleStake);

        uint256 hold = 1 hours + (uint256(keccak256(abi.encode(seed, "h"))) % lateBy);
        vm.warp(_now() + hold);
        uint256 earned = staking.pendingReward(whale);

        uint256 bound = ((inflow + leftoverBefore) * hold) / DURATION + 1e12;
        assertLe(earned, bound, "a late joiner cannot earn more than the stream's time-share");
    }

    /// @dev Characterizes the RESIDUAL exposure of the 1% threshold in a steady, busy pool: one inflow every
    /// hour, each far below 1% of the leftover, so none of them restarts the clock and each is compressed into
    /// the time left in the period. A whale (100x the honest stake) joins on `joinDay` and holds 72 hours.
    /// Benchmark: what it would earn if EVERY inflow streamed over the full 30 days (the ideal, un-snipeable
    /// stream). The whale earns more than that, not less, because the compression is only partly closed by the
    /// 1% rule. This test pins the measured worst case (about 2x the benchmark; the old rule allowed several
    /// times more) so any future change that makes it worse is caught. A 0.1% threshold measured at 85% or less.
    function _steadyRatioPercent(uint256 joinDay) internal returns (uint256) {
        uint256 inflowEach = 100e18;
        uint256 honestStake = 1_000e18;
        uint256 whaleStake = 100_000e18;
        uint256 holdHours = 72;

        _stake(honest, honestStake);
        tst.mint(whale, whaleStake);
        vm.prank(whale);
        tst.approve(address(staking), whaleStake);

        uint256 t0 = _now();
        uint256 joinHour = joinDay * 24;
        uint256 leaveHour = joinHour + holdHours;
        for (uint256 h; h < leaveHour; ++h) {
            if (h == joinHour) {
                vm.prank(whale);
                staking.stake(whaleStake);
            }
            _inflow(inflowEach);
            vm.warp(_now() + 1 hours);
        }
        uint256 actual = staking.pendingReward(whale);

        uint256 tJoin = t0 + joinHour * 1 hours;
        uint256 tLeave = t0 + leaveHour * 1 hours;
        uint256 share = (whaleStake * 1e18) / (whaleStake + honestStake);
        uint256 bench;
        for (uint256 i; i < leaveHour; ++i) {
            uint256 ti = t0 + i * 1 hours;
            uint256 lo = ti > tJoin ? ti : tJoin;
            uint256 hi = ti + DURATION < tLeave ? ti + DURATION : tLeave;
            if (hi > lo) bench += (((share * inflowEach) / 1e18) * (hi - lo)) / DURATION;
        }
        return (actual * 100) / bench;
    }

    function test_SteadyBusyPool_SniperAdvantage_StaysUnderTwoAndAHalfTimesTheIdeal() public {
        uint256[5] memory joinDays = [uint256(10), 20, 28, 40, 57];
        uint256 worst;
        for (uint256 k; k < joinDays.length; ++k) {
            uint256 id = vm.snapshotState();
            uint256 ratio = _steadyRatioPercent(joinDays[k]);
            console.log("join day / earned as percent of the ideal stream:", joinDays[k], ratio);
            if (ratio > worst) worst = ratio;
            vm.revertToState(id);
        }
        assertLe(worst, 250, "steady-pool sniper advantage stays within 2.5x the ideal stream");
    }
}
