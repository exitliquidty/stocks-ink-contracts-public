// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";

/// @dev Deducts a flat 5% fee (sent to a burn sink) on every transfer/transferFrom -- the RECIPIENT
/// gets less than the caller asked for, the SENDER's balance still drops by the full requested
/// amount. This is the standard, common fee-on-transfer shape (as opposed to the rarer "sender
/// pays extra on top" variant) -- exactly what StocksCurve's own sell() path is exposed to on its
/// outgoing leg, per this file's own audit directive.
contract FeeOnTransferStock is ERC20 {
    uint256 public constant FEE_BPS = 500;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0xdEaD), fee);
    }
}

/// @dev Attempts to reenter the curve from inside its own transfer hook, targeting a DIFFERENT
/// function than whichever one triggered the transfer -- proves ReentrancyGuard's single
/// contract-wide lock blocks cross-function reentrancy, not just same-function.
contract ReentrantStock is ERC20 {
    StocksCurve public target;
    bytes public reentryCalldata;
    bool public armed;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function arm(StocksCurve _target, bytes calldata _reentryCalldata) external {
        target = _target;
        reentryCalldata = _reentryCalldata;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && address(target) != address(0)) {
            armed = false; // fire once
            (bool ok,) = address(target).call(reentryCalldata);
            // Reentrancy must be blocked (call must fail) -- swallow the failure here so the
            // OUTER call (the legitimate buy/sell that triggered this transfer) can still return
            // normally and let the test inspect the outer call's own result.
            ok;
        }
    }
}

/// @dev Minimal stand-in for the real launch factory -- skim()'s AUDIT FIX routes recovered stock
/// excess through IGovernableFactoryV5.protocol(), so any test exercising that path needs a real
/// contract at `factory` able to answer that call (the bare `address(0xFACE)` EOA-shaped constant
/// used elsewhere in this file is fine for signature-hash-only uses, but not callable).
contract MockGovernableFactoryA3 {
    address public protocol;

    constructor(address protocol_) {
        protocol = protocol_;
    }
}

/// @notice Round-3 audit on StocksCurve.sol: adversarial testing against non-standard/malicious
/// stockTokens, focused specifically on sell()'s outgoing leg (buy()'s incoming leg is already
/// balance-diff protected, per round 1) and a fresh, independent reentrancy check.
contract StocksCurveAudit3Test is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    uint256 signerKey = 0xA11CE;
    address signer;
    address factory = address(0xFACE);
    address trader = address(0xBEEF);

    function setUp() public {
        signer = vm.addr(signerKey);
    }

    function _sign(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        return _signWithFactory(factory, stockToken, price, priceTimestamp);
    }

    function _signWithFactory(address factory_, address stockToken, uint256 price, uint256 priceTimestamp)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash = keccak256(abi.encodePacked(factory_, stockToken, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    /// @notice FIXED (external AuditAgent scan, 2026-09-30, finding #3 -- independently matches this
    /// file's own earlier-documented Low finding, originally titled
    /// test_AUDIT_Sell_FeeOnTransferStock_SellerReceivesLessThanQuotedMinOut): sell() now measures
    /// the seller's ACTUAL received balance-diff (mirroring buy()'s existing incoming-leg
    /// protection) and checks THAT against minStockOut, instead of comparing minStockOut against
    /// the pre-fee quoted amount. A seller who (reasonably, with no way to know about the token's
    /// fee) sets minStockOut to the exact quote now correctly reverts with SlippageExceeded instead
    /// of silently receiving less than they required. No real xStock wrapper currently has transfer
    /// fees (see the 723-wrapper sweep elsewhere in this suite) -- this is defense-in-depth against
    /// value leakage, verified end-to-end here rather than left theoretical.
    function test_AUDIT_Sell_FeeOnTransferStock_RevertsInsteadOfUnderpayingTheSeller() public {
        FeeOnTransferStock stock = new FeeOnTransferStock("FeeStock", "FEE", SUPPLY);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stock), price, priceTimestamp);

        TSTToken tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve = new StocksCurve(
            address(tst), address(stock), signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        vm.warp(block.timestamp + 61 seconds); // past the snipe window -- irrelevant to this test

        // Fund the curve with real stock via a normal buy() first (buy()'s own balance-diff
        // protection means realStockCollected already correctly reflects the post-fee amount).
        // Small relative to this config's own tiny 80e18 graduationStockTarget (8_000e18 USD /
        // 100e18 price), and comfortably under the 60s launch-window snipe cap.
        stock.transfer(trader, 20e18); // funding transfer itself pays the 5% fee too
        uint256 traderStockBalance = stock.balanceOf(trader);
        vm.startPrank(trader);
        stock.approve(address(curve), type(uint256).max);
        uint256 tstReceived = curve.buy(traderStockBalance, 0);
        tst.approve(address(curve), type(uint256).max);
        vm.stopPrank();

        uint256 realCollectedBefore = curve.realStockCollected();
        uint256 curveBalanceBefore = stock.balanceOf(address(curve));
        assertEq(realCollectedBefore, curveBalanceBefore, "sanity: accounting matches real balance exactly pre-sell");

        // THE FIX IN ACTION: setting minStockOut to the exact pre-fee quote (the strongest
        // guarantee a seller with no way to know about the token's fee could reasonably set) now
        // correctly reverts, since the seller's actual balance-diff receipt is strictly less than
        // that quote once the destination-side transfer fee is applied.
        uint256 quoted = curve.quoteSell(tstReceived);

        vm.prank(trader);
        vm.expectRevert(StocksCurve.SlippageExceeded.selector);
        curve.sell(tstReceived, quoted);
        console.log("CONFIRMED FIXED: sell() now reverts rather than silently underpaying the seller");

        // A seller who instead sets minStockOut to what they'll actually receive (accounting for
        // the token's own 5% fee themselves) still succeeds, and gets paid exactly that real amount.
        uint256 feeAwareMinOut = (quoted * 95) / 100;
        uint256 sellerBalanceBefore = stock.balanceOf(trader);
        vm.prank(trader);
        uint256 reportedStockOut = curve.sell(tstReceived, feeAwareMinOut);
        uint256 actuallyReceived = stock.balanceOf(trader) - sellerBalanceBefore;

        assertEq(reportedStockOut, actuallyReceived, "sell() now reports/returns the seller's real balance-diff receipt");
        assertGe(actuallyReceived, feeAwareMinOut, "seller received at least their fee-aware minStockOut");
        assertLt(actuallyReceived, quoted, "sanity: the fee is genuinely still being paid on this token");

        // The CURVE's own internal accounting stays exactly self-consistent throughout -- it debits
        // realStockCollected by the same pre-fee `quotedStockOut` amount that actually leaves its
        // own balance (the fee is paid by the curve-as-sender, not deducted from the ledger
        // separately), so this was always a seller-side value leak, never a protocol insolvency.
        assertEq(
            curve.realStockCollected(),
            stock.balanceOf(address(curve)),
            "curve's own accounting still matches its real balance exactly -- not a solvency bug"
        );
    }

    /// @notice Confirms buy()'s existing balance-diff protection (round 1) directly against a
    /// fee-on-transfer token on the INCOMING leg, for contrast with the sell()-side gap above.
    function test_Buy_FeeOnTransferStock_CorrectlyUsesActualReceivedAmount() public {
        FeeOnTransferStock stock = new FeeOnTransferStock("FeeStock", "FEE", SUPPLY);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stock), price, priceTimestamp);

        TSTToken tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve = new StocksCurve(
            address(tst), address(stock), signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        vm.warp(block.timestamp + 61 seconds); // past the snipe window -- irrelevant to this test

        stock.transfer(trader, 20e18);
        uint256 traderStockBalance = stock.balanceOf(trader); // already 19e18 after the funding transfer's own 5% fee
        vm.startPrank(trader);
        stock.approve(address(curve), type(uint256).max);
        curve.buy(traderStockBalance, 0);
        vm.stopPrank();

        // A second 5% fee applies to buy()'s own transferFrom -- only 95% of traderStockBalance
        // actually arrives. realStockCollected must reflect THAT real amount, not the requested one.
        uint256 expectedActualArrival = (traderStockBalance * 95) / 100;
        assertEq(curve.realStockCollected(), expectedActualArrival, "realStockCollected must equal actual post-fee arrival, not the requested amount");
        assertEq(curve.realStockCollected(), stock.balanceOf(address(curve)), "accounting matches real balance exactly");
    }

    /// @notice Fresh, independent reentrancy check: a malicious stockToken tries to reenter sell()
    /// from inside the transfer triggered by a legitimate buy() call. ReentrancyGuard's single
    /// contract-wide lock must block it (cross-function, not just same-function).
    function test_AUDIT_Reentrancy_MaliciousStockCannotReenterDuringBuy() public {
        ReentrantStock stock = new ReentrantStock("ReenterStock", "REENT", SUPPLY);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stock), price, priceTimestamp);

        TSTToken tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve = new StocksCurve(
            address(tst), address(stock), signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        vm.warp(block.timestamp + 61 seconds); // past the snipe window -- irrelevant to this test

        stock.transfer(trader, 5e18);
        vm.prank(trader);
        stock.approve(address(curve), type(uint256).max);

        // Arm the token to try calling sell() (a DIFFERENT nonReentrant function) the moment its
        // own transferFrom (triggered by buy()) moves value -- this fires mid-buy(), before
        // buy()'s own state updates (realStockCollected/tokensSold) even happen, the worst-case
        // timing for an attacker.
        bytes memory reentryCall = abi.encodeWithSelector(StocksCurve.sell.selector, uint256(1), uint256(0));
        stock.arm(curve, reentryCall);

        vm.prank(trader);
        uint256 tstOut = curve.buy(5e18, 0);

        // The outer buy() must have succeeded normally (the reentrant inner call failed and was
        // swallowed by the token's own try/catch-free .call(), which just discards the failure) --
        // and critically, curve state must reflect exactly ONE buy, not a corrupted double-entry.
        assertGt(tstOut, 0, "the legitimate outer buy() must still succeed");
        assertEq(curve.tokensSold(), tstOut, "exactly one buy's worth of state change -- reentrant sell() never got through");
        console.log("CONFIRMED: cross-function reentrancy (sell() from inside buy()'s own token transfer) is blocked");
    }

    /// @notice FINDING (Low): stock donated directly to the curve (bypassing buy(), e.g. an
    /// accidental direct send, or an honest attempt to "add liquidity") sits as real balance in
    /// excess of realStockCollected forever if the curve never graduates -- skim() deliberately
    /// only ever touches TST (see its own comment: "Stock is deliberately left untouched here"),
    /// and nothing else in the contract can move stock out pre-graduation. If the curve DOES later
    /// graduate, _graduate() happens to sweep the full live stock balance (not just
    /// realStockCollected) into the pool, so the donation is only unrecoverable for curves that
    /// never reach graduation -- e.g. because nobody ever buys, or the backing stock itself turns
    /// out to be non-viable. No caller, including governance/protocol, has any way to reach it.
    function test_AUDIT_DonatedStockBypassingBuy_PermanentlyStuckIfCurveNeverGraduates() public {
        MockGovernableFactoryA3 mockFactory = new MockGovernableFactoryA3(address(0xDEED));

        ERC20Mintable stock = new ERC20Mintable("Stock", "STOCK", SUPPLY);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _signWithFactory(address(mockFactory), address(stock), price, priceTimestamp);

        TSTToken tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve = new StocksCurve(
            address(tst), address(stock), signer, price, priceTimestamp, sig, 7 days, address(mockFactory), 8_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        vm.warp(block.timestamp + 61 seconds); // past the snipe window -- irrelevant to this test

        // A real, honest donation (or an accidental direct send) -- not a buy(), so
        // realStockCollected never learns about it.
        stock.mint(address(this), 5_000e18);
        stock.transfer(address(curve), 5_000e18);

        assertEq(curve.realStockCollected(), 0, "the donation is invisible to the curve's own accounting");
        assertEq(stock.balanceOf(address(curve)), 5_000e18, "but the real balance genuinely holds it");

        // skim() is the ONLY permissionless recovery mechanism pre-graduation, and it only ever
        // sweeps TST excess -- it must leave the donated stock completely untouched.
        vm.prank(trader);
        curve.skim();

        assertEq(stock.balanceOf(address(curve)), 5_000e18, "BUG: skim() does not and cannot recover donated stock");
        assertEq(stock.balanceOf(mockFactory.protocol()), 0, "BUG: nothing was ever routed to protocol()");
        assertEq(curve.realStockCollected(), 0, "the curve's own accounting still has no idea the stock is there");

        console.log("CONFIRMED: stock donated outside buy() is permanently stuck if this curve never graduates");
    }
}

contract ERC20Mintable is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
