// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice AUDIT FIX regression suite, end to end through the REAL StocksLaunchFactory/
/// TokenMetadataRegistry stack: TokenMetadataRegistry.setMetadataURI used to have no check that
/// `token` already had code -- just a plain mapping write keyed by any address. The contract's own
/// "permissionless is safe" reasoning rested on "nothing else can call this for that address
/// first, since the address doesn't exist before createCurve's transaction" -- but a CREATE
/// address is deterministic and PUBLICLY predictable from the deploying factory's own nonce well
/// before that transaction ever lands. Confirmed live (before the fix): an outside attacker who
/// reads StocksLaunchFactory's current nonce, computes the CREATE address of the very next token
/// it will ever mint, and calls setMetadataURI(thatAddress, garbage) first -- needing no
/// relationship to the real launch, no signature, nothing but gas -- permanently made every future
/// createCurve() call that supplies a non-empty metadataURI revert with AlreadySet (createCurve()
/// doesn't wrap that call in try/catch, so the whole launch reverted, not just the metadata step).
/// See TokenMetadataRegistry.sol's own docstring for the fix (`token.code.length > 0`).
contract TokenMetadataRegistryFrontrunTest is Test {
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;
    uint256 constant GRADUATION_USD_THRESHOLD = 8_000e18;
    uint256 constant MIN_REWARDS_DURATION = 1 hours;
    uint256 constant MAX_REWARDS_DURATION = 365 days;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant PROPOSAL_THRESHOLD_BPS = 100;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    TokenMetadataRegistry metadataRegistry;

    uint256 trustedSignerKey = 0xA11CE;
    address trustedSigner;
    address protocol = address(0xF00D);
    address attacker = address(0xBAD1);
    address realLauncher = address(0x1234);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");
        trustedSigner = vm.addr(trustedSignerKey);

        metadataRegistry = new TokenMetadataRegistry();

        address governorFactory = address(new StocksGovernorFactory());
        address curveDeployer = address(new StocksCurveFactory());
        address stakingFactory = address(new StocksStakingFactory());

        uint256 nonceAtStart = vm.getNonce(address(this));
        address predictedGraduator = vm.computeCreateAddress(address(this), nonceAtStart + 1);
        address predictedFactory = vm.computeCreateAddress(address(this), nonceAtStart + 2);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        graduator = new StocksGraduator(poolManager, hook, predictedFactory);
        require(address(graduator) == predictedGraduator, "graduator address mismatch");

        factory = new StocksLaunchFactory(
            trustedSigner,
            protocol,
            address(hook),
            governorFactory,
            stakingFactory,
            curveDeployer,
            address(graduator),
            address(metadataRegistry),
            GRADUATION_USD_THRESHOLD,
            MIN_REWARDS_DURATION,
            MAX_REWARDS_DURATION,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_BPS
        );
        require(address(factory) == predictedFactory, "factory address mismatch");
    }

    function _signAttestation(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(address(factory), stockToken, price, priceTimestamp));
        bytes32 ethSignedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerKey, ethSignedDigest);
        return abi.encodePacked(r, s, v);
    }

    function test_FrontRunnerPredictingTokenAddress_CannotBlockTheRealMetadataLaunch() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;

        // The attacker needs nothing except the factory's own current nonce (fully public on-chain
        // state -- readable by anyone via eth_getTransactionCount) to predict the address of the
        // VERY NEXT token this factory will ever mint, before any real launcher has done anything.
        uint256 factoryNonce = vm.getNonce(address(factory));
        address predictedToken = vm.computeCreateAddress(address(factory), factoryNonce);

        // Attacker attempts to front-run: claims that predicted address in the registry with
        // garbage, without needing a real curve, a real signature, or any relationship to the
        // eventual real launch. Must revert -- the predicted address genuinely has no code yet.
        vm.prank(attacker);
        vm.expectRevert(TokenMetadataRegistry.TokenHasNoCode.selector);
        metadataRegistry.setMetadataURI(predictedToken, "ipfs://attacker-garbage");
        assertEq(metadataRegistry.metadataURI(predictedToken), "", "the front-run attempt must not have claimed anything");

        // The real launcher's launch, with real metadata, must succeed completely normally --
        // confirms the fix blocks only the front-run, not the legitimate atomic call.
        uint256 price = 700e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);

        vm.prank(realLauncher);
        (address token,) =
            factory.createCurve("Real Launch", "REAL", stockToken, price, priceTimestamp, signature, 30 days, "ipfs://real-metadata");
        assertEq(token, predictedToken, "sanity: the real token must have landed at the address the attacker predicted");
        assertEq(metadataRegistry.metadataURI(token), "ipfs://real-metadata", "the real launcher's own metadata must be what's actually stored");
    }
}
