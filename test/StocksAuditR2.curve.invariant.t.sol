// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";

contract CurveInvStock is ERC20 {
    constructor() ERC20("Stock", "STK") {
        _mint(msg.sender, type(uint128).max);
    }
}

/// @notice Drives a real StocksCurve through random buys, sells, donations, skims and time, from several actors.
contract CurveHandler is Test {
    StocksCurve public curve;
    CurveInvStock public stock;
    TSTToken public tst;
    address[3] public actors;

    // ghost accounting
    uint256 public stockPaidIn;
    uint256 public stockPaidOut;
    uint256 public tstBoughtTotal;
    uint256 public tstSoldTotal;
    uint256 public donatedStock;
    uint256 public donatedTstAll;
    uint256 public kFloor; // the product must never fall below the value it had at the start
    uint256 public kViolations;
    uint256 public roundTripProfits;

    constructor(StocksCurve c, CurveInvStock s, TSTToken t) {
        curve = c;
        stock = s;
        tst = t;
    }

    function init() external {
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(0xA000 + i));
            stock.transfer(actors[i], 1e30);
            vm.startPrank(actors[i]);
            stock.approve(address(curve), type(uint256).max);
            tst.approve(address(curve), type(uint256).max);
            vm.stopPrank();
        }
        kFloor = _k();
    }

    function _k() internal view returns (uint256) {
        uint256 remaining = curve.CURVE_SUPPLY() - curve.tokensSold();
        return (curve.virtualStockReserve() + curve.realStockCollected()) * remaining;
    }

    function _checkK(uint256 before_) internal {
        uint256 after_ = _k();
        // the constant product may only grow (rounding is always in the pool's favour)
        if (after_ < before_) ++kViolations;
    }

    function buy(uint256 actorSeed, uint256 stockIn) external {
        address a = actors[actorSeed % 3];
        stockIn = bound(stockIn, 1, 5e22);
        uint256 kBefore = _k();
        vm.prank(a);
        try curve.buy(stockIn, 0) returns (uint256 out) {
            stockPaidIn += stockIn;
            tstBoughtTotal += out;
            _checkK(kBefore);
        } catch {}
    }

    function sell(uint256 actorSeed, uint256 fraction) external {
        address a = actors[actorSeed % 3];
        uint256 bal = tst.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bound(fraction, 1, bal);
        uint256 kBefore = _k();
        vm.prank(a);
        try curve.sell(amount, 0) returns (uint256 out) {
            stockPaidOut += out;
            tstSoldTotal += amount;
            _checkK(kBefore);
        } catch {}
    }

    /// @dev Buy then sell exactly what was received, back to back: the actor can never end up with more stock.
    function roundTrip(uint256 actorSeed, uint256 stockIn) external {
        address a = actors[actorSeed % 3];
        stockIn = bound(stockIn, 1, 5e22);
        uint256 stockBefore = stock.balanceOf(a);
        uint256 kBefore = _k();
        vm.startPrank(a);
        try curve.buy(stockIn, 0) returns (uint256 out) {
            try curve.sell(out, 0) returns (uint256 back) {
                stockPaidIn += stockIn;
                stockPaidOut += back;
                tstBoughtTotal += out;
                tstSoldTotal += out;
                if (stock.balanceOf(a) > stockBefore) ++roundTripProfits;
            } catch {
                stockPaidIn += stockIn;
                tstBoughtTotal += out;
            }
        } catch {}
        vm.stopPrank();
        _checkK(kBefore);
    }

    function donateStock(uint256 amount) external {
        amount = bound(amount, 1, 1e22);
        stock.transfer(address(curve), amount);
        donatedStock += amount;
    }

    function donateTst(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % 3];
        uint256 bal = tst.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(a);
        tst.transfer(address(curve), amount);
        donatedTstAll += amount;
    }

    function skim() external {
        uint256 kBefore = _k();
        curve.skim();
        _checkK(kBefore);
    }

    function passTime(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 3 days));
    }

    function actorTst() external view returns (uint256 sum) {
        for (uint256 i; i < 3; ++i) sum += tst.balanceOf(actors[i]);
    }
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
}

/// @notice Audit round 2: stateful invariants of the bonding curve before graduation.
contract StocksAuditR2CurveInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    StocksCurve curve;
    CurveInvStock stock;
    TSTToken tst;
    CurveHandler handler;

    function setUp() public {
        uint256 signerKey = 0xA11CE;
        address factory = address(0xFACE);
        stock = new CurveInvStock();
        uint256 price = 100e18;
        uint256 ts = block.timestamp;
        bytes32 h = keccak256(abi.encodePacked(factory, address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(h));
        tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        // a large graduation target so the run never leaves the pre-graduation phase
        curve = new StocksCurve(
            address(tst), address(stock), vm.addr(signerKey), price, ts, abi.encodePacked(r, s, v), 7 days, factory, 8_000_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        vm.warp(block.timestamp + 61); // past the snipe window

        handler = new CurveHandler(curve, stock, tst);
        // the handler pays out of its own stock balance
        stock.transfer(address(handler), 4e30);
        handler.init();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = CurveHandler.buy.selector;
        selectors[1] = CurveHandler.sell.selector;
        selectors[2] = CurveHandler.roundTrip.selector;
        selectors[3] = CurveHandler.donateStock.selector;
        selectors[4] = CurveHandler.donateTst.selector;
        selectors[5] = CurveHandler.skim.selector;
        selectors[6] = CurveHandler.passTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// The curve always holds at least the stock it has collected (donations only add).
    function invariant_StockSolvency() public view {
        assertGe(stock.balanceOf(address(curve)), curve.realStockCollected(), "collected stock is fully backed");
    }

    /// realStockCollected is exactly the stock paid in minus the stock paid out.
    function invariant_StockConservation() public view {
        assertEq(curve.realStockCollected(), handler.stockPaidIn() - handler.stockPaidOut(), "stock accounting is exact");
        assertEq(
            stock.balanceOf(address(curve)),
            curve.realStockCollected() + handler.donatedStock(),
            "balance is collected plus donations"
        );
    }

    /// Every TST is either in the curve or in a user's hands (or burned by skim): tokensSold tracks it exactly.
    function invariant_TstAccounting() public view {
        assertEq(curve.tokensSold(), handler.tstBoughtTotal() - handler.tstSoldTotal(), "tokensSold is bought minus sold");
        assertEq(handler.actorTst(), curve.tokensSold() - handler.donatedTstAll(), "actors hold what the curve sold, less what they donated");
        assertGe(tst.balanceOf(address(curve)), SUPPLY - curve.tokensSold(), "the curve holds at least the unsold supply");
        assertLe(curve.tokensSold(), curve.CURVE_SUPPLY(), "never sells more than the curve supply");
    }

    /// The constant product never decreases: nothing can be extracted by rounding.
    function invariant_ProductNeverDecreases() public view {
        assertEq(handler.kViolations(), 0, "k must never decrease on any buy, sell or skim");
    }

    /// Buying and immediately selling back never returns more than was paid.
    function invariant_NoRoundTripProfit() public view {
        assertEq(handler.roundTripProfits(), 0, "a round trip must never profit");
    }
}
