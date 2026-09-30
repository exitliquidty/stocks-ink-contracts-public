// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {CurveInvStock} from "./StocksAuditR2.curve.invariant.t.sol";

/// @notice Audit round 2: exact boundaries of the bonding curve that a mutation run showed no test was pinning.
contract StocksAuditR2CurveEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    StocksCurve curve;
    CurveInvStock stock;
    TSTToken tst;
    address buyer = address(0xB0B);
    uint256 launchTime;

    function setUp() public {
        vm.warp(1_800_000_000);
        uint256 signerKey = 0xA11CE;
        address factory = address(0xFACE);
        stock = new CurveInvStock();
        uint256 price = 100e18;
        uint256 ts = block.timestamp;
        bytes32 h = keccak256(abi.encodePacked(factory, address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(h));
        tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        curve = new StocksCurve(
            address(tst), address(stock), vm.addr(signerKey), price, ts, abi.encodePacked(r, s, v), 7 days, factory, 8_000_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        launchTime = block.timestamp;
        stock.transfer(buyer, 1e30);
        vm.prank(buyer);
        stock.approve(address(curve), type(uint256).max);
    }

    /// The largest stock amount whose quote stays within the snipe cap, by bisection.
    function _capStock() internal view returns (uint256 lo, uint256 hi) {
        uint256 cap = (curve.CURVE_SUPPLY() * curve.MAX_SNIPE_BUY_BPS()) / curve.BPS_DENOM();
        lo = 1;
        hi = 1e27;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (curve.quoteBuy(mid) > cap) hi = mid;
            else lo = mid;
        }
    }

    function test_SnipeCap_AppliesUpToTheLastSecond_AndLiftsExactlyAtSixtySeconds() public {
        (uint256 okStock, uint256 tooMuch) = _capStock();

        // one second before the window ends: an over-cap buy is refused
        vm.warp(launchTime + curve.SNIPE_WINDOW() - 1);
        vm.prank(buyer);
        vm.expectRevert(StocksCurve.SnipeCapExceeded.selector);
        curve.buy(tooMuch, 0);

        // exactly at launch + 60 the window is over: the same buy goes through
        vm.warp(launchTime + curve.SNIPE_WINDOW());
        vm.prank(buyer);
        uint256 got = curve.buy(tooMuch, 0);
        assertGt(got, (curve.CURVE_SUPPLY() * curve.MAX_SNIPE_BUY_BPS()) / curve.BPS_DENOM(), "an over-cap buy is allowed once the window has closed");
        okStock;
    }

    function test_SnipeCap_AtTheCapExactly_IsAccepted_OneStockWeiOverIsNot() public {
        (uint256 okStock, uint256 tooMuch) = _capStock();
        assertEq(tooMuch, okStock + 1, "bisection found the boundary");
        uint256 cap = (curve.CURVE_SUPPLY() * curve.MAX_SNIPE_BUY_BPS()) / curve.BPS_DENOM();
        assertLe(curve.quoteBuy(okStock), cap);
        assertGt(curve.quoteBuy(tooMuch), cap);

        vm.prank(buyer);
        curve.buy(okStock, 0);
        // the running total counts: even the smallest further buy that adds anything pushes the accumulated total over
        // the cap only if it crosses it, and one that stays under is fine
        vm.prank(buyer);
        vm.expectRevert(StocksCurve.SnipeCapExceeded.selector);
        curve.buy(tooMuch, 0);
    }

    function test_SlippageBoundary_MinOutEqualToTheQuote_IsAccepted() public {
        vm.warp(launchTime + 61);
        uint256 amount = 5e18;
        uint256 q = curve.quoteBuy(amount);
        vm.prank(buyer);
        curve.buy(amount, q); // exactly the quote: must succeed
        uint256 tstHeld = tst.balanceOf(buyer);
        uint256 s = curve.quoteSell(tstHeld);
        vm.startPrank(buyer);
        tst.approve(address(curve), tstHeld);
        curve.sell(tstHeld, s); // exactly the quote: must succeed
        vm.stopPrank();

        // and one wei better than the quote is refused
        uint256 better = curve.quoteBuy(amount) + 1;
        vm.prank(buyer);
        vm.expectRevert(StocksCurve.SlippageExceeded.selector);
        curve.buy(amount, better);
    }

    /// @dev Graduation is allowed at EXACTLY the stock target and refused one wei under it. (The isolated curve has no real
    /// factory behind it, so an allowed graduation fails later inside the factory calls; the point here is only that the
    /// refusal is NotReady or is not.)
    function test_GraduationTarget_ExactlyReached_IsReady_OneWeiUnder_IsNot() public {
        vm.warp(launchTime + 61);
        uint256 target = curve.graduationStockTarget();

        vm.prank(buyer);
        curve.buy(target - 1, 0);
        vm.expectRevert(StocksCurve.NotReady.selector);
        curve.graduate();

        vm.prank(buyer);
        curve.buy(1, 0); // realStockCollected == target exactly
        assertEq(curve.realStockCollected(), target);
        try curve.graduate() {
            fail("the isolated curve has no factory, graduation cannot complete here");
        } catch (bytes memory reason) {
            assertTrue(bytes4(reason) != StocksCurve.NotReady.selector, "at exactly the target the curve is ready");
        }
    }
}
