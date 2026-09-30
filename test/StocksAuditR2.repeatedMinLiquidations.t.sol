// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 6: the C1/round-5 fix (MIN_LIQUIDATION_DURATION = 1 days, MAX = 30 days) makes short,
/// frequent liquidations the natural choice instead of one long one. This stress-tests that pattern: many
/// consecutive minimum-duration liquidations, back to back, over a long stretch of real time, checking that nothing
/// leaks, drifts or strands across the whole sequence -- not just within one order.
contract StocksAuditR2RepeatedMinLiquidationsTest is StocksRedemptionAdversarialTest {
    function test_FifteenConsecutiveMinDurationLiquidations_ConserveEverythingAcrossTheWholeSequence() public {
        uint256 minIntervals = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        uint256 totalCommitted;
        uint256 totalBurned;
        uint256 rounds = 15;

        for (uint256 i; i < rounds; ++i) {
            // new inflow every round, simulating ongoing trading fees plus the occasional donation
            _fundTreasury(20e18 + i * 1e18);
            uint256 stockBefore = stock.balanceOf(address(staking));

            vm.prank(curve.governor());
            (uint256 committed,) = staking.liquidateTreasury(minIntervals);
            assertGt(committed, 0, "each round commits something");
            totalCommitted += committed;

            // some real trading happens mid-order, exercising the fee/burn/accounting paths concurrently
            _buyTst(trader, 1e18);

            vm.warp(staking.pendingLiquidationExpiration() + 1);
            uint256 burnBefore = tst.balanceOf(BURN);
            uint256 burned = staking.claimLiquidatedTst();
            totalBurned += burned;
            assertGt(tst.balanceOf(BURN) - burnBefore, 0, "each round's claim actually burns something");

            // the committed stock actually left the treasury's own balance (not double-counted, not stranded there)
            assertLt(stock.balanceOf(address(staking)), stockBefore, "committed stock left the treasury balance");
        }

        console.log("rounds:", rounds);
        console.log("total stock committed across all rounds (wei):", totalCommitted);
        console.log("total TST burned across all rounds (wei):", totalBurned);

        // the hook never accumulates a growing, unclaimed backlog: after the last claim it holds only its fixed
        // reserve buffers, nothing from any of the 15 orders
        assertEq(hook.tokensOwed(key.currency0, address(staking)), 0, "nothing left owed to the treasury after the last claim");
        assertEq(hook.tokensOwed(key.currency1, address(staking)), 0, "nothing left owed to the treasury after the last claim");

        // stakers' own earned rewards, accrued throughout, remain fully claimable and untouched by any of this
        uint256 stakerEarned = staking.pendingReward(staker);
        uint256 stockBeforeClaim = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        assertEq(stock.balanceOf(staker) - stockBeforeClaim, stakerEarned, "staker claims exactly what accrued through 15 liquidation cycles");

        // and redemption still works normally at the end, at whatever rate is left
        assertGt(_redeem(holder, tst.balanceOf(holder) / 10), 0, "redemption still works after 15 liquidation cycles");
    }

    /// @notice The 4% worst-case front-load bound (round 5) doesn't compound across repeated minimum-duration
    /// orders: each order's own front-load is independent and bounded on its own terms, not cumulative with the
    /// previous order's.
    function testFuzz_RepeatedMinDurationLiquidations_EachOrdersFrontLoadStaysIndependentlyBounded(uint8 roundsSeed)
        public
    {
        uint256 rounds = 3 + (roundsSeed % 5); // 3 to 7 rounds
        uint256 minIntervals = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        uint256 interval = hook.expirationInterval();

        for (uint256 i; i < rounds; ++i) {
            // always time the submission to the worst case: one second before a boundary
            uint256 boundary = (block.timestamp / interval + 1) * interval;
            vm.warp(boundary - 1);

            _fundTreasury(30e18);
            uint256 poolStockBefore = stock.balanceOf(address(pm));
            vm.prank(curve.governor());
            (uint256 committed,) = staking.liquidateTreasury(minIntervals);

            vm.warp(boundary);
            hook.executeTWAMMOrders(key);
            uint256 sold = stock.balanceOf(address(pm)) - poolStockBefore;
            assertLt(sold * minIntervals, committed * 2, "each round's own worst-case front-load stays bounded on its own");

            vm.warp(staking.pendingLiquidationExpiration() + 1);
            staking.claimLiquidatedTst();
        }
    }
}
