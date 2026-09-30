// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice Stands in for a StocksStaking-style treasury target -- a single call that takes real,
/// immediate, irreversible effect the instant it's invoked (mirrors governorLiquidate/
/// governorSetPaused's own "fires the moment execute() lands" shape), so this test can observe a
/// concrete before/after state change rather than just an abstract proposal-state transition.
contract MockTreasuryTarget {
    bool public liquidated;

    function liquidate() external {
        liquidated = true;
    }
}

/// @notice Round-2 audit, design observation (not a code defect): StocksGovernor inherits
/// Governor + GovernorSettings + GovernorCountingSimple + GovernorVotes +
/// GovernorVotesQuorumFraction -- notably NOT GovernorTimelockControl or
/// GovernorTimelockCompound. With neither wired in, `execute()` runs a passed proposal's calldata
/// immediately: there is no timelock delay between a proposal reaching Succeeded and its real,
/// irreversible on-chain effect landing. Since round 1 already established what a proposal here
/// can authorize -- StocksStaking's governorLiquidate/governorSetDuration/governorSetPaused,
/// i.e. real treasury-affecting actions on real stock backing -- this means stakers get their
/// only advance notice during the voting period itself; the moment voting closes Succeeded,
/// anyone can call execute() in the very next block with zero further warning or exit window.
///
/// This is not a bug in the sense of "not working as coded" -- Governor's own execute() has
/// always worked this way absent a timelock extension, and nothing in this contract's own logic
/// is incorrect. It's flagged because the combination of (a) real treasury authority and (b) zero
/// execution delay is a materially different risk profile than a purely advisory vote, and
/// nothing in this repo documents this as a deliberate choice the way, e.g., the reserved-supply
/// dilution question was explicitly raised and resolved earlier this session. Worth the project
/// owner's explicit sign-off (or a GovernorTimelockControl addition) rather than silent inheritance
/// of OZ's un-timelocked default.
contract StocksGovernorAudit2Test is Test {
    TSTToken token;
    StocksGovernor gov;
    MockTreasuryTarget treasury;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant QUORUM_NUMERATOR = 10; // 10% of circulating supply

    function setUp() public {
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, alice);

        vm.prank(alice);
        token.delegate(alice);

        gov = new StocksGovernor(
            "Tesla Stock Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_NUMERATOR
        );

        treasury = new MockTreasuryTarget();

        vm.warp(block.timestamp + 1);
    }

    function test_AUDIT_NoTimelock_TreasuryActionExecutesImmediatelyOnceVoteSucceeds() public {
        address[] memory targets = new address[](1);
        targets[0] = address(treasury);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(MockTreasuryTarget.liquidate, ());
        bytes32 descriptionHash = keccak256(bytes("Liquidate the treasury"));

        vm.prank(alice);
        uint256 proposalId = gov.propose(targets, values, calldatas, "Liquidate the treasury");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        gov.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));

        // Voting period ends -- this is the ONLY window stakers ever had to react.
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "sanity: vote succeeded");
        assertFalse(treasury.liquidated(), "not yet executed");

        // No timelock delay exists to insert here -- execute() can be called the very next block,
        // with zero further notice, and the real, irreversible effect lands immediately.
        gov.execute(targets, values, calldatas, descriptionHash);

        assertTrue(treasury.liquidated(), "AUDIT: treasury action took real, irreversible effect the instant execute() was called, with no timelock window after voting closed");
    }
}
