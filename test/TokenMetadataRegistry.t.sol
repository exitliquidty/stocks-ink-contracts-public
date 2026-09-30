// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";

contract DummyTokenStub {}

/// @notice AUDIT FIX regression suite: setMetadataURI now requires `token` to already have code --
/// see that function's own docstring for the front-running vulnerability this closes (a CREATE
/// address is publicly predictable before the real deploying transaction lands, so "the address
/// doesn't exist yet" was never actually true from an outside front-runner's perspective). `token`
/// here is a real, tiny deployed contract (not makeAddr's plain EOA-like address) specifically so
/// these tests exercise the NEW check's happy path, not just its revert path.
contract TokenMetadataRegistryTest is Test {
    TokenMetadataRegistry registry;
    address token;

    function setUp() public {
        registry = new TokenMetadataRegistry();
        token = address(new DummyTokenStub());
    }

    function test_SetMetadataURI_HappyPath() public {
        registry.setMetadataURI(token, "ipfs://bafyfake");
        assertEq(registry.metadataURI(token), "ipfs://bafyfake");
        console.log("PASS: setMetadataURI stores and returns the exact URI set");
    }

    function test_SetMetadataURI_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit TokenMetadataRegistry.MetadataURISet(token, "ipfs://bafyfake");
        registry.setMetadataURI(token, "ipfs://bafyfake");
        console.log("PASS: setMetadataURI emits MetadataURISet with the token and URI");
    }

    function test_SetMetadataURI_RevertsOnDoubleSet() public {
        registry.setMetadataURI(token, "ipfs://first");
        vm.expectRevert(TokenMetadataRegistry.AlreadySet.selector);
        registry.setMetadataURI(token, "ipfs://second");
        assertEq(registry.metadataURI(token), "ipfs://first", "sanity: the original URI must survive the reverted second call");
        console.log("PASS: a second setMetadataURI call for the same token reverts and leaves the first URI intact");
    }

    /// @dev Anyone can call this successfully for a token that has never been set -- confirms the
    /// contract really is permissionless, which only real-world safety comes from
    /// StocksLaunchFactory calling it atomically at creation, not from any access control here.
    function test_SetMetadataURI_CallableByAnyoneForAnUnsetToken() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        registry.setMetadataURI(token, "ipfs://fromrando");
        assertEq(registry.metadataURI(token), "ipfs://fromrando");
        console.log("PASS: setMetadataURI has no caller restriction -- safety comes from atomic set-once-at-creation usage, not access control");
    }

    function test_MetadataURI_DefaultsToEmptyStringForUnsetToken() public view {
        assertEq(registry.metadataURI(token), "");
        console.log("PASS: an unset token's metadataURI reads back as empty string, not a revert");
    }

    /// @dev AUDIT FIX regression: an address with no code yet -- exactly what a front-runner has
    /// to work with, since they can only ever predict a FUTURE token's address before it's deployed
    /// -- must revert, not silently succeed and squat the slot.
    function test_SetMetadataURI_RevertsForAddressWithNoCode() public {
        address predictedFutureToken = makeAddr("predictedFutureToken");
        assertEq(predictedFutureToken.code.length, 0, "sanity: this address must genuinely have no code");
        vm.expectRevert(TokenMetadataRegistry.TokenHasNoCode.selector);
        registry.setMetadataURI(predictedFutureToken, "ipfs://attacker-garbage");
        assertEq(registry.metadataURI(predictedFutureToken), "", "the slot must remain genuinely unset after the reverted attempt");
        console.log("PASS: setMetadataURI reverts for an address with no code, closing the front-run");
    }

    /// @dev AUDIT FIX regression: once the real token is actually deployed to that same address,
    /// the legitimate call must succeed normally -- this fix only ever blocks calls that arrive
    /// BEFORE real deployment, never the real, atomic call that follows it.
    function test_SetMetadataURI_SucceedsOnceCodeExistsAtThatAddress() public {
        address futureToken = makeAddr("futureToken");
        vm.expectRevert(TokenMetadataRegistry.TokenHasNoCode.selector);
        registry.setMetadataURI(futureToken, "ipfs://too-early");

        vm.etch(futureToken, address(new DummyTokenStub()).code);
        registry.setMetadataURI(futureToken, "ipfs://real-metadata");
        assertEq(registry.metadataURI(futureToken), "ipfs://real-metadata");
        console.log("PASS: setMetadataURI succeeds normally once the real token actually has code");
    }
}
