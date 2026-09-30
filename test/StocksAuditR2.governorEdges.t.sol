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

    /// @notice Two proposals created in the same second share one snapshot timepoint. The burn balance recorded for that
    /// timepoint must be the one seen by the FIRST proposal: a later proposal in the same second must not overwrite it, or
    /// someone could burn tokens between the two proposals and shift the first proposal's quorum after it was created.
    function test_TheBurnSnapshot_OfASharedTimepoint_IsNotOverwrittenByALaterProposal() public {
        vm.warp(block.timestamp + 1);
        uint256 a = _propose("first");
        uint256 snapshot = gov.proposalSnapshot(a);

        // a large burn lands in the same second, then a second proposal is created
        vm.prank(alice);
        token.transfer(BURN, SUPPLY / 2);
        uint256 b = _propose("second");
        assertEq(gov.proposalSnapshot(b), snapshot, "both proposals share the snapshot timepoint");

        vm.warp(snapshot + 1);
        // the quorum for that timepoint is what the first proposal saw: nothing burned yet
        assertEq(gov.quorum(snapshot), (SUPPLY * 10) / 100, "the first proposal's quorum ignores the later burn");
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
