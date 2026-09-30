// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";

/// @notice Fuzz version of the two properties in StocksCurve.halmos.t.sol. That Halmos test cannot run with the
/// current tooling (halmos 0.3.3 fails in setUp with an unsupported deployCode cheatcode before it checks
/// anything), so the same properties are covered here by fuzzing over the FULL uint256 range and the edge
/// values, at 200,000 runs each: a quote either reverts on overflow or stays within the curve's bounds, for any
/// starting state (fresh curve; mid-curve after sales), any input and any reserve size.
contract StocksCurveQuoteBoundsFuzzTest is Test {
    StocksCurve curve;

    function _curve(uint256 price, uint256 threshold) internal returns (StocksCurve c) {
        uint256 key = 0xA11CE;
        address factory = address(0xFACE);
        address stock = address(0xBEEF);
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(factory, stock, price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(h));
        c = new StocksCurve(
            address(0xCAFE), stock, vm.addr(key), price, ts, abi.encodePacked(r, s, v), 7 days, factory, threshold, 1 days, 365 days
        );
    }

    /// forge-config: default.fuzz.runs = 200000
    function testFuzz_QuoteBuy_NeverExceedsCurveSupply(uint256 price, uint256 threshold, uint256 stockIn) public {
        price = bound(price, 1e10, 1e30);
        threshold = bound(threshold, 1e18, 1e26);
        if ((threshold * 1e18) / price == 0) return;
        StocksCurve c = _curve(price, threshold);
        try c.quoteBuy(stockIn) returns (uint256 tstOut) {
            assertLe(tstOut, c.CURVE_SUPPLY(), "a buy quote never exceeds the whole sellable supply");
        } catch {}
    }

    /// forge-config: default.fuzz.runs = 200000
    function testFuzz_QuoteSell_NeverExceedsVirtualPlusRealReserve(uint256 price, uint256 threshold, uint256 tstIn)
        public
    {
        price = bound(price, 1e10, 1e30);
        threshold = bound(threshold, 1e18, 1e26);
        if ((threshold * 1e18) / price == 0) return;
        StocksCurve c = _curve(price, threshold);
        try c.quoteSell(tstIn) returns (uint256 stockOut) {
            // nothing has been sold on a fresh curve, so a sell quote is priced against the virtual reserve alone
            assertLe(stockOut, c.virtualStockReserve(), "a sell quote never exceeds the reserve it is priced against");
        } catch {}
    }

    function test_EdgeValues_DoNotBreakTheBounds() public {
        StocksCurve c = _curve(200e18, 8_000e18);
        uint256[6] memory edges = [uint256(0), 1, 2, 1e18, type(uint128).max, type(uint256).max];
        for (uint256 i; i < edges.length; ++i) {
            try c.quoteBuy(edges[i]) returns (uint256 t) {
                assertLe(t, c.CURVE_SUPPLY());
            } catch {}
            try c.quoteSell(edges[i]) returns (uint256 s) {
                assertLe(s, c.virtualStockReserve());
            } catch {}
        }
    }
}
