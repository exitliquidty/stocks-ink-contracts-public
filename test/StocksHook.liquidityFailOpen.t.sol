// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksHookSolvencyBase, SolvencyMockERC20} from "./StocksHook.solvency.t.sol";

/// @notice Audit round 7 (external review, L-1): before this fix, `beforeAddLiquidity` called
/// `executeTWAMMOrders` completely unguarded (a revert there reverted the whole add-liquidity transaction), and
/// `beforeRemoveLiquidity` caught the failure but WITHOUT the `beforeSwap`'s own gas-gaming guard, reopening the
/// exact F-1(b) edge that guard was built to close (a crafted gas limit lets `try` run out of gas doing the real
/// work while the 1/64 left over still finishes the caller's action against stale TWAMM state). Both hooks now
/// share `beforeSwap`'s own gas-guarded try/catch via `_safeTwammExecute`. This mirrors `StocksHook.failOpenGas.t.sol`'s
/// methodology exactly, applied to `modifyLiquidity` instead of `swap`.
contract StocksHookLiquidityFailOpenTest is StocksHookSolvencyBase {
    using PoolIdLibrary for PoolKey;

    function _lastVirtual() internal view returns (uint256) {
        return hook.lastVirtualOrderTimestamp(key.toId());
    }

    /// @dev Submits one long order and lets the pool sit idle, so the next interaction has to catch up --
    /// identical setup to StocksHook.failOpenGas.t.sol's own `_setupIdlePool`.
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

    function _tinyAddParams() internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(uint256(1))
        });
    }

    function _addWithGas(uint256 gasLimit) internal returns (bool ok) {
        try lpRouter.modifyLiquidity{gas: gasLimit}(key, _tinyAddParams(), "") {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _removeWithGas(uint256 gasLimit) internal returns (bool ok) {
        IPoolManager.ModifyLiquidityParams memory p = _tinyAddParams();
        p.liquidityDelta = -p.liquidityDelta;
        try lpRouter.modifyLiquidity{gas: gasLimit}(key, p, "") {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _sweepAdd(uint256 target, uint256 from, uint256 to, uint256 step)
        internal
        returns (uint256 reverted, uint256 executed, uint256 skipped)
    {
        for (uint256 g = from; g <= to; g += step) {
            uint256 id = vm.snapshotState();
            bool ok = _addWithGas(g);
            if (!ok) reverted++;
            else if (_lastVirtual() < target) skipped++;
            else executed++;
            vm.revertToState(id);
        }
    }

    function _sweepRemove(uint256 target, uint256 from, uint256 to, uint256 step)
        internal
        returns (uint256 reverted, uint256 executed, uint256 skipped)
    {
        // give the position we're about to remove a real balance to remove from, once, outside the sweep
        lpRouter.modifyLiquidity(key, _tinyAddParams(), "");
        for (uint256 g = from; g <= to; g += step) {
            uint256 id = vm.snapshotState();
            bool ok = _removeWithGas(g);
            if (!ok) reverted++;
            else if (_lastVirtual() < target) skipped++;
            else executed++;
            vm.revertToState(id);
        }
    }

    /// @notice beforeAddLiquidity now fails open: no gas limit lets adding liquidity succeed WITHOUT TWAMM having
    /// executed, matching the exact property beforeSwap already proves. Before this fix there was no try/catch at
    /// all here, so an expensive catch-up would have made every add revert outright instead of failing open.
    function test_AddLiquidity_LongIdle_NoGasLimitLetsItSucceedWithoutExecutingTwamm() public {
        uint256 target = _setupIdlePool(6000, 5000);
        (uint256 reverted, uint256 executed, uint256 skipped) = _sweepAdd(target, 1_000_000, 45_000_000, 1_000_000);
        console.log("add liquidity -- reverted / executed-with-twamm / skipped-twamm:", reverted, executed, skipped);
        assertGt(executed, 0, "sanity: with enough gas, adding liquidity works and executes TWAMM");
        assertEq(skipped, 0, "no gas limit may let liquidity be added while skipping TWAMM execution");
    }

    /// @notice beforeRemoveLiquidity keeps the same "no skip" guarantee it already had, but now WITH the gas-gaming
    /// guard beforeSwap has -- closing the specific edge where a bare catch (no gas check) could let a crafted gas
    /// limit remove liquidity against stale TWAMM state.
    function test_RemoveLiquidity_LongIdle_NoGasLimitLetsItSucceedWithoutExecutingTwamm() public {
        uint256 target = _setupIdlePool(6000, 5000);
        (uint256 reverted, uint256 executed, uint256 skipped) = _sweepRemove(target, 1_000_000, 45_000_000, 1_000_000);
        console.log("remove liquidity -- reverted / executed-with-twamm / skipped-twamm:", reverted, executed, skipped);
        assertGt(executed, 0, "sanity: with enough gas, removing liquidity works and executes TWAMM");
        assertEq(skipped, 0, "no gas limit may let liquidity be removed while skipping TWAMM execution");
    }

    /// @notice The everyday case (moderate idleness) is unaffected for both add and remove: no bypass, and normal
    /// liquidity actions still work.
    function test_ModerateIdle_AddAndRemove_NoBypass_AndEverydayActionsStillWork() public {
        uint256 target = _setupIdlePool(6, 4);
        (uint256 revertedA, uint256 executedA, uint256 skippedA) = _sweepAdd(target, 200_000, 3_000_000, 50_000);
        assertGt(executedA, 0);
        assertEq(skippedA, 0);
        revertedA;

        uint256 target2 = _setupIdlePool(6, 4);
        (uint256 revertedR, uint256 executedR, uint256 skippedR) = _sweepRemove(target2, 200_000, 3_000_000, 50_000);
        assertGt(executedR, 0);
        assertEq(skippedR, 0);
        revertedR;
    }
}
