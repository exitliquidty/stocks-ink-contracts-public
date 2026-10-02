// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice Audit round 2: governor boundaries and one subtle guarantee (the burn snapshot of a proposal is never
/// overwritten by a later proposal in the same second) that a mutation run showed no test was pinning.
contract StocksAuditR2GovernorEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    TSTToken token;
    StocksGovernor gov;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, alice);
        vm.prank(alice);
        token.delegate(alice);
        gov = new StocksGovernor("Tesla Governor", IVotes(address(token)), 1 hours, 1 hours, 0, 10);
    }

    /// @dev External so `vm.expectRevert` can be used more than once in a test (a revert inside `new` in the test's own
    /// frame would end the test at that line).
    function deployGov(uint256 thresholdBps) external returns (StocksGovernor) {
        return new StocksGovernor("G", IVotes(address(token)), 1 hours, 1 hours, thresholdBps, 10);
    }

    function test_ProposalThresholdBps_AcceptsExactly100Percent_RefusesOneMore() public {
        vm.expectRevert(abi.encodeWithSelector(StocksGovernor.ProposalThresholdBpsTooHigh.selector, 10_001));
        this.deployGov(10_001);

        StocksGovernor full = this.deployGov(10_000);
        assertEq(full.proposalThreshold(), SUPPLY, "100% of the circulating supply");
        StocksGovernor none = this.deployGov(0);
        assertEq(none.proposalThreshold(), 0);
    }

    function _propose(string memory description) internal returns (uint256 id) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(0xCAFE);
        vm.prank(alice);
        id = gov.propose(targets, values, calldatas, description);
    }

    /// @notice Two proposals created in the same second share one snapshot timepoint. The burn balance for that timepoint
    /// is recorded exactly once, by the first vote, and nothing afterwards can move it -- a bar that drifted once voting
    /// had begun would be unfixable, since quorum itself is immutable.
    ///
    /// The value is read at the snapshot rather than at proposal creation. Those are a whole votingDelay apart and TST
    /// burns continuously in between, so a burn landing before the snapshot genuinely belongs in the subtraction:
    /// crediting circulating supply with tokens that are already gone would put quorum above its true value and fail
    /// proposals that should pass.
    function test_TheBurnSnapshot_OfASharedTimepoint_IsRecordedOnceAndNeverMovesAfterwards() public {
        vm.warp(block.timestamp + 1);
        uint256 a = _propose("first");
        uint256 snapshot = gov.proposalSnapshot(a);

        // a large burn lands in the same second, then a second proposal is created
        vm.prank(alice);
        token.transfer(BURN, SUPPLY / 2);
        uint256 b = _propose("second");
        assertEq(gov.proposalSnapshot(b), snapshot, "both proposals share the snapshot timepoint");

        vm.warp(snapshot + 1);
        // The burn landed before the snapshot, so it counts against circulating supply.
        uint256 expected = ((SUPPLY - SUPPLY / 2) * 10) / 100;
        assertEq(gov.quorum(snapshot), expected, "a burn before the snapshot is counted against circulating supply");

        // The first vote fixes the figure for this timepoint...
        vm.prank(alice);
        gov.castVote(a, 1);
        assertEq(gov.quorum(snapshot), expected, "voting records the value it was already reading");

        // ...and a later burn cannot move it, for either proposal sharing that timepoint.
        vm.prank(alice);
        token.transfer(BURN, SUPPLY / 4);
        assertEq(gov.quorum(snapshot), expected, "a burn after the snapshot was recorded must not move quorum");

        vm.prank(alice);
        gov.castVote(b, 1);
        assertEq(gov.quorum(snapshot), expected, "a second proposal cannot overwrite the recorded snapshot");
    }

    /// @notice A burn that lands BEFORE any proposal of that second is counted, as intended.
    function test_ABurnBeforeTheFirstProposal_IsCounted() public {
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        token.transfer(BURN, SUPPLY / 2);
        uint256 a = _propose("first");
        uint256 snapshot = gov.proposalSnapshot(a);
        vm.warp(snapshot + 1);
        assertEq(gov.quorum(snapshot), ((SUPPLY / 2) * 10) / 100, "quorum is 10% of the non-burned supply");
    }
}
