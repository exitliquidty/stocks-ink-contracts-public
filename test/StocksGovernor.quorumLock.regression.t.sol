// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";

/// @dev Stand-in for StocksStaking: a function only the governor may call.
contract GovernedTarget {
    address public immutable governor;
    bool public poked;

    constructor(address governor_) {
        governor = governor_;
    }

    function poke() external {
        require(msg.sender == governor, "only governor");
        poked = true;
    }
}

/// @notice Regression tests for audit finding F-3: governance could lower its OWN quorum.
///
/// The bug: OpenZeppelin's `updateQuorumNumerator` is `onlyGovernance` (callable by any passing proposal
/// that targets the governor) and only rejects values ABOVE the denominator; `MIN_QUORUM_NUMERATOR` is
/// enforced in the constructor alone. One ordinary-looking proposal ("lower quorum to encourage
/// participation") passing at the normal 10% quorum could set it to 0, after which a holder with 0.30% of
/// supply passed proposals alone while nobody else voted. Same class V9 closed for the voting window.
///
/// The fix: `updateQuorumNumerator` now reverts, exactly like `setVotingDelay` / `setVotingPeriod`. Every
/// `onlyGovernance` function on the governor is then either locked, inert (`setProposalThreshold`, whose
/// stored value `proposalThreshold()` never reads, as documented in StocksGovernor.audit3.t.sol), or a
/// generic call (`relay`) that cannot bypass a reverting target.
contract StocksGovernorQuorumLockRegressionTest is Test {
    TSTToken token;
    StocksGovernor gov;
    GovernedTarget target;

    address whale = address(0xA11CE); // the holders who could pass a benign-looking first proposal
    address attacker = address(0xBAD); // holds just over the proposal threshold, nothing else

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant QUORUM_NUMERATOR = 10; // the real hardcoded value (StocksCurve.QUORUM_NUMERATOR)
    uint256 constant THRESHOLD_BPS = 25; // the intended mainnet profile (0.25% of circulating supply)

    function setUp() public {
        token = new TSTToken("Tesla Stock", "TSLATST", SUPPLY, whale);
        vm.prank(whale);
        token.transfer(attacker, 3_000_000e18); // 0.30%: just above the 0.25% proposal threshold
        vm.prank(whale);
        token.delegate(whale);
        vm.prank(attacker);
        token.delegate(attacker);

        gov = new StocksGovernor(
            "Tesla Stock Governor", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, THRESHOLD_BPS, QUORUM_NUMERATOR
        );
        target = new GovernedTarget(address(gov));
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ---------- helpers ----------

    function _propose(address proposer, address to, bytes memory data, string memory description)
        internal
        returns (uint256 id)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = to;
        calldatas[0] = data;
        vm.prank(proposer);
        id = gov.propose(targets, values, calldatas, description);
    }

    /// @dev Proposes, lets `voter` vote For (address(0) = nobody votes), and runs out the voting period.
    function _proposeAndVote(address proposer, address voter, address to, bytes memory data, string memory description)
        internal
        returns (uint256 id)
    {
        id = _propose(proposer, to, data, description);
        vm.warp(vm.getBlockTimestamp() + VOTING_DELAY + 1);
        if (voter != address(0)) {
            vm.prank(voter);
            gov.castVote(id, 1); // For
        }
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    function _execute(address to, bytes memory data, string memory description) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = to;
        calldatas[0] = data;
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _lowerQuorumCall(uint256 n) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("updateQuorumNumerator(uint256)", n);
    }

    function _relay(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("relay(address,uint256,bytes)", to, uint256(0), data);
    }

    // ---------- the original attack, now blocked ----------

    function test_ProposalToLowerQuorum_CanPassTheVote_ButNeverExecutes() public {
        string memory d = "Lower quorum to encourage participation";
        bytes memory data = _lowerQuorumCall(0);
        uint256 id = _proposeAndVote(whale, whale, address(gov), data, d);
        assertEq(uint256(gov.state(id)), uint256(IGovernor.ProposalState.Succeeded), "the vote itself can pass");

        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        _execute(address(gov), data, d);

        assertEq(gov.quorumNumerator(), QUORUM_NUMERATOR, "the quorum numerator is unchanged");
        assertEq(uint256(gov.state(id)), uint256(IGovernor.ProposalState.Succeeded), "and it never executed");
    }

    function test_AfterTheBlockedProposal_ALoneSmallHolderStillCannotPassAnything() public {
        bytes memory data = _lowerQuorumCall(0);
        string memory d = "Lower quorum to encourage participation";
        _proposeAndVote(whale, whale, address(gov), data, d);
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        _execute(address(gov), data, d);

        // The attacker (0.30% of supply) now tries a treasury action alone, nobody else voting.
        bytes memory poke = abi.encodeWithSignature("poke()");
        uint256 id = _proposeAndVote(attacker, attacker, address(target), poke, "Treasury action");
        assertEq(
            uint256(gov.state(id)),
            uint256(IGovernor.ProposalState.Defeated),
            "still defeated: the 10% quorum was never lowered"
        );
    }

    function test_Control_AtNormalQuorum_ALoneSmallHolderCannotPassAnything() public {
        uint256 id = _proposeAndVote(attacker, attacker, address(target), abi.encodeWithSignature("poke()"), "Treasury action");
        assertEq(uint256(gov.state(id)), uint256(IGovernor.ProposalState.Defeated));
    }

    // ---------- every way in ----------

    function test_DirectCall_RevertsForAnyoneIncludingTheGovernorItself() public {
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.updateQuorumNumerator(0);

        vm.prank(attacker);
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.updateQuorumNumerator(1);

        vm.prank(address(gov)); // the exact context onlyGovernance used to accept
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.updateQuorumNumerator(0);
    }

    function test_RelayPath_CannotReachIt() public {
        string memory d = "Relay a quorum change";
        bytes memory data = _relay(address(gov), _lowerQuorumCall(0));
        _proposeAndVote(whale, whale, address(gov), data, d);
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        _execute(address(gov), data, d);
        assertEq(gov.quorumNumerator(), QUORUM_NUMERATOR);
    }

    function test_RaisingQuorum_IsBlockedToo() public {
        vm.prank(address(gov));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.updateQuorumNumerator(100);
    }

    /// @dev Reviewed earlier and left alone on purpose: reachable, but inert, because proposalThreshold() is
    /// computed live from the immutable basis points and never reads the stored setting.
    function test_SetProposalThreshold_StaysReachableButInert() public {
        uint256 before_ = gov.proposalThreshold();
        bytes memory data = abi.encodeWithSignature("setProposalThreshold(uint256)", uint256(999_999_999e18));
        _proposeAndVote(whale, whale, address(gov), data, "Attempt to change the proposal threshold");
        _execute(address(gov), data, "Attempt to change the proposal threshold");
        assertEq(gov.proposalThreshold(), before_, "the live threshold ignores the stored value");
        assertEq(before_, ((SUPPLY) * THRESHOLD_BPS) / 10_000, "still 0.25% of circulating supply");
    }

    function test_VotingDelayAndPeriodSetters_StillRevert() public {
        vm.prank(address(gov));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.setVotingDelay(1);
        vm.prank(address(gov));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.setVotingPeriod(1);
    }

    // ---------- nothing else changed ----------

    function test_ViewsAndQuorumMathAreUnchanged() public {
        assertEq(gov.quorumNumerator(), 10);
        assertEq(gov.quorumDenominator(), 100);
        uint256 id = _propose(whale, address(target), abi.encodeWithSignature("poke()"), "x");
        uint256 snapshot = gov.proposalSnapshot(id);
        vm.warp(snapshot + 1); // quorum() only answers for timepoints in the past
        // 10% of the (fully unburned) 1B supply.
        assertEq(gov.quorum(snapshot), (SUPPLY * 10) / 100);
    }

    function test_ConstructorStillEnforcesTheMinimumQuorum() public {
        vm.expectRevert(abi.encodeWithSelector(StocksGovernor.QuorumNumeratorTooLow.selector, 0, gov.MIN_QUORUM_NUMERATOR()));
        new StocksGovernor("X", IVotes(address(token)), VOTING_DELAY, VOTING_PERIOD, THRESHOLD_BPS, 0);
    }

    function test_LegitimateProposals_StillPassAndExecute() public {
        bytes memory poke = abi.encodeWithSignature("poke()");
        _proposeAndVote(whale, whale, address(target), poke, "Treasury action");
        _execute(address(target), poke, "Treasury action");
        assertTrue(target.poked(), "ordinary governance actions are unaffected");
    }

    // ---------- randomized ----------

    /// @dev Whatever governance-only call a passing proposal makes on the governor (directly or through
    /// relay), with any argument, quorum, voting timing and thresholds stay exactly as deployed.
    function testFuzz_NoGovernanceCallCanChangeQuorumOrTiming(uint8 which, uint256 arg) public {
        bytes memory inner;
        uint256 pick = which % 7;
        if (pick == 0) inner = abi.encodeWithSignature("updateQuorumNumerator(uint256)", arg);
        else if (pick == 1) inner = abi.encodeWithSignature("setVotingDelay(uint48)", uint48(arg));
        else if (pick == 2) inner = abi.encodeWithSignature("setVotingPeriod(uint32)", uint32(arg));
        else if (pick == 3) inner = abi.encodeWithSignature("setProposalThreshold(uint256)", arg);
        else if (pick == 4) inner = _relay(address(gov), abi.encodeWithSignature("updateQuorumNumerator(uint256)", arg));
        else if (pick == 5) inner = _relay(address(gov), abi.encodeWithSignature("setVotingPeriod(uint32)", uint32(arg)));
        else inner = _relay(address(gov), abi.encodeWithSignature("setProposalThreshold(uint256)", arg));

        uint256 qn = gov.quorumNumerator();
        uint256 qd = gov.quorumDenominator();
        uint256 vd = gov.votingDelay();
        uint256 vp = gov.votingPeriod();
        uint256 pt = gov.proposalThreshold();

        string memory d = "fuzz";
        _proposeAndVote(whale, whale, address(gov), inner, d);
        // setProposalThreshold (picks 3 and 6) is reachable but inert by design; everything else is locked.
        if (pick != 3 && pick != 6) vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        _execute(address(gov), inner, d);

        assertEq(gov.quorumNumerator(), qn);
        assertEq(gov.quorumDenominator(), qd);
        assertEq(gov.votingDelay(), vd);
        assertEq(gov.votingPeriod(), vp);
        assertEq(gov.proposalThreshold(), pt);
    }

    function testFuzz_QuorumNumeratorIsFixedForAnyValue(uint256 n, bool asGovernor) public {
        if (asGovernor) vm.prank(address(gov));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        gov.updateQuorumNumerator(n);
        assertEq(gov.quorumNumerator(), QUORUM_NUMERATOR);
    }
}
