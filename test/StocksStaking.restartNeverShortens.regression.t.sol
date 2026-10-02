// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Regression tests for the round-24 finding: a material-inflow restart could SHORTEN the vesting of
/// the leftover stream after governance lowered `rewardsDuration`.
///
/// The bug: the restart rule (the F-2 reward-sniping fix, see StocksStaking.rewardsniping.regression.t.sol)
/// spread `inflow + leftover` over the raw `rewardsDuration`. That is only a defence while `rewardsDuration`
/// is at least the time left on the running period, which the constructor value always is. `setRewardsDuration`
/// lets governance lower it (down to 1 day) while a longer period is still running, and from then on a restart
/// compressed the whole leftover into the new, shorter window. The restart is permissionless and costs only a
/// donation of 1% of the leftover, so anyone could stake big, force it, and collect a stream that was meant to
/// take weeks in a day: exactly the sniping the restart rule exists to prevent.
///
/// The fix: a restart runs over the LONGER of `rewardsDuration` and the time remaining, so the leftover never
/// vests faster than it was already going to. The new duration still takes over once the running period ends.
contract StocksStakingRestartNeverShortensRegressionTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address honest = address(0xA11CE);
    address whale = address(0xB16);

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

    function _setDuration(uint256 newDuration) internal {
        vm.prank(governor);
        staking.setRewardsDuration(newDuration);
    }

    // ================= the rule =================

    function test_LoweredDuration_RestartKeepsTheLeftoverOnItsOriginalSchedule() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 1 days);
        _setDuration(1 days);

        uint256 pfBefore = staking.periodFinish();
        uint256 remaining = pfBefore - _now();
        uint256 leftover = _leftover();
        uint256 reward = leftover / 50; // 2% of what is left: material, so the period restarts
        _inflow(reward);

        assertEq(remaining, 29 days, "sanity: 29 days were still left when the duration dropped to 1 day");
        assertEq(staking.periodFinish(), pfBefore, "the restart must not pull periodFinish in to now + 1 day");
        assertEq(staking.rewardRate(), (reward + leftover) / remaining, "inflow + leftover stream over the time left");
    }

    function test_LoweredDuration_StillLongerThanTheTimeLeft_RestartsOverTheNewDuration() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 27 days); // 3 days left
        _setDuration(7 days);

        uint256 leftover = _leftover();
        _inflow(500e18);

        assertEq(staking.periodFinish(), _now() + 7 days, "7 days beats the 3 left, so the new duration is used");
        assertEq(staking.rewardRate(), (500e18 + leftover) / 7 days);
    }

    function test_DurationExactlyEqualToTheTimeLeft_IsTheSameEitherWay() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 23 days); // 7 days left
        _setDuration(7 days);

        uint256 pfBefore = staking.periodFinish();
        uint256 leftover = _leftover();
        _inflow(500e18);

        assertEq(staking.periodFinish(), pfBefore);
        assertEq(staking.periodFinish(), _now() + 7 days);
        assertEq(staking.rewardRate(), (500e18 + leftover) / 7 days);
    }

    function test_RaisedDuration_RestartsOverTheNewLongerDuration() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);
        _setDuration(60 days);

        uint256 leftover = _leftover();
        _inflow(1_000e18);

        assertEq(staking.periodFinish(), _now() + 60 days, "raising the duration is unaffected by the fix");
        assertEq(staking.rewardRate(), (1_000e18 + leftover) / 60 days);
    }

    function test_LoweredDuration_TakesOverOnceTheRunningPeriodHasEnded() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 1 days);
        _setDuration(1 days);

        vm.warp(staking.periodFinish() + 1);
        _inflow(500e18);

        assertEq(staking.periodFinish(), _now() + 1 days, "a fresh period uses the governed duration");
        assertEq(staking.rewardRate(), 500e18 / uint256(1 days));
    }

    function test_ImmaterialInflow_AfterALoweredDuration_IsUntouchedByTheFix() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 1 days);
        _setDuration(1 days);

        uint256 pfBefore = staking.periodFinish();
        uint256 rateBefore = staking.rewardRate();
        uint256 remaining = pfBefore - _now();
        uint256 reward = _leftover() / 200; // 0.5%: immaterial
        _inflow(reward);

        assertEq(staking.periodFinish(), pfBefore);
        assertEq(staking.rewardRate(), rateBefore + reward / remaining);
    }

    // ================= the attack =================

    /// @dev Day 1 of a 30-day, 1,000-stock stream. Governance lowers the duration to 1 day. A whale with 100x
    /// the honest stake joins, donates just over 1% of the leftover to force the restart, holds one day and
    /// claims. Before the fix the restart packed all ~967 of leftover (plus the donation) into that one day and
    /// the whale took ~99% of it. Now the stream keeps its 29-day schedule and the whale earns one day of it.
    function test_Attack_LoweredDuration_SniperCannotCompressTheLeftoverIntoOneDay() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 1 days);
        _setDuration(1 days);

        _stake(whale, 100_000e18);
        uint256 leftover = _leftover();
        uint256 donation = leftover / 100 + 1;
        stock.mint(address(staking), donation);
        vm.prank(whale);
        staking.notifyRewardAmount();
        assertEq(staking.periodFinish(), _now() + 29 days, "the forced restart did not shorten the period");

        vm.warp(_now() + 1 days);
        vm.prank(whale);
        staking.claim();
        uint256 whaleGot = stock.balanceOf(whale);

        console.log("leftover when the whale arrived:", leftover / 1e18);
        console.log("whale claimed after one day (was ~967):", whaleGot / 1e18);
        console.log("whale's own donation:", donation / 1e18);

        uint256 timeShare = ((leftover + donation) * 1 days) / 29 days;
        assertLe(whaleGot, timeShare, "at most one day's share of a 29-day stream");
        assertLt(whaleGot, 40e18, "about 33, not about 967");
        assertGt(whaleGot, donation, "sanity: the whale still earns its honest pro-rata day");

        // The honest staker still collects the rest of the stream it was already owed, on schedule.
        vm.warp(staking.periodFinish() + 1);
        vm.prank(honest);
        staking.claim();
        assertGt(stock.balanceOf(honest), 40e18, "the honest staker's one day + its share of the remaining 28");
    }

    // ================= accounting stays sound =================

    function test_LoweredDuration_Restart_EverythingStillVests_AndNeverOverpays() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 1 days);
        _setDuration(1 days);
        _inflow(300e18); // material: restart over the 29 days left

        vm.warp(staking.periodFinish() + 1);
        vm.prank(honest);
        staking.claim();
        uint256 got = stock.balanceOf(honest);
        assertLe(got, 1_300e18, "never more than was ever added");
        assertGe(got + 2 * DURATION, 1_300e18, "and everything vests: only rounding dust stays behind");
    }

    // ================= randomized =================

    /// @dev For ANY governed duration, elapsed time and material inflow: a restart never moves periodFinish
    /// earlier, never streams more than inflow + leftover, and runs over max(duration, time left).
    function testFuzz_Restart_NeverMovesPeriodFinishEarlier(uint256 elapsed, uint256 newDays, uint256 reward) public {
        elapsed = bound(elapsed, 1, DURATION - 1);
        newDays = bound(newDays, 1, 365);
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + elapsed);
        _setDuration(newDays * 1 days);

        uint256 pfBefore = staking.periodFinish();
        uint256 remaining = pfBefore - _now();
        uint256 leftover = _leftover();
        reward = bound(reward, leftover / 100 + 1, 1_000_000e18); // always material
        _inflow(reward);

        uint256 expected = newDays * 1 days > remaining ? newDays * 1 days : remaining;
        assertEq(staking.periodFinish(), _now() + expected, "restart runs over max(duration, time left)");
        assertGe(staking.periodFinish(), pfBefore, "periodFinish never moves earlier");
        assertLe(staking.rewardRate() * expected, reward + leftover, "never streams more than inflow + leftover");
        assertGe(staking.rewardRate() * expected + expected, reward + leftover, "and loses at most one rounding step");
    }

    /// @dev Whatever duration governance picks mid-period, a stake that joins and forces a restart can earn at
    /// most the stream's time-share over the time that was ALREADY left, never the whole leftover in a day.
    function testFuzz_SniperEarnsAtMostTheTimeShare_UnderAnyGovernedDuration(uint256 seed) public {
        uint256 elapsed = 1 hours + (uint256(keccak256(abi.encode(seed, "e"))) % 20 days);
        uint256 newDays = 1 + (uint256(keccak256(abi.encode(seed, "d"))) % 365);
        uint256 whaleStake = 1_000e18 + (uint256(keccak256(abi.encode(seed, "w"))) % 10_000_000e18);

        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + elapsed);
        _setDuration(newDays * 1 days);

        _stake(whale, whaleStake);
        uint256 remaining = staking.periodFinish() - _now();
        uint256 leftover = _leftover();
        uint256 donation = leftover / 100 + 1;
        _inflow(donation);

        uint256 hold = 1 hours + (uint256(keccak256(abi.encode(seed, "h"))) % 3 days);
        vm.warp(_now() + hold);
        uint256 earned = staking.pendingReward(whale);

        uint256 window = newDays * 1 days > remaining ? newDays * 1 days : remaining;
        uint256 bound_ = ((leftover + donation) * hold) / window + 1e12;
        assertLe(earned, bound_, "a late joiner cannot earn more than the stream's time-share");
    }
}
