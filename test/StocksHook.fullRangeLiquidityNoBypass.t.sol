// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHookSolvencyBase} from "./StocksHook.solvency.t.sol";

/// @notice Follow-up to StocksHook.rangeOrderFeeBypass.t.sol: with narrow-range positions now rejected
/// outright, only full-range third-party liquidity remains possible (StocksHook.beforeAddLiquidity allows it
/// unconditionally, matching test_AUDIT_ThirdPartyFullLiquidityWithdrawal_NeverBricksPoolDespiteOutstandingTwammOrder
/// in StocksHook.audit5.t.sol, which already confirms this is intentional). This checks the same question the
/// original bypass targeted: can add-then-remove, timed around a price move, ever substitute for a taxed
/// swap() and come out ahead?
///
/// Structurally, a full-range position cannot replicate the original mechanism at all: unlike a narrow range
/// placed entirely above the current price (which can be funded ONE-SIDED, in pure TST, and converts to pure
/// stock as price crosses the whole band), a full-range position's modifyLiquidity call is priced at the
/// CURRENT sqrtPriceX96 and requires BOTH tokens in the ratio that price dictates -- there is no way to
/// "pre-stage" a one-sided directional bet the way the narrow-range bypass did.
///
/// Beyond that structural block, this also verifies the deeper reason no amount of clever timing can make
/// full-range add/remove profitable at all: for a zero-fee constant-product position (every pool here uses
/// fee: 0), the value of what comes back out after ANY price move is provably less than the value of simply
/// holding what went in -- textbook impermanent loss, with no direction in which it flips into a gain. Proven
/// below directly against the real PoolManager: the withdrawn amounts, valued at the post-move price, are
/// strictly less than the deposited amounts valued at that same price, across both directions of a large
/// price move -- confirming there is no free lunch to extract this way, not just no one-sided bypass.
contract StocksHookFullRangeLiquidityNoBypassTest is StocksHookSolvencyBase {
    using PoolIdLibrary for PoolKey;

    function _orderingMode() internal pure override returns (uint8) {
        return 1; // TST is currency0, stock is currency1
    }

    address lp = address(uint160(0x111111));
    address normalTrader = address(0xBEEF02);

    function _currentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
    }

    /// @dev Pushes price up a lot via an ordinary swap (stock in, TST out), same shape as the original bypass
    /// test's price-mover, just without any attacker position already staged in its path.
    function _normalTraderPushesPriceUp(uint256 amount) internal {
        stock.transfer(normalTrader, amount);
        vm.startPrank(normalTrader);
        stock.approve(address(swapRouter), amount);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @notice The LP deposits balanced full-range liquidity (the only kind allowed), an unrelated large
    /// trade moves price substantially, and the LP withdraws. Confirms genuine impermanent loss in the real
    /// implementation: what comes back, valued at the post-move price, is strictly less than what went in,
    /// valued at that same price -- there is no price move, in either direction, that turns full-range
    /// add/remove into a profitable substitute for a taxed swap.
    function test_FullRangeAddThenRemove_AroundALargePriceMove_IsNeverProfitable_PriceGoesUp() public {
        _checkNoFreeLunch(true);
    }

    function test_FullRangeAddThenRemove_AroundALargePriceMove_IsNeverProfitable_PriceGoesDown() public {
        _checkNoFreeLunch(false);
    }

    function _checkNoFreeLunch(bool priceGoesUp) internal {
        int24 minTick = TickMath.minUsableTick(60);
        int24 maxTick = TickMath.maxUsableTick(60);

        tst.transfer(lp, 10_000_000e18);
        stock.transfer(lp, 10_000_000e18);
        vm.startPrank(lp);
        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);

        BalanceDelta addDelta = lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick, tickUpper: maxTick, liquidityDelta: 3_000_000e18, salt: bytes32(uint256(9))}),
            ""
        );
        vm.stopPrank();
        // Both amounts are costs (negative), confirming a full-range add always takes both tokens -- there is
        // no way to fund this one-sided the way the narrow-range bypass could.
        uint256 tstDeposited = uint256(uint128(-addDelta.amount0()));
        uint256 stockDeposited = uint256(uint128(-addDelta.amount1()));
        assertGt(tstDeposited, 0, "sanity: full-range add always costs TST");
        assertGt(stockDeposited, 0, "sanity: full-range add always costs stock too -- cannot be funded one-sided");

        // An unrelated, ordinary trade moves price substantially in the chosen direction -- this trade pays
        // its own full flywheel cost on its own trade, same as every other test in this file's sibling.
        if (priceGoesUp) {
            _normalTraderPushesPriceUp(3_000_000e18);
        } else {
            // Push price down: TST in, stock out.
            tst.transfer(normalTrader, 3_000_000e18);
            vm.startPrank(normalTrader);
            tst.approve(address(swapRouter), 3_000_000e18);
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(3_000_000e18),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            vm.stopPrank();
        }

        uint160 sqrtPriceAfterMove = _currentSqrtPrice();

        vm.prank(lp);
        BalanceDelta removeDelta = lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick, tickUpper: maxTick, liquidityDelta: -3_000_000e18, salt: bytes32(uint256(9))}),
            ""
        );
        uint256 tstWithdrawn = uint256(uint128(removeDelta.amount0()));
        uint256 stockWithdrawn = uint256(uint128(removeDelta.amount1()));

        // Value everything at the SAME price (right after the move, in stock-per-TST terms, scaled 1e18) so
        // deposited and withdrawn amounts are directly comparable -- this is the real Uniswap v4 math, not
        // the idealized textbook formula.
        uint256 priceAfter = _priceStockPerTst(sqrtPriceAfterMove);
        uint256 depositedValueInStock = stockDeposited + (tstDeposited * priceAfter) / 1e18;
        uint256 withdrawnValueInStock = stockWithdrawn + (tstWithdrawn * priceAfter) / 1e18;

        console.log("deposited value (in stock terms, at post-move price):", depositedValueInStock);
        console.log("withdrawn value  (in stock terms, at post-move price):", withdrawnValueInStock);

        // The core claim: no free lunch. Withdrawn value must be strictly LESS than deposited value once
        // price has genuinely moved -- textbook impermanent loss, confirming there is no price move, in
        // either direction, that makes full-range add/remove a profitable substitute for a taxed swap.
        assertLt(withdrawnValueInStock, depositedValueInStock, "full-range LP must never come out ahead of what they put in, once price has moved");
    }

    /// @notice Sanity check on the fixture's own price/ratio math, used only to value both sides consistently
    /// above -- not part of the hook or curve logic itself.
    function _priceStockPerTst(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // TST is currency0 here (orderingMode 1): price of token0 in token1 terms = (sqrtPriceX96/2^96)^2.
        // Computed via the same mulDiv-with-squaring approach as StocksCurve.graduationMarginalPrice.t.sol.
        return _mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e18, 1 << 192);
    }

    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return (a * b) / denominator;
    }
}
