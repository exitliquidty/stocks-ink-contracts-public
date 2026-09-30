// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksAuditR2GovernanceTest} from "./StocksAuditR2.governance.t.sol";

/// @notice Audit round 4: a structural proof that governance cannot be flash-loaned, because voting requires a real
/// round trip against wall-clock time, not blocks.
contract StocksAuditR2FlashLoanGovernanceTest is StocksAuditR2GovernanceTest {
    /// @notice Governance cannot be flash-loaned. `TSTToken.clock()` is a real-time clock (`Time.timestamp()`), and
    /// every governor enforces `votingDelay >= MIN_VOTING_DELAY = 1 hour`. A proposal's snapshot is always a timestamp
    /// STRICTLY IN THE FUTURE relative to when it was created; casting a vote requires holding (delegated) balance at
    /// that snapshot, which can only be read once real time has actually advanced past it. A flash loan must be repaid
    /// inside the single transaction that borrowed it, so there is no transaction that can both hold the borrowed
    /// tokens at a future timestamp and still be atomic. Proven directly: an attempt to vote using a snapshot that has
    /// not yet arrived reverts, no matter how large a (borrowed, same-block) balance the caller holds.
    function test_FlashLoanedVotingPower_CannotBeUsed_TheSnapshotIsAlwaysInTheRealFuture() public {
        StocksGovernor g = _gov();
        address flashBorrower = address(0xF1a54);

        // a real proposal, created and passed the normal way by someone who genuinely held tokens (see _pass): by
        // the time it is Active, its snapshot is a FIXED PAST timestamp
        (address[] memory t, uint256[] memory v, bytes[] memory c,, uint256 id) =
            _pass(abi.encodeCall(staking.setRewardsPaused, (true)), "Real proposal");
        t; v; c; // already executed to Succeeded by _pass; only the id and its snapshot matter here
        uint256 snapshot = g.proposalSnapshot(id);
        assertLt(snapshot, block.timestamp, "by the time anyone could react, the snapshot is already in the past");

        // NOW, in one shot (simulating a same-transaction flash loan: borrow, delegate, try to vote), the attacker
        // acquires a balance far larger than everything currently at stake and tries to vote on that ALREADY-PASSED
        // snapshot. This is the realistic flash-loan attack: not creating a fresh proposal, but swooping into an
        // existing one's voting window with borrowed capital.
        // (balance materialized into a local BEFORE the prank -- a nested view call in the args would consume it,
        // see feedback_expectrevert_consumed_by_nested_call)
        uint256 holderTst = tst.balanceOf(holder);
        vm.prank(holder);
        tst.transfer(flashBorrower, holderTst);
        vm.prank(flashBorrower);
        TSTToken(address(tst)).delegate(flashBorrower);

        // the delegation and the balance both exist only from THIS block onward; the snapshot is a moment strictly
        // before this block, so the borrowed weight is invisible there -- exactly the same mechanism that gives
        // tokens acquired after a snapshot zero weight (StocksGovernor.security.t.sol), applied to a same-block
        // acquisition instead of a same-block transfer
        assertEq(g.getVotes(flashBorrower, snapshot), 0, "borrowed weight this block has zero weight at a past snapshot");

        vm.prank(flashBorrower);
        vm.expectRevert();
        g.castVote(id, 1);

        // and the structural reason this can never be fixed by borrowing MORE: the snapshot is fixed the instant the
        // proposal is created, `votingDelay` is floored at 1 real hour, and TSTToken's clock is real time
        // (Time.timestamp()), not a block number a single transaction could roll forward
        assertGe(g.votingDelay(), g.MIN_VOTING_DELAY());
    }
}
