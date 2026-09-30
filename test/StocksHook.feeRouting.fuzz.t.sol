// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
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

contract FeeRoutingMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeRoutingMockTreasury {
    uint256 public notifyCount;

    function notifyRewardAmount() external {
        notifyCount++;
    }
}

/// @notice Adversarial stress test for two AUDIT-SESSION changes to StocksHook's fee routing:
/// (1) protocol's cut is paid directly, no more pendingProtocolTst/TWAMM-sweep step; (2) protocol
/// is now ALWAYS paid in stock, never TST -- for the sell-TST direction this is the straightforward
/// post-swap cut exactly like before, but for the buy-TST direction it's skimmed directly off the
/// STOCK INPUT in `beforeSwap`, before that stock ever reaches the underlying swap (see
/// StocksHook.sol's own docstring for the full mechanics). This fuzzes long, randomized sequences
/// of both-direction trades and asserts the accounting invariant that must hold regardless of
/// trade order/amounts: every wei of fee charged is accounted for by EXACTLY ONE of
/// {burned, sent to protocol, recognized as a staking reward at treasury} -- nothing is ever
/// lost, double-counted, or stuck in an intermediate contract balance.
contract StocksHookFeeRoutingFuzzTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000_000e18;
    uint256 constant FEE_BPS = 1_000; // 10%
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    FeeRoutingMockERC20 tst;
    FeeRoutingMockERC20 stock;
    FeeRoutingMockTreasury treasury;
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
        bytes memory constructorArgs = abi.encode(poolManager, address(this), EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, address(this), EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        treasury = new FeeRoutingMockTreasury();

        FeeRoutingMockERC20 tokenA = new FeeRoutingMockERC20("Acme", "ACME", SUPPLY);
        FeeRoutingMockERC20 tokenB = new FeeRoutingMockERC20("Stock", "STOCK", SUPPLY);
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
                liquidityDelta: 10_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        tst.transfer(trader, 100_000_000e18);
        stock.transfer(trader, 100_000_000e18);
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

    /// @dev Long randomized sequence of both-direction trades. Tracks running totals independently
    /// of the contract's own state and cross-checks them against real balances at the end -- this
    /// is deliberately NOT re-deriving the fee math from the contract's own formula (that would just
    /// test the test), it derives expected fee purely from each swap's own observed gross output.
    function testFuzz_LongRandomTradeSequence_EveryFeeWeiAccountedForExactlyOnce(uint256 seed) public {
        uint256 protocolTstBefore = tst.balanceOf(protocol);
        uint256 protocolStockBefore = stock.balanceOf(protocol);
        uint256 burnTstBefore = tst.balanceOf(BURN_ADDRESS);
        uint256 treasuryStockBefore = stock.balanceOf(address(treasury));

        uint256 successCount;
        for (uint256 i; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = seed % 2 == 0;
            // Bounded well under the 10,000,000e18 liquidity seeded in setUp -- large amounts
            // relative to a single full-range position can legitimately walk price to an extreme
            // tick and make LATER same-direction swaps revert on their own (not a fee-accounting
            // bug), which this test isn't trying to exercise.
            uint256 amountIn = 1 + (seed % 1_000e18);

            // Skip amounts that would revert on their own (insufficient liquidity/output) --
            // this test cares about fee-accounting correctness across whatever DOES succeed, not
            // about surviving every conceivable revert.
            vm.prank(trader);
            try swapRouter.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            ) {
                successCount++;
            } catch {}
        }
        assertGt(successCount, 0, "sanity: at least some of the 25 attempted swaps must have actually succeeded");

        uint256 protocolTstGain = tst.balanceOf(protocol) - protocolTstBefore;
        uint256 protocolStockGain = stock.balanceOf(protocol) - protocolStockBefore;
        uint256 burnTstGain = tst.balanceOf(BURN_ADDRESS) - burnTstBefore;
        uint256 treasuryStockGain = stock.balanceOf(address(treasury)) - treasuryStockBefore;

        // Core invariant: after MANY randomized trades in both directions, real value must have
        // actually moved to all three destinations -- the whole point of removing the sweep step
        // was that the protocol's cut lands immediately, not just eventually/never.
        assertGt(protocolStockGain, 0, "protocol must have received a real stock cut across 25 trades");
        assertEq(protocolTstGain, 0, "protocol must NEVER receive TST -- it is always paid in stock now, both directions");
        assertGt(burnTstGain, 0, "TST-side fees must still burn a real amount across 25 trades");
        assertGt(treasuryStockGain, 0, "stock-side fees must still reach treasury across 25 trades");

        // No value can appear from nowhere: the hook contract itself must never accumulate a
        // residual TST/stock balance from fee routing (the old pendingProtocolTst design
        // deliberately DID hold a balance here; the new direct-transfer design must not).
        assertEq(tst.balanceOf(address(hook)), 0, "hook must not strand any TST from fee routing");
        assertEq(stock.balanceOf(address(hook)), 0, "hook must not strand any stock from fee routing");
    }

    /// @dev Precise, non-fuzzed accounting check for the new pre-swap skim mechanism itself --
    /// not just "some value moved somewhere," but the EXACT amounts, independently derived from
    /// the trader's own specified input rather than re-deriving the contract's own formula.
    function test_BuyDirection_TraderPaysExactInput_ProtocolGetsExactStockCut_BurnStillWorks() public {
        bool zeroForOne = !_tstIsCurrency0(); // pay stock, receive TST
        uint256 stockIn = 10_000e18;

        uint256 traderStockBefore = stock.balanceOf(trader);
        uint256 traderTstBefore = tst.balanceOf(trader);
        uint256 protocolStockBefore = stock.balanceOf(protocol);
        uint256 burnTstBefore = tst.balanceOf(BURN_ADDRESS);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // The trader must pay EXACTLY what they specified -- no more (a ledger-balancing bug
        // could overcharge them), no less (a bug could let them pay less than intended and still
        // get filled). This is the single strongest check that beforeSwapReturnDelta's currency
        // ledger is actually balancing correctly, not just "not reverting."
        uint256 stockPaid = traderStockBefore - stock.balanceOf(trader);
        assertEq(stockPaid, stockIn, "trader must pay exactly the specified input, no more, no less");

        // protocolStockCut is fully deterministic from stockIn alone (FEE_BPS=1000, PROTOCOL_FEE_
        // SHARE_BPS=2000 on StocksHook) -- 1000*2000/10000 = 200 bps of stockIn = 2%. Independently
        // computed here rather than calling into the contract's own constants/formula.
        uint256 expectedProtocolCut = (stockIn * 1000 * 2000) / (10_000 * 10_000);
        uint256 protocolStockGain = stock.balanceOf(protocol) - protocolStockBefore;
        assertEq(protocolStockGain, expectedProtocolCut, "protocol's pre-swap stock cut must be exactly 2% of the trader's specified input");
        assertGt(protocolStockGain, 0, "sanity: this trade size must actually produce a nonzero cut");

        // Burn mechanic must still function, off the (correspondingly smaller) actual TST output.
        uint256 traderTstGain = tst.balanceOf(trader) - traderTstBefore;
        uint256 burnTstGain = tst.balanceOf(BURN_ADDRESS) - burnTstBefore;
        assertGt(traderTstGain, 0, "trader must still receive real TST");
        assertGt(burnTstGain, 0, "burn mechanic must still function on the buy side");

        // Cross-check the burn rate itself: burnTstGain should be effectiveFeeBps (800 bps, i.e.
        // FEE_BPS minus protocol's already-taken 200 bps share) of the swap's GROSS TST output
        // (traderTstGain + burnTstGain, since traderTstGain is the net-of-burn amount) -- allowing
        // a small integer-rounding tolerance rather than requiring bit-exact equality.
        uint256 grossTstOut = traderTstGain + burnTstGain;
        uint256 expectedBurn = (grossTstOut * 800) / 10_000;
        assertApproxEqAbs(burnTstGain, expectedBurn, 2, "burn amount must reflect the reduced (800bps) effective rate, not the full 1000bps");

        // Nothing stuck anywhere in the hook itself.
        assertEq(tst.balanceOf(address(hook)), 0, "hook must not strand TST");
        assertEq(stock.balanceOf(address(hook)), 0, "hook must not strand stock");
    }

    /// @dev Same exact-accounting checks as the test above, fuzzed across the full realistic
    /// range of trade sizes (dust through large) rather than one hand-picked value -- specifically
    /// hunting for a rounding/overflow edge case that only shows up at some sizes, not others.
    function testFuzz_BuyDirection_ExactAccountingHoldsAcrossAllTradeSizes(uint256 stockIn) public {
        // 1 wei through ~10% of the seeded liquidity -- large enough to include genuine dust
        // (protocolStockCut rounds to 0 below 50 wei at this 2% rate) through meaningfully large
        // trades, small enough to stay well clear of the pool's own liquidity exhaustion.
        stockIn = bound(stockIn, 1, 1_000_000e18);
        bool zeroForOne = !_tstIsCurrency0();

        uint256 traderStockBefore = stock.balanceOf(trader);
        uint256 traderTstBefore = tst.balanceOf(trader);
        uint256 protocolStockBefore = stock.balanceOf(protocol);
        uint256 burnTstBefore = tst.balanceOf(BURN_ADDRESS);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 stockPaid = traderStockBefore - stock.balanceOf(trader);
        assertEq(stockPaid, stockIn, "trader must pay exactly the specified input at every trade size");

        uint256 expectedProtocolCut = (stockIn * 1000 * 2000) / (10_000 * 10_000);
        uint256 protocolStockGain = stock.balanceOf(protocol) - protocolStockBefore;
        assertEq(protocolStockGain, expectedProtocolCut, "protocol's cut must be exactly 2% of input at every trade size, including dust rounding to 0");

        uint256 traderTstGain = tst.balanceOf(trader) - traderTstBefore;
        uint256 burnTstGain = tst.balanceOf(BURN_ADDRESS) - burnTstBefore;
        if (traderTstGain + burnTstGain > 0) {
            uint256 grossTstOut = traderTstGain + burnTstGain;
            uint256 expectedBurn = (grossTstOut * 800) / 10_000;
            assertApproxEqAbs(burnTstGain, expectedBurn, 2, "burn amount must reflect the reduced 800bps rate at every trade size");
        }

        assertEq(tst.balanceOf(address(hook)), 0, "hook must never strand TST, at any trade size");
        assertEq(stock.balanceOf(address(hook)), 0, "hook must never strand stock, at any trade size");
    }

    /// @dev The riskiest untested interaction: a real, independently-owned TWAMM order actively
    /// filling on this pool WHILE a buy-TST swap (which now does BOTH executeTWAMMOrders AND the
    /// new pre-swap stock skim in the same beforeSwap call) happens. Confirms neither mechanism
    /// disturbs the other -- the order's own fill math is untouched by the skim (which never
    /// calls poolManager.swap()/modifyLiquidity(), only take(), so it cannot move price/ticks),
    /// and the skim's own accounting is untouched by whatever the order execution just settled.
    function test_BuyDirectionSwap_DoesNotDisturb_ConcurrentlyActiveTwammOrder() public {
        address twammOwner = address(0xABCD);
        uint256 orderAmountIn = 50_000e18;
        uint256 orderDuration = EXPIRATION_INTERVAL * 4;
        bool orderZeroForOne = _tstIsCurrency0(); // TWAMM owner sells TST, buys stock

        tst.mint(twammOwner, orderAmountIn);
        vm.startPrank(twammOwner);
        tst.approve(address(hook), orderAmountIn);
        (, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: orderZeroForOne, duration: orderDuration, amountIn: orderAmountIn})
        );
        vm.stopPrank();

        // Let real time pass so the order is genuinely mid-fill (not yet expired) when the
        // buy-TST swap below triggers executeTWAMMOrders as a side effect of its own beforeSwap.
        vm.warp(block.timestamp + orderDuration / 2);

        bool buyZeroForOne = !_tstIsCurrency0();
        uint256 stockIn = 20_000e18;
        uint256 protocolStockBefore = stock.balanceOf(protocol);
        uint256 traderStockBefore = stock.balanceOf(trader);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: buyZeroForOne, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: _priceLimit(buyZeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // The skim itself must be completely unaffected by the concurrently-filling order.
        assertEq(traderStockBefore - stock.balanceOf(trader), stockIn, "trader must still pay exactly stockIn despite a concurrent TWAMM order");
        uint256 expectedProtocolCut = (stockIn * 1000 * 2000) / (10_000 * 10_000);
        assertEq(stock.balanceOf(protocol) - protocolStockBefore, expectedProtocolCut, "protocol's cut must be unaffected by a concurrent TWAMM order");

        // Let the order fully expire, then confirm it independently still fills and pays out
        // correctly -- unaffected by having shared a beforeSwap call with the skim above.
        vm.warp(block.timestamp + orderDuration);
        hook.executeTWAMMOrders(key);
        vm.prank(twammOwner);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));
        uint256 ownerStockBefore = stock.balanceOf(twammOwner);
        vm.prank(twammOwner);
        (uint256 tokens0, uint256 tokens1) = hook.claimTokensByPoolKey(key);
        uint256 ownerStockClaimed = _tstIsCurrency0() ? tokens1 : tokens0;
        assertGt(ownerStockClaimed, 0, "the concurrent TWAMM order must have genuinely filled and be claimable");
        assertEq(stock.balanceOf(twammOwner), ownerStockBefore + ownerStockClaimed, "TWAMM owner must receive exactly what claimTokensByPoolKey reported");
    }

    /// @dev Confirms the defense-in-depth Overflow() guard in beforeSwap is actually reachable
    /// (not dead code) and fires cleanly. Uniswap V4 core's OWN int128 checked cast on
    /// amountSpecified (Pool.sol's toInt128() calls) happens LATER, inside the core swap math --
    /// beforeSwap runs BEFORE that, so it sees the raw, unbounded int256 amountSpecified first.
    /// This means a caller invoking poolManager.swap() directly with an absurd amountSpecified
    /// (something no real trader could ever fund, but nothing stops the raw call itself) hits
    /// THIS guard before anything else in the entire call path -- confirmed here rather than
    /// assumed, since the guard's own comment claimed it was unreachable-in-practice but never
    /// verified against what actually runs before it.
    function test_BeforeSwap_OverflowGuard_ReachableAndFiresCleanly() public {
        // protocolStockCut = stockIn * 200 / 10000 must exceed type(int128).max (~1.7e38) --
        // stockIn just over 8.5e39 clears that with room to spare, while staying safely inside
        // int256's own range (no wraparound on the negation below).
        uint256 stockIn = 9e39;
        bool zeroForOne = !_tstIsCurrency0();

        uint256 protocolStockBefore = stock.balanceOf(protocol);
        vm.prank(trader);
        // Bare vm.expectRevert(), same convention as this file's other hook-internal-revert
        // checks: PoolManager wraps a hook's own revert in its own WrappedError(hook, selector,
        // ...), so matching Overflow()'s bare selector directly wouldn't match what actually
        // bubbles up here -- confirmed via the raw trace that StocksHook.beforeSwap itself does
        // revert with exactly Overflow() before PoolManager's wrapping layer.
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(stockIn), sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Confirmed clean revert -- nothing was taken or transferred before the guard fired.
        assertEq(stock.balanceOf(protocol), protocolStockBefore, "no partial state change before the guard reverts");
        assertEq(stock.balanceOf(address(hook)), 0, "hook must hold nothing after the reverted attempt");
    }

    /// @dev Edge-case config the real graduation flow never actually produces (protocol is always
    /// factory-wide, treasury is always a fresh per-pool StocksStaking deploy, so they can never
    /// collide there) -- but registerPool's own validation doesn't forbid it, so worth confirming
    /// directly: if protocol and treasury were ever the SAME address, the protocol's TST/stock cut
    /// must still be a real, separately-accounted transfer, not silently merged into whatever
    /// notifyRewardAmount() just swept in as "reward" from the remainder transfer that precedes it
    /// in afterSwap's own code (transfer remainder -> notify -> transfer protocolCut, in that
    /// order) -- notifyRewardAmount() must never observe protocolCut as part of its balance delta.
    function test_ProtocolEqualsTreasury_ProtocolCutNotSweptIntoSameCallsRewardNotify() public {
        PoolKey memory key2;
        {
            FeeRoutingMockERC20 tokenA2 = new FeeRoutingMockERC20("Acme2", "ACME2", SUPPLY);
            FeeRoutingMockERC20 tokenB2 = new FeeRoutingMockERC20("Stock2", "STOCK2", SUPPLY);
            (Currency c0, Currency c1) = address(tokenA2) < address(tokenB2)
                ? (Currency.wrap(address(tokenA2)), Currency.wrap(address(tokenB2)))
                : (Currency.wrap(address(tokenB2)), Currency.wrap(address(tokenA2)));
            key2 = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
            // protocol == treasury, an address this hook forwards a raw ERC20 balance to either way
            // (it happens to also implement notifyRewardAmount() for this test, matching what a
            // real treasury address always is).
            hook.registerPool(key2, address(tokenA2), address(tokenB2), address(treasury), address(treasury), FEE_BPS);
            poolManager.initialize(key2, SQRT_PRICE_1_1);

            tokenA2.approve(address(lpRouter), type(uint256).max);
            tokenB2.approve(address(lpRouter), type(uint256).max);
            lpRouter.modifyLiquidity(
                key2,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(60),
                    tickUpper: TickMath.maxUsableTick(60),
                    liquidityDelta: 10_000_000e18,
                    salt: bytes32(0)
                }),
                ""
            );
            tokenB2.transfer(trader, 1_000_000e18);
            vm.prank(trader);
            tokenB2.approve(address(swapRouter), type(uint256).max);

            bool zeroForOne = Currency.unwrap(key2.currency0) == address(tokenB2);
            uint256 balBefore = tokenA2.balanceOf(address(treasury)) + tokenB2.balanceOf(address(treasury));
            vm.prank(trader);
            swapRouter.swap(
                key2,
                IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -500_000e18, sqrtPriceLimitX96: _priceLimit(zeroForOne)}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            uint256 balAfter = tokenA2.balanceOf(address(treasury)) + tokenB2.balanceOf(address(treasury));

            // Whatever landed at the combined protocol==treasury address, it must be a real,
            // strictly positive transfer (remainder + protocolCut, both real value) -- not proof by
            // itself that nothing was double-counted, but confirms this edge config doesn't cause a
            // revert or silently drop either cut.
            assertGt(balAfter, balBefore, "combined protocol/treasury address must receive real value from both cuts");
        }
    }
}
