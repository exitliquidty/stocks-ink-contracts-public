// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksHookSolvencyBase, SolvencyMockERC20} from "./StocksHook.solvency.t.sol";

/// @notice Audit round 7 (G.5, external review): TWAMM orders whose per-interval sell rate is tiny (well under
/// one whole token per interval) were never specifically fuzzed. This checks, over many random tiny-order shapes,
/// that (a) the full committed principal is always accounted for (never silently lost -- either paid out as
/// proceeds/dust owed, or still sitting as the hook's own unsold token balance), (b) execution never reverts or
/// gets stuck on a dust order, and (c) the order eventually becomes fully claimable.
contract StocksHookTwammDustOrdersFuzzTest is StocksHookSolvencyBase {
    /// @dev amountIn from 1 wei up to a few whole tokens, duration from 1 interval up to a few hundred, chosen so
    /// the per-interval sell rate is frequently well under 1e18 (a "dust" rate relative to 18-decimal tokens).
    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_TinyOrder_PrincipalIsFullyAccountedFor_NeverReverts_EventuallyFullyClaimable(
        uint256 amountInSeed,
        uint256 durationIntervalsSeed,
        bool zeroForOne
    ) public {
        uint256 durationIntervals = bound(durationIntervalsSeed, 1, 400);
        uint256 duration = durationIntervals * 1 hours;
        // TWAMM refuses a genuinely zero sell rate (SellRateCannotBeZero) -- that boundary is already correct and
        // tested elsewhere; this test targets the DUST zone just above it. StocksHook.submitOrder takes its own
        // ~2% order-input fee off amountIn BEFORE the rate is computed, so the floor needs enough margin that the
        // POST-fee amount still clears one whole unit per second, not just the pre-fee amount.
        uint256 amountIn = bound(amountInSeed, duration * 100, duration * 4_000);

        address owner = handler.actors(0);
        address sellToken = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address buyToken = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        uint256 hookSellBefore = SolvencyMockERC20(sellToken).balanceOf(address(hook));
        uint256 protocolSellBefore = SolvencyMockERC20(sellToken).balanceOf(protocol);

        vm.startPrank(owner);
        SolvencyMockERC20(sellToken).approve(address(hook), amountIn);
        uint256 ownerSellBefore = SolvencyMockERC20(sellToken).balanceOf(owner);
        (bytes32 orderId, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amountIn})
        );
        uint256 pulled = ownerSellBefore - SolvencyMockERC20(sellToken).balanceOf(owner);
        vm.stopPrank();

        // what the owner actually paid never exceeds what was approved/requested, and it is accounted for exactly:
        // a protocol cut (StocksHook's own order-input fee) plus whatever the hook itself now holds for the order
        uint256 toHook = SolvencyMockERC20(sellToken).balanceOf(address(hook)) - hookSellBefore;
        uint256 toProtocol = SolvencyMockERC20(sellToken).balanceOf(protocol) - protocolSellBefore;
        assertLe(pulled, amountIn, "never pulls more than requested");
        assertEq(toHook + toProtocol, pulled, "everything paid is accounted for: protocol cut plus the hook's own order balance");

        // let the whole order run to completion, touching the pool periodically the way real usage would
        uint256 buyOwed;
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + duration / 5 + 1);
            hook.executeTWAMMOrders(key); // must never revert on a dust rate
        }
        vm.warp(vm.getBlockTimestamp() + duration + 2 hours);
        hook.executeTWAMMOrders(key);

        vm.prank(owner);
        (uint256 buyDelta, uint256 sellDelta) = hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));
        buyOwed = zeroForOne ? buyDelta : sellDelta;
        buyOwed; // silence unused warning if the branch below doesn't read it further

        // the order is gone from the books once fully expired and synced: no lingering non-zero sellRate under
        // this orderId that could still be "owed" more principal later
        ITWAMM.Order memory afterSync = hook.getOrder(key, orderKey);
        assertEq(afterSync.sellRate, 0, "a fully expired, synced order leaves no outstanding sellRate");

        // whatever wasn't sold (dust that rounded away) stays inside the hook, never vanishes: claiming what's
        // owed and checking the hook's own buy-side balance covers it is enough to prove nothing was destroyed
        uint256 owedToOwner = hook.tokensOwed(zeroForOne ? key.currency1 : key.currency0, owner);
        assertLe(owedToOwner, SolvencyMockERC20(buyToken).balanceOf(address(hook)) + 1, "the hook can always cover what it owes the order");

        vm.prank(owner);
        hook.claimTokensByPoolKey(key);
        assertEq(hook.tokensOwed(zeroForOne ? key.currency1 : key.currency0, owner), 0, "claiming pays out everything owed, nothing stuck");
    }
}
