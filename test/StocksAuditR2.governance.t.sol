// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 2, governance and treasury business-logic attacks, on the real production stack.
contract StocksAuditR2GovernanceTest is StocksRedemptionAdversarialTest {
    StocksGovernor gov;

    function _gov() internal returns (StocksGovernor g) {
        g = StocksGovernor(payable(curve.governor()));
        gov = g;
    }

    /// @dev The holder (who holds most of the circulating supply here) delegates to themselves, proposes `data` on the
    /// staking contract, votes For, and waits out the window. Returns the pieces needed to execute.
    function _pass(bytes memory data, string memory description)
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descHash, uint256 id)
    {
        StocksGovernor g = _gov();
        vm.prank(holder);
        TSTToken(address(tst)).delegate(holder);
        vm.warp(_now() + 1);

        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(staking);
        calldatas[0] = data;
        descHash = keccak256(bytes(description));

        vm.prank(holder);
        id = g.propose(targets, values, calldatas, description);
        vm.warp(_now() + g.votingDelay() + 1);
        vm.prank(holder);
        g.castVote(id, 1);
        vm.warp(_now() + g.votingPeriod() + 1);
        assertEq(uint8(g.state(id)), uint8(IGovernor.ProposalState.Succeeded), "the proposal passed");
    }

    // ------------------------------------------------------------------------------------------------ C1

    /// @notice FINDING C1 (fixed). `liquidateTreasury(durationIntervals)` used to have no upper bound: a proposal that passed
    /// with an absurd duration (a typo, or a hostile vote) moved EVERY unallocated stock share into a TWAMM order that sold it
    /// at a negligible rate for a century, with no cancel path. The duration is now capped at MAX_LIQUIDATION_DURATION.
    function test_C1_ALongLiquidation_IsRejected_AndTheTreasuryStaysRedeemable() public {
        _fundTreasury(500e18);
        uint256 redeemableBefore = staking.redeemableStock();
        assertGt(redeemableBefore, 400e18, "a large redeemable treasury");

        uint256 interval = hook.expirationInterval();
        uint256 maxIntervals = staking.MAX_LIQUIDATION_DURATION() / interval;

        // 100 years of one-hour intervals: the proposal still PASSES the vote, but execution reverts
        uint256 intervals = 100 * 365 * 24;
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _pass(abi.encodeCall(StocksStaking.liquidateTreasury, (intervals)), "Liquidate over a century");
        vm.expectRevert();
        gov.execute(t, v, c, h);
        assertGt(staking.redeemableStock(), 300e18, "nothing moved: the treasury is still fully redeemable");
        assertEq(stock.balanceOf(address(hook)) < 1e15, true, "and the hook holds no order");

        // direct call by the governor: exact error, boundary accepted, one over rejected
        address g = curve.governor();
        vm.prank(g);
        vm.expectRevert(StocksStaking.LiquidationTooLong.selector);
        staking.liquidateTreasury(maxIntervals + 1);
        vm.prank(g);
        vm.expectRevert(StocksStaking.LiquidationTooLong.selector);
        staking.liquidateTreasury(type(uint256).max);
        vm.prank(g);
        (uint256 committed,) = staking.liquidateTreasury(maxIntervals);
        assertGt(committed, 0, "the longest allowed order is accepted");

        // and it finishes inside the cap: after the maximum duration everything has been sold and is claimable
        vm.warp(_now() + staking.MAX_LIQUIDATION_DURATION() + 1 hours);
        staking.claimLiquidatedTst();
        assertLt(stock.balanceOf(address(hook)), committed / 20, "the order has sold (almost) everything within the cap");
    }
}
