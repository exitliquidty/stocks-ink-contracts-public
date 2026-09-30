// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 2: exact boundaries and access checks on the staking contract that a mutation run showed no test
/// was pinning.
contract StocksAuditR2StakingEdgesTest is StocksRedemptionAdversarialTest {
    function test_RewardsDuration_ExactBounds_AreAccepted_OneOutsideIsRefused() public {
        address g = curve.governor();
        uint256 lo = staking.MIN_GOVERNABLE_REWARDS_DURATION();
        uint256 hi = staking.MAX_GOVERNABLE_REWARDS_DURATION();

        vm.startPrank(g);
        vm.expectRevert(StocksStaking.InvalidGovernableRewardsDuration.selector);
        staking.setRewardsDuration(lo - 1);
        vm.expectRevert(StocksStaking.InvalidGovernableRewardsDuration.selector);
        staking.setRewardsDuration(hi + 1);

        staking.setRewardsDuration(lo);
        assertEq(staking.rewardsDuration(), lo, "the minimum is accepted");
        staking.setRewardsDuration(hi);
        assertEq(staking.rewardsDuration(), hi, "the maximum is accepted");
        vm.stopPrank();
    }

    function test_OnlyTheGovernor_CanChangeTheDuration_PauseOrLiquidate() public {
        address stranger = address(0x5771);
        vm.startPrank(stranger);
        vm.expectRevert(StocksStaking.NotGovernor.selector);
        staking.setRewardsDuration(2 days);
        vm.expectRevert(StocksStaking.NotGovernor.selector);
        staking.setRewardsPaused(true);
        vm.expectRevert(StocksStaking.NotGovernor.selector);
        staking.liquidateTreasury(1);
        vm.stopPrank();
    }

    function test_SetPool_IsCallableOnlyByTheCurve_AndOnlyOnce() public {
        vm.prank(address(0x5771));
        vm.expectRevert(StocksStaking.NotCurve.selector);
        staking.setPool(key);
        // even the curve cannot set it again
        vm.prank(address(curve));
        vm.expectRevert(StocksStaking.PoolAlreadySet.selector);
        staking.setPool(key);
    }

    function test_ConstructorMinimumDuration_IsExact() public {
        // exactly one hour is accepted, one second less is refused
        new StocksStaking(address(tst), address(stock), 1 hours, address(0x60), address(0x61), address(0x62));
        vm.expectRevert(StocksStaking.RewardsDurationTooShort.selector);
        new StocksStaking(address(tst), address(stock), 1 hours - 1, address(0x60), address(0x61), address(0x62));
    }
}
