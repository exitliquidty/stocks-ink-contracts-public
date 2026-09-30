// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";

/// @notice Read-only post-deployment check: run it against the real chain right after DeployFactoryV12 and it
/// reverts with a specific message if anything is wired wrong or configured differently from what was intended.
/// It only reads; it never broadcasts.
///
///   FACTORY_ADDRESS            -- the deployed StocksLaunchFactory
///   POOL_MANAGER_ADDRESS       -- the Uniswap v4 PoolManager the stack must point at
///   TRUSTED_SIGNER_ADDRESS     -- the price signer that must be baked into the factory
///   PROTOCOL_TREASURY_ADDRESS  -- the address that must receive the protocol's cut
///   EXPIRATION_INTERVAL_SECONDS, GRADUATION_USD_THRESHOLD, MIN_REWARDS_DURATION_SECONDS,
///   MAX_REWARDS_DURATION_SECONDS, VOTING_DELAY_SECONDS, VOTING_PERIOD_SECONDS, PROPOSAL_THRESHOLD_BPS
///                              -- the profile values the deploy was run with
///
/// Run: forge script script/VerifyDeploymentV12.s.sol --rpc-url <rpc>   (no --broadcast)
contract VerifyDeploymentV12 is Script {
    function run() external view {
        StocksLaunchFactory factory = StocksLaunchFactory(vm.envAddress("FACTORY_ADDRESS"));
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        require(address(factory).code.length > 0, "FACTORY_ADDRESS has no code");

        StocksHook hook = StocksHook(factory.hook());
        StocksGraduator graduator = StocksGraduator(factory.v4Graduator());

        // wiring, in both directions
        require(address(graduator.hook()) == address(hook), "graduator.hook != factory.hook");
        require(graduator.factory() == address(factory), "graduator.factory != this factory");
        require(hook.poolDeployer() == address(graduator), "hook.poolDeployer != graduator");
        require(address(graduator.poolManager()) == poolManager, "graduator points at the wrong PoolManager");
        require(address(hook.poolManager()) == poolManager, "hook points at the wrong PoolManager");
        require(hook.owner() == address(0), "hook ownership is not renounced");
        require(hook.killedAt() == 0, "hook is killed");

        // the hook's address must encode exactly the permissions it implements, and fit the size limit
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "hook address does not encode its permissions");
        require(address(hook).code.length > 0 && address(hook).code.length <= 24_576, "hook code size is out of range");
        require(hook.expirationInterval() == vm.envUint("EXPIRATION_INTERVAL_SECONDS"), "wrong TWAMM interval");

        // every sub-contract exists
        require(factory.governorFactory().code.length > 0, "governorFactory has no code");
        require(factory.stakingFactory().code.length > 0, "stakingFactory has no code");
        require(factory.curveDeployer().code.length > 0, "curveDeployer has no code");
        require(factory.metadataRegistry().code.length > 0, "metadataRegistry has no code");

        // the profile
        require(factory.trustedSigner() == vm.envAddress("TRUSTED_SIGNER_ADDRESS"), "wrong trusted signer");
        require(factory.protocol() == vm.envAddress("PROTOCOL_TREASURY_ADDRESS"), "wrong protocol treasury");
        require(factory.graduationUsdThreshold() == vm.envUint("GRADUATION_USD_THRESHOLD"), "wrong graduation threshold");
        require(factory.minRewardsDuration() == vm.envUint("MIN_REWARDS_DURATION_SECONDS"), "wrong min rewards duration");
        require(factory.maxRewardsDuration() == vm.envUint("MAX_REWARDS_DURATION_SECONDS"), "wrong max rewards duration");
        require(uint256(factory.votingDelay()) == vm.envUint("VOTING_DELAY_SECONDS"), "wrong voting delay");
        require(uint256(factory.votingPeriod()) == vm.envUint("VOTING_PERIOD_SECONDS"), "wrong voting period");
        require(factory.proposalThresholdBps() == vm.envUint("PROPOSAL_THRESHOLD_BPS"), "wrong proposal threshold");

        // fixed protocol constants
        require(graduator.HOOK_TST_RESERVE_WEI() == 1e20 && graduator.HOOK_STOCK_RESERVE_WEI() == 1e12, "reserve constants changed");
        require(factory.TOTAL_SUPPLY() == 1_000_000_000e18, "total supply constant changed");

        console.log("OK: deployment matches the intended wiring and profile");
        console.log("  factory:  ", address(factory));
        console.log("  hook:     ", address(hook));
        console.log("  graduator:", address(graduator));
    }
}
