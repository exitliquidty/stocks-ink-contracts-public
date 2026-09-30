// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {StocksGraduationPriceSweepTest} from "./StocksGraduation.priceSweep.t.sol";

/// @notice Audit round 13 (external review, F7): "_graduate opens the pool at a different price from the curve
/// it replaces", claiming an early buyer gains ~58% by selling into the pool right after graduation because the
/// pool opens at 1.5x the curve's own realized average price for the graduating buy.
///
/// Refuted on two independent grounds:
/// 1. The review's own worked proof has a real arithmetic error. Re-derived with exact integer (BigInt) math using
///    this contract's actual constants (CURVE_SUPPLY=800_000_000e18, VIRTUAL_RESERVE_DIVISOR=3) and the review's
///    own example numbers (graduationStockTarget=100e18): the correct tstToSeed is 150,000,000e18, not the
///    400,000,000e18 the review's proof claims -- a 2.67x error that invalidates its "1.5x the average" conclusion.
/// 2. The real comparison to make isn't "pool price vs. curve's average price for one trade" -- it's "pool price
///    vs. the curve's own MARGINAL (instantaneous) price at the exact moment of graduation", since that's the
///    price continuity an AMM handoff actually needs (the same way Uniswap and other bonding-curve launches seed
///    at spot price, not at the average price paid across all prior trades). This file proves that marginal price
///    IS what the pool opens at, computed independently in Solidity from the curve's own public state
///    (virtualStockReserve, realStockCollected, tokensSold, CURVE_SUPPLY) and compared against the pool's actual
///    sqrtPriceX96 after a real graduation. Any upward-sloping bonding curve's average realized price for a trade
///    is always below its post-trade marginal price -- that gap is the normal, intended reward for buying earlier
///    on the curve, not a bug introduced at graduation.
contract StocksCurveGraduationMarginalPriceTest is StocksGraduationPriceSweepTest {
    /// @notice Reproduces the review's own scenario shape (single buy that exactly triggers graduation) and
    /// checks the pool's real opening price against the curve's own marginal price at that boundary, computed
    /// independently from the curve's public state -- not trusted from either side's hand arithmetic.
    function test_PoolOpensAtCurvesOwnMarginalPrice_NotAnExploitableJump() public {
        uint256 price = 500e18;
        (address token, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61); // past the snipe window

        uint256 target = curve.graduationStockTarget();

        // Single buy landing exactly on the graduation target, same shape as the review's own proof.
        vm.startPrank(whale);
        stock.approve(address(curve), target);
        curve.buy(target, 0);
        vm.stopPrank();

        assertEq(curve.realStockCollected(), target, "sanity: hit the target exactly, same as the review's proof");

        curve.graduate();
        assertTrue(curve.graduated(), "graduated");

        // The curve's own marginal (instantaneous) price at the graduation boundary, in stock-per-TST scaled by
        // 1e18, computed straight from its own public state -- the same state the review's own proof used.
        uint256 remaining = curve.CURVE_SUPPLY() - curve.tokensSold();
        uint256 oldVirtualStock = curve.virtualStockReserve() + curve.realStockCollected();
        uint256 curveMarginalPrice = FullMath.mulDiv(oldVirtualStock, 1e18, remaining);

        // The pool's real opening price, read back from its actual sqrtPriceX96 -- not derived from the same
        // formula being tested, so this is an independent cross-check, not a tautology.
        PoolKey memory key = StocksPoolView(curve.pair()).poolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(pm, id);
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;
        // price1Per0 = (sqrtPriceX96/2^96)^2, i.e. token1 per token0, scaled by 1e18.
        uint256 price1Per0 = FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e18, 1 << 192);
        // Normalize to stock-per-TST regardless of which currency ended up as token0.
        uint256 poolMarginalPrice = tstIsCurrency0 ? price1Per0 : FullMath.mulDiv(1e18, 1e18, price1Per0);

        // Within 0.5% -- the hook's tiny fixed reserve carve-out (HOOK_TST_RESERVE_WEI/HOOK_STOCK_RESERVE_WEI,
        // subtracted from the seed before sqrtPriceX96 is computed) and integer rounding account for the rest.
        uint256 diff = poolMarginalPrice > curveMarginalPrice
            ? poolMarginalPrice - curveMarginalPrice
            : curveMarginalPrice - poolMarginalPrice;
        assertLt(diff * 1000, curveMarginalPrice * 5, "pool must open at (approximately) the curve's own marginal price, not some other value");

        // Contrast with the review's own comparison point: the curve's AVERAGE realized price for the graduating
        // buy is, and is expected to be, materially below the marginal price above -- that gap is the normal
        // reward structure of any upward-sloping bonding curve, not evidence of a pricing bug at graduation.
        uint256 curveAveragePrice = FullMath.mulDiv(target, 1e18, curve.tokensSold());
        assertLt(curveAveragePrice, curveMarginalPrice, "sanity: average price for an upward-sloping curve is always below its post-trade marginal price");
    }
}
