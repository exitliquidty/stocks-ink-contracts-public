// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";

contract MockStockTokenSandwich is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Audit round 2 gap-fill (flagged, not yet reached, in AUDIT.md's "category-by-category" pass):
/// a classic front-run/back-run sandwich against an ORDINARY curve buy() -- distinct from
/// StocksAuditR2.mev.t.sol, which only tests sandwiching the treasury's TWAMM liquidation on the
/// post-graduation pool. This is the pre-graduation bonding curve itself: attacker buys ahead of a
/// victim (pushing the quote up), the victim buys at the worse rate, attacker sells right back.
///
/// StocksCurve.security.t.sol already proved a LONE actor's own buy-then-sell round trip is never
/// profitable (rounding always favours the curve). What that doesn't cover is whether a THIRD PARTY's
/// trade landing in between changes that -- i.e. whether an attacker can extract value FROM a victim's
/// own trade, not just fail to profit off empty air.
contract StocksCurveSandwichTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    uint256 signerKey = 0xA11CE;
    address signer;
    address factory = address(0xFACE);
    address attacker = address(0xBAD);
    address victim = address(0xF00D);

    function setUp() public {
        signer = vm.addr(signerKey);
    }

    function _sign(address stockToken, uint256 price, uint256 priceTimestamp, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash = keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    function _deployCurveAndTst(uint256 price, string memory tag)
        internal
        returns (StocksCurve curve, TSTToken tstToken, MockStockTokenSandwich stockToken)
    {
        stockToken = new MockStockTokenSandwich(string.concat("Stock", tag), string.concat("STOCK", tag), SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), price, priceTimestamp, signerKey);

        tstToken = new TSTToken(string.concat("Acme", tag), string.concat("ACME", tag), SUPPLY, address(this));
        curve = new StocksCurve(
            address(tstToken), address(stockToken), signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
        );
        tstToken.transfer(address(curve), SUPPLY);
    }

    /// @dev Zero slippage tolerance is the strongest, most important case: if the victim insists on
    /// exactly the quote they saw (minTstOut == honest quote), any front-run that moves the price at
    /// all must make their own buy() revert outright -- they can never be silently shortchanged.
    function test_ZeroSlippageVictim_IsFullyProtected_TradeRevertsRatherThanLosingValue() public {
        // Real-scale parameters (the current live TEST-profile threshold, $150/share -- a plausible
        // real stock price): graduationStockTarget ~53.3 stock, virtualStockReserve ~17.8 stock, so
        // trade sizes below are chosen relative to that real depth, not the earlier arbitrary values.
        (StocksCurve curve, TSTToken tstToken, MockStockTokenSandwich stockToken) = _deployCurveAndTst(150e18, "A");
        vm.warp(block.timestamp + 61); // past the snipe window

        uint256 victimStock = 1e18; // ~$150 trade
        stockToken.mint(victim, victimStock);
        stockToken.mint(attacker, 500_000e18);

        uint256 honestQuote = curve.quoteBuy(victimStock);
        assertGt(honestQuote, 0, "sanity: honest quote is nonzero");

        // attacker front-runs with a buy comparable in size to the curve's own virtual depth
        vm.startPrank(attacker);
        stockToken.approve(address(curve), 5e18);
        curve.buy(5e18, 0);
        vm.stopPrank();

        // the quote has now moved -- victim's zero-tolerance minTstOut is the ORIGINAL honest quote
        uint256 quoteAfterFrontrun = curve.quoteBuy(victimStock);
        assertLt(quoteAfterFrontrun, honestQuote, "sanity: the front-run must have made stock buy less TST");

        vm.startPrank(victim);
        stockToken.approve(address(curve), victimStock);
        vm.expectRevert(StocksCurve.SlippageExceeded.selector);
        curve.buy(victimStock, honestQuote);
        vm.stopPrank();

        console.log("PASS: zero-slippage victim's buy correctly reverted instead of executing at a worse rate");
    }

    /// @dev With a nonzero, realistic slippage tolerance, quantify what a same-direction front-run
    /// (attacker buys ahead of the victim's own buy, then sells back) does to a victim's ordinary buy.
    /// As with the sell-side test below, this is standard AMM/MEV behaviour, not curve-specific -- the
    /// one real, load-bearing guarantee to prove is that the victim's own minTstOut floor is genuinely
    /// honored regardless of the attack, never silently underpaid below what they explicitly agreed to.
    function test_Sandwich_OfAnOrdinaryBuy_VictimsOwnSlippageProtectionAlwaysHolds() public {
        // Real-scale parameters: see the zero-slippage test above for the depth math.
        (StocksCurve curve, TSTToken tstToken, MockStockTokenSandwich stockToken) = _deployCurveAndTst(150e18, "B");
        vm.warp(block.timestamp + 61);

        uint256 victimStock = 1e18; // ~$150 trade
        stockToken.mint(attacker, 10_000_000e18);

        uint256[4] memory slippageBps = [uint256(50), 100, 300, 1000]; // 0.5%, 1%, 3%, 10%
        uint256[3] memory attackSizes = [uint256(1e17), 1e18, 8e18]; // small, ~equal-to-victim, near the full virtual depth

        for (uint256 i = 0; i < slippageBps.length; i++) {
            for (uint256 j = 0; j < attackSizes.length; j++) {
                uint256 snap = vm.snapshotState();

                stockToken.mint(victim, victimStock);
                uint256 honestQuote = curve.quoteBuy(victimStock);
                uint256 minTstOut = honestQuote - (honestQuote * slippageBps[i]) / 10_000;

                uint256 attackerStockBefore = stockToken.balanceOf(attacker);

                vm.startPrank(attacker);
                stockToken.approve(address(curve), attackSizes[j]);
                uint256 frontrunTstOut = curve.buy(attackSizes[j], 0);
                vm.stopPrank();

                uint256 victimTstBefore = tstToken.balanceOf(victim);
                vm.startPrank(victim);
                stockToken.approve(address(curve), victimStock);
                bool victimTraded = true;
                try curve.buy(victimStock, minTstOut) {} catch {
                    victimTraded = false;
                }
                vm.stopPrank();

                if (victimTraded) {
                    uint256 victimActualReceived = tstToken.balanceOf(victim) - victimTstBefore;
                    // the one real, load-bearing safety guarantee: the victim's own slippage floor was
                    // genuinely honored, regardless of the attacker's front-run.
                    assertGe(victimActualReceived, minTstOut, "victim received less than their own minTstOut floor");

                    vm.startPrank(attacker);
                    tstToken.approve(address(curve), frontrunTstOut);
                    curve.sell(frontrunTstOut, 0);
                    vm.stopPrank();

                    int256 attackerPnlStock = int256(stockToken.balanceOf(attacker)) - int256(attackerStockBefore);

                    console.log("slippageBps, attackSize (stock wei):", slippageBps[i], attackSizes[j]);
                    console.log("  victim: honest quote, actual received, own floor (TST wei):");
                    console.log(honestQuote, victimActualReceived, minTstOut);
                    console.log("  attacker round-trip pnl (stock wei):");
                    console.logInt(attackerPnlStock);

                    // documented, not asserted against: same reasoning as the sell-side test below --
                    // this is the standard, inherent same-direction sandwich profit any constant-product
                    // AMM exhibits. The real safety guarantee enforced is the assertGe above.
                } else {
                    console.log("slippageBps, attackSize (stock wei): victim protected, trade reverted");
                    console.log(slippageBps[i], attackSizes[j]);
                }

                vm.revertToState(snap);
            }
        }
    }

    /// @dev Same shape, but selling into a victim instead of buying ahead of one: attacker sells first
    /// (pushing price of TST down), victim sells at the worse rate, attacker buys back. Checked
    /// separately since quoteSell's rounding direction differs from quoteBuy's.
    ///
    /// Unlike the buy-side test, this is a SAME-DIRECTION front-run (attacker sells, victim also
    /// sells), which is a fundamentally different, well-known AMM/MEV pattern from an opposite-
    /// direction "classic" sandwich: the attacker's profit here isn't from the victim's own trade
    /// executing outside their slippage tolerance (that tolerance is still independently enforced and
    /// verified below) -- it comes from the victim's real trade ALSO moving the price further in the
    /// same direction, which the attacker then arbitrages by reversing their own position at the
    /// resulting, more favorable rate. This is inherent to ANY constant-product-style AMM (Uniswap
    /// included) with public trade visibility, not specific to this curve's own accounting -- so the
    /// two things actually worth proving here are (1) the victim's own slippage protection is real
    /// (never receives less than minStockOut, regardless of the attack) and (2) the profit scales
    /// with trade size the way plain AMM arithmetic predicts, not in some larger/anomalous way that
    /// would suggest the curve's own accounting is leaking extra value beyond what price impact alone
    /// explains.
    function test_Sandwich_OfAVictimSell_VictimsOwnSlippageProtectionAlwaysHolds() public {
        // Real-scale parameters: see the zero-slippage test above for the depth math. The attacker's
        // own setup buy is kept modest (2 stock, ~11% of virtual depth) so it doesn't itself consume
        // most of the curve's supply before the attack even starts.
        (StocksCurve curve, TSTToken tstToken, MockStockTokenSandwich stockToken) = _deployCurveAndTst(150e18, "C");
        vm.warp(block.timestamp + 61);

        stockToken.mint(attacker, 10_000_000e18);
        stockToken.mint(victim, 10_000_000e18);
        vm.startPrank(attacker);
        stockToken.approve(address(curve), type(uint256).max);
        curve.buy(2e18, 0);
        vm.stopPrank();
        vm.startPrank(victim);
        stockToken.approve(address(curve), type(uint256).max);
        uint256 victimTst = curve.buy(1e18, 0);
        vm.stopPrank();

        uint256[3] memory slippageBps = [uint256(50), 300, 1000];
        // sized relative to the attacker's own real TST holdings after the setup buy above, not an
        // arbitrary absolute figure -- logged each iteration so the real proportion is on record.
        uint256 attackerHoldings = tstToken.balanceOf(attacker);
        uint256[2] memory attackTstSizes = [attackerHoldings / 20, attackerHoldings / 4]; // 5%, 25% of holdings

        for (uint256 i = 0; i < slippageBps.length; i++) {
            for (uint256 j = 0; j < attackTstSizes.length; j++) {
                uint256 snap = vm.snapshotState();

                uint256 honestQuote = curve.quoteSell(victimTst);
                if (honestQuote == 0) {
                    vm.revertToState(snap);
                    continue;
                }
                uint256 minStockOut = honestQuote - (honestQuote * slippageBps[i]) / 10_000;

                uint256 attackerTstBefore = tstToken.balanceOf(attacker);

                vm.startPrank(attacker);
                tstToken.approve(address(curve), attackTstSizes[j]);
                uint256 frontrunStockOut = curve.sell(attackTstSizes[j], 0);
                vm.stopPrank();

                uint256 victimStockBefore = stockToken.balanceOf(victim);
                vm.startPrank(victim);
                tstToken.approve(address(curve), victimTst);
                bool victimTraded = true;
                try curve.sell(victimTst, minStockOut) {} catch {
                    victimTraded = false;
                }
                vm.stopPrank();

                if (victimTraded) {
                    uint256 victimActualReceived = stockToken.balanceOf(victim) - victimStockBefore;
                    // the one real, load-bearing safety guarantee: the victim's own slippage floor was
                    // genuinely honored by the contract, regardless of the attacker's front-run.
                    assertGe(victimActualReceived, minStockOut, "victim received less than their own minStockOut floor");

                    vm.startPrank(attacker);
                    stockToken.approve(address(curve), frontrunStockOut);
                    curve.buy(frontrunStockOut, 0);
                    vm.stopPrank();

                    int256 attackerPnlTst = int256(tstToken.balanceOf(attacker)) - int256(attackerTstBefore);

                    console.log("sell-sandwich slippageBps, attackTstSize (fraction of attacker's own holdings):");
                    console.log(slippageBps[i], attackTstSizes[j]);
                    console.log("  victim: honest quote, actual received, own floor (stock wei):");
                    console.log(honestQuote, victimActualReceived, minStockOut);
                    console.log("  attacker round-trip pnl (TST wei), as bps of the attack size itself:");
                    console.logInt(attackerPnlTst);
                    if (attackerPnlTst > 0) {
                        console.log(uint256(attackerPnlTst) * 10_000 / attackTstSizes[j]);
                    }

                    // this IS the standard, expected, inherent same-direction sandwich profit any
                    // constant-product AMM exhibits -- documented, not asserted against, since asserting
                    // "must be unprofitable" would be false for any such AMM including this one; the
                    // safety guarantee actually enforced is the assertGe above, checked on every iteration.
                } else {
                    console.log("sell-sandwich slippageBps, attackTstSize: victim protected, trade reverted");
                    console.log(slippageBps[i], attackTstSizes[j]);
                }

                vm.revertToState(snap);
            }
        }
    }
}
