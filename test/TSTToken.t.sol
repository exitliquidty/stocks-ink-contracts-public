// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TSTToken} from "../src/TSTToken.sol";

contract TSTTokenTest is Test {
    TSTToken token;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        token = new TSTToken("Acme", "ACME", SUPPLY, alice);
    }

    function test_Balance_CarriesZeroVotesUntilDelegated() public {
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.getVotes(alice), 0);

        vm.prank(alice);
        token.delegate(alice);

        assertEq(token.getVotes(alice), SUPPLY);
    }

    function test_SelfDelegation_ActivatesCheckpoints() public {
        vm.prank(alice);
        token.delegate(alice);

        vm.warp(block.timestamp + 1);
        assertEq(token.getPastVotes(alice, block.timestamp - 1), SUPPLY);
    }

    function test_Transfer_MovesVotesOnlyWhenBothPartiesDelegated() public {
        vm.prank(alice);
        token.delegate(alice);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        // Alice's own delegated votes drop immediately on transfer...
        assertEq(token.getVotes(alice), SUPPLY - 100e18);
        // ...but bob never delegated, so his new balance carries no voting power yet.
        assertEq(token.getVotes(bob), 0);

        vm.prank(bob);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 100e18);
    }

    function test_DelegateBySig_ActivatesVotesForSigner() public {
        (address carol, uint256 carolKey) = makeAddrAndKey("carol");
        vm.prank(alice);
        token.transfer(carol, 50e18);

        uint256 expiry = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"), carol, uint256(0), expiry
            )
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolKey, digest);

        token.delegateBySig(carol, 0, expiry, v, r, s);
        assertEq(token.getVotes(carol), 50e18);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function test_Clock_UsesTimestampNotBlockNumber() public {
        assertEq(token.clock(), block.timestamp);
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }
}
