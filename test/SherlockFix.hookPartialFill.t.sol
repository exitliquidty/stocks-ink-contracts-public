// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {StocksHookSolvencyBase} from "./StocksHook.solvency.t.sol";

/// @notice Sherlock review, StocksHook `afterSwap`: `beforeSwap` takes the protocol's cut on the full
/// specified input. If the price limit then stops the swap part-way, the cut was only rejected when it was at
/// least the whole fill, so a partial fill went through paying a cut far above the intended rate (their
/// example: 200 on 400 actually swapped).
///
/// The fix: a buy that the price limit stops short of its full input reverts.
contract SherlockHookPartialFillTest is StocksHookSolvencyBase {
    function _orderingMode() internal pure override returns (uint8) {
        return 1; // TST is currency0, stock is currency1: a buy is zeroForOne = false
    }

    address trader = address(0xBEEF01);
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function _buy(uint256 stockIn, uint160 limit) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: limit}),
            settings,
            ""
        );
    }

    /// @notice A buy of 10,000 whose price limit lets only about half of it through. The cut (200) is well
    /// under the fill (about 4,900), so before the fix this succeeded and the trader paid twice the intended
    /// rate. Now it reverts and the trader keeps everything.
    function test_BuyStoppedShortByItsPriceLimit_Reverts() public {
        uint256 half = 5_000e18;
        stock.transfer(trader, 2 * half);
        vm.prank(trader);
        stock.approve(address(swapRouter), type(uint256).max);

        // Find the price a full buy of `half` ends at, then put everything back.
        uint256 id = vm.snapshotState();
        vm.prank(trader);
        _buy(half, TickMath.MAX_SQRT_PRICE - 1);
        (uint160 priceAfterHalf,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        vm.revertToState(id);

        uint256 stockBefore = stock.balanceOf(trader);
        uint256 protocolBefore = stock.balanceOf(protocol);

        vm.expectRevert();
        this.buyExternal(2 * half, priceAfterHalf);

        assertEq(stock.balanceOf(trader), stockBefore, "the trader keeps everything");
        assertEq(stock.balanceOf(protocol), protocolBefore, "no cut is taken");
    }

    /// @dev External so that the revert happens one call deeper than the test frame.
    function buyExternal(uint256 stockIn, uint160 limit) external {
        vm.prank(trader);
        _buy(stockIn, limit);
    }

    /// @notice A buy whose price limit is never reached is untouched: the trader pays exactly the specified
    /// input and the protocol receives exactly its 2%.
    function test_BuyThatFillsCompletely_IsUnaffected() public {
        uint256 stockIn = 10_000e18;
        stock.transfer(trader, stockIn);
        uint256 stockBefore = stock.balanceOf(trader);
        uint256 protocolBefore = stock.balanceOf(protocol);

        vm.startPrank(trader);
        stock.approve(address(swapRouter), stockIn);
        BalanceDelta delta = _buy(stockIn, TickMath.MAX_SQRT_PRICE - 1);
        vm.stopPrank();

        assertGt(uint256(uint128(delta.amount0())), 0, "the trader receives TST");
        assertEq(stockBefore - stock.balanceOf(trader), stockIn, "the trader pays exactly the specified input");
        assertEq(stock.balanceOf(protocol) - protocolBefore, (stockIn * 1000 * 2000) / (10_000 * 10_000));
    }
}
