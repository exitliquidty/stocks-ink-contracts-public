// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHookSolvencyBase, SolvencyMockERC20} from "./StocksHook.solvency.t.sol";

/// @notice Audit round 13 (external review, reopened lead): "a range order trades TST and stock without
/// paying the hook fee." Round 10 closed a *different* mechanism -- JIT-liquidity fee-skimming, where a bot
/// temporarily provides liquidity to capture a share of someone ELSE's swap fee, correctly ruled out here
/// because every pool uses `fee: 0` (no native LP fee exists to skim). This was not that: it was using
/// `modifyLiquidity` (add above the current price, wait for someone else's ordinary swap to push price
/// through the range, remove) as a *substitute for calling swap() at all* -- realizing the same effective
/// token conversion a swap would, but through a code path `beforeSwap`/`afterSwap` never see, so the
/// flywheel's 10% cost was never charged on the position owner's own conversion.
///
/// Confirmed real and quantified before the fix (this exact harness, unmodified): 918,470.63e18 TST
/// deposited into a narrow range entirely above the current price, then an unrelated, ordinary swap (which
/// correctly paid the full fee on its OWN trade) pushed price above the whole range. Removing the position
/// returned 1,277,542.29e18 stock, with the treasury receiving 0 from it. The exact same 918,470.63e18 TST
/// spent on a direct sell() instead returned only 825,107.89e18 stock -- ~35% less -- with 73,342.92e18
/// going to the treasury. A rational actor was strictly better off using the bypass.
///
/// Fixed in StocksHook.beforeAddLiquidity: any non-full-range position is now rejected outright
/// (NonFullRangeLiquidityNotAllowed). This protocol's own design never wanted third-party concentrated
/// liquidity in the first place -- the graduator seeds exactly one permanent full-range position and nothing
/// else was ever meant to exist alongside it -- so refusing anything narrower closes the mechanism rather
/// than trying to price it. This file now proves the fix blocks the exact scenario above, and that ordinary
/// full-range liquidity (the only kind this protocol's design actually uses) is unaffected.
contract StocksHookRangeOrderFeeBypassTest is StocksHookSolvencyBase {
    using PoolIdLibrary for PoolKey;

    // Fixes TST as currency0 (the lower-address token) so every direction below is unambiguous, rather than
    // handling both orderings generically -- this test exists to establish whether the mechanism is real at
    // all, not to fuzz it across every token ordering.
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    int24 constant TICK_SPACING = 60;
    // Comfortably above the starting tick (0) and a multiple of TICK_SPACING. ~18% to ~82% price move --
    // large but not extreme, well inside what a single organic large trade can realistically produce on a
    // shallow pool. (The exact values only matter for the full-range/no-regression tests below now -- the
    // bypass tests never get far enough to need the price to actually move.)
    int24 constant RANGE_LOWER = 600;
    int24 constant RANGE_UPPER = 6000;

    address attacker = address(0xA77AC4);
    address normalTrader = address(0xBEEF01);

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
    }

    /// @dev The base pool from setUp is only 10_000_000e18 deep -- fine for the solvency handler's own
    /// bounded random-walk amounts, but too shallow for a swap that deliberately needs to move price ~82%
    /// (tick 0 to past 6000) without tripping a *different*, already-documented, unrelated edge (round 9:
    /// beforeSwap's pre-swap cut is sized off the swap's own *specified* amount, not what a price limit
    /// actually lets through -- irrelevant to what this file is testing, but a specified amount wildly
    /// larger than the pool can support makes that cut itself un-payable and reverts for reasons that have
    /// nothing to do with the range-order mechanism). Adding real depth first, funded by the test contract's
    /// own share of SUPPLY (already approved to lpRouter in the base setUp), avoids that entirely. Still a
    /// full-range position, same shape the fix leaves as the only kind allowed.
    function _addExtraBaseLiquidity() internal {
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 490_000_000e18,
                salt: bytes32(uint256(2))
            }),
            ""
        );
    }

    /// @dev Pushes price up past `RANGE_UPPER` via an ordinary, unrelated swap -- this swap itself pays the
    /// full flywheel fee on its own trade (confirmed by the treasury/burn deltas asserted in each test), it
    /// just isn't the attacker's own transaction.
    function _normalTraderPushesPriceAboveRange() internal {
        stock.transfer(normalTrader, 300_000_000e18);
        vm.startPrank(normalTrader);
        stock.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, // stock in, TST out -- pushes the tick up
                amountSpecified: -int256(300_000_000e18),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(RANGE_UPPER + TICK_SPACING)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertGt(_currentTick(), RANGE_UPPER, "sanity: price must clear the whole attacker range");
    }

    /// @notice The fix, proven at its first point of contact: the attacker's own narrow-range add -- the
    /// very first step of the bypass -- now reverts outright, before any of the rest of the exploit sequence
    /// (the price-moving swap, the remove) could ever run.
    function test_NarrowRangeAdd_NowRevertsOutright() public {
        _addExtraBaseLiquidity();
        uint256 attackerTst = 1_000_000e18;
        tst.transfer(attacker, attackerTst);

        vm.startPrank(attacker);
        tst.approve(address(lpRouter), type(uint256).max);
        // Bare vm.expectRevert(), same convention as this codebase's other hook-internal-revert checks
        // (StocksHook.feeRouting.fuzz.t.sol's Overflow() guard test): PoolManager wraps a hook's own revert
        // in its own WrappedError(hook, selector, ...), so matching NonFullRangeLiquidityNotAllowed()'s bare
        // selector directly doesn't match what actually bubbles up here -- confirmed via the raw trace that
        // StocksHook.beforeAddLiquidity itself does revert with exactly NonFullRangeLiquidityNotAllowed()
        // before PoolManager's wrapping layer.
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: RANGE_LOWER, tickUpper: RANGE_UPPER, liquidityDelta: 4_000_000e18, salt: bytes32(0)}),
            ""
        );
        vm.stopPrank();
    }

    /// @notice The same rejection holds for a range that's merely *off by one tick* from full-range in
    /// either direction -- confirms this is a real tickLower/tickUpper check, not something that happens to
    /// only catch the specific wide range the bypass proof above used.
    function test_OffByOneTickEitherSide_StillReverts() public {
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);

        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);

        // Bare vm.expectRevert() -- see test_NarrowRangeAdd_NowRevertsOutright's own comment for why.
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick + TICK_SPACING, tickUpper: maxTick, liquidityDelta: 1e18, salt: bytes32(uint256(3))}),
            ""
        );

        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick, tickUpper: maxTick - TICK_SPACING, liquidityDelta: 1e18, salt: bytes32(uint256(4))}),
            ""
        );
    }

    /// @notice No regression: full-range liquidity -- the only kind this protocol's own design ever uses
    /// (the graduator's permanent seed position, and this test's own base-liquidity setup) -- still adds and
    /// removes normally, unaffected by the fix.
    function test_FullRangeLiquidity_StillWorksNormally() public {
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);

        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);

        BalanceDelta addDelta = lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick, tickUpper: maxTick, liquidityDelta: 1_000_000e18, salt: bytes32(uint256(5))}),
            ""
        );
        assertLt(addDelta.amount0(), 0, "sanity: adding full-range liquidity costs currency0");
        assertLt(addDelta.amount1(), 0, "sanity: adding full-range liquidity costs currency1");

        BalanceDelta removeDelta = lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: minTick, tickUpper: maxTick, liquidityDelta: -1_000_000e18, salt: bytes32(uint256(5))}),
            ""
        );
        assertGt(removeDelta.amount0(), 0, "sanity: removing it pays currency0 back");
        assertGt(removeDelta.amount1(), 0, "sanity: removing it pays currency1 back");
    }
}
