// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {StocksGraduationPriceSweepTest} from "./StocksGraduation.priceSweep.t.sol";

/// @notice Audit round 13 (external review lead, doc1: "The graduation seed floor opens the pool below the
/// last curve price"; doc2's results table: "Pool opened 48% below the curve price; holders' TST worth about
/// half", triggered by "a big buy nearly sells out the curve").
///
/// Confirmed real and independently quantified with this codebase's own real constants (CURVE_SUPPLY,
/// TOTAL_SUPPLY, VIRTUAL_RESERVE_DIVISOR, MIN_TST_SEED_SUPPLY_BPS), not the review's own unverified numbers:
/// a single buy overshooting the graduation target by 50x (the top of this codebase's own pre-existing fuzz
/// range in StocksGraduation.priceSweep.t.sol) left the seed's price-matched TST amount below `minSeed`
/// (StocksGraduator.MIN_TST_SEED_SUPPLY_BPS, 1% of TOTAL_SUPPLY), so `_graduate` floored `tstToSeed` UP to
/// `minSeed` while `stockToSeed` stayed at the real (unaffected) `realStockCollected` -- opening the pool at
/// only ~53% of the curve's own marginal price, i.e. ~47% below, matching the review's own "48% below" figure
/// closely. Every existing TST holder's tokens silently repriced lower the instant that pool opened, with no
/// action of their own.
///
/// There is no fix that keeps both the floor AND price-correctness: proportionally scaling `stockToSeed` up to
/// match a floored `tstToSeed` at the true price would need more real stock than the curve ever actually
/// collected -- it doesn't exist to seed with. Fixed in `_graduate`: the floor is removed outright, the seed is
/// always exactly price-matched, and `StocksGraduator`'s own pre-existing `SeedTooSmall()` check (already
/// there for this exact reason, previously unreachable because the curve always topped `tstToSeed` up first)
/// now does its job -- refusing to graduate at a distorted price rather than silently opening a mispriced
/// pool.
///
/// SUPERSEDED (external AuditAgent scan, 2026-09-30, finding #8): the round-13 fix above only stopped the
/// mispriced pool from opening -- it still let an extreme buy succeed and then left the curve needing a
/// rescue partial-sell-back before graduate() would work. StocksCurve.buy() now carries its own
/// SeedWouldBeUnreachable() guard (checked BEFORE the trade executes, not after) that rejects the one
/// individual overshoot trade outright, so the curve can never enter that state in the first place -- no
/// rescue sell-back is ever needed. Proven below: the exact same 50x-overshoot buy that used to require a
/// rescue now simply reverts at buy()-time, and the trader can immediately retry with a smaller, allowed
/// amount on the very same curve.
contract StocksCurveGraduationSeedFloorTest is StocksGraduationPriceSweepTest {
    /// @notice The exact scenario this bug used to mishandle: a 50x overshoot buy. Before round 13's fix this
    /// silently opened the pool ~47% below the curve's marginal price; after round 13 it let the buy through
    /// but rejected graduate() instead; after this round's buy()-side guard, the buy itself is rejected
    /// up front and nothing ever needs mispricing or rescuing.
    function test_ExtremeOvershoot_NowRevertsAtBuyTimeInsteadOfMispricingThePool() public {
        uint256 price = 500e18;
        (, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        uint256 stockIn = target * 50; // 5000% overshoot, this codebase's own prior fuzz ceiling

        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        // Bare vm.expectRevert(): StocksCurve.SeedWouldBeUnreachable() fires directly inside buy() now,
        // rather than StocksGraduator.SeedTooSmall() bubbling up through a later graduate() call -- kept bare
        // to stay robust to exactly which of the two (now both still present) identically-purposed checks
        // would end up firing on a given overshoot size.
        vm.expectRevert();
        curve.buy(stockIn, 0);
        vm.stopPrank();

        assertFalse(curve.graduated(), "must not have graduated -- the overshoot buy itself never went through");
    }

    /// @notice Confirms this isn't a curve brick: after the buy()-side guard rejects the extreme overshoot
    /// trade, the SAME curve immediately accepts a smaller, allowed buy and later graduates normally, at a
    /// correctly price-matched seed -- proving the guard rejects only the one oversized trade, not the curve.
    function test_ExtremeOvershoot_RejectedAtBuyTime_ThenASmallerBuyStillGraduatesPriceCorrectly() public {
        uint256 price = 500e18;
        (address token, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        uint256 extremeStockIn = target * 50;

        vm.startPrank(whale);
        stock.approve(address(curve), extremeStockIn);
        vm.expectRevert();
        curve.buy(extremeStockIn, 0);
        vm.stopPrank();

        // Immediately retry on the SAME curve with a comfortably-allowed 20x overshoot (matching
        // test_LargeButSurvivableOvershoot_StillGraduatesNormally's own threshold below) -- proving the
        // rejected trade above didn't leave the curve itself in any bad or stuck state.
        uint256 stockIn = target * 20;
        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);
        vm.stopPrank();

        curve.graduate();
        assertTrue(curve.graduated(), "the curve must graduate normally once a properly-sized buy is made");

        // And it's price-correct, same cross-check as the marginal-price test: the pool's real opening price
        // matches the curve's own marginal price at the (now-recovered) graduation boundary.
        uint256 remaining = curve.CURVE_SUPPLY() - curve.tokensSold();
        uint256 oldVirtualStock = curve.virtualStockReserve() + curve.realStockCollected();
        uint256 curveMarginalPrice = FullMath.mulDiv(oldVirtualStock, 1e18, remaining);

        PoolKey memory key = StocksPoolView(curve.pair()).poolKey();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(pm, id);
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;
        uint256 price1Per0 = FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e18, 1 << 192);
        uint256 poolMarginalPrice = tstIsCurrency0 ? price1Per0 : FullMath.mulDiv(1e18, 1e18, price1Per0);

        uint256 diff = poolMarginalPrice > curveMarginalPrice
            ? poolMarginalPrice - curveMarginalPrice
            : curveMarginalPrice - poolMarginalPrice;
        assertLt(diff * 1000, curveMarginalPrice * 5, "pool must open at (approximately) the curve's own marginal price");
    }

    /// @notice No regression: a large but survivable 20x overshoot (well under the ~26x threshold) still
    /// graduates normally, exactly as StocksGraduation.priceSweep.t.sol's own fuzz range already covers.
    function test_LargeButSurvivableOvershoot_StillGraduatesNormally() public {
        uint256 price = 500e18;
        (, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        uint256 stockIn = target * 20; // 2000% overshoot, comfortably under the ~26x floor threshold

        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);
        vm.stopPrank();

        curve.graduate();
        assertTrue(curve.graduated(), "a 20x overshoot must still graduate cleanly");
    }
}
