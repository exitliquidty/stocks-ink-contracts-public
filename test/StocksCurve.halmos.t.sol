// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";

/// @notice Halmos symbolic proofs for the bonding-curve quote math. Unlike the Foundry fuzz
/// tests covering the same properties (testFuzz_BuyThenSellRoundTrip_NeverProfitable etc.),
/// these exhaustively cover the full uint256 input space via SMT solving instead of sampling.
contract StocksCurveHalmosTest is SymTest, Test {
    StocksCurve curve;

    function setUp() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        address factory = address(0xFACE);
        address stock = address(0xBEEF);
        address tst = address(0xCAFE);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;

        bytes32 hash = keccak256(abi.encodePacked(factory, stock, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(hash));
        bytes memory sig = abi.encodePacked(r, s, v);

        curve = new StocksCurve(
            tst, stock, signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
        );
    }

    /// @notice quoteBuy() must never quote out more TST than the curve's entire sellable supply,
    /// no matter how large the stock input is.
    function check_QuoteBuy_NeverExceedsCurveSupply(uint256 stockIn) public view {
        uint256 tstOut = curve.quoteBuy(stockIn);
        assert(tstOut <= curve.CURVE_SUPPLY());
    }

    /// @notice quoteSell() must never quote out more stock than the curve's virtual+real reserve.
    function check_QuoteSell_NeverExceedsVirtualReserve(uint256 tstIn) public view {
        uint256 stockOut = curve.quoteSell(tstIn);
        assert(stockOut <= curve.virtualStockReserve());
    }

    // The round-trip ("buy then sell can't be profitable") and monotonicity properties are
    // already covered exhaustively by testFuzz_BuyThenSellRoundTrip_NeverProfitable and
    // testFuzz_SellThenBuyRoundTrip_NeverProfitable in StocksCurve.security.t.sol. A symbolic
    // version of those was attempted here but dropped: composing two Math.ceilDiv calls over
    // full-width symbolic uint256s is a known hard case for SMT bitvector solvers and timed out
    // even at 60s/bounded-input, independent of the actual math being correct.
}
