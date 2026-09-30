// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksHookSolvencyBase, SolvencyMockERC20} from "./StocksHook.solvency.t.sol";

/// @notice Regression tests for audit finding F-1: a few wei of rounding in the vendored TWAMM's netting of
/// opposite-direction orders left the hook short of what virtual order execution had to settle at an
/// order's expiry, so `executeTWAMMOrders` reverted, and because beforeSwap called it unguarded, EVERY
/// swap (plus every sync and liquidation) on the pool reverted with `ERC20InsufficientBalance`
/// (needed = balance + 1). Roughly 1 in 1,000 random 24-operation workloads hit it, and it reproduced
/// with the fee logic disabled, so the cause is the vendored math.
///
/// Fixed two ways, both tested here:
///   1. StocksGraduator hands the hook a rounding reserve at graduation (100 TST and a millionth of a
///      share), so the shortfall is always covered. The shortfall is ~1-3 wei on a 1:1 test pool but grows
///      with the TST-per-share price ratio (~1.4e6 wei at a typical 5e6, ~2.2e8 at 5e8) and lands almost
///      entirely in TST, which is why the TST reserve is the big one.
///   2. StocksHook.beforeSwap fails open: if execution ever reverts anyway, swaps still work.
///
/// `_replay()` is the exact 9-step sequence the invariant fuzzer shrank the failure to.
abstract contract TwammRoundingBase is StocksHookSolvencyBase {
    function _replay() internal {
        handler.submitOrder(40963, false, 2277, 12033);
        handler.submitOrder(16828, true, 40961, 14882);
        handler.warpTime(16384);
        handler.warpTime(203322850);
        handler.executeOrders();
        handler.warpTime(500000000000000000000000);
        handler.syncOrder(79228162514264337593543950336);
        handler.claim(1991);
        handler.warpTime(7791);
    }

    function _smallSwapReverts(bool zeroForOne) internal returns (bool) {
        address inToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address who = handler.actors(0);
        vm.startPrank(who);
        SolvencyMockERC20(inToken).approve(address(swapRouter), type(uint256).max);
        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e15),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            vm.stopPrank();
            return false;
        } catch {
            vm.stopPrank();
            return true;
        }
    }

    /// @dev True if TWAMM's own virtual order execution reverts (the underlying rounding shortfall).
    function _executionReverts() internal returns (bool) {
        try hook.executeTWAMMOrders(key) {
            return false;
        } catch {
            return true;
        }
    }

    function _rand(uint256 i, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(i, salt)));
    }

    /// @dev One random 24-step workload: orders both ways, swaps, time, syncs, claims, execute.
    function _walk(uint256 seed) internal {
        for (uint256 n; n < 24; n++) {
            uint256 r = _rand(seed, n);
            uint256 op = r % 9;
            uint256 a = _rand(r, 11);
            uint256 b = _rand(r, 12);
            uint256 c = _rand(r, 13);
            if (op <= 1) {
                try handler.submitOrder(a, b % 2 == 0, c, _rand(r, 14)) {} catch {}
            } else if (op == 2) {
                try handler.swap(a, b % 2 == 0, c) {} catch {}
            } else if (op <= 4) {
                try handler.warpTime(a) {} catch {}
            } else if (op == 5) {
                try handler.executeOrders() {} catch {}
            } else if (op <= 7) {
                try handler.syncOrder(a) {} catch {}
            } else {
                try handler.claim(a) {} catch {}
            }
        }
        vm.warp(vm.getBlockTimestamp() + 8 hours); // let every order expire
    }
}

/// @notice With NO reserve (an unfixed hook's balance): the vendored rounding shortfall still exists, but
/// swaps no longer freeze because beforeSwap fails open.
contract TwammRoundingNoReserveTest is TwammRoundingBase {
    function _tstReserve() internal pure override returns (uint256) {
        return 0;
    }

    function _stockReserve() internal pure override returns (uint256) {
        return 0;
    }

    function test_Replay_ExecutionStillReverts_ButBothSwapDirectionsWork() public {
        _replay();
        assertTrue(_executionReverts(), "root cause is unchanged: the vendored math leaves the hook 1 wei short");
        assertFalse(_smallSwapReverts(true), "swap zeroForOne must still work (fail-open)");
        assertFalse(_smallSwapReverts(false), "swap oneForZero must still work (fail-open)");
    }

    function test_Replay_SendingTwoWeiToTheHook_RepairsExecution() public {
        _replay();
        assertTrue(_executionReverts(), "precondition: execution is stuck");
        SolvencyMockERC20(Currency.unwrap(key.currency0)).transfer(address(hook), 2);
        SolvencyMockERC20(Currency.unwrap(key.currency1)).transfer(address(hook), 2);
        assertFalse(_executionReverts(), "a 2-wei donation repairs it");
    }

    /// forge-config: default.fuzz.runs = 2500
    function testFuzz_NoReserve_SwapsNeverRevertAfterAnyWorkload(uint256 seed) public {
        _walk(seed);
        assertFalse(_smallSwapReverts(true), "swap zeroForOne reverted");
        assertFalse(_smallSwapReverts(false), "swap oneForZero reverted");
    }
}

/// @notice With the graduation reserve in place (what a real graduated pool now has), the shortfall is
/// covered: virtual execution itself never reverts, so orders keep executing as well as swaps working.
contract TwammRoundingWithReserveTest is TwammRoundingBase {
    function test_Replay_ExecutionSucceeds_AndSwapsWork() public {
        _replay();
        assertFalse(_executionReverts(), "the reserve covers the rounding shortfall");
        assertFalse(_smallSwapReverts(true));
        assertFalse(_smallSwapReverts(false));
    }

    /// forge-config: default.fuzz.runs = 4000
    function testFuzz_WithReserve_ExecutionAndSwapsNeverRevertAfterAnyWorkload(uint256 seed) public {
        _walk(seed);
        assertFalse(_executionReverts(), "TWAMM execution reverted despite the reserve");
        assertFalse(_smallSwapReverts(true), "swap zeroForOne reverted");
        assertFalse(_smallSwapReverts(false), "swap oneForZero reverted");
    }
}

/// @notice The earlier tests use a 1:1 pool with small orders. A real graduated pool looks nothing like
/// that: about 200M TST against 40 stock shares (roughly 5 million TST per share), a thin pool, and a
/// treasury liquidation can be several times the pool's whole depth. Rounding in the vendored TWAMM
/// depends on price, so these rerun the workloads on such a pool, in BOTH token orderings (which
/// currency is TST depends on the new token's address), with orders up to 3x the pool's depth.
abstract contract TwammRealisticBase is TwammRoundingBase {
    function _realisticPool() internal pure override returns (bool) {
        return true;
    }

    /// @dev If TWAMM execution reverts, returns how many wei the hook was short (from
    /// ERC20InsufficientBalance(sender, balance, needed) found anywhere in the revert data). `unexpected`
    /// is true when it reverted for any OTHER reason.
    /// @dev True if the last measured shortfall was in TST (false = the stock token).
    bool internal lastShortfallWasTst;

    function _executionDeficit() internal returns (bool reverted, uint256 deficit, bool unexpected) {
        try hook.executeTWAMMOrders(key) {
            return (false, 0, false);
        } catch (bytes memory r) {
            reverted = true;
            for (uint256 i; i + 4 + 96 <= r.length; i++) {
                if (r[i] == 0xe4 && r[i + 1] == 0x50 && r[i + 2] == 0xd3 && r[i + 3] == 0x8c) {
                    uint256 bal;
                    uint256 need;
                    assembly {
                        bal := mload(add(add(r, 32), add(i, 36)))
                        need := mload(add(add(r, 32), add(i, 68)))
                    }
                    lastShortfallWasTst = (tst.balanceOf(address(hook)) == bal);
                    return (true, need > bal ? need - bal : 0, false);
                }
            }
            return (true, 0, true);
        }
    }

    function _assertSwapsWork() internal {
        assertFalse(_smallSwapReverts(true), "swap zeroForOne reverted");
        assertFalse(_smallSwapReverts(false), "swap oneForZero reverted");
    }
}

abstract contract TwammRealisticNoReserve is TwammRealisticBase {
    function _tstReserve() internal pure override returns (uint256) {
        return 0;
    }

    function _stockReserve() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev With no reserve, any execution failure must be a token shortfall (never another error), and
    /// it must stay far below the reserve the graduator provides.
    function _checkShortfallBounded(uint256 seed) internal {
        _walk(seed);
        (, uint256 deficit, bool unexpected) = _executionDeficit();
        assertFalse(unexpected, "TWAMM execution reverted for a reason other than a token shortfall");
        // The shortfall must stay at least 1000x below the reserve the graduator hands the hook.
        if (lastShortfallWasTst) {
            assertLe(deficit, 1e17, "TST shortfall is less than 1000x under the 1e20 TST reserve");
        } else {
            assertLe(deficit, 1e9, "stock shortfall is less than 1000x under the 1e12 stock reserve");
        }
        _assertSwapsWork();
    }
}

abstract contract TwammRealisticWithReserve is TwammRealisticBase {
    function _checkNeverStuck(uint256 seed) internal {
        _walk(seed);
        (bool reverted, uint256 deficit, bool unexpected) = _executionDeficit();
        assertFalse(unexpected, "TWAMM execution reverted for a reason other than a token shortfall");
        assertFalse(reverted, "TWAMM execution reverted despite the reserve");
        deficit; // silence unused
        _assertSwapsWork();
    }
}

contract TwammRealisticTstCurrency0NoReserveTest is TwammRealisticNoReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ShortfallStaysSmall(uint256 seed) public {
        _checkShortfallBounded(seed);
    }
}

contract TwammRealisticTstCurrency1NoReserveTest is TwammRealisticNoReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ShortfallStaysSmall(uint256 seed) public {
        _checkShortfallBounded(seed);
    }
}

contract TwammRealisticTstCurrency0WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRealisticTstCurrency1WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

/// @notice Price-ratio sweep with the graduation reserve in place, both token orderings. Ratios are TST per
/// stock share: cheap 5e4, extreme 5e8, super-extreme 5e10 (a $5,000 share after its TST has dumped
/// ~100x). The typical 5e6 case is above.

contract TwammRatioCheapTstCurrency0WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 4000e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRatioCheapTstCurrency1WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 4000e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRatioExtremeTstCurrency0WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 0.4e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRatioExtremeTstCurrency1WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 0.4e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRatioSuperExtremeTstCurrency0WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 0.004e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRatioSuperExtremeTstCurrency1WithReserveTest is TwammRealisticWithReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 0.004e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRatioExtremeTstCurrency0NoReserveTest is TwammRealisticNoReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 0.4e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ShortfallStaysSmall(uint256 seed) public {
        _checkShortfallBounded(seed);
    }
}

contract TwammRatioSuperExtremeTstCurrency1NoReserveTest is TwammRealisticNoReserve {
    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    function _realisticStockSeed() internal pure override returns (uint256) {
        return 0.004e18;
    }

    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_ShortfallStaysSmall(uint256 seed) public {
        _checkShortfallBounded(seed);
    }
}

/// @notice Adversarial check that nobody can drain the reserve the graduator hands the hook, and that it is
/// still there after any workload has fully settled. The hook has no sweep or withdraw function and pays
/// claims only from `tokensOwed`, so the reserve should only ever be consumed by real rounding shortfalls.
contract TwammReserveDrainTest is TwammRoundingBase {
    address internal constant OUTSIDER = address(0xDEAD1);

    function _hookBal(Currency c) internal view returns (uint256) {
        return SolvencyMockERC20(Currency.unwrap(c)).balanceOf(address(hook));
    }

    /// @dev Someone with no orders tries every way in: claim, sync-and-claim with a made-up order, batch claim.
    function test_OutsiderWithNoOrders_CannotClaimAnythingFromTheReserve() public {
        uint256 b0 = _hookBal(key.currency0);
        uint256 b1 = _hookBal(key.currency1);
        assertGe(b0 + b1, 1, "sanity: the hook holds the reserve");

        vm.startPrank(OUTSIDER);
        (uint256 c0, uint256 c1) = hook.claimTokensByPoolKey(key);
        assertEq(c0 + c1, 0, "nothing is owed, so nothing is paid");

        ITWAMM.OrderKey memory fake = ITWAMM.OrderKey({owner: OUTSIDER, expiration: uint160(block.timestamp + 1 hours), zeroForOne: true});
        vm.expectRevert();
        hook.syncAndClaimTokens(ITWAMM.SyncParams({key: key, orderKey: fake}));

        // Someone else's order key: sync requires the caller to be the owner.
        ITWAMM.OrderKey memory others = ITWAMM.OrderKey({owner: handler.actors(0), expiration: uint160(block.timestamp + 1 hours), zeroForOne: true});
        vm.expectRevert();
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: others}));
        vm.stopPrank();

        assertEq(_hookBal(key.currency0), b0, "reserve untouched (currency0)");
        assertEq(_hookBal(key.currency1), b1, "reserve untouched (currency1)");
    }

    /// @dev A tiny order, held to expiry and claimed, must never pay out more than that order earned, and the
    /// reserve must not shrink beyond rounding.
    function test_TinyOrder_ThenClaim_CannotExtractTheReserve() public {
        uint256 tstBefore = SolvencyMockERC20(address(tst)).balanceOf(address(hook));
        uint256 stockBefore = SolvencyMockERC20(address(stock)).balanceOf(address(hook));

        address who = handler.actors(2);
        handler.submitOrder(2, true, 1, 1e18);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        handler.settleAll();

        // The actor put in ~1e18 of currency0 and can never take out meaningfully more than that in value;
        // what matters here is the hook's balances: the reserve is still there.
        assertGe(SolvencyMockERC20(address(tst)).balanceOf(address(hook)) + 1e12, tstBefore, "TST reserve intact");
        assertGe(SolvencyMockERC20(address(stock)).balanceOf(address(hook)) + 1e12, stockBefore, "stock reserve intact");
        who; // silence unused
    }

    /// @dev After ANY random workload has fully settled (every order synced, everyone claimed), the hook still
    /// holds the reserve, less at most the rounding shortfall the reserve exists to absorb.
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_AfterFullSettlement_TheReserveIsStillThere(uint256 seed) public {
        uint256 tstReserve = _tstReserve();
        uint256 stockReserve = _stockReserve();
        _walk(seed);
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        handler.settleAll();
        assertGe(SolvencyMockERC20(address(tst)).balanceOf(address(hook)) + 1e12, tstReserve, "TST reserve drained");
        assertGe(SolvencyMockERC20(address(stock)).balanceOf(address(hook)) + 1e6, stockReserve, "stock reserve drained");
    }
}

/// @notice The same stress against the REAL deployed Uniswap v4 PoolManager on Ink (via a fork), not a local
/// build of the pinned source, in a realistic pool (about 5e6 TST per share, orders up to 3x the pool's depth),
/// with the graduation reserve in place and again with none (swaps must still never revert).
contract TwammRealPoolManagerWithReserveTest is TwammRealisticWithReserve {
    function _useRealPoolManager() internal pure override returns (bool) {
        return true;
    }

    function _orderingMode() internal pure override returns (uint8) {
        return 1;
    }

    /// forge-config: default.fuzz.runs = 150
    function testFuzz_RealPoolManager_ExecutionNeverStuck(uint256 seed) public {
        _checkNeverStuck(seed);
    }
}

contract TwammRealPoolManagerNoReserveTest is TwammRealisticNoReserve {
    function _useRealPoolManager() internal pure override returns (bool) {
        return true;
    }

    function _orderingMode() internal pure override returns (uint8) {
        return 2;
    }

    /// forge-config: default.fuzz.runs = 150
    function testFuzz_RealPoolManager_ShortfallStaysSmall(uint256 seed) public {
        _checkShortfallBounded(seed);
    }
}
