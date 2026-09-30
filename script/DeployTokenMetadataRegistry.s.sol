// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";

/// @notice One-time deploy for TokenMetadataRegistry -- see that contract's own docstring for why
/// it's a single, generation-agnostic shared singleton rather than something redeployed alongside
/// each new StocksLaunchFactory generation. Run this ONCE; the resulting address then goes into
/// every future factory generation's own TOKEN_METADATA_REGISTRY_ADDRESS env var (same pattern as
/// POOL_MANAGER_ADDRESS being a stable external address every deploy script reuses).
///
/// No constructor args, no env vars needed -- just:
///   forge script script/DeployTokenMetadataRegistry.s.sol --rpc-url <rpc> --broadcast --private-key <key>
contract DeployTokenMetadataRegistry is Script {
    function run() external returns (address registry) {
        vm.startBroadcast();
        registry = address(new TokenMetadataRegistry());
        vm.stopBroadcast();

        console.log("TokenMetadataRegistry deployed at:", registry);
        console.log("Set TOKEN_METADATA_REGISTRY_ADDRESS to this address for every future factory generation's deploy.");
    }
}
