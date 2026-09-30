// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract MockERC20V5 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

contract MockTreasuryV5 {
    uint256 public notifyCount;

    function notifyRewardAmount() external {
        notifyCount++;
    }
}

/// @notice Direct, hook-level unit tests for StocksHook -- same lightweight methodology as
/// MemeStockHookV4.security.t.sol (real forked PoolManager, real V4-core PoolSwapTest/
/// PoolModifyLiquidityTest test-helper routers, mock tokens/treasury -- fast, no full production
/// stack needed), confirming everything MemeStockHookV4's own security suite already covers still
/// holds after the merge (exact-output rejection, both-direction fee routing, pool-registration
/// gating), plus what's actually NEW here: the combined beforeInitialize, the kill-switch being
/// permanently unreachable, and protocol's fee cut being paid directly, always in stock -- in
/// afterSwap for the sell-TST direction, pre-swap off the stock input in beforeSwap for the
/// buy-TST direction (see StocksHook.sol's own docstring) -- with no separate sweep/claim step.
contract StocksHookSecurityTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant FEE_BPS = 1_000; // 10%
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1, Q64.96
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    MockERC20V5 tst;
    MockERC20V5 stock;
    MockTreasuryV5 treasury;
    address protocol = address(0xBEEF);
    address trader = address(0xCAFE);

    PoolKey key;
    PoolId poolId;

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory creationCode = type(StocksHook).creationCode;
        // poolDeployer == address(this) -- this test contract plays the role StocksGraduator
        // plays in production, matching the real trust model exactly.
        bytes memory constructorArgs = abi.encode(poolManager, address(this), EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, address(this), EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        treasury = new MockTreasuryV5();

        MockERC20V5 tokenA = new MockERC20V5("Acme", "ACME", SUPPLY);
        MockERC20V5 tokenB = new MockERC20V5("Stock", "STOCK", SUPPLY);
        (tst, stock) = (tokenA, tokenB);

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        poolId = key.toId();

        hook.registerPool(key, address(tst), address(stock), address(treasury), protocol, FEE_BPS);
        poolManager.initialize(key, SQRT_PRICE_1_1);

        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        tst.transfer(trader, 10_000e18);
        stock.transfer(trader, 10_000e18);
        vm.startPrank(trader);
        tst.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _tstIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(tst);
    }

    function _priceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _freshKey(string memory salt) internal returns (PoolKey memory key2) {
        MockERC20V5 c = new MockERC20V5(string.concat("Acme", salt), string.concat("ACME", salt), SUPPLY);
        MockERC20V5 s = new MockERC20V5(string.concat("Stock", salt), string.concat("STOCK", salt), SUPPLY);
        (Currency c0, Currency c1) = address(c) < address(s)
            ? (Currency.wrap(address(c)), Currency.wrap(address(s)))
            : (Currency.wrap(address(s)), Currency.wrap(address(c)));
        key2 = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
    }

    // ============================================================
    // Combined beforeInitialize: both parents' checks must hold
    // ============================================================

    function test_Initialize_RevertsForNonPoolDeployerSender() public {
        PoolKey memory key2 = _freshKey("A");
        hook.registerPool(
            key2, Currency.unwrap(key2.currency0), Currency.unwrap(key2.currency1), address(treasury), protocol, FEE_BPS
        );

        vm.prank(trader);
        vm.expectRevert();
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_Initialize_SucceedsForPoolDeployerSender() public {
        PoolKey memory key2 = _freshKey("B");
        hook.registerPool(
            key2, Currency.unwrap(key2.currency0), Currency.unwrap(key2.currency1), address(treasury), protocol, FEE_BPS
        );

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // TWAMM's own state must also have been initialized by the SAME beforeInitialize call --
        // confirms the combined check ran both halves, not just MemeStockHookV4's original one.
        assertGt(hook.lastVirtualOrderTimestamp(key2.toId()), 0, "TWAMM state was not initialized");
    }

    function test_Initialize_StillRevertsIfNeverRegistered_EvenForPoolDeployer() public {
        PoolKey memory key2 = _freshKey("C");
        vm.expectRevert();
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    // ============================================================
    // Exact-output rejection (unchanged from MemeStockHookV4)
    // ============================================================

    function test_ExactOutputSwap_Reverts_ZeroForOne() public {
        vm.prank(trader);
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10e18, sqrtPriceLimitX96: _priceLimit(true)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_ExactOutputSwap_NoLongerSilentlyBypassesFee() public {
        uint256 burnBefore = tst.balanceOf(BURN_ADDRESS);
        uint256 protocolStockBefore = stock.balanceOf(protocol);

        vm.prank(trader);
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: _priceLimit(true)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(tst.balanceOf(BURN_ADDRESS), burnBefore);
        // Exact-output is left untouched by beforeSwap (see StocksHook.beforeSwap's own docstring
        // -- it only ever acts on exact-input) and rejected outright in afterSwap either way, so
        // protocol must not have received anything from this reverted attempt.
        assertEq(stock.balanceOf(protocol), protocolStockBefore);
    }

    // ============================================================
    // Both-direction fee routing still works with TWAMM in the loop
    // ============================================================

    function test_ExactInputSwap_StillChargesFee_PayStockReceiveTst() public {
        bool zeroForOne = !_tstIsCurrency0();
        uint256 burnBefore = tst.balanceOf(BURN_ADDRESS);
        uint256 protocolStockBefore = stock.balanceOf(protocol);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -500e18, sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertGt(tst.balanceOf(BURN_ADDRESS), burnBefore);
        // Protocol is now ALWAYS paid in stock, never TST -- for this direction its cut is
        // skimmed pre-swap, off the stock input, in beforeSwap -- see StocksHook.sol's own
        // docstring and test/StocksHook.feeRouting.fuzz.t.sol for the precise accounting checks.
        assertGt(stock.balanceOf(protocol), protocolStockBefore, "protocol's pre-swap stock cut must be paid directly");
    }

    function test_ExactInputSwap_StillChargesFee_PayTstReceiveStock() public {
        bool zeroForOne = _tstIsCurrency0();
        uint256 treasuryBefore = stock.balanceOf(address(treasury));
        uint256 protocolBefore = stock.balanceOf(protocol);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -500e18, sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertGt(stock.balanceOf(address(treasury)), treasuryBefore);
        assertGt(stock.balanceOf(protocol), protocolBefore);
        assertEq(treasury.notifyCount(), 1);
    }

    // ============================================================
    // NEW: kill-switch is permanently unreachable
    // ============================================================

    function test_KillHook_AlwaysRevertsForAnyCaller() public {
        vm.expectRevert(); // owner() is address(0) after renounceOwnership() in the constructor
        hook.killHook();

        vm.prank(address(this)); // even the deployer, who briefly held ownership mid-constructor
        vm.expectRevert();
        hook.killHook();

        vm.prank(protocol);
        vm.expectRevert();
        hook.killHook();
    }

    function test_Owner_IsZeroAddress() public view {
        assertEq(hook.owner(), address(0), "ownership must have been renounced at construction");
    }

    // ============================================================
    // NEW: beforeAddLiquidity/beforeRemoveLiquidity don't break ordinary LP actions
    // ============================================================

    function test_RemoveLiquidity_StillWorks_WithNoTwammOrdersOutstanding() public {
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -500_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ============================================================
    // NEW: protocol's fee cut is always paid directly in stock, both directions -- for the buy-TST
    // direction it's skimmed pre-swap off the stock input (beforeSwap), never sent in TST at all.
    // ============================================================

    function test_RepeatedTstFeeSwaps_AccumulateDirectlyInProtocolWallet() public {
        bool zeroForOne = !_tstIsCurrency0(); // pay stock, receive TST -- charges the TST-side fee
        uint256 protocolStockBefore = stock.balanceOf(protocol);
        uint256 protocolTstBefore = tst.balanceOf(protocol);
        for (uint256 i; i < 5; i++) {
            vm.prank(trader);
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -500e18, sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        assertGt(stock.balanceOf(protocol), protocolStockBefore, "protocol must have actually received real stock across repeated buy-side swaps");
        assertEq(tst.balanceOf(protocol), protocolTstBefore, "protocol must never receive TST, even on the buy-TST direction");
    }

    // ============================================================
    // Permissionless direct TWAMM order submission (submitOrder/sync/claim) --
    // StocksHook inherits TWAMM's own public submitOrder/sync/claimTokensByPoolKey/
    // claimTokensByCurrencies/batchSubmitOrders unmodified, so ANY address can open a real
    // long-term order directly on a Stocks.ink pool, completely bypassing the bonding curve. These
    // tests call submitOrder/sync/claim exactly as an ordinary trader would.
    // ============================================================

    function test_UserSubmitOrder_PermissionlessDirectOnPool_FillsAndPaysOnlyTheSubmitter() public {
        bool zeroForOne = _tstIsCurrency0(); // trader sells TST, receives stock
        uint256 amountIn = 1_000e18;
        uint256 duration = EXPIRATION_INTERVAL * 4;

        vm.startPrank(trader);
        tst.approve(address(hook), amountIn);
        (, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn})
        );
        vm.stopPrank();

        assertEq(orderKey.owner, trader, "order owner must be the actual submitting EOA, not the hook");
        // submitOrder actually pulls (amountIn / duration) * duration, NOT amountIn itself -- the
        // integer-division truncation of sellRate silently leaves up to `duration - 1` wei of the
        // requested amountIn never transferred and never part of the order. Purely self-inflicted
        // dust loss for the submitter (nobody else's funds are affected), but worth documenting
        // precisely since it's easy to assume submitOrder debits exactly amountIn.
        uint256 actualPulled = (amountIn / duration) * duration;
        assertEq(tst.balanceOf(address(hook)), actualPulled, "hook should hold exactly sellRate*duration, not the raw requested amountIn");
        assertLt(actualPulled, amountIn, "sanity: this amountIn/duration pair should actually truncate for this assertion to be meaningful");

        vm.warp(block.timestamp + duration + 1);
        hook.executeTWAMMOrders(key); // permissionless, callable by anyone (called here by the test contract itself)

        uint256 stockBefore = stock.balanceOf(trader);
        vm.prank(trader);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));
        vm.prank(trader);
        (uint256 tokens0, uint256 tokens1) = hook.claimTokensByPoolKey(key);
        uint256 stockClaimed = _tstIsCurrency0() ? tokens1 : tokens0;
        assertGt(stockClaimed, 0, "a fully-expired real order must have earned real stock proceeds");
        assertEq(stock.balanceOf(trader), stockBefore + stockClaimed, "trader must receive exactly what claimTokensByPoolKey reported");
    }

    function test_UserSubmitOrder_TokensOwedIsPerSender_OutsiderCanNeverClaimAnotherUsersFill() public {
        bool zeroForOne = _tstIsCurrency0();
        uint256 amountIn = 1_000e18;
        uint256 duration = EXPIRATION_INTERVAL * 4;

        vm.startPrank(trader);
        tst.approve(address(hook), amountIn);
        (, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn})
        );
        vm.stopPrank();

        vm.warp(block.timestamp + duration + 1);
        hook.executeTWAMMOrders(key);

        // sync() itself is owner-gated (Unauthorized() if called by anyone else), but even if an
        // outsider tries to just claim outright -- no sync of their own ever happened for them --
        // claimTokensByPoolKey/claimTokensByCurrencies must pay them exactly nothing: tokensOwed
        // is keyed by msg.sender, never by pool or by who else has orders outstanding.
        address outsider = address(0xD00D);
        vm.prank(outsider);
        vm.expectRevert(ITWAMM.Unauthorized.selector);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));

        vm.prank(outsider);
        (uint256 out0, uint256 out1) = hook.claimTokensByPoolKey(key);
        assertEq(out0, 0, "outsider must never receive currency0 from a fill they had no order in");
        assertEq(out1, 0, "outsider must never receive currency1 from a fill they had no order in");

        // The real owner can still claim their own full proceeds afterward, completely undisturbed.
        uint256 stockBefore = stock.balanceOf(trader);
        vm.prank(trader);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));
        vm.prank(trader);
        (uint256 tokens0, uint256 tokens1) = hook.claimTokensByPoolKey(key);
        uint256 stockClaimed = _tstIsCurrency0() ? tokens1 : tokens0;
        assertGt(stockClaimed, 0, "the real owner's proceeds must be untouched by the outsider's failed claim attempt");
        assertEq(stock.balanceOf(trader), stockBefore + stockClaimed, "owner receives exactly their own fill, nothing more or less");
    }

    function test_UserSubmitOrder_SellRateRoundsToZero_RevertsCleanly() public {
        bool zeroForOne = _tstIsCurrency0();
        vm.startPrank(trader);
        tst.approve(address(hook), 1);
        vm.expectRevert(ITWAMM.SellRateCannotBeZero.selector);
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: EXPIRATION_INTERVAL * 1000, amountIn: 1})
        );
        vm.stopPrank();
    }

    function test_UserSubmitOrder_DurationNotMultipleOfInterval_RevertsExpirationNotOnInterval() public {
        bool zeroForOne = _tstIsCurrency0();
        vm.startPrank(trader);
        tst.approve(address(hook), 1_000e18);
        vm.expectRevert(); // ExpirationNotOnInterval(uint256) -- bare vm.expectRevert(), same convention as this file's other parameterized-error reverts
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: EXPIRATION_INTERVAL + 1, amountIn: 1_000e18})
        );
        vm.stopPrank();
    }

    // ============================================================
    // registerPool validation -- every one of its 7 distinct revert branches, previously
    // completely untested in either MemeStockHookV4.security.t.sol or this file. registerPool
    // permanently freezes a pool's fee-routing terms (see its own docstring), so every guard
    // here is security-critical.
    // ============================================================

    function test_RegisterPool_RevertsForNonPoolDeployerSender() public {
        PoolKey memory key2 = _freshKey("D1");
        vm.prank(trader);
        vm.expectRevert(StocksHook.NotPoolDeployer.selector);
        hook.registerPool(
            key2, Currency.unwrap(key2.currency0), Currency.unwrap(key2.currency1), address(treasury), protocol, FEE_BPS
        );
    }

    function test_RegisterPool_RevertsIfAlreadyRegistered() public {
        // `key` was already registered once in setUp().
        vm.expectRevert(StocksHook.AlreadyRegistered.selector);
        hook.registerPool(key, address(tst), address(stock), address(treasury), protocol, FEE_BPS);
    }

    function test_RegisterPool_RevertsOnZeroTstToken() public {
        PoolKey memory key2 = _freshKey("D2");
        vm.expectRevert(StocksHook.ZeroAddress.selector);
        hook.registerPool(key2, address(0), Currency.unwrap(key2.currency1), address(treasury), protocol, FEE_BPS);
    }

    function test_RegisterPool_RevertsOnZeroStockToken() public {
        PoolKey memory key2 = _freshKey("D3");
        vm.expectRevert(StocksHook.ZeroAddress.selector);
        hook.registerPool(key2, Currency.unwrap(key2.currency0), address(0), address(treasury), protocol, FEE_BPS);
    }

    function test_RegisterPool_RevertsOnZeroTreasury() public {
        PoolKey memory key2 = _freshKey("D4");
        vm.expectRevert(StocksHook.ZeroAddress.selector);
        hook.registerPool(
            key2, Currency.unwrap(key2.currency0), Currency.unwrap(key2.currency1), address(0), protocol, FEE_BPS
        );
    }

    function test_RegisterPool_RevertsOnZeroProtocol() public {
        PoolKey memory key2 = _freshKey("D5");
        vm.expectRevert(StocksHook.ZeroAddress.selector);
        hook.registerPool(
            key2, Currency.unwrap(key2.currency0), Currency.unwrap(key2.currency1), address(treasury), address(0), FEE_BPS
        );
    }

    function test_RegisterPool_RevertsIfTstAndStockTokensIdentical() public {
        PoolKey memory key2 = _freshKey("D6");
        address token = Currency.unwrap(key2.currency0);
        vm.expectRevert(StocksHook.IdenticalTokens.selector);
        hook.registerPool(key2, token, token, address(treasury), protocol, FEE_BPS);
    }

    function test_RegisterPool_RevertsIfFeeExceedsMax() public {
        PoolKey memory key2 = _freshKey("D7");
        // Materialize this BEFORE arming expectRevert -- hook.MAX_FEE_BPS() is itself a staticcall,
        // and if it sat inline in the next statement's arguments it would consume the armed
        // expectRevert before registerPool ever runs. See feedback_expectrevert_consumed_by_nested_call.
        uint256 tooHighFee = hook.MAX_FEE_BPS() + 1;
        vm.expectRevert(StocksHook.FeeTooHigh.selector);
        hook.registerPool(
            key2, Currency.unwrap(key2.currency0), Currency.unwrap(key2.currency1), address(treasury), protocol, tooHighFee
        );
    }

    function test_RegisterPool_RevertsIfHooksAddressWrong() public {
        PoolKey memory key2 = _freshKey("D8");
        // Same currencies/tokens as a valid registration, but `hooks` points elsewhere. This can
        // never actually be reached via a real poolManager.initialize call in production (the
        // PoolKey's own hooks field is how the PoolManager routes to a hook at all), but
        // registerPool's own standalone check must still hold on a direct call.
        PoolKey memory badHooksKey = PoolKey({
            currency0: key2.currency0,
            currency1: key2.currency1,
            fee: key2.fee,
            tickSpacing: key2.tickSpacing,
            hooks: IHooks(address(0x1234))
        });
        vm.expectRevert(StocksHook.InvalidPoolKey.selector);
        hook.registerPool(
            badHooksKey,
            Currency.unwrap(key2.currency0),
            Currency.unwrap(key2.currency1),
            address(treasury),
            protocol,
            FEE_BPS
        );
    }

    function test_RegisterPool_RevertsIfTstTokenMatchesNeitherCurrency() public {
        PoolKey memory key2 = _freshKey("D9");
        MockERC20V5 unrelated = new MockERC20V5("Unrelated", "UNR", SUPPLY);
        vm.expectRevert(StocksHook.InvalidPoolKey.selector);
        hook.registerPool(key2, address(unrelated), Currency.unwrap(key2.currency1), address(treasury), protocol, FEE_BPS);
    }

    function test_RegisterPool_RevertsIfStockTokenDoesNotMatchTheOtherCurrency() public {
        PoolKey memory key2 = _freshKey("D10");
        MockERC20V5 unrelated = new MockERC20V5("Unrelated", "UNR", SUPPLY);
        // tstToken_ correctly matches currency0, but stockToken_ is neither currency1 nor
        // currency0 -- distinct branch from the "matches neither" case above, which fails on
        // tstToken_ itself.
        vm.expectRevert(StocksHook.InvalidPoolKey.selector);
        hook.registerPool(key2, Currency.unwrap(key2.currency0), address(unrelated), address(treasury), protocol, FEE_BPS);
    }

    // ============================================================
    // Batch order submission/claim (batchSubmitOrders / batchSyncAndClaimTokens) -- inherited
    // unmodified from vendored TWAMM, same permissionless surface as submitOrder/sync above, and
    // previously completely untested anywhere in the repo.
    // ============================================================

    function test_UserBatchSubmitOrders_ThenBatchSyncAndClaim_BothOrdersFillIndependently() public {
        bool zeroForOne = _tstIsCurrency0();
        uint256 amountIn = 500e18;
        uint256 duration = EXPIRATION_INTERVAL * 4;

        ITWAMM.SubmitOrderParams[] memory orders = new ITWAMM.SubmitOrderParams[](2);
        orders[0] = ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn});
        orders[1] =
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration * 2, amountIn: amountIn});

        vm.startPrank(trader);
        tst.approve(address(hook), type(uint256).max);
        (bytes32[] memory orderIds, ITWAMM.OrderKey[] memory orderKeys) = hook.batchSubmitOrders(orders);
        vm.stopPrank();

        assertEq(orderIds.length, 2, "batchSubmitOrders must return one id per submitted order");
        assertEq(orderKeys[0].owner, trader, "batch order 0 owner must be the real submitting EOA");
        assertEq(orderKeys[1].owner, trader, "batch order 1 owner must be the real submitting EOA");

        vm.warp(block.timestamp + duration * 2 + 1);
        hook.executeTWAMMOrders(key);

        ITWAMM.SyncParams[] memory syncs = new ITWAMM.SyncParams[](2);
        syncs[0] = ITWAMM.SyncParams({key: key, orderKey: orderKeys[0]});
        syncs[1] = ITWAMM.SyncParams({key: key, orderKey: orderKeys[1]});
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;

        uint256 stockBefore = stock.balanceOf(trader);
        vm.prank(trader);
        uint256[] memory claimed = hook.batchSyncAndClaimTokens(syncs, currencies);

        uint256 stockIdx = _tstIsCurrency0() ? 1 : 0;
        assertGt(claimed[stockIdx], 0, "batch claim must have paid out real stock proceeds from both fully-expired orders");
        assertEq(
            stock.balanceOf(trader),
            stockBefore + claimed[stockIdx],
            "trader must receive exactly what batchSyncAndClaimTokens reported for stock"
        );
    }

    function test_UserBatchSubmitOrders_DuplicateOrderKeyInSameBatch_RevertsEntireBatchAtomically() public {
        // Two entries with an IDENTICAL owner/zeroForOne/duration collide on the exact same
        // orderKey (owner+expiration+zeroForOne) and orderId -- a real, easy-to-hit footgun for any
        // batch-submission UI that lets a user queue "the same trade twice" in one call.
        // batchSubmitOrders has no try/catch around its loop, so the second entry's
        // OrderAlreadyExists bubbles up and reverts the WHOLE batch, including the first,
        // otherwise-perfectly-valid order -- confirmed here to be a real, fully atomic revert (the
        // first order's own token pull never sticks either), not a partial-fill.
        bool zeroForOne = _tstIsCurrency0();
        uint256 amountIn = 500e18;
        uint256 duration = EXPIRATION_INTERVAL * 4;

        ITWAMM.SubmitOrderParams[] memory orders = new ITWAMM.SubmitOrderParams[](2);
        orders[0] = ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn});
        orders[1] = ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn});

        uint256 tstBefore = tst.balanceOf(trader);
        uint256 hookTstBefore = tst.balanceOf(address(hook));
        vm.startPrank(trader);
        tst.approve(address(hook), type(uint256).max);
        vm.expectRevert(); // OrderAlreadyExists(OrderKey) -- bare vm.expectRevert() per this file's existing parameterized-error convention
        hook.batchSubmitOrders(orders);
        vm.stopPrank();

        assertEq(tst.balanceOf(trader), tstBefore, "a reverted batch must leave the trader's balance completely untouched, not partially debited for order 0");
        assertEq(tst.balanceOf(address(hook)), hookTstBefore, "the hook must not retain any funds from the first order in a batch that reverted on the second");
    }

    function test_UserBatchSyncAndClaim_OneUnauthorizedOrderKeyInBatch_RevertsWholeClaim() public {
        // trader batches their OWN legitimate, fully-expired order together with a SECOND real
        // order that belongs to someone else (e.g. a stale cache entry, a copy-paste mistake, or a
        // keeper naively batching claims across multiple users for gas savings). sync()'s
        // owner-check has no try/catch anywhere in batchSyncAndClaimTokens's loop, so the foreign
        // order's Unauthorized revert takes down the ENTIRE call -- denying trader their own
        // otherwise-valid claim in the same transaction, purely as a side effect of someone else's
        // orderKey being present in the batch.
        bool zeroForOne = _tstIsCurrency0();
        uint256 amountIn = 500e18;
        uint256 duration = EXPIRATION_INTERVAL * 4;

        address otherTrader = address(0xD00D2);
        tst.transfer(otherTrader, 10_000e18);

        vm.startPrank(trader);
        tst.approve(address(hook), amountIn);
        (, ITWAMM.OrderKey memory myOrderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn})
        );
        vm.stopPrank();

        vm.startPrank(otherTrader);
        tst.approve(address(hook), amountIn);
        (, ITWAMM.OrderKey memory otherOrderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration * 2, amountIn: amountIn})
        );
        vm.stopPrank();

        vm.warp(block.timestamp + duration * 2 + 1);
        hook.executeTWAMMOrders(key);

        ITWAMM.SyncParams[] memory syncs = new ITWAMM.SyncParams[](2);
        syncs[0] = ITWAMM.SyncParams({key: key, orderKey: myOrderKey});
        syncs[1] = ITWAMM.SyncParams({key: key, orderKey: otherOrderKey});
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;

        uint256 stockBefore = stock.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(ITWAMM.Unauthorized.selector);
        hook.batchSyncAndClaimTokens(syncs, currencies);

        assertEq(stock.balanceOf(trader), stockBefore, "a reverted batch claim must not have paid out trader's own otherwise-valid order");

        // trader's own order is untouched by the failed batch and remains fully claimable alone.
        vm.prank(trader);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: myOrderKey}));
        vm.prank(trader);
        (uint256 t0, uint256 t1) = hook.claimTokensByPoolKey(key);
        uint256 stockClaimed = _tstIsCurrency0() ? t1 : t0;
        assertGt(stockClaimed, 0, "trader's own order must still be fully claimable individually after the batch reverted");
    }
}
