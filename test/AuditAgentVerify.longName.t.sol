// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Verifying and fixing AuditAgent report finding #2: a TST name of 23-31 bytes used to pass
/// TSTToken's own EIP712 constructor (also capped at 31 bytes via ShortStrings) but made
/// `tstToken.name() + " Governor"` (9 more bytes) exceed ShortStrings' 31-byte limit inside
/// StocksGovernor's own EIP712 constructor -- permanently reverting every graduate() call for that
/// curve forever, since the TST name is immutable. Confirmed real with a direct test BEFORE the fix
/// (a 24-byte name launched fine, then graduate() reverted identically on every retry). Fixed by
/// rejecting the name at `createCurve` time instead -- the same "validate at launch, don't discover the
/// problem at graduation" pattern this contract already uses for its other constructor-time checks.
contract AuditAgentLongNameTest is StocksRedemptionAdversarialTest {
    function test_AuditAgent2_NameInDangerZone_RejectedCleanlyAtLaunch_NotBrickedAtGraduation() public {
        // 24 bytes -- comfortably inside TSTToken's own 31-byte limit on its own, but 24 + 9 (" Governor")
        // = 33 > 31 (ShortStrings' limit) -- exactly the zone that used to launch fine and brick forever
        // at graduation. Now rejected immediately, before any token or curve is even deployed.
        string memory name24 = "AAAAAAAAAAAAAAAAAAAAAAAA"; // exactly 24 chars
        console.log("name length (bytes):", bytes(name24).length);
        console.log("name + ' Governor' length (bytes):", bytes(name24).length + 9);

        uint256 price = 200e18;
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));

        vm.expectRevert(StocksLaunchFactory.NameTooLongForGraduation.selector);
        factory.createCurve(name24, "LN24", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        console.log("CONFIRMED FIXED: createCurve now rejects a danger-zone name immediately, cleanly, with a clear error");

        // and the attestation is NOT burned by the rejected attempt -- the creator can immediately retry
        // with a valid (shorter) name using the exact same attestation, no griefing of their own launch.
        factory.createCurve("Short", "OK", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        console.log("CONFIRMED: the same attestation still works with a valid name -- rejection doesn't burn it");
    }

    /// @dev The exact boundary: 22 bytes (the new maximum) must still launch AND graduate successfully --
    /// confirms the fix isn't overly conservative and doesn't reject names that were always safe.
    function test_AuditAgent2_ExactBoundary_22Bytes_StillLaunchesAndGraduatesNormally() public {
        string memory name22 = "AAAAAAAAAAAAAAAAAAAAAA"; // exactly 22 chars, the new maximum allowed
        require(bytes(name22).length == 22, "sanity: test string must be exactly 22 bytes");

        uint256 price = 200e18;
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));

        (, address curveAddr) =
            factory.createCurve(name22, "N22", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        StocksCurve c = StocksCurve(curveAddr);
        vm.warp(vm.getBlockTimestamp() + 61);

        address newHolder = address(0xB0122);
        stock.transfer(newHolder, 100e18);
        vm.startPrank(newHolder);
        stock.approve(curveAddr, type(uint256).max);
        c.buy(45e18, 0);
        vm.stopPrank();

        c.graduate(); // must NOT revert -- 22 + 9 = 31, exactly at ShortStrings' own limit
        console.log("PASS: the exact new boundary (22 bytes) still launches and graduates normally");
    }

    /// @dev Control: a SHORT name (comfortably under the boundary) graduates normally too, confirming
    /// the fix is specific to the danger zone, not a general regression.
    function test_AuditAgent2_Control_ShortName_GraduatesNormally() public {
        string memory shortName = "Short"; // 5 bytes, 5 + 9 = 14, well under 31
        uint256 price = 200e18;
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));

        (, address curveAddr) =
            factory.createCurve(shortName, "SHRT", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        StocksCurve c = StocksCurve(curveAddr);
        vm.warp(vm.getBlockTimestamp() + 61);

        address newHolder = address(0xB0B24);
        stock.transfer(newHolder, 100e18);
        vm.startPrank(newHolder);
        stock.approve(curveAddr, type(uint256).max);
        c.buy(45e18, 0);
        vm.stopPrank();

        c.graduate(); // must NOT revert
        console.log("control PASS: a short name graduates normally, confirming the danger zone is name-length-specific");
    }
}
