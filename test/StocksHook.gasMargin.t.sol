// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

/// @dev A chain of `depth` nested external calls that ends in an infinite loop (an out-of-gas), where every
/// level reverts when the level below it failed, exactly how a failing call bubbles up through
/// executeTWAMMOrders, the PoolManager and a token.
contract NestedOutOfGas {
    function go(uint256 depth) external {
        if (depth == 0) {
            while (true) {}
        }
        (bool ok,) = address(this).call(abi.encodeCall(this.go, (depth - 1)));
        if (!ok) revert("inner failed");
    }
}

/// @notice Checks the arithmetic behind StocksHook.beforeSwap's out-of-gas guard, in isolation.
///
/// beforeSwap does `gasBefore = gasleft(); try this.executeTWAMMOrders(key) {} catch { if (gasleft() <
/// gasBefore / 8) revert TwammExecutionOutOfGas(); }`. Every call level keeps 1/64 of its gas for itself
/// (EIP-150), so an out-of-gas in the k-th nested call leaves the caller with about 1 - (63/64)^k of the gas
/// it had: 1.6% at k = 1 (the execution loop itself), 3.1% at k = 2 (the swap into the PoolManager), 4.6% at
/// k = 3 (a token transfer inside that). The guard must fire (leftover below the threshold) for every level
/// that can actually occur. In this file the call chain is `probe -> go(depth) -> go(depth-1) -> ... -> go(0)`,
/// so the failing call is level `depth + 1`.
contract StocksHookGasMarginTest is Test {
    NestedOutOfGas nest;

    function setUp() public {
        nest = new NestedOutOfGas();
    }

    /// @dev Leftover gas, in parts per 10,000 of what the caller had, after an out-of-gas at level `depth + 1`.
    function _leftoverBps(uint256 depth, uint256 gasAvailable) internal returns (uint256) {
        uint256 leftoverBps;
        // Run inside a fresh call so the caller's gas is exactly `gasAvailable` at the try.
        (bool ok, bytes memory ret) =
            address(this).call{gas: gasAvailable}(abi.encodeCall(this.probe, (depth)));
        require(ok, "probe frame failed");
        leftoverBps = abi.decode(ret, (uint256));
        return leftoverBps;
    }

    function probe(uint256 depth) external returns (uint256) {
        uint256 gasBefore = gasleft();
        try nest.go(depth) {}
        catch {
            return (gasleft() * 10_000) / gasBefore;
        }
        revert("expected the nested call to fail");
    }

    /// @dev The measured leftover for levels 1 to 10 against the two candidate thresholds. A 1/32 threshold is
    /// 312 bps, a 1/8 threshold is 1,250 bps: the guard fires when leftover is BELOW the threshold.
    function test_GuardThreshold_CatchesEveryRealisticDepth() public {
        uint256 gasAvailable = 20_000_000;
        for (uint256 depth; depth < 10; ++depth) {
            uint256 leftover = _leftoverBps(depth, gasAvailable);
            bool caughtBy32 = leftover < 312;
            bool caughtBy8 = leftover < 1_250;
            console.log("level / leftover bps / caught by 1/32 / caught by 1/8:", depth + 1, leftover);
            console.log("   ", caughtBy32, caughtBy8);
            // The real path is at most three levels deep: executeTWAMMOrders, the PoolManager swap or take
            // inside it, and a token transfer inside that. The guard must hold at all of them, with room to
            // spare: it holds through level eight.
            if (depth + 1 <= 8) assertTrue(caughtBy8, "1/8 guard must fire up to eight levels deep");
        }
    }

    /// @dev The reason the threshold was widened: at level three (a token transfer inside a PoolManager call
    /// inside the execution) the old 1/32 guard would NOT fire, and at level two it was within 1% of not firing.
    function test_OldThreshold_WouldHaveMissedThreeLevels() public {
        uint256 leftover = _leftoverBps(2, 20_000_000);
        assertGt(leftover, 312, "at level three the leftover is above 1/32, so 1/32 would have let it through");
        assertLt(leftover, 1_250, "but the 1/8 guard still catches it");
    }
}
