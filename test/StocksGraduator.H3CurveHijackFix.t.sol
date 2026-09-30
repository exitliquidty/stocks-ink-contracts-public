// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// AUDIT FIX H-3 regression suite -- proves the direct-hijack vulnerability found in a live
// security review of the deployed V6 stack (StocksGraduator.graduate() had no way to tell a real
// curve's own graduation call apart from anyone else's, closed by StocksLaunchFactory's new
// curveOf(token) registry) is actually fixed, using the REAL StocksLaunchFactory/StocksCurve
// stack end to end -- not a hand-rolled mock registry like StocksGraduator.security.t.sol's own
// suite uses for its narrower, Graduator-only tests. See StocksGraduator.sol's own `factory`
// docstring and StocksLaunchFactory.sol's own `curveOf` docstring for the full writeup.

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract StocksGraduatorH3CurveHijackFixTest is Test {
    using PoolIdLibrary for PoolKey;

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

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");
        trustedSigner = vm.addr(trustedSignerKey);

        metadataRegistry = new TokenMetadataRegistry();

        address governorFactory = address(new StocksGovernorFactory());
        address curveDeployer = address(new StocksCurveFactory());
        address stakingFactory = address(new StocksStakingFactory());

        // Same 3-way nonce-prediction dance script/DeployFactoryV12.s.sol uses for real: predict
        // both the graduator's AND the factory's future addresses before deploying the hook.
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

    // Signed message is keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp))
    // -- see StocksLaunchFactory.createCurve's own `signature` param docstring for why `factory`
    // (this contract's own address) is bound into it.
    function _signAttestation(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(address(factory), stockToken, price, priceTimestamp));
        bytes32 ethSignedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerKey, ethSignedDigest);
        return abi.encodePacked(r, s, v);
    }

    function _launchRealCurve(string memory tag, address stockToken, uint256 price)
        internal
        returns (address token, address curve)
    {
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (token, curve) = factory.createCurve(
            string.concat("Test", tag), string.concat("TST", tag), stockToken, price, priceTimestamp, signature, 30 days, ""
        );
    }

    /// @dev The actual vulnerability, reproduced end to end through the REAL factory/curve stack
    /// (not a hand-rolled mock curve) -- must now revert instead of succeeding.
    function test_RevertWhen_OutsiderCallsGraduateDirectlyForARealLaunchedToken() public {
        // A real stock token address (wMSTRx) -- irrelevant which one for this test, since the
        // attack doesn't depend on the stock side at all.
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
        (address token, address curve) = _launchRealCurve("A", stockToken, 700e18);
        assertFalse(StocksCurve(curve).graduated());

        uint256 totalSupply = IERC20(token).totalSupply();
        uint256 attackerTst = totalSupply / 100; // exactly the H-1 floor -- see original PoC
        deal(token, attacker, attackerTst);
        deal(stockToken, attacker, 1e15);

        vm.startPrank(attacker);
        IERC20(token).approve(address(graduator), attackerTst);
        IERC20(stockToken).approve(address(graduator), 1e15);
        vm.expectRevert(StocksGraduator.NotCurve.selector);
        graduator.graduate(token, stockToken, attacker, attacker, 2000, attackerTst, 1e15);
        vm.stopPrank();

        // The real curve's own future legitimate graduation must NOT be bricked -- confirms this
        // is a real fix, not just a revert that also breaks the legitimate path.
        assertFalse(_isRegistered(token, stockToken), "attacker's call must not have registered anything");
    }

    /// @dev The real curve itself -- the one and only address factory.curveOf(token) actually
    /// returns -- must still be able to graduate normally. Confirms the fix authenticates
    /// correctly, not just rejects everyone.
    function test_RealCurveCanStillGraduateNormally() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
        // Audit round 13 (external review lead, fixed): price chosen low enough that the buyAmount below
        // (kept large, matching this test's own "buy the whole curve out" intent) stays within
        // StocksCurve._graduate's price-matched-seed floor -- see StocksCurve.graduationSeedFloor.t.sol for
        // the fix itself. graduationStockTarget scales inversely with price, so a lower price keeps this
        // same buyAmount's overshoot ratio survivable rather than triggering SeedTooSmall. The synthetic
        // attestation this test signs itself controls this value entirely.
        (address token, address curve) = _launchRealCurve("B", stockToken, 0.5e18);
        assertEq(factory.curveOf(token), curve);

        // Past the 60-second post-launch snipe window (StocksCurve.SNIPE_WINDOW) -- otherwise
        // MAX_SNIPE_BUY_BPS caps a single early buy well below what a real graduation needs,
        // which isn't what this test is trying to exercise.
        vm.warp(block.timestamp + 61);

        // Buy the whole curve out to force a real, organic graduation through StocksCurve's own
        // buy() path -- exactly how a real launch would reach graduate(), not a direct call.
        address buyer = address(0xB0B);
        uint256 buyAmount = 200_000e18;
        deal(stockToken, buyer, buyAmount);
        vm.startPrank(buyer);
        IERC20(stockToken).approve(curve, buyAmount);
        // StocksCurve.buy(stockAmountIn, minTstOut) -- pushes the curve toward its real
        // graduation threshold; exact signature/threshold behavior already covered by
        // StocksCurve's own test suite, this just needs it to actually graduate.
        StocksCurve(curve).buy(buyAmount, 0);
        vm.stopPrank();

        // graduate() is its own separate, permissionless call -- buy() only accumulates toward
        // the threshold, it doesn't auto-trigger graduation.
        StocksCurve(curve).graduate();

        assertTrue(StocksCurve(curve).graduated(), "real curve must have actually graduated for this test to mean anything");
        console.log("Real curve graduated successfully through the normal path.");

        // curveOf must remain correctly pointed at the real curve, and the direct hijack must
        // still be blocked for this token even after real graduation.
        assertEq(factory.curveOf(token), curve);
        // Materialized into a local BEFORE arming expectRevert -- a view call nested directly in
        // the next statement's own arguments would otherwise consume the arming itself (it's the
        // very next external call Foundry sees), leaving graduate()'s own revert unchecked.
        uint256 attackerTst = IERC20(token).totalSupply() / 100;
        vm.prank(attacker);
        vm.expectRevert(StocksGraduator.NotCurve.selector);
        graduator.graduate(token, stockToken, attacker, attacker, 2000, attackerTst, 1e15);
    }

    function _isRegistered(address tstToken, address stockToken) internal view returns (bool registered) {
        (Currency c0, Currency c1) = tstToken < stockToken
            ? (Currency.wrap(tstToken), Currency.wrap(stockToken))
            : (Currency.wrap(stockToken), Currency.wrap(tstToken));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        (registered,,,,,,) = hook.launches(key.toId());
    }
}
