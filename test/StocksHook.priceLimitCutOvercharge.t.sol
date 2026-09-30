// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {StocksHookSolvencyBase} from "./StocksHook.solvency.t.sol";

/// @notice Audit round 13 (external review lead, doc1: "A swap stopped by its price limit pays the cut on
/// unswapped stock" -- StocksHook.beforeSwap; doc2's results table: "Protocol took 2,000 stock when the fair
/// cut was 20"). Investigating whether this is real, and how bad, rather than trusting the review's own
/// unverified number or dismissing it as "self-harm only" without checking.
///
/// Confirmed real and independently quantified: `beforeSwap` sizes `protocolStockCut` off the trader's full
/// SPECIFIED input (`stockIn = uint256(-params.amountSpecified)`), before the core swap runs and before it's
/// known whether a tight `sqrtPriceLimitX96` will truncate the actual fill. The cut is taken unconditionally
/// via `poolManager.take()` inside `beforeSwap`. Traced through v4-core's own `Hooks.sol`: the caller's final
/// delta is `swapDelta - hookDelta` (afterSwap), where `swapDelta` is the CORE swap's own delta -- computed on
/// the truncated fill if the price limit stops it early -- and `hookDelta` still carries the FULL
/// specified-amount cut. So a trader whose price limit truncates their trade pays the full, large cut on top
/// of only a small truncated fill, not a proportional cut on what actually executed.
///
/// This file reproduces it directly: a trader specifies a large stockIn but sets a tight price limit that
/// truncates the actual core fill to a small fraction of it, and measures the real total cost against what a
/// fair, proportional cut on the ACTUAL fill would have been.
///
/// Fixed in StocksHook.afterSwap: rather than attempting a partial refund (afterSwap's own returned delta can
/// only adjust the unspecified/output currency, never the specified/input stock side the cut was taken from,
/// and a raw ERC20 refund to `sender` risks landing in a router contract instead of the real trader), the
/// trade now reverts outright (`PreSwapCutWouldExceedActualFill`) whenever the already-taken cut would consume
/// the entire real fill or more -- the trader gets a clean revert to retry with a wider limit, never a
/// one-sided loss. This file proves both: the truncated-fill overcharge scenario now reverts, and an ordinary,
/// untruncated trade is completely unaffected.
contract StocksHookPriceLimitCutOverchargeTest is StocksHookSolvencyBase {
    function _orderingMode() internal pure override returns (uint8) {
        return 1; // TST is currency0, stock is currency1
    }

    address trader = address(0xBEEF01);

    function _currentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
    }

    /// @notice Before the fix (this exact scenario, unmodified harness): a 100_000e18 stockIn buy with a
    /// price limit 1 tick above the current price truncated the real fill to a small fraction of that, while
    /// the protocol still took its full ~2,000e18 cut sized off the whole 100_000e18 -- a cut that alone
    /// exceeded the entire truncated trade. After the fix, this reverts cleanly instead.
    function test_TightPriceLimitTruncatesFill_NowRevertsInsteadOfOvercharging() public {
        uint256 stockIn = 100_000e18;
        stock.transfer(trader, stockIn);

        int24 tickBefore = _currentTick();
        // A price limit just 1 tick above the current price -- the swap can barely move before stopping,
        // truncating the core fill to a small fraction of the specified 100_000e18.
        uint160 tightLimit = TickMath.getSqrtPriceAtTick(tickBefore + 1);

        uint256 traderStockBefore = stock.balanceOf(trader);

        vm.startPrank(trader);
        stock.approve(address(swapRouter), stockIn);
        // Bare vm.expectRevert() -- PoolManager wraps hook-internal reverts in WrappedError(...), same
        // convention as this codebase's other hook-internal-revert checks (see
        // StocksHook.rangeOrderFeeBypass.t.sol's own comment on this).
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: tightLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Nothing moved -- a clean revert, not a partial, one-sided loss.
        assertEq(stock.balanceOf(trader), traderStockBefore, "trader must not lose anything on a reverted swap");
    }

    /// @notice No regression: an ordinary trade with a price limit wide enough to never bind (the normal
    /// case, and what every other passing fee-routing test already uses) still works exactly as before --
    /// the new check only fires when the cut would consume the entire real fill or more, which a normal,
    /// untruncated ~2% cut never comes close to.
    function test_WidePriceLimit_OrdinaryTradeStillWorksNormally() public {
        uint256 stockIn = 10_000e18;
        stock.transfer(trader, stockIn);

        uint256 traderStockBefore = stock.balanceOf(trader);
        uint256 protocolStockBefore = stock.balanceOf(protocol);

        vm.startPrank(trader);
        stock.approve(address(swapRouter), stockIn);
        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertGt(uint256(uint128(delta.amount0())), 0, "trader must receive TST");
        uint256 realStockPaid = traderStockBefore - stock.balanceOf(trader);
        assertEq(realStockPaid, stockIn, "trader pays exactly the specified input, same as before the fix");

        uint256 expectedCut = (stockIn * 1000 * 2000) / (10_000 * 10_000);
        assertEq(stock.balanceOf(protocol) - protocolStockBefore, expectedCut, "protocol still gets its fair cut on an ordinary, untruncated trade");
    }
}
