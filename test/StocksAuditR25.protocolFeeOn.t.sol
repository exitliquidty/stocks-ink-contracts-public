// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Round 25: what happens if Uniswap turns the v4 PROTOCOL fee on for a Stocks.ink pool.
///
/// Every pool here is created with an LP fee of 0, and earlier rounds leaned on that: rounds 3 and 6 classed four
/// TWAMM mutants as equivalent "because activeFee is provably always 0 ... setProtocolFee is never called anywhere
/// in first-party code". That is true of this repo and not of the PoolManager: `setProtocolFee` belongs to the
/// PoolManager's protocolFeeController, which Uniswap's owner can appoint at any time (on Ink it is currently
/// address(0)). The fee is capped at 0.1% per direction and is taken from every swap's input, including the
/// hook's own TWAMM swaps. Nothing in this protocol can prevent or undo it, so the code has to stay solvent
/// with it on. These tests run a busy, mixed scenario with the fee at its maximum and check exactly that.
contract StocksAuditR25ProtocolFeeOnTest is StocksRedemptionAdversarialTest {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _liquidate(uint256 n) internal returns (uint256 committed, bytes32 orderId) {
        address gov = curve.governor();
        vm.prank(gov);
        (committed, orderId) = staking.liquidateTreasury(n);
    }

    function _sellTstVia(address who, uint256 tstIn) internal {
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

    function _order(address who, bool sellTst, uint256 amount, uint256 intervals)
        internal
        returns (ITWAMM.OrderKey memory ok)
    {
        vm.startPrank(who);
        (sellTst ? tst : stock).approve(address(hook), amount);
        (, ok) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({
                key: key,
                zeroForOne: sellTst ? tstIsCurrency0 : !tstIsCurrency0,
                duration: intervals * 1 hours,
                amountIn: amount
            })
        );
        vm.stopPrank();
    }

    /// @dev Syncs an order and claims; returns false if the hook could not pay everything it owed this owner.
    function _syncAndClaimInFull(address who, ITWAMM.OrderKey memory ok) internal returns (bool paidInFull) {
        vm.startPrank(who);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: ok}));
        uint256 owed0 = hook.tokensOwed(key.currency0, who);
        uint256 owed1 = hook.tokensOwed(key.currency1, who);
        (uint256 got0, uint256 got1) = hook.claimTokensByPoolKey(key);
        vm.stopPrank();
        paidInFull = got0 == owed0 && got1 == owed1;
    }

    function _scenario(bool feeOn) internal returns (uint256 hookTstLeft, uint256 hookStockLeft) {
        if (feeOn) {
            pm.setProtocolFeeController(address(this));
            pm.setProtocolFee(key, (uint24(1000) << 12) | 1000); // the maximum, both directions
        }
        deal(address(tst), alice, 40_000_000e18);
        deal(address(stock), alice, 1_000e18);
        deal(address(tst), bob, 40_000_000e18);
        deal(address(stock), bob, 1_000e18);

        _fundTreasury(150e18);
        vm.warp(_now() + 1 hours);
        _liquidate(30); // treasury: stock -> TST, 30 intervals
        ITWAMM.OrderKey memory aliceOrder = _order(alice, true, 20_000_000e18, 12); // opposing: TST -> stock
        ITWAMM.OrderKey memory bobOrder = _order(bob, false, 7e18, 20); // competing: stock -> TST

        // 32 hours of mixed trading. Odd hours are skipped entirely so some catch-ups span two intervals, and one
        // alternating-direction pair of short orders is dropped in midway to force netting in both directions.
        ITWAMM.OrderKey memory aliceShort;
        ITWAMM.OrderKey memory bobShort;
        for (uint256 h = 1; h <= 32; ++h) {
            vm.warp(_now() + 1 hours);
            if (h % 2 == 1) continue;
            if (h % 4 == 0) _buyTst(trader, 3e18);
            else _sellTstVia(alice, 1_500_000e18);
            if (h == 6) {
                aliceShort = _order(alice, true, 5_000_000e18, 3);
                bobShort = _order(bob, false, 9e18, 2);
            }
        }

        vm.warp(_now() + 2 hours);
        staking.claimLiquidatedTst();
        assertEq(hook.tokensOwed(Currency.wrap(address(tst)), address(staking)), 0, "the treasury was paid in full");

        assertTrue(_syncAndClaimInFull(alice, aliceOrder), "alice's long order paid in full");
        assertTrue(_syncAndClaimInFull(bob, bobOrder), "bob's long order paid in full");
        assertTrue(_syncAndClaimInFull(alice, aliceShort), "alice's short order paid in full");
        assertTrue(_syncAndClaimInFull(bob, bobShort), "bob's short order paid in full");

        // an ordinary swap in each direction still works afterwards
        _buyTst(trader, 1e18);
        _sellTstVia(alice, 100_000e18);

        hookTstLeft = tst.balanceOf(address(hook));
        hookStockLeft = stock.balanceOf(address(hook));
    }

    function test_ProtocolFeeAtMaximum_EveryOrderIsPaidInFull_AndTheHookKeepsItsReserve() public {
        uint256 id = vm.snapshotState();
        (uint256 tstOff, uint256 stockOff) = _scenario(false);
        vm.revertToState(id);
        (uint256 tstOn, uint256 stockOn) = _scenario(true);

        console.log("hook TST left   -- protocol fee off / on:", tstOff, tstOn);
        console.log("hook stock left -- protocol fee off / on:", stockOff, stockOn);

        // Everyone has been paid, so whatever the hook still holds is its graduation reserve (100 TST and 1e12
        // stock wei) give or take rounding. With the fee on it must not have had to dip into that reserve.
        assertGe(tstOn + 1e9, graduator.HOOK_TST_RESERVE_WEI(), "TST reserve intact with the protocol fee on");
        assertGe(stockOn + 1e6, graduator.HOOK_STOCK_RESERVE_WEI(), "stock reserve intact with the protocol fee on");
        assertGe(tstOff + 1e9, graduator.HOOK_TST_RESERVE_WEI(), "control: TST reserve intact with it off");
        assertGe(stockOff + 1e6, graduator.HOOK_STOCK_RESERVE_WEI(), "control: stock reserve intact with it off");
    }

    /// @dev The pre-swap protocol cut is sized off the trader's specified input; the PoolManager's own fee then
    /// comes out of the same input. A buy must still go through and still be charged both, in that order.
    function test_ProtocolFeeAtMaximum_BuysAndSellsStillSettle_AndTheFlywheelIsStillCharged() public {
        pm.setProtocolFeeController(address(this));
        pm.setProtocolFee(key, (uint24(1000) << 12) | 1000);

        uint256 protocolBefore = stock.balanceOf(protocol);
        uint256 burnBefore = tst.balanceOf(BURN);
        uint256 got = _buyTst(trader, 10e18);
        assertGt(got, 0, "the buy filled");
        assertEq(stock.balanceOf(protocol) - protocolBefore, 10e18 * 200 / 10_000, "2% of the stock in went to the protocol");
        uint256 burned = tst.balanceOf(BURN) - burnBefore;
        assertApproxEqRel(burned, (got * 800) / 9_200, 1e12, "8% of the TST out was burned");

        uint256 treasuryBefore = stock.balanceOf(address(staking));
        deal(address(tst), alice, 1_000_000e18);
        uint256 aliceStockBefore = stock.balanceOf(alice);
        _sellTstVia(alice, 1_000_000e18);
        uint256 aliceGot = stock.balanceOf(alice) - aliceStockBefore;
        uint256 toTreasury = stock.balanceOf(address(staking)) - treasuryBefore;
        assertGt(aliceGot, 0, "the sell filled");
        assertApproxEqRel(toTreasury, (aliceGot * 800) / 9_000, 1e12, "8% of the stock out went to the treasury");
    }
}
