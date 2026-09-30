// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Verifying and fixing AuditAgent report finding #8: at the OLD SOLDOUT_THRESHOLD_BPS (9,900,
/// 99%), `remaining` (CURVE_SUPPLY * 1% = 8,000,000e18 TST) was already below StocksGraduator's own
/// MIN_TST_SEED_SUPPLY_BPS floor (10,000,000e18 TST, 1% of the full 1B TOTAL_SUPPLY) -- the sold-out
/// graduation path was mathematically guaranteed to revert SeedTooSmall at its own trigger point, every
/// time. Worse, and not stated by the original finding: nothing capped ordinary `buy()` calls from
/// pushing `tokensSold` arbitrarily close to CURVE_SUPPLY regardless of which eligibility path was used,
/// so even the ordinary target-reached graduation path could be permanently stranded by continued trading
/// after eligibility, before anyone called graduate().
///
/// Fixed two ways: (1) SOLDOUT_THRESHOLD_BPS lowered to 9,700 (97%), comfortably seedable; (2) buy()
/// itself now recomputes the exact seed formula after every trade and refuses to let the curve cross into
/// an unseedable state at all, closing the general case the specific 99%/1% conflict was one symptom of.
contract AuditAgentSoldoutSeedConflictTest is StocksRedemptionAdversarialTest {
    /// @dev Re-derives the OLD threshold's math directly, independent of the fix, to record the exact
    /// numbers that made the original finding real: at 99% sold, remaining was 8M TST against a
    /// 10M TST minimum -- a real, provable conflict, not a hypothetical one.
    function test_AuditAgent8_OldThresholdMath_WasGenuinelyUnseedable() public view {
        uint256 curveSupply = curve.CURVE_SUPPLY();
        uint256 oldSoldoutBps = 9_900;
        uint256 tokensSoldAtOldThreshold = (curveSupply * oldSoldoutBps) / curve.BPS_DENOM();
        uint256 remainingAtOldThreshold = curveSupply - tokensSoldAtOldThreshold;
        uint256 minSeedRequired = (curve.TOTAL_SUPPLY() * 100) / curve.BPS_DENOM(); // graduator's 1%
        console.log("old 99% threshold: tokensSold, remaining, min seed required:");
        console.log(tokensSoldAtOldThreshold, remainingAtOldThreshold, minSeedRequired);
        // tstToSeed is always STRICTLY LESS than remaining (proven elsewhere this session), so if
        // remaining alone is already below the minimum, tstToSeed can never reach it either.
        assertLt(remainingAtOldThreshold, minSeedRequired, "confirms the old 99% threshold was mathematically guaranteed unseedable");
    }

    /// @dev The new threshold (97%), by contrast, leaves real margin: remaining alone is comfortably
    /// above the minimum, and (separately, proven below) the actual curve reaches it seedably in practice.
    function test_AuditAgent8_NewThresholdMath_HasRealMargin() public view {
        uint256 curveSupply = curve.CURVE_SUPPLY();
        uint256 newSoldoutBps = curve.SOLDOUT_THRESHOLD_BPS();
        assertEq(newSoldoutBps, 9_700, "sanity: confirms the fix is in place");
        uint256 tokensSoldAtNewThreshold = (curveSupply * newSoldoutBps) / curve.BPS_DENOM();
        uint256 remainingAtNewThreshold = curveSupply - tokensSoldAtNewThreshold;
        uint256 minSeedRequired = (curve.TOTAL_SUPPLY() * 100) / curve.BPS_DENOM();
        console.log("new 97% threshold: tokensSold, remaining, min seed required:");
        console.log(tokensSoldAtNewThreshold, remainingAtNewThreshold, minSeedRequired);
        assertGt(remainingAtNewThreshold, minSeedRequired, "the new threshold leaves real margin above the graduator's minimum");
    }

    /// @dev The real, end-to-end proof: a fresh curve, bought all the way up near sell-out with real
    /// trades, genuinely graduates successfully via the sold-out path -- not just correct in theory.
    function test_AuditAgent8_RealCurve_BoughtNearSoldOut_GraduatesSuccessfully() public {
        (StocksCurve c, address curveAddr) = _freshCurve(150e18);
        address whale = address(0xA11CE8);
        // fund generously -- the curve's own constant-product pricing naturally requires progressively
        // more stock as it approaches sell-out, this is simply "a lot", sized to comfortably clear 97%.
        stock.transfer(whale, 5_000_000e18);
        vm.startPrank(whale);
        stock.approve(curveAddr, type(uint256).max);

        // buy in STOCK-denominated chunks (buy()'s own input unit -- remaining, by contrast, is a TST
        // count on a completely different scale, conflating the two was the bug in an earlier draft of
        // this test) so the buy()-side guard, if it were ever going to trigger, shows up clearly in the
        // trace rather than all at once; stop once sold-out eligibility is reached. The curve's price
        // rises steeply near sell-out, so later chunks buy progressively less TST per unit of stock --
        // sized generously and with enough rounds to comfortably reach 97% either way.
        uint256 soldOutTarget = (c.CURVE_SUPPLY() * c.SOLDOUT_THRESHOLD_BPS()) / c.BPS_DENOM();
        uint256 rounds;
        while (c.tokensSold() < soldOutTarget && rounds < 500) {
            uint256 stockChunk = 20e18; // a modest, realistic per-round stock amount
            try c.buy(stockChunk, 0) {} catch { break; }
            rounds++;
        }
        vm.stopPrank();

        console.log("rounds of buying, final tokensSold, curve supply, sold-out target:");
        console.log(rounds, c.tokensSold(), c.CURVE_SUPPLY(), soldOutTarget);
        assertGe(c.tokensSold(), soldOutTarget, "sanity: the curve genuinely reached sold-out eligibility");

        c.graduate(); // must succeed -- this is the real, end-to-end proof the fix works
        assertTrue(c.graduated(), "the sold-out path now genuinely graduates instead of reverting SeedTooSmall");
        console.log("PASS: a real curve bought to sold-out eligibility graduates successfully");
    }

    /// @dev The buy()-side guard specifically: an attempt to buy so much in one trade that it would push
    /// the curve past the seedable zone is rejected cleanly, with a clear error, rather than silently
    /// stranding the curve for a later graduate() call to discover.
    function test_AuditAgent8_ExtremeSingleBuy_RejectedByGuard_NotAllowedToStrandTheCurve() public {
        (StocksCurve c, address curveAddr) = _freshCurve(150e18);
        address whale = address(0xB0B8);
        stock.transfer(whale, 50_000_000e18);
        vm.startPrank(whale);
        stock.approve(curveAddr, type(uint256).max);

        // an absolutely enormous single buy, attempting to sell out almost the entire curve in one shot
        uint256 hugeAmount = 40_000_000e18;
        vm.expectRevert(StocksCurve.SeedWouldBeUnreachable.selector);
        c.buy(hugeAmount, 0);
        vm.stopPrank();
        console.log("PASS: an extreme single buy that would strand the curve is rejected cleanly by the new guard");
    }

    /// @dev The critical false-positive check: ordinary, realistic early buys -- the vast majority of
    /// real trading activity -- must NOT be blocked by the new guard. Reuses the base fixture's own
    /// real setUp() buys (holder 30e18, staker 12e18) plus the standard test flow, which must all still
    /// work exactly as every other test in this suite already depends on.
    function test_AuditAgent8_Control_OrdinaryEarlyBuys_NeverBlockedByTheNewGuard() public {
        // setUp() itself already performed two ordinary buys and a successful graduation for the base
        // `curve` -- if the guard had any false-positive risk for normal activity, every other test in
        // this entire session's suite would already be failing. Confirmed directly here too, freshly:
        (StocksCurve c, address curveAddr) = _freshCurve(150e18);
        address ordinary = address(0xC0FFEE8);
        stock.transfer(ordinary, 1_000e18);
        vm.startPrank(ordinary);
        stock.approve(curveAddr, type(uint256).max);
        uint256 got = c.buy(10e18, 0); // a small, realistic early trade
        vm.stopPrank();
        assertGt(got, 0, "an ordinary early buy must succeed normally, unaffected by the new guard");
        console.log("control PASS: ordinary early buying is completely unaffected by the new guard");
    }

    // ---- helper: a fresh, independent curve using this fixture's own real factory/signer ----
    function _freshCurve(uint256 price) internal returns (StocksCurve c, address curveAddr) {
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        (, curveAddr) = factory.createCurve("Fresh", "FRSH8", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        c = StocksCurve(curveAddr);
        vm.warp(vm.getBlockTimestamp() + 61); // past the snipe window
    }
}
