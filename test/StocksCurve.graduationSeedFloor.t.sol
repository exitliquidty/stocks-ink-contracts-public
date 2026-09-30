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
/// pool. This isn't a permanent brick: proven below that `sell()` lets a later `graduate()` succeed once
/// `remaining` recovers.
contract StocksCurveGraduationSeedFloorTest is StocksGraduationPriceSweepTest {
    /// @notice The exact scenario this bug used to mishandle: a 50x overshoot buy. Before the fix this
    /// silently opened the pool ~47% below the curve's marginal price; after the fix it reverts instead of
    /// mispricing anything.
    function test_ExtremeOvershoot_NowRevertsInsteadOfMispricingThePool() public {
        uint256 price = 500e18;
        (, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        uint256 stockIn = target * 50; // 5000% overshoot, this codebase's own prior fuzz ceiling

        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);
        vm.stopPrank();

        // Bare vm.expectRevert(): StocksGraduator.SeedTooSmall() bubbles up through StocksCurve.graduate(),
        // both plain (non-hook) external calls here, so the raw selector would normally match directly -- kept
        // bare anyway to stay robust to exactly which of the two contracts' identically-purposed checks ends
        // up firing.
        vm.expectRevert();
        curve.graduate();

        assertFalse(curve.graduated(), "must not have graduated at a distorted price");
    }

    /// @notice Confirms this isn't a permanent brick: after the extreme buyer sells some of their TST back
    /// (recovering `remaining`), a later graduate() call succeeds normally, at a correctly price-matched seed.
    function test_ExtremeOvershoot_RecoversAfterPartialSellBack_ThenGraduatesPriceCorrectly() public {
        uint256 price = 500e18;
        (address token, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        uint256 stockIn = target * 50;

        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        uint256 tstOut = curve.buy(stockIn, 0);
        vm.stopPrank();

        vm.expectRevert();
        curve.graduate();

        // Sell back a SMALL fraction of the received TST -- just 2% is already enough to bring the seed back
        // above the floor (confirmed by direct calculation), while `realStockCollected` stays comfortably
        // above the graduation target throughout. A partial unwind, not a full one.
        vm.startPrank(whale);
        IERC20(token).approve(address(curve), tstOut);
        curve.sell(tstOut / 50, 0);
        vm.stopPrank();

        curve.graduate();
        assertTrue(curve.graduated(), "must graduate once the seed recovers");

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
