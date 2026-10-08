// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @notice Sherlock review, StocksGovernor `quorum`: the burned balance used for a proposal's quorum was the
/// live one until the first vote, which then pinned it. Anyone could pin it with a zero-weight vote, and
/// leaving the first vote late lowered the quorum by everything burned in the meantime.
///
/// The fix: TSTToken keeps a history of the burn address's balance (`getPastBurned`) and the governor reads
/// it at the proposal's snapshot. One fixed figure per proposal.
contract SherlockGovernorQuorumSnapshotTest is Test {
    TSTToken token;
    StocksGovernor gov;

    address whale = address(0xA11CE);
    address voter = address(0xB0B);
    address nobody = address(0x1234);
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, whale);
        vm.prank(whale);
        token.delegate(whale);
        gov = new StocksGovernor("Tesla Stock Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, 25, 10);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _burn(address from, uint256 amount) internal {
        vm.prank(from);
        token.transfer(BURN, amount);
    }

    function _propose(string memory description) internal returns (uint256 id) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(0xCAFE);
        vm.prank(whale);
        id = gov.propose(targets, values, calldatas, description);
    }

    /// @notice Burns after the snapshot, a zero-weight first vote and a late first vote all leave the quorum
    /// where the snapshot put it.
    function test_QuorumIsFixedAtTheSnapshot() public {
        _burn(whale, 100_000_000e18);
        uint256 id = _propose("a");
        uint256 snapshot = gov.proposalSnapshot(id);
        vm.warp(snapshot + 1);

        uint256 expected = ((SUPPLY - 100_000_000e18) * 10) / 100;
        assertEq(gov.quorum(snapshot), expected, "10% of circulating supply at the snapshot");

        // Before the fix this burn, landing before the first vote, lowered the quorum.
        _burn(whale, 50_000_000e18);
        assertEq(gov.quorum(snapshot), expected, "a burn after the snapshot does not move it");

        // Before the fix this zero-weight vote was what pinned the figure.
        vm.prank(nobody);
        gov.castVote(id, 1);
        assertEq(gov.quorum(snapshot), expected, "a zero-weight vote does not move it");

        _burn(whale, 10_000_000e18);
        assertEq(gov.quorum(snapshot), expected, "nor does a burn after the first vote");
    }

    /// @notice What is burned between proposal creation and the snapshot is excluded, as intended.
    function test_BurnBeforeTheSnapshotIsCounted() public {
        uint256 id = _propose("b");
        uint256 snapshot = gov.proposalSnapshot(id);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _burn(whale, 30_000_000e18);
        vm.warp(snapshot + 1);
        assertEq(gov.quorum(snapshot), ((SUPPLY - 30_000_000e18) * 10) / 100);
    }

    /// @notice A holder cannot vote with its snapshot balance and also lower the bar by burning that balance
    /// once voting has opened. 95M votes against a 100M quorum stays short. Before the fix the burn pulled the
    /// quorum down to 90.5M and the proposal passed.
    function test_BurningAfterTheSnapshotCannotLowerTheBar() public {
        vm.prank(whale);
        token.transfer(voter, 95_000_000e18);
        vm.prank(voter);
        token.delegate(voter);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 id = _propose("c");
        uint256 snapshot = gov.proposalSnapshot(id);
        vm.warp(snapshot + 1);

        _burn(voter, 95_000_000e18);
        vm.prank(voter);
        gov.castVote(id, 1);

        vm.warp(gov.proposalDeadline(id) + 1);
        assertEq(gov.quorum(snapshot), 100_000_000e18);
        assertEq(uint256(gov.state(id)), uint256(IGovernor.ProposalState.Defeated));
    }

    /// @notice The token's burn history returns the balance as of each time.
    function test_GetPastBurned_ReturnsTheBalanceAtEachTime() public {
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(token.getPastBurned(t0), 0);

        vm.warp(t0 + 100);
        _burn(whale, 5e18);
        vm.warp(t0 + 200);
        _burn(whale, 7e18);
        _burn(whale, 1e18); // a second burn in the same second
        vm.warp(t0 + 300);

        assertEq(token.getPastBurned(t0 + 99), 0);
        assertEq(token.getPastBurned(t0 + 100), 5e18);
        assertEq(token.getPastBurned(t0 + 199), 5e18);
        assertEq(token.getPastBurned(t0 + 200), 13e18);
        assertEq(token.getPastBurned(t0 + 300), 13e18);
        assertEq(token.balanceOf(BURN), 13e18);
    }
}
