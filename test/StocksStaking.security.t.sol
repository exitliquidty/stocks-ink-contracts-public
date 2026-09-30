// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Security coverage for StocksStaking's reward math under multiple concurrent stakers.
contract StocksStakingSecurityTest is Test {
    address governor = address(0x6046);

    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    // ============================================================
    // Multi-staker reward SOLVENCY -- the core Synthetix-style-rewards-fork invariant. Every
    // existing test anywhere in this repo (including the freshfork file's own extensive pause/
    // resume/liquidate battery) only ever exercises ONE real staker at a time.
    // Double-counting or under/over-crediting bugs in rewardPerToken()/_settle()'s interaction with
    // MULTIPLE concurrent stakers joining/leaving at different times are exactly the bug class real
    // Synthetix-fork incidents have hit historically -- never directly fuzzed here before.
    // ============================================================

    /// @dev Three stakers join at fuzzed amounts and fuzzed times, against a single fixed real
    /// reward deposit recognized up front. After everyone has fully unstaked and claimed
    /// everything they're owed, the STRICT invariant this test exists to prove: the sum of every
    /// real payout across all three can never exceed the amount actually deposited as reward --
    /// no combination of join/leave timing may let the contract pay out more than it truly has.
    /// (Under-paying due to rounding dust is fine and expected -- Synthetix-style integer-division
    /// reward math always leaves some dust; OVER-paying is the one outcome that would mean real
    /// insolvency.)
    function testFuzz_MultiStakerRewardSolvency_NeverOverpaysAcrossAnyRealDistribution(
        uint256 amountA,
        uint256 amountB,
        uint256 amountC,
        uint256 warpAfterA,
        uint256 warpAfterB,
        uint256 warpAfterC
    ) public {
        amountA = bound(amountA, 1e18, 1_000_000e18);
        amountB = bound(amountB, 1e18, 1_000_000e18);
        amountC = bound(amountC, 1e18, 1_000_000e18);
        warpAfterA = bound(warpAfterA, 0, 10 days);
        warpAfterB = bound(warpAfterB, 0, 10 days);
        warpAfterC = bound(warpAfterC, 0, 40 days); // past a 30-day rewardsDuration, so the stream can fully finish

        MockERC20 solvTst = new MockERC20("SolvTst", "STST");
        MockERC20 solvStock = new MockERC20("SolvStock", "SSTOCK");
        MockHookV5 solvHook = new MockHookV5(solvStock, solvTst, EXPIRATION_INTERVAL, 1);
        StocksStaking solvStaking =
            new StocksStaking(address(solvTst), address(solvStock), 30 days, governor, address(solvHook), address(this));

        address alice = makeAddr("solvAlice");
        address bob = makeAddr("solvBob");
        address carol = makeAddr("solvCarol");

        // A single, fixed, real reward deposit recognized up front -- the exact amount this test's
        // solvency invariant is measured against.
        uint256 realReward = 100_000e18;
        solvStock.mint(address(solvStaking), realReward);
        solvStaking.notifyRewardAmount();

        solvTst.mint(alice, amountA);
        vm.startPrank(alice);
        solvTst.approve(address(solvStaking), amountA);
        solvStaking.stake(amountA);
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfterA);

        solvTst.mint(bob, amountB);
        vm.startPrank(bob);
        solvTst.approve(address(solvStaking), amountB);
        solvStaking.stake(amountB);
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfterB);

        solvTst.mint(carol, amountC);
        vm.startPrank(carol);
        solvTst.approve(address(solvStaking), amountC);
        solvStaking.stake(amountC);
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfterC);

        // Everyone unstakes and claims everything they're owed.
        uint256 totalPaid;
        vm.startPrank(alice);
        solvStaking.unstake(amountA);
        solvStaking.claim();
        vm.stopPrank();
        totalPaid += solvStock.balanceOf(alice);

        vm.startPrank(bob);
        solvStaking.unstake(amountB);
        solvStaking.claim();
        vm.stopPrank();
        totalPaid += solvStock.balanceOf(bob);

        vm.startPrank(carol);
        solvStaking.unstake(amountC);
        solvStaking.claim();
        vm.stopPrank();
        totalPaid += solvStock.balanceOf(carol);

        assertLe(totalPaid, realReward, "SOLVENCY VIOLATION: total real payouts across all stakers exceeded the real reward ever deposited");
    }
}
