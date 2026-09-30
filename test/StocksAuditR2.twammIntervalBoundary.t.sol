// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 5 (external review finding, independently reproduced and fixed): the vendored TWAMM rounds a
/// new order's virtual start down to the BEGINNING of the current expirationInterval, not to the real moment it was
/// submitted. An order submitted moments before an interval boundary therefore has up to one whole interval's worth
/// of its sell rate applied to that single, already-mostly-elapsed interval -- it can execute almost entirely within
/// the first real second after submission instead of selling gradually. Since a governance proposal's `execute()` can
/// be called by anyone at any time once it has passed, an attacker who times execution one second before a boundary
/// (rather than the proposer, who has no reason to) could turn a supposedly gradual, MEV-resistant liquidation into
/// an instant dump. Fixed with `StocksStaking.MIN_LIQUIDATION_DURATION = 1 days`: the worst case is always at most
/// one interval's SHARE of the order, so requiring the order to span many intervals bounds that share to a small
/// fraction instead of nearly all of it.
contract StocksAuditR2TwammIntervalBoundaryTest is StocksRedemptionAdversarialTest {
    /// @dev The exact shape of the finding, confirmed by calling the vendored hook directly (the same call
    /// StocksStaking.liquidateTreasury would have made pre-fix, bypassing the new minimum so the raw defect is
    /// visible): an order submitted one second before a boundary sells almost the entire committed amount within
    /// that one real second, while the same order submitted exactly ON a boundary sells nothing yet.
    function test_TheUnderlyingTimingDefect_ExistsInTheVendoredHookItself() public {
        uint256 interval = hook.expirationInterval();
        uint256 boundary = (block.timestamp / interval + 1) * interval;

        // case A: one second before the boundary
        uint256 snap = vm.snapshotState();
        vm.warp(boundary - 1);
        stock.approve(address(hook), type(uint256).max);
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: !tstIsCurrency0, duration: interval, amountIn: 500e18})
        );
        uint256 poolStockBefore = stock.balanceOf(address(pm));
        vm.warp(boundary);
        hook.executeTWAMMOrders(key);
        uint256 soldEarly = stock.balanceOf(address(pm)) - poolStockBefore;
        console.log("submitted 1s before a boundary: sold within 1 real second (thousandths):", (soldEarly * 1000) / 500e18);
        assertGt((soldEarly * 1000) / 500e18, 900, "the underlying defect really does front-load almost the whole order");
        vm.revertToState(snap);

        // case B: exactly on the boundary
        vm.warp(boundary);
        stock.approve(address(hook), type(uint256).max);
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: !tstIsCurrency0, duration: interval, amountIn: 500e18})
        );
        poolStockBefore = stock.balanceOf(address(pm));
        vm.warp(boundary + 1);
        hook.executeTWAMMOrders(key);
        uint256 soldOnBoundary = stock.balanceOf(address(pm)) - poolStockBefore;
        console.log("submitted exactly on a boundary: sold within 1 real second (thousandths):", (soldOnBoundary * 1000) / 500e18);
        assertEq(soldOnBoundary, 0, "aligned submission does not front-load");
    }

    // ------------------------------------------------------------------------------ the fix, via StocksStaking

    /// @notice A liquidation duration below MIN_LIQUIDATION_DURATION is refused outright, however many intervals it
    /// spans -- this is the actual, real-world entry point (StocksStaking.liquidateTreasury), not the raw hook call
    /// above.
    function test_LiquidationBelowTheMinimumDuration_Reverts() public {
        uint256 interval = hook.expirationInterval();
        uint256 minIntervals = staking.MIN_LIQUIDATION_DURATION() / interval;
        _fundTreasury(500e18);
        vm.prank(curve.governor());
        vm.expectRevert(StocksStaking.LiquidationTooShort.selector);
        staking.liquidateTreasury(minIntervals - 1);

        // the boundary itself is accepted
        vm.prank(curve.governor());
        (uint256 committed,) = staking.liquidateTreasury(minIntervals);
        assertGt(committed, 0);
    }

    /// @notice Once MIN_LIQUIDATION_DURATION is enforced, the same worst-case timing (an execute() called one second
    /// before an interval boundary) front-loads at most about one interval's share of the order, not nearly all of
    /// it: a small, bounded fraction instead of an instant dump.
    function test_MinDuration_BoundsTheWorstCaseFrontLoadToOneIntervalsShare() public {
        uint256 interval = hook.expirationInterval();
        uint256 minIntervals = staking.MIN_LIQUIDATION_DURATION() / interval;
        uint256 boundary = (block.timestamp / interval + 1) * interval;
        vm.warp(boundary - 1);

        _fundTreasury(500e18);
        uint256 poolStockBefore = stock.balanceOf(address(pm));
        vm.prank(curve.governor());
        (uint256 committed,) = staking.liquidateTreasury(minIntervals);

        vm.warp(boundary);
        hook.executeTWAMMOrders(key);
        uint256 stockSoldIntoPool = stock.balanceOf(address(pm)) - poolStockBefore;
        console.log("MIN duration, worst-case timing: sold within 1 real second (thousandths):", (stockSoldIntoPool * 1000) / committed);
        // bounded near 1/minIntervals of the order, not the whole thing (some slack for price-impact/slippage effects)
        assertLt(stockSoldIntoPool * minIntervals, committed * 2, "front-loaded share stays close to 1/minIntervals");
    }

    /// @notice For a long liquidation (near the 30-day cap), the same worst-case timing front-loads a negligible
    /// fraction: this round's fix does not change the behaviour that round 2/3 already proved safe for realistic,
    /// long-running liquidations -- it specifically closes the SHORT-duration gap.
    function test_LongLiquidation_WorstCaseTimingStaysNegligible() public {
        uint256 interval = hook.expirationInterval();
        uint256 maxIntervals = staking.MAX_LIQUIDATION_DURATION() / interval;
        uint256 boundary = (block.timestamp / interval + 1) * interval;
        vm.warp(boundary - 1);

        _fundTreasury(500e18);
        uint256 poolStockBefore = stock.balanceOf(address(pm));
        vm.prank(curve.governor());
        (uint256 committed,) = staking.liquidateTreasury(maxIntervals);

        vm.warp(boundary);
        hook.executeTWAMMOrders(key);
        uint256 stockSoldIntoPool = stock.balanceOf(address(pm)) - poolStockBefore;
        console.log("30-day order, worst-case timing: sold within 1 real second (thousandths):", (stockSoldIntoPool * 1000) / committed);
        // bounded near 1/maxIntervals of the order (roughly 0.14% at the 720-interval cap), with slack for slippage
        assertLt(stockSoldIntoPool * maxIntervals, committed * 2, "front-loaded share stays close to 1/maxIntervals, negligible at this length");
    }
}
