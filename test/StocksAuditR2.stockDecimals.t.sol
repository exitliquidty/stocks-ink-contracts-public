// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";

contract SixDecimalStock is ERC20 {
    constructor() ERC20("Six", "SIX") {
        _mint(msg.sender, type(uint128).max);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract NoDecimalsStock {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @notice A token whose decimals() reverts instead of returning a value, to prove that case is also tolerated
/// (not just "no code at all").
contract RevertingDecimalsStock {
    function decimals() external pure returns (uint8) {
        revert("no");
    }
}

/// @notice Audit round 7 (C8/L-2, external review): every quote and reserve constant in StocksCurve assumes
/// 18-decimal stock wei. Round 4 attempted a `try IERC20Metadata(...).decimals()` guard and reverted it after
/// discovering Foundry's simulator hard-reverts calls to no-code addresses even inside try/catch (breaking dozens
/// of pre-existing placeholder-address tests) -- see feedback_foundry_nocode_call_bypasses_trycatch. This round
/// retries with a low-level `staticcall`, which behaves identically to a real chain under the simulator too
/// (confirmed directly: `ok: true, data.length: 0` against a no-code address, not a revert).
contract StocksAuditR2StockDecimalsTest is Test {
    uint256 signerKey = 0xA11CE;
    address factory_ = address(0xFACE);

    function _curveWith(address stock, uint256 price) internal returns (StocksCurve) {
        uint256 ts = block.timestamp;
        bytes32 h = keccak256(abi.encodePacked(factory_, stock, price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(h));
        TSTToken t = new TSTToken("Z", "Z", 1_000_000_000e18, address(this));
        return new StocksCurve(
            address(t), stock, vm.addr(signerKey), price, ts, abi.encodePacked(r, s, v), 7 days, factory_, 8_000e18, 1 days, 365 days
        );
    }

    /// @dev External wrapper so vm.expectRevert works against the `new` call (see feedback_expectrevert_new_ends_test).
    function _deploy(address tok) external {
        _curveWith(tok, 200e18);
    }

    function test_ConstructorRejects_ANonEighteenDecimalStockToken() public {
        SixDecimalStock six = new SixDecimalStock();
        vm.expectRevert(StocksCurve.UnsupportedStockDecimals.selector);
        this._deploy(address(six));
    }

    /// @notice A token with no `decimals()` at all (optional per EIP-20; every bare test placeholder address
    /// elsewhere in the suite is exactly this case) is NOT blocked -- the check can only catch a clear,
    /// self-reported mismatch.
    function test_AStockTokenWithNoDecimalsFunctionAtAll_IsNotBlocked() public {
        NoDecimalsStock nd = new NoDecimalsStock();
        StocksCurve c = _curveWith(address(nd), 200e18);
        assertGt(c.graduationStockTarget(), 0);
    }

    /// @notice A token whose decimals() call itself reverts is likewise not blocked -- staticcall's `ok` is false,
    /// same handling as no code at all.
    function test_AStockTokenWhoseDecimalsCallReverts_IsNotBlocked() public {
        RevertingDecimalsStock rd = new RevertingDecimalsStock();
        StocksCurve c = _curveWith(address(rd), 200e18);
        assertGt(c.graduationStockTarget(), 0);
    }

    /// @notice A bare placeholder address with genuinely no code (the pattern ~24 pre-existing tests use) is not
    /// blocked either -- confirms the round-4 regression is actually fixed this time, not just reasoned about.
    function test_ABarePlaceholderAddressWithNoCode_IsNotBlocked() public {
        StocksCurve c = _curveWith(address(0xBEEF), 200e18);
        assertGt(c.graduationStockTarget(), 0);
    }

    function test_ConstructorAccepts_ARealEighteenDecimalStockToken() public {
        StocksCurve c = _curveWith(address(new TSTToken("Real", "REAL", 1_000_000_000e18, address(this))), 200e18);
        assertGt(c.graduationStockTarget(), 0);
    }
}
