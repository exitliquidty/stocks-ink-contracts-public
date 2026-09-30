// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Every existing liquidateTreasury test drives StocksStaking against MockHookV5, never
/// the real StocksHook -- meaning the interaction between a real, governance-submitted treasury
/// liquidation TWAMM order and StocksHook's own beforeSwap (which now also does the pre-swap
/// protocol stock skim, and calls executeTWAMMOrders as a side effect on every swap) has never
/// been exercised end to end. This test builds the full real stack, graduates a real curve, funds
/// and starts a real liquidation order through the real hook, then runs a real buy-TST swap that
/// triggers both mechanisms in the same beforeSwap call, and confirms neither interferes with the
/// other.
contract StocksStakingRealHookLiquidationTest is Test {
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
    PoolSwapTest swapRouter;

    uint256 trustedSignerKey = 0xA11CE;
    address trustedSigner;
    address protocol = address(0xF00D);
    address buyer = address(0xB0B);
    address swapper = address(0xC0FFEE);

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

        swapRouter = new PoolSwapTest(poolManager);
    }

    function _signAttestation(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(address(factory), stockToken, price, priceTimestamp));
        bytes32 ethSignedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerKey, ethSignedDigest);
        return abi.encodePacked(r, s, v);
    }

    function test_RealTreasuryLiquidationOrder_CoexistsWithRealBuySwapAndItsPreSwapSkim() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;

        // Audit round 13 (external review lead, fixed): price chosen low enough that the buyAmount below (kept
        // large, for a realistically large seeded pool -- this test needs real depth for its liquidation/swap
        // amounts) stays within StocksCurve._graduate's price-matched-seed floor (graduationStockTarget scales
        // inversely with price, so a lower price means a larger target, keeping this same buyAmount's overshoot
        // ratio comfortably survivable rather than triggering SeedTooSmall). The synthetic attestation this test
        // signs itself controls this value entirely; it isn't tied to the real stock's real market price.
        uint256 price = 0.5e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curve) =
            factory.createCurve("Real Liquidation Test", "RLT", stockToken, price, priceTimestamp, signature, 30 days, "");

        vm.warp(block.timestamp + 61);
        uint256 buyAmount = 200_000e18;
        deal(stockToken, buyer, buyAmount);
        vm.startPrank(buyer);
        IERC20(stockToken).approve(curve, buyAmount);
        StocksCurve(curve).buy(buyAmount, 0);
        vm.stopPrank();
        StocksCurve(curve).graduate();
        assertTrue(StocksCurve(curve).graduated());

        address stakingAddr = StocksCurve(curve).staking();
        address governorAddr = StocksCurve(curve).governor();
        StocksStaking staking = StocksStaking(stakingAddr);

        // Fund the treasury with real excess stock (simulating accumulated dividends/fees) that
        // has never been recognized as a reward yet -- liquidateTreasury's own floor math treats
        // this as fully safe-to-liquidate excess.
        uint256 treasuryFunding = 5_000e18;
        deal(stockToken, stakingAddr, treasuryFunding);

        // liquidateTreasury is onlyGovernor -- pranking as the real deployed StocksGovernor
        // contract's own address exercises the real hook/TWAMM interaction this test cares about
        // without also re-deriving the full propose/vote/queue/execute governance flow, which is
        // already covered elsewhere.
        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governorAddr);
        (uint256 stockCommitted, bytes32 orderId) = staking.liquidateTreasury(_minLiqIntervals1);
        assertGt(stockCommitted, 0, "sanity: a real liquidation order must have actually committed real stock");
        assertTrue(orderId != bytes32(0));

        // Let real time pass so the liquidation order is genuinely mid-fill when the swap below
        // triggers executeTWAMMOrders as a beforeSwap side effect.
        vm.warp(block.timestamp + EXPIRATION_INTERVAL);

        PoolKey memory key = StocksPoolView(StocksCurve(curve).pair()).poolKey();
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;
        bool buyZeroForOne = !tstIsCurrency0; // pay stock, receive TST

        uint256 stockIn = 20_000e18;
        deal(stockToken, swapper, stockIn);
        vm.startPrank(swapper);
        IERC20(stockToken).approve(address(swapRouter), stockIn);

        uint256 protocolStockBefore = IERC20(stockToken).balanceOf(protocol);
        uint256 swapperStockBefore = IERC20(stockToken).balanceOf(swapper);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: buyZeroForOne,
                amountSpecified: -int256(stockIn),
                sqrtPriceLimitX96: buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // The pre-swap skim itself must be completely correct despite a real, concurrently-filling
        // governance liquidation order sharing the same beforeSwap call.
        uint256 stockPaid = swapperStockBefore - IERC20(stockToken).balanceOf(swapper);
        assertEq(stockPaid, stockIn, "swapper must pay exactly stockIn despite a concurrent real liquidation order");
        uint256 expectedProtocolCut = (stockIn * 1000 * 2000) / (10_000 * 10_000);
        assertEq(
            IERC20(stockToken).balanceOf(protocol) - protocolStockBefore,
            expectedProtocolCut,
            "protocol's real cut must be unaffected by a concurrent real liquidation order"
        );

        // The liquidation order itself must still be independently claimable and correct --
        // unaffected by having shared a beforeSwap call with the skim above.
        vm.warp(block.timestamp + EXPIRATION_INTERVAL * 2);
        uint256 burnBefore = IERC20(token).balanceOf(hook.BURN_ADDRESS());
        uint256 tstBurned = staking.claimLiquidatedTst();
        assertGt(tstBurned, 0, "the real liquidation order must have genuinely filled and be claimable");

        // A governance liquidation order is, mechanically, just another TWAMM order selling stock
        // for TST -- StocksHook's own TWAMM-order fee fix (see its "TWAMM order fee parity"
        // section) makes THIS order pay the pool's fee too, exactly like the swapper's trade
        // above: `claimLiquidatedTst()` calls `hook.sync(...)` internally, which now burns this
        // pool's effectiveFeeBps share of the order's real earnings BEFORE StocksStaking ever sees
        // or reports them -- so the burn-address delta here is StocksStaking's own reported
        // `tstBurned` PLUS that fee, not equal to it. This is the fix working as intended, not a
        // discrepancy: the whole point was that no TWAMM order, including the protocol's own
        // liquidation flow, should be able to skip this pool's fee mechanism.
        uint256 totalBurnDelta = IERC20(token).balanceOf(hook.BURN_ADDRESS()) - burnBefore;
        uint256 feeBurnedAtSync = totalBurnDelta - tstBurned;
        assertGt(feeBurnedAtSync, 0, "StocksHook's TWAMM-order fee fix must burn a real, nonzero fee on this order's proceeds too");

        uint256 grossEarnings = tstBurned + feeBurnedAtSync;
        uint256 effectiveFeeBps = 1000 - (1000 * 2000) / 10_000; // same feeBps/PROTOCOL_FEE_SHARE_BPS as expectedProtocolCut above
        uint256 expectedFeeBurn = (grossEarnings * effectiveFeeBps) / 10_000;
        assertApproxEqAbs(
            feeBurnedAtSync,
            expectedFeeBurn,
            1,
            "the fee fix's own burn must match effectiveFeeBps of this liquidation order's real gross earnings"
        );

        console.log("PASS: real treasury liquidation order coexists correctly with the real pre-swap skim");
        console.log("  stockCommitted:", stockCommitted, "tstBurned (StocksStaking's own report):", tstBurned);
        console.log("  fee burned at sync (StocksHook's own TWAMM-order fix):", feeBurnedAtSync);
    }

    /// @notice Every gas-griefing/pumpTwammBacklog test so far (test/StocksStaking.liquidationAdversarial.t.sol)
    /// runs against a freshly-deployed LOCAL PoolManager, never the real, live Ink PoolManager this fix will
    /// actually run against in production. Real deployments can have different code paths (already-warm vs
    /// cold storage slots, the real deployed bytecode rather than what's built locally, real protocol fee
    /// settings) that a local build can't fully stand in for. Reproduces the same staggered-order gas-griefing
    /// setup and the pumpTwammBacklog fix against the real fork, end to end.
    function test_PumpTwammBacklog_WorksAgainstTheRealInkPoolManager() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
        uint256 price = 0.5e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curve) =
            factory.createCurve("Real Pump Test", "RPT", stockToken, price, priceTimestamp, signature, 30 days, "");

        vm.warp(block.timestamp + 61);
        uint256 buyAmount = 200_000e18;
        address buyer2 = address(0xB0B2);
        deal(stockToken, buyer2, buyAmount);
        vm.startPrank(buyer2);
        IERC20(stockToken).approve(curve, buyAmount);
        StocksCurve(curve).buy(buyAmount, 0);
        vm.stopPrank();
        StocksCurve(curve).graduate();

        address stakingAddr = StocksCurve(curve).staking();
        address governorAddr = StocksCurve(curve).governor();
        StocksStaking staking = StocksStaking(stakingAddr);
        PoolKey memory key = StocksPoolView(StocksCurve(curve).pair()).poolKey();
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;

        deal(stockToken, stakingAddr, 5_000e18);

        // Baseline: what a real, unstaggered liquidation costs on the real fork.
        uint256 minIntervals = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governorAddr);
        uint256 gasBefore = gasleft();
        staking.liquidateTreasury(minIntervals);
        uint256 baselineGas = gasBefore - gasleft();

        // Stagger 15 tiny attacker orders across 15 distinct real hourly boundaries, then let them all expire
        // in total silence -- the same shape as the local test, now against the real deployed TWAMM state.
        address realAttacker = address(0xA77AC4F0);
        uint256 startTime = block.timestamp;
        uint256 n = 15;
        for (uint256 i = 1; i <= n; ++i) {
            deal(stockToken, realAttacker, 1e12);
            vm.startPrank(realAttacker);
            IERC20(stockToken).approve(address(hook), 1e12);
            hook.submitOrder(
                ITWAMM.SubmitOrderParams({key: key, zeroForOne: !tstIsCurrency0, duration: i * EXPIRATION_INTERVAL, amountIn: 1e12})
            );
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * EXPIRATION_INTERVAL);

        // Confirm the backlog really did inflate cost on the real fork too, same as locally.
        vm.warp(block.timestamp + staking.MIN_LIQUIDATION_DURATION() + EXPIRATION_INTERVAL);
        // (liquidateTreasury from the prior call already expired by now -- fund again for a fresh one.)
        deal(stockToken, stakingAddr, 5_000e18);
        vm.prank(governorAddr);
        gasBefore = gasleft();
        staking.liquidateTreasury(minIntervals);
        uint256 staggeredGas = gasBefore - gasleft();

        console.log("real-fork liquidateTreasury gas -- baseline:  ", baselineGas);
        console.log("real-fork liquidateTreasury gas -- staggered: ", staggeredGas);
        assertGt(staggeredGas, baselineGas, "the staggered backlog must genuinely inflate cost on the real fork too");

        // Now prove pumpTwammBacklog defuses a fresh staggered backlog on the real fork.
        vm.warp(block.timestamp + staking.MIN_LIQUIDATION_DURATION() + EXPIRATION_INTERVAL);
        startTime = block.timestamp;
        for (uint256 i = 1; i <= n; ++i) {
            deal(stockToken, realAttacker, 1e12);
            vm.startPrank(realAttacker);
            IERC20(stockToken).approve(address(hook), 1e12);
            hook.submitOrder(
                ITWAMM.SubmitOrderParams({key: key, zeroForOne: !tstIsCurrency0, duration: i * EXPIRATION_INTERVAL, amountIn: 1e12})
            );
            vm.stopPrank();
        }
        vm.warp(startTime + (n + 1) * EXPIRATION_INTERVAL);

        vm.prank(address(0xD1FF5EA1));
        hook.pumpTwammBacklog(key, EXPIRATION_INTERVAL, 50);

        deal(stockToken, stakingAddr, 5_000e18);
        vm.prank(governorAddr);
        gasBefore = gasleft();
        staking.liquidateTreasury(minIntervals);
        uint256 gasAfterPump = gasBefore - gasleft();

        console.log("real-fork liquidateTreasury gas -- after pumpTwammBacklog:", gasAfterPump);
        assertLt(gasAfterPump, staggeredGas, "pumpTwammBacklog must meaningfully reduce cost on the real fork, same as locally");
        assertLt(gasAfterPump, baselineGas * 2, "and land close to the real, unstaggered baseline, not just 'somewhat better'");
    }

    /// @notice Neither StocksHook.priceLimitCutOvercharge.t.sol nor StocksHook.rangeOrderFeeBypass.t.sol has
    /// ever run against the real, live Ink PoolManager -- only a freshly-deployed local one, same gap the
    /// pumpTwammBacklog test above just closed for the gas-griefing fix. The real fork just showed a
    /// meaningfully different baseline gas figure for liquidateTreasury (400,061 vs. 288,635 locally),
    /// confirming real state genuinely differs from a fresh local deploy in ways worth checking each fix
    /// against directly. This verifies the price-limit cut overcharge fix (PreSwapCutWouldExceedActualFill)
    /// end to end on the real fork: a tight price limit must revert instead of overcharging, and an ordinary
    /// swap must still work normally.
    function test_PriceLimitCutOverchargeFix_WorksAgainstTheRealInkPoolManager() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
        uint256 price = 0.5e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curve) =
            factory.createCurve("Real Price Limit Test", "RPLT", stockToken, price, priceTimestamp, signature, 30 days, "");

        vm.warp(block.timestamp + 61);
        uint256 buyAmount = 200_000e18;
        address buyer3 = address(0xB0B3);
        deal(stockToken, buyer3, buyAmount);
        vm.startPrank(buyer3);
        IERC20(stockToken).approve(curve, buyAmount);
        StocksCurve(curve).buy(buyAmount, 0);
        vm.stopPrank();
        StocksCurve(curve).graduate();

        PoolKey memory key = StocksPoolView(StocksCurve(curve).pair()).poolKey();
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;

        // A tight price limit (1 tick above current) on a large stock-in trade -- the exact shape that
        // overcharged before the fix.
        (, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint160 tightLimit = TickMath.getSqrtPriceAtTick(tickBefore + 1);

        address realSwapper = address(0xC0FFEE2);
        uint256 stockIn = 100_000e18;
        deal(stockToken, realSwapper, stockIn);
        vm.startPrank(realSwapper);
        IERC20(stockToken).approve(address(swapRouter), stockIn);
        vm.expectRevert(); // PoolManager wraps the hook's own revert -- see this codebase's own bare-revert convention
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: !tstIsCurrency0, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: tightLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // An ordinary swap with a wide-open limit must still work normally right afterward.
        address realSwapper2 = address(0xC0FFEE3);
        uint256 stockIn2 = 10_000e18;
        deal(stockToken, realSwapper2, stockIn2);
        vm.startPrank(realSwapper2);
        IERC20(stockToken).approve(address(swapRouter), stockIn2);
        uint256 tstBefore = IERC20(token).balanceOf(realSwapper2);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !tstIsCurrency0,
                amountSpecified: -int256(stockIn2),
                sqrtPriceLimitX96: !tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertGt(IERC20(token).balanceOf(realSwapper2) - tstBefore, 0, "an ordinary swap must still succeed normally on the real fork");
        console.log("PASS: price-limit cut overcharge fix verified against the real Ink PoolManager");
    }

    /// @notice Verifies the range-order fee bypass fix (NonFullRangeLiquidityNotAllowed) end to end on the
    /// real fork: a narrow (non-full-range) liquidity add must revert, and a full-range add must still work.
    function test_RangeOrderBypassFix_WorksAgainstTheRealInkPoolManager() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
        uint256 price = 0.5e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curve) =
            factory.createCurve("Real Range Order Test", "RROT", stockToken, price, priceTimestamp, signature, 30 days, "");

        vm.warp(block.timestamp + 61);
        uint256 buyAmount = 200_000e18;
        address buyer4 = address(0xB0B4);
        deal(stockToken, buyer4, buyAmount);
        vm.startPrank(buyer4);
        IERC20(stockToken).approve(curve, buyAmount);
        StocksCurve(curve).buy(buyAmount, 0);
        vm.stopPrank();
        StocksCurve(curve).graduate();

        PoolKey memory key = StocksPoolView(StocksCurve(curve).pair()).poolKey();
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(poolManager);

        address realLp = address(uint160(0x193330));
        deal(token, realLp, 10_000e18);
        deal(stockToken, realLp, 10_000e18);
        vm.startPrank(realLp);
        IERC20(token).approve(address(lpRouter), type(uint256).max);
        IERC20(stockToken).approve(address(lpRouter), type(uint256).max);

        vm.expectRevert(); // PoolManager wraps the hook's own revert -- see this codebase's own bare-revert convention
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );

        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        BalanceDelta addDelta = lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick, tickUpper: maxTick, liquidityDelta: 1e18, salt: bytes32(uint256(1))}),
            ""
        );
        vm.stopPrank();
        assertLt(addDelta.amount0(), 0, "full-range liquidity must still be addable normally on the real fork");
        console.log("PASS: range-order bypass fix verified against the real Ink PoolManager");
    }
}
