// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksHookSolvencyBase, SolvencyMockERC20} from "./StocksHook.solvency.t.sol";

/// @notice Adversarial check of the fail-open `try this.executeTWAMMOrders(key) {} catch {}` in
/// StocksHook.beforeSwap.
///
/// The worry: a `try` forwards only 63/64 of the remaining gas. If TWAMM's catch-up execution is EXPENSIVE
/// (a pool idle for thousands of intervals with a long order outstanding makes it loop once per idle
/// interval), an attacker could pick a gas limit that makes the execution run out of gas INSIDE the try,
/// while the 1/64 left over is still enough to finish the swap. A bare `catch {}` would swallow that
/// out-of-gas failure and let the swap complete against a stale, un-executed TWAMM state, letting the
/// attacker trade ahead of pending order flow. Before the fail-open change such a swap simply ran out of gas.
///
/// The property under test, for EVERY gas limit: if the swap succeeds, TWAMM execution really happened.
contract StocksHookFailOpenGasTest is StocksHookSolvencyBase {
    using PoolIdLibrary for PoolKey;

    function _lastVirtual() internal view returns (uint256) {
        return hook.lastVirtualOrderTimestamp(key.toId());
    }

    function _swapWithGas(address who, uint256 gasLimit) internal returns (bool ok) {
        vm.startPrank(who);
        try swapRouter.swap{gas: gasLimit}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1e15),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
    }

    /// @dev Submits one long order and lets the pool sit idle, so the next interaction has to catch up.
    function _setupIdlePool(uint256 orderHours, uint256 idleHours) internal returns (uint256 target) {
        address orderOwner = handler.actors(0);
        address sellToken = Currency.unwrap(key.currency0);
        vm.startPrank(orderOwner);
        SolvencyMockERC20(sellToken).approve(address(hook), 1e22);
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: orderHours * 1 hours, amountIn: 1e22})
        );
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + idleHours * 1 hours);
        target = (vm.getBlockTimestamp() / 1 hours) * 1 hours;
        assertLt(_lastVirtual(), target, "sanity: execution is behind");
    }

    /// @dev Counts, over a sweep of gas limits, swaps that reverted / executed TWAMM / succeeded WITHOUT
    /// executing it (the bypass).
    function _sweep(uint256 target, uint256 from, uint256 to, uint256 step)
        internal
        returns (uint256 reverted, uint256 executed, uint256 skipped)
    {
        address swapper = handler.actors(1);
        for (uint256 g = from; g <= to; g += step) {
            uint256 id = vm.snapshotState();
            bool ok = _swapWithGas(swapper, g);
            if (!ok) reverted++;
            else if (_lastVirtual() < target) skipped++;
            else executed++;
            vm.revertToState(id);
        }
    }

    /// @dev A 6,000-hour order, then 5,000 hours of idleness: the next interaction has to loop through
    /// about 5,000 intervals. Sweeps gas limits from 1M to 45M.
    function test_LongIdle_NoGasLimitLetsASwapSucceedWithoutExecutingTwamm() public {
        uint256 target = _setupIdlePool(6000, 5000);
        (uint256 reverted, uint256 executed, uint256 skipped) = _sweep(target, 1_000_000, 45_000_000, 1_000_000);
        console.log("swap reverted (needs more gas):", reverted);
        console.log("swap succeeded AND TWAMM executed:", executed);
        console.log("swap succeeded WITHOUT executing TWAMM (before the fix: 20):", skipped);
        assertGt(executed, 0, "sanity: with enough gas the swap works and executes TWAMM");
        assertEq(skipped, 0, "no gas limit may let a swap complete while skipping TWAMM execution");
    }

    /// @dev A real attacker searches in fine steps right at the boundary between "runs out of gas inside the
    /// try" and "has enough gas". The coarse sweep puts that boundary between 25M and 26M, so this sweeps
    /// 24.8M to 25.8M in 40k steps (kept narrow so the whole test fits inside Foundry's default gas limit).
    function test_LongIdle_FineSweepAroundTheBoundary() public {
        uint256 target = _setupIdlePool(6000, 5000);
        (uint256 reverted, uint256 executed, uint256 skipped) = _sweep(target, 24_800_000, 25_800_000, 40_000);
        console.log("fine sweep: reverted / executed / skipped:", reverted, executed, skipped);
        assertEq(skipped, 0, "no gas limit, at any granularity, lets a swap skip TWAMM execution");
    }

    /// @dev Moderate idleness (a few hours behind, a short order): the everyday case must be unaffected, and
    /// also bypass-free.
    function test_ModerateIdle_NoBypass_AndEverydaySwapsStillWork() public {
        uint256 target = _setupIdlePool(6, 4);
        (uint256 reverted, uint256 executed, uint256 skipped) = _sweep(target, 200_000, 3_000_000, 50_000);
        console.log("moderate idle: reverted / executed / skipped:", reverted, executed, skipped);
        assertGt(executed, 0);
        assertEq(skipped, 0);
    }

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_AnyGasLimit_SwapSucceedsOnlyIfTwammExecuted(uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 200_000, 60_000_000);
        uint256 target = _setupIdlePool(6000, 5000);
        if (_swapWithGas(handler.actors(1), gasLimit)) {
            assertGe(_lastVirtual(), target, "a swap succeeded while TWAMM execution was skipped");
        }
    }
}
