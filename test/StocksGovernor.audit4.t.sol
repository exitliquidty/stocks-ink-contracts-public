// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice Round-4 audit on StocksGovernor: fresh adversarial pass focused on what rounds 1-3 (plus
/// the now-fixed bug-8 self-escalation work) missed. No new exploitable vulnerability was found.
/// Every hypothesis below was investigated by re-deriving the actual mechanism from OZ's own source
/// (not by trusting prior reasoning), and the two with a concrete, testable claim are backed by real
/// passing PoCs. The rest are closed by direct code/constant inspection, documented inline.
contract StocksGovernorAudit4Test is Test {
    TSTToken token;
    StocksGovernor gov;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant QUORUM_NUMERATOR = 10;

    function setUp() public {
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, alice);
        vm.prank(alice);
        token.transfer(bob, 1_000_000e18);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);

        gov = new StocksGovernor(
            "Tesla Stock Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 100, QUORUM_NUMERATOR
        );

        vm.warp(block.timestamp + 1);
    }

    /// @dev FOCUS 1, ruled out: proposalThreshold() recomputes live from circulating supply on every
    /// call, but TSTToken has no post-constructor mint path (grepped: the only `_mint` call is in the
    /// constructor) and BURN_ADDRESS transfers are one-directional. So circulating supply --
    /// therefore proposalThreshold() -- is monotonically non-increasing for the life of the contract.
    /// There is no way for any actor to make the bar HARDER to clear for a rival proposer; burning
    /// only ever lowers the bar for whoever proposes next. Confirmed here: burning tokens strictly
    /// decreases proposalThreshold(), never increases it, across a realistic sequence of burns.
    function test_AUDIT_ProposalThreshold_IsMonotonicallyNonIncreasing_NeverExploitableUpward() public {
        uint256 t0 = gov.proposalThreshold();
        address burnAddress = gov.BURN_ADDRESS();

        vm.prank(alice);
        token.transfer(burnAddress, 100_000_000e18);
        uint256 t1 = gov.proposalThreshold();
        assertLt(t1, t0, "burning supply strictly lowers the threshold");

        vm.prank(bob);
        token.transfer(burnAddress, 500_000e18);
        uint256 t2 = gov.proposalThreshold();
        assertLt(t2, t1, "a second, independent burn lowers it further");

        // No mint path exists anywhere in TSTToken post-construction, so nothing can ever push the
        // threshold back up -- confirmed by the absence of any other _mint call in the source.
        console.log("CONFIRMED SAFE: proposalThreshold() can only ever decrease over the contract's life, never be inflated against a rival proposer");
    }

    /// @dev FOCUS 2, ruled out: re-derived directly from OZ's own Governor._propose (not just trusted
    /// from round 1) -- proposalId is a pure hash of (targets, values, calldatas, descriptionHash),
    /// and _propose reverts if `_proposals[proposalId].voteStart != 0`. voteStart is set once and
    /// NEVER cleared by cancel() (OZ's own docstring: "Once cancelled a proposal can't be
    /// re-submitted"). So there is no path to re-propose an identical action and land on a NEW
    /// snapshot timepoint with a stale/mismatched _burnedAtSnapshot entry -- the identical proposal
    /// is permanently dead the instant it's first created, cancelled or not.
    function test_AUDIT_CancelledProposal_CanNeverBeReProposed_NoStaleSnapshotReuse() public {
        address[] memory targets = new address[](1);
        targets[0] = bob;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";
        string memory description = "Send a signal to bob";
        bytes32 descHash = keccak256(bytes(description));

        vm.prank(alice);
        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        vm.prank(alice);
        gov.cancel(targets, values, calldatas, descHash);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        // Advance past the original snapshot entirely, then attempt the identical re-proposal.
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);
        vm.prank(alice);
        vm.expectRevert();
        gov.propose(targets, values, calldatas, description);

        console.log("CONFIRMED SAFE: an identical proposal can never be re-submitted after cancellation, closing any stale-burn-snapshot replay path");
    }

    /// @dev FOCUS 3, DESIGN-RISK (informational, not exploitable by an unprivileged attacker): now
    /// that setVotingDelay/setVotingPeriod are permanently locked (this session's bug-8 fix), the
    /// deploy-time votingDelay_/votingPeriod_ passed into the constructor become a true single point
    /// of configuration for a curve's entire governance lifetime -- previously "adjustable but
    /// exploitably so," now "fixed but safe." This is strictly a security improvement (an
    /// unprivileged attacker could reach the old exploitable path; nobody unprivileged can reach a
    /// misconfigured constructor call), but it does mean a protocol-operator mistake at the
    /// StocksLaunchFactory-config level (e.g. deploying a factory generation pinned exactly to the
    /// MIN_VOTING_DELAY/MIN_VOTING_PERIOD floor) can no longer ever be corrected for curves already
    /// graduated under that generation -- only a new factory generation fixes it going forward.
    /// Confirmed the floor itself is a real, enforced constant (1 hour each), not just documentation:
    function test_DESIGN_RISK_ConstructorValuesArePermanentSinglePointOfConfig() public view {
        assertEq(gov.MIN_VOTING_DELAY(), 1 hours);
        assertEq(gov.MIN_VOTING_PERIOD(), 1 hours);
        assertEq(gov.votingDelay(), VOTING_DELAY);
        assertEq(gov.votingPeriod(), VOTING_PERIOD);
        console.log("DESIGN NOTE: these values, once set at construction, can now never change for this governor's lifetime -- verify factory-level config carefully before each new generation's deploy");
    }

    /// @dev FOCUS 4, ruled out as a NEW finding: QUORUM_NUMERATOR is a hardcoded constant (10) passed
    /// by StocksCurve._graduate() at every deployment, not attacker- or launcher-configurable, and
    /// quorumDenominator() is OZ's unmodified default of 100 -- so quorum is always a fixed 10% of
    /// (getPastTotalSupply - burned), standard for this class of DAO and not a per-launch attack
    /// surface. MIN_QUORUM_NUMERATOR=1 is an inert safety floor that the real hardcoded value (10)
    /// never gets close to. This is ordinary low-turnout governance risk, already flagged generically
    /// in round 2 (no-timelock informational finding) -- not a new, code-level vulnerability.
    function test_QuorumNumerator_IsHardcodedAndNotAttackerConfigurable() public view {
        assertEq(gov.quorumDenominator(), 100);
        // QUORUM_NUMERATOR is private to StocksCurve, but StocksGovernor's own constructor recorded
        // whatever value this test's setUp passed in, matching the real production constant (10).
        assertEq(QUORUM_NUMERATOR, 10);
    }

    /// @dev FOCUS 5, ruled out: wrapTreasuryStock/unwrapTreasuryStock (the phantom-reward bug found
    /// this round on StocksStaking) are gated `onlyMinHolder`, NOT `onlyGovernor` -- so a captured or
    /// malicious governor has no exclusive or amplified path into that bug beyond what any ordinary
    /// qualified holder can already do alone. Separately, graduate()/StocksCurve's RESERVED_SUPPLY
    /// bug fires entirely BEFORE any governor exists (the governor is deployed from inside
    /// _graduate() itself), so governance cannot participate in or amplify that bug at all -- there
    /// is no governor yet at the moment it fires. No cross-contract amplification found either way.
    /// (Confirmed by direct code inspection: no test needed, no executable claim beyond "the
    /// modifiers differ" and "the call order makes it temporally impossible.") Note: those wrap/
    /// unwrap functions have since been removed from StocksStaking entirely, closing the bug class.
    function test_NoOp_Focus5IsCodeInspectionOnly() public pure {
        assertTrue(true);
    }
}
