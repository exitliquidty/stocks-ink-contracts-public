// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksAuditR2GovernanceTest} from "./StocksAuditR2.governance.t.sol";

/// @notice Audit round 2, business logic: vote borrowing, stale proposals, reward-stream griefing, pause behaviour.
contract StocksAuditR2EconomicsTest is StocksAuditR2GovernanceTest {
    function _sellAll(address who) internal returns (uint256 stockBack) {
        uint256 amount = tst.balanceOf(who);
        uint256 before = stock.balanceOf(who);
        vm.startPrank(who);
        tst.approve(address(swapRouter), amount);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tstIsCurrency0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        stockBack = stock.balanceOf(who) - before;
    }

    // ------------------------------------------------------------------------------ vote borrowing

    /// @notice A stranger with no tokens borrows voting power for exactly one moment: they buy TST during the voting
    /// delay, delegate, hold it across the snapshot second, sell it straight back, and then still vote with the
    /// snapshotted weight. Snapshot governance always allows this; the question is what it costs. Here they pass a
    /// proposal that pauses staking rewards.
    function test_VoteBorrowing_WorksButCostsAFractionOfTheBorrowedStake() public {
        address attacker = address(0xA77);
        stock.transfer(attacker, 100_000e18);
        vm.prank(attacker);
        stock.approve(address(swapRouter), type(uint256).max);

        StocksGovernor g = _gov();
        uint256 circulating = tst.totalSupply() - tst.balanceOf(BURN);
        console.log("circulating supply (TST wei):", circulating);
        // step 1: enough to pass the proposer threshold (0.25%) and a bit more
        uint256 stockStart = stock.balanceOf(attacker);
        _buyTst(attacker, 1e18);
        vm.prank(attacker);
        TSTToken(address(tst)).delegate(attacker);
        vm.warp(_now() + 2);
        uint256 threshold = g.proposalThreshold();
        assertGe(TSTToken(address(tst)).getVotes(attacker), threshold, "the attacker clears the proposer threshold");

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(staking);
        calldatas[0] = abi.encodeCall(StocksStaking.setRewardsPaused, (true));
        string memory description = "Pause rewards";
        vm.prank(attacker);
        uint256 id = g.propose(targets, values, calldatas, description);
        uint256 snapshot = g.proposalSnapshot(id);

        // step 2: just before the snapshot, buy enough for quorum (10%), delegate
        vm.warp(snapshot - 2);
        uint256 quorumNeeded = g.quorum(snapshot - 3);
        uint256 have = tst.balanceOf(attacker);
        uint256 stockSpentSoFar = stockStart - stock.balanceOf(attacker);
        uint256 stepStock = 1e18;
        while (tst.balanceOf(attacker) < quorumNeeded + quorumNeeded / 10 && stepStock <= 60_000e18) {
            _buyTst(attacker, stepStock);
            stepStock *= 2;
        }
        assertGe(tst.balanceOf(attacker), quorumNeeded, "the attacker holds a quorum's worth at the snapshot");
        vm.prank(attacker);
        // already delegated to itself: the new balance carries the votes automatically
        vm.warp(snapshot + 1);

        // step 3: sell everything back, THEN vote with the snapshotted weight
        uint256 borrowed = tst.balanceOf(attacker);
        _sellAll(attacker);
        assertEq(tst.balanceOf(attacker), 0, "the attacker holds nothing while voting");
        vm.prank(attacker);
        g.castVote(id, 1);
        vm.warp(_now() + g.votingPeriod() + 1);
        assertEq(uint8(g.state(id)), uint8(IGovernor.ProposalState.Succeeded), "the borrowed vote passed the proposal");

        uint256 cost = stockStart - stock.balanceOf(attacker);
        console.log("stock spent net (wei):", cost);
        console.log("TST borrowed for one second (wei):", borrowed);
        console.log("stock it would have cost at the start price, roughly (wei):", borrowed * (stockSpentSoFar + 1) / (have + 1));
        // the pool charges 10% each way plus price impact: net cost is a large part of the borrowed value
        assertGt(cost, 0, "borrowing votes is never free");
        g.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertTrue(staking.rewardsPaused(), "the pause executed");
    }

    // ------------------------------------------------------------------------------ stale proposals

    /// @notice OpenZeppelin's governor has no expiry on a passed proposal: it can be executed by anyone, any time later.
    /// Documented behaviour, checked so the design note stays true.
    function test_APassedProposal_CanBeExecutedALongTimeLater() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _pass(abi.encodeCall(StocksStaking.setRewardsPaused, (true)), "Pause rewards");
        vm.warp(_now() + 400 days);
        assertFalse(staking.rewardsPaused());
        gov.execute(t, v, c, h);
        assertTrue(staking.rewardsPaused(), "executed 400 days after it passed");
    }

    // ------------------------------------------------------------------------------ pause behaviour

    /// @notice A pause vote must never trap anyone: stakers can still unstake and claim what they had earned, and
    /// holders can still redeem.
    function test_PausedRewards_NeverTrapStakersOrRedeemers() public {
        _fundTreasury(100e18);
        vm.warp(_now() + 5 days);
        uint256 earned = staking.pendingReward(staker);
        assertGt(earned, 0, "the staker earned something");

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _pass(abi.encodeCall(StocksStaking.setRewardsPaused, (true)), "Pause rewards");
        gov.execute(t, v, c, h);
        assertTrue(staking.rewardsPaused());

        uint256 earnedWhenPaused = staking.pendingReward(staker);
        vm.warp(_now() + 90 days);
        assertEq(staking.pendingReward(staker), earnedWhenPaused, "nothing accrues while paused");

        // claim, unstake, redeem all still work
        uint256 stockBefore = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        assertEq(stock.balanceOf(staker) - stockBefore, earnedWhenPaused, "the staker claims exactly what was earned");
        uint256 staked = staking.balanceOf(staker);
        vm.prank(staker);
        staking.unstake(staked);
        assertEq(tst.balanceOf(staker), staked, "the staker gets every staked TST back");
        assertGt(_redeem(holder, tst.balanceOf(holder) / 10), 0, "redemption still pays out while paused");
    }

    // ------------------------------------------------------------------------------ reward-stream griefing

    /// @notice C5: `notifyRewardAmount()` is permissionless, so a griefer can call it every second and make each update
    /// round down. The most anyone can ever shave off a stream this way is one unit of the per-token accumulator per
    /// call, i.e. `calls * totalStaked / 1e18` stock wei in total. Checked by calling it every second for an hour against
    /// the same stream left alone.
    function testFuzz_C5_CallingNotifyEverySecond_CostsStakersAtMostOneUnitPerCall(uint256 stakedTst, uint256 reward) public {
        stakedTst = bound(stakedTst, 1e18, staking.balanceOf(staker));
        reward = bound(reward, 1e9, 1_000e18);

        // give the staking pool a known stake and a stream
        uint256 unstake0 = staking.balanceOf(staker) - stakedTst;
        if (unstake0 > 0) {
            vm.prank(staker);
            staking.unstake(unstake0);
        }
        stock.transfer(address(staking), reward);
        staking.notifyRewardAmount();

        uint256 snap = vm.snapshotState();
        vm.warp(_now() + 1 hours);
        uint256 honest = staking.pendingReward(staker);
        vm.revertToState(snap);

        for (uint256 i = 0; i < 3600; i++) {
            vm.warp(_now() + 1);
            staking.notifyRewardAmount();
        }
        uint256 attacked = staking.pendingReward(staker);

        uint256 maxLoss = (3600 * staking.totalStaked()) / 1e18 + 1;
        assertLe(attacked, honest, "griefing can only lose value, never create it");
        assertLe(honest - attacked, maxLoss, "the loss stays within one unit per call");
    }

    /// @notice Repeated top-ups of exactly the restart threshold (1% of what is left) restart the stream every time,
    /// spreading the remaining balance over a fresh period. The griefer's donations go to the stakers; this measures how
    /// much slower the ORIGINAL balance is paid out, and that nothing is ever lost.
    function test_RepeatedThresholdDonations_DelayPayoutButLoseNothing() public {
        _fundTreasury(100e18);
        uint256 snap = vm.snapshotState();
        vm.warp(_now() + 30 days);
        uint256 honestAtEnd = staking.pendingReward(staker);
        vm.revertToState(snap);

        uint256 donated;
        for (uint256 day = 0; day < 30; day++) {
            vm.warp(_now() + 1 days);
            // 1% of what is still to stream, plus a hair
            uint256 leftover = staking.redeemableStock();
            uint256 donation = leftover / 100 + 1;
            stock.transfer(address(staking), donation);
            staking.notifyRewardAmount();
            donated += donation;
        }
        uint256 attackedAtEnd = staking.pendingReward(staker);
        console.log("honest earned after 30 days (wei):", honestAtEnd);
        console.log("earned after 30 days of 1% restarts (wei):", attackedAtEnd);
        console.log("total donated by the griefer (wei):", donated);
        // every unit the griefer put in is owed to stakers, and the total owed never drops below the honest case
        uint256 owedLater = attackedAtEnd + staking.redeemableStock();
        assertGe(owedLater + 1e6, honestAtEnd + donated, "nothing is ever lost, donations are pure additions");
    }
}
