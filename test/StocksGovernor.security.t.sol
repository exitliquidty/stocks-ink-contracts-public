// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice V5 sibling of TreasuryGovernor.security.t.sol -- StocksGovernor is documented as
/// "identical mechanics" to TreasuryGovernor with exactly one real difference (a real per-launch
/// `name_` constructor param instead of a hardcoded literal). Ports every test from that suite to
/// confirm the shared mechanics genuinely carried over, then adds coverage for the one thing that
/// DID change (the name), plus the proposalThreshold()/quorum() circulating-supply math (which
/// excludes BURN_ADDRESS) that neither suite fuzzed before.
contract StocksGovernorSecurityTest is Test {
    TSTToken token;
    StocksGovernor gov;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant QUORUM_NUMERATOR = 10;
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, alice);
        vm.prank(alice);
        token.delegate(alice);

        gov = new StocksGovernor(
            string.concat(token.name(), " Governor"), IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_NUMERATOR
        );
    }

    function _propose(address target, bytes memory data, string memory description)
        internal
        returns (uint256 proposalId)
    {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;

        // See TreasuryGovernor.security.t.sol's identical comment: proposalThreshold() is checked
        // against votes at clock()-1, so alice's same-second delegate() in setUp needs one more
        // second to become a visible past checkpoint.
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        proposalId = gov.propose(targets, values, calldatas, description);
    }

    // ============================================================
    // Ported from TreasuryGovernor.security.t.sol -- confirms "identical mechanics" holds
    // ============================================================

    function test_SnapshotPreventsBuyThenVoteThenTransferThenVoteAgain() public {
        uint256 proposalId = _propose(address(0xCAFE), "", "Some action");
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        (, uint256 forVotesAfterAlice,) = gov.proposalVotes(proposalId);
        assertEq(forVotesAfterAlice, SUPPLY);

        vm.prank(alice);
        token.transfer(bob, SUPPLY);
        vm.prank(bob);
        token.delegate(bob);
        assertEq(token.getVotes(bob), SUPPLY);

        vm.prank(bob);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        (, uint256 forVotesAfterBob,) = gov.proposalVotes(proposalId);
        assertEq(forVotesAfterBob, forVotesAfterAlice);
    }

    function test_TokensAcquiredAfterSnapshot_HaveZeroVotingWeight() public {
        uint256 proposalId = _propose(address(0xCAFE), "", "Some action");
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        token.transfer(bob, 100e18);
        vm.prank(bob);
        token.delegate(bob);

        vm.prank(bob);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        (, uint256 forVotes,) = gov.proposalVotes(proposalId);
        assertEq(forVotes, 0);
    }

    function test_UndelegatedHolder_VotesWithZeroWeight() public {
        uint256 proposalId = _propose(address(0xCAFE), "", "Some action");
        vm.prank(alice);
        token.transfer(bob, 100e18); // bob never delegates

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(bob);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        (, uint256 forVotes,) = gov.proposalVotes(proposalId);
        assertEq(forVotes, 0);
    }

    function test_RevertWhen_VotingDelayBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(StocksGovernor.VotingDelayTooShort.selector, 0, gov.MIN_VOTING_DELAY()));
        new StocksGovernor("X Governor", IVotes(address(token)), 0, VOTING_PERIOD, 0, QUORUM_NUMERATOR);
    }

    function test_RevertWhen_VotingPeriodBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(StocksGovernor.VotingPeriodTooShort.selector, 1, gov.MIN_VOTING_PERIOD()));
        new StocksGovernor("X Governor", IVotes(address(token)), VOTING_DELAY, 1, 0, QUORUM_NUMERATOR);
    }

    function test_RevertWhen_QuorumNumeratorIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(StocksGovernor.QuorumNumeratorTooLow.selector, 0, gov.MIN_QUORUM_NUMERATOR()));
        new StocksGovernor("X Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 0, 0);
    }

    function test_MinimumBoundaryValues_DeploySuccessfully() public {
        StocksGovernor boundaryGov = new StocksGovernor(
            "X Governor", IVotes(address(token)), gov.MIN_VOTING_DELAY(), gov.MIN_VOTING_PERIOD(), 0, gov.MIN_QUORUM_NUMERATOR()
        );
        assertEq(boundaryGov.votingDelay(), gov.MIN_VOTING_DELAY());
        assertEq(boundaryGov.votingPeriod(), gov.MIN_VOTING_PERIOD());
        assertEq(boundaryGov.quorumNumerator(), gov.MIN_QUORUM_NUMERATOR());
    }

    // ============================================================
    // NEW: the one real difference from TreasuryGovernor -- a genuine per-launch name
    // ============================================================

    /// @dev TreasuryGovernor's own docstring flags this as the exact gap StocksGovernor exists to
    /// close: every TreasuryGovernor instance reports the identical hardcoded "TreasuryGovernor"
    /// name on an explorer or wallet-signing prompt, with nothing identifying which pool it
    /// governs. Confirms StocksGovernor's name() genuinely reflects the real per-launch value
    /// passed at construction, not another hardcoded literal.
    function test_Name_ReflectsRealPerLaunchValue_NotHardcoded() public {
        assertEq(gov.name(), "Tesla Stock Governor");

        TSTToken otherToken = new TSTToken("Apple Stock", "AAPLTST", SUPPLY, alice);
        StocksGovernor otherGov = new StocksGovernor(
            string.concat(otherToken.name(), " Governor"), IVotes(address(otherToken)), VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_NUMERATOR
        );
        assertEq(otherGov.name(), "Apple Stock Governor");
        assertTrue(keccak256(bytes(gov.name())) != keccak256(bytes(otherGov.name())));
    }

    // ============================================================
    // NEW: proposalThreshold()/quorum() circulating-supply math (excludes BURN_ADDRESS) --
    // not fuzzed by either this suite or TreasuryGovernor's own before now
    // ============================================================

    /// @dev Both proposalThreshold() and quorum() compute circulating supply as
    /// totalSupply - balanceOf(BURN_ADDRESS) -- burned TST tokens (from every regular trading fee)
    /// must never count toward either bar, or a heavily-burned (i.e. heavily-traded, mature) pool
    /// would see its OWN governance bars creep down as supply burns, making it progressively
    /// easier to propose/pass things over the pool's lifetime purely as a side effect of trading
    /// volume -- backwards from the intended "activity-independent, supply-proportional" bars.
    function testFuzz_BurnedSupply_NeverCountsTowardThresholdOrQuorum(uint256 burnAmount) public {
        burnAmount = bound(burnAmount, 0, SUPPLY - 1);
        uint256 expectedCirculating = SUPPLY - burnAmount;

        vm.prank(alice);
        token.transfer(BURN_ADDRESS, burnAmount);

        vm.warp(block.timestamp + 1);
        uint256 expectedThreshold = (expectedCirculating * gov.proposalThresholdBps()) / 10_000;
        assertEq(gov.proposalThreshold(), expectedThreshold);

        uint256 proposalId = _propose(address(0xCAFE), "", "Some action");
        // quorum(timepoint) does a checkpoint lookup that reverts (ERC5805FutureLookup) if
        // timepoint hasn't happened yet -- advance past the proposal's own snapshot (voteStart)
        // before querying it, same as every other test in this file already does before voting.
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        (,,, uint256 quorumAtSnapshot) = _proposalSnapshotQuorum(proposalId);
        // quorum() reads getPastTotalSupply/balanceOf at the proposal's own snapshot -- alice's
        // burn above already landed before the snapshot (same block, prior to _propose's warp),
        // so the expected value already reflects it.
        assertEq(quorumAtSnapshot, (expectedCirculating * QUORUM_NUMERATOR) / 100);
    }

    function _proposalSnapshotQuorum(uint256 proposalId)
        internal
        view
        returns (uint256 against, uint256 forVotes, uint256 abstain, uint256 quorumAtSnapshot)
    {
        (against, forVotes, abstain) = gov.proposalVotes(proposalId);
        quorumAtSnapshot = gov.quorum(gov.proposalSnapshot(proposalId));
    }
}
