// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 2: can a trader profitably sandwich the treasury's TWAMM liquidation, extracting value from it?
///
/// The liquidation sells the treasury's stock for TST over time. TWAMM executes lazily, so an attacker who controls when
/// the accumulated slices execute can try to (1) buy TST just before, pushing the price up so the treasury's stock buys
/// fewer TST, then (2) sell back. The flywheel cost of about 10% on each leg is the defense; this measures whether it is
/// enough, for orders of different sizes relative to the pool.
contract StocksAuditR2MevTest is StocksRedemptionAdversarialTest {
    function _sell(address who, uint256 amountIn) internal returns (uint256 stockBack) {
        uint256 before = stock.balanceOf(who);
        vm.startPrank(who);
        tst.approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tstIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        stockBack = stock.balanceOf(who) - before;
    }

    /// @dev Runs the liquidation of `committed` stock over 24 hours and returns the TST it bought (and burned), with an
    /// optional sandwich of `attackStock` around the moment the accumulated slices execute after `idleHours` of nobody
    /// touching the pool. Also returns what the attacker ended with minus what it started with, in stock.
    function _run(uint256 committed, uint256 attackStock, uint256 idleHours)
        internal
        returns (uint256 tstBurnedByOrder, int256 attackerPnl)
    {
        _fundTreasury(committed);
        // stakers keep what they have earned so far; the liquidation takes the rest
        vm.prank(address(0)); // no-op, keeps the pranks below explicit
        address gov = curve.governor();
        vm.prank(gov);
        staking.liquidateTreasury(24);

        vm.warp(_now() + idleHours * 1 hours);

        uint256 burnBefore = tst.balanceOf(BURN);
        int256 pnl;
        if (attackStock > 0) {
            uint256 stockBefore = stock.balanceOf(trader);
            uint256 tstBefore = tst.balanceOf(trader);
            _buyTst(trader, attackStock); // 1) push the price up
            // 2) the accumulated slices execute now, at the inflated price (any swap or this call triggers it)
            hook.executeTWAMMOrders(key);
            uint256 tstHeld = tst.balanceOf(trader) - tstBefore;
            _sell(trader, tstHeld); // 3) sell everything back
            pnl = int256(stock.balanceOf(trader)) - int256(stockBefore);
        } else {
            hook.executeTWAMMOrders(key);
        }

        vm.warp(_now() + 25 hours);
        burnBefore; // (the attacker's own flywheel burns are in the burn balance, so the order's proceeds are read directly)
        tstBurnedByOrder = staking.claimLiquidatedTst();
        attackerPnl = pnl;
    }

    function test_Sandwich_OfTheLiquidation_IsUnprofitable_AtEverySize() public {
        uint256 poolStock = stock.balanceOf(address(pm));
        console.log("pool stock (wei):", poolStock);

        uint256[3] memory orderSizes = [poolStock / 20, poolStock / 5, poolStock / 2]; // 5%, 20%, 50% of the pool
        uint256[4] memory attackSizes = [poolStock / 50, poolStock / 10, poolStock / 4, poolStock];

        for (uint256 i = 0; i < orderSizes.length; i++) {
            uint256 snap = vm.snapshotState();
            (uint256 honestBurn,) = _run(orderSizes[i], 0, 12);
            vm.revertToState(snap);

            for (uint256 j = 0; j < attackSizes.length; j++) {
                uint256 snap2 = vm.snapshotState();
                (uint256 burnUnderAttack, int256 pnl) = _run(orderSizes[i], attackSizes[j], 12);
                vm.revertToState(snap2);
                int256 lostByTreasury = int256(honestBurn) - int256(burnUnderAttack);
                // the treasury's loss in stock terms: the order's proceeds valued at the pool's price after the attack
                console.log("order % of pool, attack % of pool:");
                console.log(orderSizes[i] * 100 / poolStock, attackSizes[j] * 100 / poolStock);
                console.log("  attacker pnl (stock wei), treasury order proceeds lost (TST wei), honest proceeds (TST wei):");
                console.logInt(pnl);
                console.logInt(lostByTreasury);
                console.log(honestBurn);
                assertLt(pnl, 0, "the sandwich must lose money");
                // and the damage to the order is small in every case: under 5% of what an honest run collects
                assertLt(uint256(lostByTreasury > 0 ? lostByTreasury : int256(0)) * 20, honestBurn, "the order loses under 5%");
            }
        }
    }
}
