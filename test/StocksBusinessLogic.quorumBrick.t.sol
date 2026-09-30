// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Business-logic vulnerability hunt: staked TST sits inside `StocksStaking`, which never
/// delegates its own held tokens anywhere (grepped directly: zero `delegate` calls in the whole contract)
/// -- so staked TST carries ZERO voting power, confirmed structurally, not assumed. But `quorum()`'s
/// denominator is `circulatingSupply = getPastTotalSupply(timepoint) - burned`, which counts staked TST
/// as part of circulating supply (it isn't burned, just held elsewhere). `QUORUM_NUMERATOR` is 10 (10% of
/// circulating supply), fixed forever -- `updateQuorumNumerator()` is a hard `pure` override that always
/// reverts, no path to ever change it, not even via a future passed proposal.
///
/// The business-logic question this raises, worth testing directly rather than left as a theoretical
/// concern: once enough of the supply is staked, does quorum become MATHEMATICALLY UNREACHABLE -- not
/// "hard to reach", but literally impossible even with 100% participation from every non-staked holder --
/// permanently bricking governance with no recovery path, precisely BECAUSE the flywheel (round 19's own
/// finding: stakers capture ~11.8x their proportional share of value) gives holders a strong, rational
/// incentive to stake, pushing participation exactly toward the threshold that breaks this?
contract StocksQuorumBrickTest is StocksRedemptionAdversarialTest {
    function _gov() internal view returns (StocksGovernor) {
        return StocksGovernor(payable(curve.governor()));
    }

    /// @dev Stakes essentially the entire circulating supply except for a small, deliberately-unstaked
    /// remainder, then checks whether that remainder -- voting FOR with 100% unanimous, maximum possible
    /// support -- can still pass a routine proposal.
    function _runAtStakedFraction(uint256 stakedBps) internal returns (bool quorumReached, uint256 forVotes, uint256 quorumNeeded) {
        uint256 snap = vm.snapshotState();

        // pull everyone's TST into one pool of real, spendable supply, then split it precisely into a
        // "staked" bucket and a "voting" (non-staked, self-delegated) bucket according to stakedBps.
        address megaStaker = address(0x57A4E5); // deliberately distinct from `staker`/`holder`
        address voter = address(0x707E5); // the only non-staked, actively-voting holder

        uint256 holderTst = tst.balanceOf(holder);
        vm.prank(holder);
        tst.transfer(megaStaker, holderTst);

        uint256 totalPool = tst.balanceOf(megaStaker) + tst.balanceOf(staker);
        uint256 toStake = (totalPool * stakedBps) / 10_000;
        uint256 toVote = totalPool - toStake;

        // fund megaStaker up to exactly `toStake` (topping up or trimming from what it already holds)
        if (tst.balanceOf(megaStaker) < toStake) {
            vm.prank(staker);
            tst.transfer(megaStaker, toStake - tst.balanceOf(megaStaker));
        }
        vm.startPrank(megaStaker);
        tst.approve(address(staking), toStake);
        staking.stake(toStake);
        vm.stopPrank();

        // whatever real TST is left (staker's remaining + megaStaker's leftover) goes to the one voter
        uint256 stakerLeft = tst.balanceOf(staker);
        if (stakerLeft > 0) {
            vm.prank(staker);
            tst.transfer(voter, stakerLeft);
        }
        uint256 megaLeft = tst.balanceOf(megaStaker);
        if (megaLeft > 0) {
            vm.prank(megaStaker);
            tst.transfer(voter, megaLeft);
        }
        toVote; // the actual voter balance is whatever real dust ended up there; logged below

        vm.prank(voter);
        TSTToken(address(tst)).delegate(voter);
        vm.warp(_now() + 1);

        StocksGovernor g = _gov();
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(staking);
        calldatas[0] = abi.encodeCall(StocksStaking.setRewardsPaused, (true));
        string memory description = "Routine, harmless proposal";

        vm.prank(voter);
        uint256 id = g.propose(targets, values, calldatas, description);
        vm.warp(_now() + g.votingDelay() + 1);
        vm.prank(voter);
        g.castVote(id, 1); // For, with every last unit of real voting power the non-staked side has

        vm.warp(_now() + g.votingPeriod() + 1);
        IGovernor.ProposalState finalState = g.state(id);

        forVotes = g.getVotes(voter, g.proposalSnapshot(id));
        quorumNeeded = g.quorum(g.proposalSnapshot(id));
        quorumReached = finalState == IGovernor.ProposalState.Succeeded;

        vm.revertToState(snap);
    }

    function test_HighStakingParticipation_CanMakeQuorumMathematicallyUnreachable() public {
        uint256[5] memory scenarios = [uint256(5000), 8000, 8900, 9100, 9900]; // 50%, 80%, 89%, 91%, 99% staked

        for (uint256 i; i < scenarios.length; i++) {
            (bool reached, uint256 forVotes, uint256 quorumNeeded) = _runAtStakedFraction(scenarios[i]);
            console.log("staked bps, quorum reached (1=yes), voter's max possible For votes, quorum needed:");
            console.log(scenarios[i], reached ? 1 : 0);
            console.log(forVotes, quorumNeeded);
        }

        // the precise, quantified finding: at 91% staked, even 100% unanimous participation from every
        // remaining non-staked holder cannot reach quorum -- not a close call, a structural impossibility,
        // since quorum (10% of circulating supply) exceeds the total non-staked supply (9%) that could
        // ever vote at all.
        (bool reachedAt91,,) = _runAtStakedFraction(9100);
        assertFalse(reachedAt91, "at 91% staked, quorum must be mathematically unreachable even with unanimous non-staked participation");

        // and confirm the boundary is real and sharp: comfortably below the threshold, the same unanimous
        // vote DOES pass, proving this isn't an artifact of the test setup itself failing to vote correctly.
        (bool reachedAt80,,) = _runAtStakedFraction(8000);
        assertTrue(reachedAt80, "sanity: well below the threshold, the same unanimous vote genuinely can and does pass");
    }

    /// @dev The other half of the finding: is there ANY recovery path once bricked? updateQuorumNumerator
    /// is checked directly, not assumed, to be permanently, unconditionally blocked -- confirming there is
    /// no governance-driven fix once this state is reached, from any caller, under any circumstance.
    function test_NoRecoveryPath_QuorumNumeratorIsPermanentlyImmutable() public {
        StocksGovernor g = _gov();
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        g.updateQuorumNumerator(1);

        // not even the governor's own timelock/executor address (were one wired in) or the DAO itself,
        // acting through its own execute() path, could reach this -- it's a `pure` function that reverts
        // unconditionally regardless of caller, confirmed by calling it directly with no access control
        // bypassed, the same way any other external caller would.
        vm.prank(address(g));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        g.updateQuorumNumerator(1);
    }
}
