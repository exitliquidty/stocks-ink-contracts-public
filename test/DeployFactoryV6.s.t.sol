// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice V6 sibling of the retired DeployFactoryV5.s.t.sol -- same regression test for the exact
/// CREATE2 deployment mechanism DeployFactoryV6.s.sol uses to deploy StocksHook to a mined address
/// under a REAL broadcast; the mechanism itself is byte-for-byte unchanged from V5 (V6's only real
/// difference is StocksLaunchFactory's own new metadataRegistry wiring, which has nothing to do
/// with this hook-deploy path). See DeployFactoryV4.s.t.sol's own docstring for the full,
/// empirically-confirmed reason `DeployFactoryV6.run()` itself is NOT invoked here (forge test's
/// in-process vm.startBroadcast() simulation does not increment the broadcaster's nonce for a
/// plain .call() the way a real `forge script --broadcast` does, so testing the full script
/// in-process would validate the WRONG nonce arithmetic) -- this tests the one piece that
/// genuinely IS environment-independent: whether HookMiner's mined salt, deployed via a raw call
/// to CREATE2_FACTORY encoded exactly the way DeployFactoryV6.s.sol encodes it, actually produces
/// a working StocksHook at the predicted address, with six permission flags and a third
/// constructor argument (expirationInterval).
///
/// Before ever running DeployFactoryV6.s.sol against real Ink mainnet, re-verify the FULL script
/// (nonce arithmetic included) exactly the way DeployFactoryV4.s.sol's own docstring instructs --
/// see that file's own docstring for the full anvil-fork verification steps; the nonce offset here
/// (+4, not V4's +3) reflects the one extra pre-graduator broadcast transaction this script makes
/// (a fresh, V5-and-later-exclusive StocksGovernorFactory deploy, not reused from the legacy
/// shared one) -- reconfirm that offset the same way, not by reasoning alone, before it ever
/// touches a real broadcast.
///
/// Run with: forge test --match-contract DeployFactoryV6HookCreate2Test -vv
contract DeployFactoryV6HookCreate2Test is Test {
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function setUp() public {
        vm.createSelectFork("ink");
    }

    function test_RawCreate2FactoryCall_DeploysHookAtMinedAddress() public {
        address arbitraryGraduator = makeAddr("graduator");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), arbitraryGraduator, EXPIRATION_INTERVAL);
        (address predictedHook, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(StocksHook).creationCode, constructorArgs);

        // Exactly DeployFactoryV6.s.sol's own encoding: salt as the first 32 bytes, followed by
        // the full init code, matching the canonical deterministic-deployment-proxy's expected
        // calldata format.
        bytes memory hookInitCode = abi.encodePacked(type(StocksHook).creationCode, constructorArgs);
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, hookInitCode));
        require(ok, "CREATE2 factory call failed");
        address deployedHook = address(bytes20(ret));

        assertEq(deployedHook, predictedHook, "deployed hook address != HookMiner's prediction");
        assertGt(deployedHook.code.length, 0, "no code at deployed hook address");

        // Not just "an address with some code" -- confirm it's a genuinely working
        // StocksHook with the right permission bits AND the right (renounced) owner state.
        StocksHook hook = StocksHook(deployedHook);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(hook.poolDeployer(), arbitraryGraduator);
        assertEq(hook.expirationInterval(), EXPIRATION_INTERVAL);
        assertEq(hook.owner(), address(0), "kill-switch must be permanently renounced even via this deploy path");

        console.log("PASS: raw CREATE2_FACTORY call deployed hook at the mined address:", deployedHook);
    }
}
