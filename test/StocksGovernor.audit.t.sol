// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice Round-2 audit finding on StocksGovernor, FIXED: quorum() used to mix a
/// properly-snapshotted getPastTotalSupply(timepoint) with a LIVE (current-block)
/// balanceOf(BURN_ADDRESS). Since Governor.state() re-evaluates _quorumReached() ->
/// quorum(proposalSnapshot(id)) fresh on every single call (never caches it at vote-close time),
/// the quorum bar for an ALREADY-SNAPSHOTTED, even ALREADY-CLOSED vote could be lowered after the
/// fact by anyone burning TST -- something any holder can always do (BURN_ADDRESS is just a plain
/// transfer target). This was one-directional (burning can only shrink circulating supply, never
/// grow it), so the only exploitable direction was turning an under-quorum (Defeated) proposal into
/// a quorum-met one after voting had already closed, purely by burning tokens that never voted for
/// it -- not "governance being powerful", but the quorum check itself no longer meaning what it's
/// supposed to mean once voting locks in.
///
/// Fixed in StocksGovernor by freezing each proposal's burn-exclusion amount in _propose(), the one
/// point a timepoint is ever assigned -- see _burnedAtSnapshot's own comment there. This file now
/// proves both directions: the original exploit no longer reproduces (test #1), and quorum still
/// correctly shrinks for a genuinely NEW proposal created after real burning has already happened
/// (test #2) -- the fix closes the manipulation without freezing quorum at the token's original,
/// ever-more-unreachable-over-time fixed supply.
///
/// testFuzz_BurnedSupply_NeverCountsTowardThresholdOrQuorum in StocksGovernor.security.t.sol only
/// burns BEFORE the proposal is created and never burns again -- it couldn't see the pre-fix bug,
/// because the live burn balance never changed between snapshot time and query time in that test.
/// Its own comment ("quorum() reads getPastTotalSupply/balanceOf at the proposal's own snapshot")
/// was only half true pre-fix: the total-supply half was a real snapshot read, the balanceOf half
/// was not -- now both halves are genuinely frozen at the snapshot.
contract StocksGovernorAuditTest is Test {
    TSTToken token;
    StocksGovernor gov;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant QUORUM_NUMERATOR = 10; // 10% of circulating supply
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, alice);

        // alice keeps 950,000,000e18; bob gets 50,000,000e18 (5% of total supply) -- bob's own
        // vote alone is meant to be far short of the real 10%-of-1B = 100,000,000e18 quorum.
        vm.prank(alice);
        token.transfer(bob, 50_000_000e18);

        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);

        gov = new StocksGovernor(
            "Tesla Stock Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_NUMERATOR
        );

        vm.warp(block.timestamp + 1);
    }

    function _propose() internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = address(0xCAFE);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(alice);
        proposalId = gov.propose(targets, values, calldatas, "Some action");
    }

    function test_AUDIT_BurningAfterVoteCloses_NoLongerMovesQuorum() public {
        uint256 proposalId = _propose();

        // _propose() just froze this proposal's burn-exclusion at whatever balanceOf(BURN_ADDRESS)
        // was at proposal-creation time (zero, here -- nobody has burned anything yet).
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Only bob votes, with 5% of total supply -- far under the real 10% quorum bar computed
        // against the untouched 1,000,000,000e18 circulating supply (100,000,000e18 needed, bob
        // only has 50,000,000e18). Alice deliberately abstains from voting at all: her balance
        // still counts toward circulating supply for the quorum bar, just not toward the tally.
        vm.prank(bob);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));

        uint256 quorumBeforeBurn = gov.quorum(gov.proposalSnapshot(proposalId));
        assertEq(quorumBeforeBurn, 100_000_000e18, "sanity: 10% of untouched 1B supply");

        // Voting period fully closes -- this proposal is genuinely, finally Defeated for lack of
        // quorum, by the numbers everyone who voted saw.
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Defeated), "closes as Defeated");

        // Alice never voted on this proposal at all. She now burns 500,000,000e18 of her own,
        // untouched TST -- an action with zero connection to this specific vote's outcome from
        // any voter's perspective, done well after every voter has already seen the result.
        vm.prank(alice);
        token.transfer(BURN_ADDRESS, 500_000_000e18);

        // FIXED: quorum() now reads the burn-exclusion frozen at _propose() time (still zero),
        // never a live balanceOf -- Alice's post-close burn has zero effect on this proposal's
        // quorum bar, which stays exactly what every voter saw while the vote was actually open.
        uint256 quorumAfterBurn = gov.quorum(gov.proposalSnapshot(proposalId));
        assertEq(quorumAfterBurn, 100_000_000e18, "FIX: quorum unmoved by a post-close burn");

        // The proposal's outcome cannot be flipped after the fact anymore.
        assertEq(
            uint8(gov.state(proposalId)),
            uint8(IGovernor.ProposalState.Defeated),
            "FIX: closed, Defeated proposal stays Defeated despite the post-vote burn"
        );
    }

    /// @notice The other half of the fix: quorum must still be allowed to shrink over time as this
    /// system's routine, ongoing TST burning (see StocksHook's fee routing) genuinely reduces
    /// circulating supply -- freezing the exclusion at proposal-creation time must never mean
    /// freezing it at the token's ORIGINAL fixed supply forever. A proposal created AFTER a real,
    /// large burn gets a smaller, accurate quorum bar computed against the post-burn circulating
    /// supply, not the untouched 1,000,000,000e18 total.
    function test_AUDIT_QuorumStillShrinks_ForNewProposalAfterRealBurn() public {
        // A real burn happens well before any proposal exists -- 600,000,000e18 gone, leaving
        // 400,000,000e18 genuinely circulating (alice's remaining 350,000,000e18 + bob's
        // 50,000,000e18).
        vm.prank(alice);
        token.transfer(BURN_ADDRESS, 600_000_000e18);

        uint256 proposalId = _propose();
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // 10% of the real, already-shrunk 400,000,000e18 circulating supply -- not 10% of the
        // original 1,000,000,000e18. The fix's snapshot-at-propose-time design correctly picks up
        // burning that already happened before this proposal was ever created.
        uint256 quorumForNewProposal = gov.quorum(gov.proposalSnapshot(proposalId));
        assertEq(quorumForNewProposal, 40_000_000e18, "quorum reflects real burning that predates this proposal");

        // Bob's full 50,000,000e18 for-vote now clears that smaller, accurate bar.
        vm.prank(bob);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(
            uint8(gov.state(proposalId)),
            uint8(IGovernor.ProposalState.Succeeded),
            "quorum correctly reachable once real burning has shrunk circulating supply"
        );
    }
}
