// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHookSolvencyBase} from "./StocksHook.solvency.t.sol";

/// @notice Audit round 13 (external review, F8): "_emitSwapEvent adds preSwapStockCut to a delta that already
/// contains it", claiming the buy-direction Swap event over-reports the trader's real input by double-counting
/// the pre-swap protocol cut, since `-delta.amount0()`/`-delta.amount1()` (the core swap's own BalanceDelta)
/// supposedly already includes it.
///
/// Refuted directly, at the v4-core level: `Hooks.sol`'s own `beforeSwap` wrapper does
/// `amountToSwap += hookDeltaSpecified` BEFORE the core swap runs, where `hookDeltaSpecified` is exactly
/// `protocolStockCut` (positive, returned by `StocksHook.beforeSwap` via `toBeforeSwapDelta`). Since
/// `amountToSwap` starts negative (exact input), adding a positive `protocolStockCut` REDUCES its magnitude --
/// the core swap that actually produces `delta` runs on `stockIn - protocolStockCut`, not the full `stockIn`.
/// So `-delta.amount0()` (or `amount1()`) is already NET of the cut, and `_emitSwapEvent` adding
/// `preSwapStockCut` back is exactly what's needed to reconstruct the trader's true total input -- not a
/// double-count. This file proves it by reading the trader's own real wallet delta (the actual amount they
/// paid, external ground truth) against the `inputAmount` the Swap event actually reports, using the real
/// StocksHook event ABI directly (not the review's own unverified arithmetic).
contract StocksHookEmitSwapEventAccountingTest is StocksHookSolvencyBase {
    // Same convention as StocksHook.rangeOrderFeeBypass.t.sol: orderingMode 1 fixes TST as the lower-address
    // token, i.e. always currency0, so every direction below is unambiguous without needing a helper.
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    address trader = address(0xBEEF01);

    // Matches StocksHook.sol's own event signature exactly.
    event Swap(
        bytes32 indexed poolId,
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 feeToken0,
        uint256 feeToken1,
        address indexed to
    );

    /// @notice Buy-direction swap (stock in, TST out -- the branch F8 targets, where beforeSwap takes a
    /// pre-swap protocol cut from the stock input). Confirms the Swap event's reported input EXACTLY equals
    /// the trader's real wallet cost, not something larger from double-counting the cut.
    function test_BuyDirectionSwap_EmittedInputMatchesTradersRealCost_NoDoubleCount() public {
        uint256 stockIn = 10_000e18;
        stock.transfer(trader, stockIn);

        vm.startPrank(trader);
        stock.approve(address(swapRouter), stockIn);

        uint256 traderStockBefore = stock.balanceOf(trader);

        vm.recordLogs();
        // TST is currency0 (orderingMode 1), so paying stock (currency1) in means zeroForOne = false.
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(stockIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 realStockPaid = traderStockBefore - stock.balanceOf(trader);
        assertEq(realStockPaid, stockIn, "sanity: trader must pay exactly what they specified");

        // Pull the hook's own Swap event out of the recorded logs and decode its reported input.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic0 = keccak256("Swap(bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,address)");
        bool found;
        uint256 reportedAmount0In;
        uint256 reportedAmount1In;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == swapTopic0) {
                (reportedAmount0In, reportedAmount1In,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                found = true;
                break;
            }
        }
        assertTrue(found, "sanity: the hook's own Swap event must have been emitted");

        // Stock is currency1 here (TST is currency0), and stock is what the trader input -- so the input
        // must be reported on the amount1In side, with amount0In at zero.
        uint256 reportedInput = reportedAmount1In;
        assertEq(reportedAmount0In, 0, "sanity: the non-input side must report zero");

        // The actual check: the emitted input must equal what the trader really paid, not
        // (stockIn - protocolStockCut) + protocolStockCut counted twice on top of the real cost.
        assertEq(reportedInput, realStockPaid, "Swap event must report the trader's real total input exactly once, not double-count the pre-swap cut");
    }
}
