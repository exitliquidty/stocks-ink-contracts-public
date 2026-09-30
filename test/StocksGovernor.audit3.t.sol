// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice Round-3 audit finding on StocksGovernor, RESOLVED: this contract inherits
/// `GovernorSettings`, which exposes `setVotingDelay`/`setVotingPeriod`/`setProposalThreshold` as
/// `onlyGovernance` functions -- reachable via any successful proposal whose own `targets` includes
/// `address(this)` (confirmed against OZ's `Governor._executor()`, which returns `address(this)`
/// since no timelock is wired in here, matching round 2's own finding). `MIN_VOTING_DELAY`/
/// `MIN_VOTING_PERIOD` were ONLY checked in this contract's own constructor, with no re-enforcement
/// when `setVotingDelay`/`setVotingPeriod` were called later via a passed proposal -- meaning an
/// otherwise-unremarkable, floor-respecting proposal could permanently collapse the delay/period to
/// as little as 0/1, after which every future proposal on the same governor inherited the new,
/// unsafe timing (e.g. a near-instant second proposal on a 1-second window).
///
/// FIX: `setVotingDelay`/`setVotingPeriod` are now overridden in `StocksGovernor` to unconditionally
/// revert with `VotingSettingsAreImmutable` -- since nothing in this system ever needs to retune
/// timing post-launch (not exposed in the UI, no operational path relies on it), the capability is
/// removed entirely rather than narrowed to a re-checked floor. `votingDelay()`/`votingPeriod()`
/// stay permanently fixed at whatever the constructor already validated against
/// `MIN_VOTING_DELAY`/`MIN_VOTING_PERIOD`.
///
/// `StocksGovernor` separately overrides `proposalThreshold()` to ignore `GovernorSettings`'s own
/// stored value entirely (recomputed fresh from a hardcoded BPS constant and live circulating
/// supply) -- so `setProposalThreshold` remains reachable but INERT, changing nothing real; it did
/// not need the same immutability treatment.
contract StocksGovernorAudit3Test is Test {
    TSTToken token;
    StocksGovernor gov;

    address alice = address(0xA11CE);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant QUORUM_NUMERATOR = 10;

    function setUp() public {
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, alice);
        vm.prank(alice);
        token.delegate(alice);

        gov = new StocksGovernor(
            "Tesla Stock Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_NUMERATOR
        );

        vm.warp(block.timestamp + 1);
    }

    function _proposeVoteExecute(address target, bytes memory data, string memory description)
        internal
        returns (uint256 proposalId)
    {
        (proposalId,,,) = _proposeAndVoteToSucceeded(target, data, description);

        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        bytes32 descHash = keccak256(bytes(description));
        gov.execute(targets, values, calldatas, descHash);
    }

    /// @dev Proposes, votes to Succeeded, and stops right before execute() -- lets a test decide
    /// whether execute() is expected to succeed or revert.
    function _proposeAndVoteToSucceeded(address target, bytes memory data, string memory description)
        internal
        returns (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = target;
        values = new uint256[](1);
        values[0] = 0;
        calldatas = new bytes[](1);
        calldatas[0] = data;

        vm.prank(alice);
        proposalId = gov.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + gov.votingDelay() + 1);
        vm.prank(alice);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));

        vm.warp(block.timestamp + gov.votingPeriod() + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "sanity: proposal must genuinely succeed under current safe params");
    }

    /// @dev FIXED: an otherwise-normal, floor-respecting proposal can still pass a vote to lower
    /// votingDelay, but execute() now reverts instead of ever applying it -- votingDelay() stays
    /// permanently at the constructor-validated value.
    function test_AUDIT_SelfEscalatingVotingDelayProposal_NowRevertsOnExecute() public {
        assertEq(gov.votingDelay(), VOTING_DELAY, "sanity: starts at the safe, floor-respecting value");

        bytes memory data = abi.encodeWithSelector(GovernorSettings.setVotingDelay.selector, uint48(0));
        (, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeAndVoteToSucceeded(address(gov), data, "Lower voting delay to 0");

        bytes32 descHash = keccak256(bytes("Lower voting delay to 0"));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.execute(targets, values, calldatas, descHash);

        assertEq(gov.votingDelay(), VOTING_DELAY, "FIXED: votingDelay is untouched -- the proposal passed the vote but could never actually apply");
        console.log("CONFIRMED FIXED: a passed proposal targeting setVotingDelay reverts on execute() and changes nothing");
    }

    /// @dev FIXED: same for votingPeriod -- proves the self-escalation chain (collapse period, then
    /// exploit it with a fast second proposal) described in the round-3 finding can no longer even
    /// get past step one.
    function test_AUDIT_SelfEscalatingVotingPeriodProposal_NowRevertsOnExecute() public {
        assertEq(gov.votingPeriod(), VOTING_PERIOD, "sanity: starts at the safe, floor-respecting value");

        bytes memory data = abi.encodeWithSelector(GovernorSettings.setVotingPeriod.selector, uint32(1));
        (, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeAndVoteToSucceeded(address(gov), data, "Lower voting period to 1 second");

        bytes32 descHash = keccak256(bytes("Lower voting period to 1 second"));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.execute(targets, values, calldatas, descHash);

        assertEq(gov.votingPeriod(), VOTING_PERIOD, "FIXED: votingPeriod is untouched -- no proposal can ever shorten the window for future proposals");
        console.log("CONFIRMED FIXED: votingPeriod can never be collapsed via governance, closing the near-instant-second-proposal escalation");
    }

    /// @dev Confirms setProposalThreshold is reachable but inert -- StocksGovernor's own override
    /// ignores GovernorSettings' stored value entirely, so this specific setter poses no risk.
    function test_SetProposalThreshold_ReachableButInert() public {
        uint256 before = gov.proposalThreshold();
        bytes memory data = abi.encodeWithSelector(GovernorSettings.setProposalThreshold.selector, uint256(999_999_999e18));
        _proposeVoteExecute(address(gov), data, "Attempt to change proposal threshold");
        assertEq(gov.proposalThreshold(), before, "proposalThreshold() must be unaffected -- it's computed fresh from the immutable proposalThresholdBps set at construction, not GovernorSettings' stored value");
        console.log("CONFIRMED SAFE: setProposalThreshold changes GovernorSettings' internal storage but proposalThreshold() ignores it entirely");
    }
}
