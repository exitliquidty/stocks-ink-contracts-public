// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";

contract MockStockToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @notice Regression for the reviewer-flagged gap: the constructor only rejected
/// graduationStockTarget == 0, not virtualStockReserve (= graduationStockTarget / 3) rounding down to 0. With
/// virtualStockReserve == 0 and realStockCollected == 0 pre-launch, quoteBuy()'s oldVirtualStock is 0 for the
/// very first trade, and the constant-product formula degenerates: tstOut = remaining - ceilDiv(0, newVirtualStock)
/// = remaining, i.e. the entire curve supply, for any nonzero stockIn (even 1 wei). Only reachable via an
/// extreme signed price -- graduationUsdThreshold is a governance-fixed deploy constant (8,000e18 in every real
/// deploy so far, see project_v5_deploy_config_env_vars / project_v5d_mainnet_deploy), so this needs
/// price >= threshold * 1e18 / 2 to trigger, i.e. a signed price around $4 sextillion/share -- reachable only by
/// a malicious or compromised trusted signer, who already has far more direct attack surface (they can just sign
/// any price they like). Still a total, irreversible failure mode and a free one-line guard, so it's fixed
/// regardless of reachability.
contract StocksCurveVirtualReserveZeroRegressionTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant GRADUATION_USD_THRESHOLD = 8_000e18; // matches every real deploy config

    uint256 signerKey = 0xA11CE;
    address signer;
    address factory = address(0xFACE);

    function setUp() public {
        signer = vm.addr(signerKey);
    }

    function _sign(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 hash = keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    function _deploy(uint256 price, string memory tag) internal returns (StocksCurve curve, MockStockToken stockToken) {
        stockToken = new MockStockToken(string.concat("Stock", tag), string.concat("STOCK", tag), SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), price, priceTimestamp);
        TSTToken tstToken = new TSTToken(string.concat("Acme", tag), string.concat("ACME", tag), SUPPLY, address(this));
        curve = new StocksCurve(
            address(tstToken),
            address(stockToken),
            signer,
            price,
            priceTimestamp,
            sig,
            7 days,
            factory,
            GRADUATION_USD_THRESHOLD,
            1 days,
            365 days
        );
        tstToken.transfer(address(curve), SUPPLY);
    }

    /// @dev graduationStockTarget = (8_000e18 * 1e18) / price. Picking price so the target lands at exactly 2
    /// (still nonzero, so the pre-existing == 0 check does NOT catch it) makes virtualStockReserve = 2 / 3 = 0.
    function _priceForTarget(uint256 target) internal pure returns (uint256) {
        return (GRADUATION_USD_THRESHOLD * 1e18) / target;
    }

    /// @dev vm.expectRevert only watches the very next call frame (see feedback_expectrevert_consumed_by_nested_call
    /// / feedback_expectrevert_new_ends_test) -- so all the setup (mock token, TST token, signature) has to happen
    /// BEFORE arming it, with `new StocksCurve(...)` itself as the very next thing that runs.
    function test_PriceThatRoundsVirtualReserveToZero_NowRejectedAtDeploy() public {
        uint256 price = _priceForTarget(2);
        MockStockToken stockToken = new MockStockToken("StockA", "STOCKA", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), price, priceTimestamp);
        TSTToken tstToken = new TSTToken("AcmeA", "ACMEA", SUPPLY, address(this));

        vm.expectRevert(StocksCurve.InvalidPrice.selector);
        new StocksCurve(
            address(tstToken), address(stockToken), signer, price, priceTimestamp, sig, 7 days, factory,
            GRADUATION_USD_THRESHOLD, 1 days, 365 days
        );
    }

    function test_PriceThatRoundsVirtualReserveToZero_TargetOfOne_AlsoRejected() public {
        uint256 price = _priceForTarget(1);
        MockStockToken stockToken = new MockStockToken("StockB", "STOCKB", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), price, priceTimestamp);
        TSTToken tstToken = new TSTToken("AcmeB", "ACMEB", SUPPLY, address(this));

        vm.expectRevert(StocksCurve.InvalidPrice.selector);
        new StocksCurve(
            address(tstToken), address(stockToken), signer, price, priceTimestamp, sig, 7 days, factory,
            GRADUATION_USD_THRESHOLD, 1 days, 365 days
        );
    }

    /// @dev The very next value up (graduationStockTarget == 3, so virtualStockReserve == 1) must still deploy --
    /// the fix must not be over-tight and reject anything the old check would have allowed.
    function test_JustAboveTheBoundary_StillDeploysFine() public {
        uint256 price = _priceForTarget(3);
        (StocksCurve curve,) = _deploy(price, "C");
        assertEq(curve.virtualStockReserve(), 1, "sanity: this is exactly the boundary case");
        // and a normal first buy no longer hands out the whole supply
        uint256 out = curve.quoteBuy(1e18);
        assertLt(out, curve.CURVE_SUPPLY(), "first buyer does not receive the entire curve supply");
    }

    /// @dev A realistic deploy (a genuinely-priced stock) is completely unaffected by the new guard.
    function test_RealisticPrice_Unaffected() public {
        uint256 price = 150e18; // $150/share
        (StocksCurve curve,) = _deploy(price, "D");
        assertGt(curve.virtualStockReserve(), 0);
    }
}
