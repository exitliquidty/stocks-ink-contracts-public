// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StocksStaking} from "../../src/StocksStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWrappedStock} from "../mocks/MockWrappedStock.sol";
import {MockHookV5} from "../mocks/MockHookV5.sol";

/// @notice V5 sibling of StockStakingGovernableHandler.sol -- same bounded-random-action pattern
/// Foundry's invariant fuzzer drives, combining ordinary staking with every governor-gated
/// treasury action, now including TWAMM order submission/claiming instead of an instant swap.
/// Uses MockHookV5 instead of a real MemeStockPair/router -- the real order-matching/pricing
/// machinery is already proven against a live PoolManager fork by
/// StocksLaunchFactory.freshfork.t.sol; this handler is about StocksStaking's OWN
/// accounting under arbitrarily long, arbitrarily interleaved random sequences.
contract StocksStakingHandler is Test {
    MockERC20 public tst;
    MockERC20 public rawStock;
    MockWrappedStock public wrapper;
    MockHookV5 public hook;
    StocksStaking public staking;
    address public governor;

    address[3] public actors = [address(0x1111), address(0x2222), address(0x3333)];

    uint256 public totalTstMinted;
    uint256 public totalStakedGhost;
    uint256 public totalClaimedGhost;

    // --- In-kind redemption ghosts --------------------------------------------------------------
    uint256 public redemptionsDone;
    uint256 public redemptionsRefusedLegitimately;
    /// @dev Bumped when a redemption changed any staker's earned rewards (must never happen).
    uint256 public earnedRewardViolations;
    /// @dev Bumped when the payout differed from the quote taken immediately before (must never happen).
    uint256 public quoteMismatches;
    /// @dev Bumped when the treasury balance did not fall by exactly payout + protocol cut (must never happen).
    uint256 public balanceDeltaMismatches;
    /// @dev Bumped when a redemption reverted with anything other than a listed, legitimate reason.
    uint256 public unexpectedRedeemReverts;
    /// @dev Bumped when a redemption lowered the redeemable-per-TST rate for the holders who stay (must never happen).
    uint256 public rateFellForRemainingHolders;

    constructor(
        MockERC20 _tst,
        MockERC20 _rawStock,
        MockWrappedStock _wrapper,
        MockHookV5 _hook,
        StocksStaking _staking,
        address _governor
    ) {
        tst = _tst;
        rawStock = _rawStock;
        wrapper = _wrapper;
        hook = _hook;
        staking = _staking;
        governor = _governor;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // --- Ordinary staking lifecycle -------------------------------------------------------------

    function stake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 1_000_000e18);

        tst.mint(who, amount);
        totalTstMinted += amount;
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        totalStakedGhost += amount;
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 balance = staking.balanceOf(who);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(who);
        staking.unstake(amount);

        totalStakedGhost -= amount;
    }

    function claim(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 pendingBefore = staking.pendingReward(who);
        if (pendingBefore == 0) return;

        vm.prank(who);
        staking.claim();

        totalClaimedGhost += pendingBefore;
    }

    // --- In-kind redemption ---------------------------------------------------------------------
    // Fresh TST is minted to the caller (so total supply is honestly tracked by the existing ghost) and part of
    // it is redeemed. Interleaved by the fuzzer with everything else: liquidations, pauses, dividends,
    // claims, stakes, time. Every property the redemption promises is checked here on every call.

    function redeem(uint256 actorSeed, uint256 amount, bool sizeable) external {
        address who = _actor(actorSeed);
        amount = sizeable ? bound(amount, 1e18, 400_000e18) : bound(amount, 1, 1e18);

        tst.mint(who, amount);
        totalTstMinted += amount;

        uint256[3] memory earnedBefore;
        for (uint256 i = 0; i < 3; i++) {
            earnedBefore[i] = staking.pendingReward(actors[i]);
        }
        (uint256 qOut, uint256 qProtocol,) = staking.quoteRedeem(amount);
        uint256 balanceBefore = wrapper.balanceOf(address(staking));
        uint256 supplyBefore = staking.nonBurnedSupply();
        uint256 redeemableBefore = staking.redeemableStock();

        vm.startPrank(who);
        tst.approve(address(staking), amount);
        try staking.redeem(amount, 0) returns (uint256 out) {
            vm.stopPrank();
            redemptionsDone++;
            for (uint256 i = 0; i < 3; i++) {
                if (staking.pendingReward(actors[i]) != earnedBefore[i]) earnedRewardViolations++;
            }
            if (out != qOut) quoteMismatches++;
            if (balanceBefore - wrapper.balanceOf(address(staking)) != out + qProtocol) balanceDeltaMismatches++;
            uint256 supplyAfter = staking.nonBurnedSupply();
            if (supplyAfter > 0) {
                // (redeemable / supply) after must be >= before, up to a rounding tolerance of a few wei
                if (staking.redeemableStock() * supplyBefore + supplyBefore * 4 < redeemableBefore * supplyAfter) {
                    rateFellForRemainingHolders++;
                }
            }
        } catch (bytes memory reason) {
            vm.stopPrank();
            bytes4 sel = bytes4(reason);
            if (
                sel == StocksStaking.NothingToRedeem.selector
            ) {
                redemptionsRefusedLegitimately++;
            } else {
                unexpectedRedeemReverts++;
            }
        }
    }

    // --- Organic treasury inflow ------------------------------------------------------------------
    // Real fee-routing (via StocksHook.afterSwap) is already proven by the fork test; this
    // simulates its net effect -- wrapper-share deposits landing on the treasury -- directly, same
    // "real ERC-4626 vault, not a test-only mint" mechanics as the original handler's donateReward.

    function donateReward(uint256 amount) external {
        amount = bound(amount, 1, 500_000e18);
        rawStock.mint(address(this), amount);
        rawStock.approve(address(wrapper), amount);
        wrapper.deposit(amount, address(staking));
        staking.notifyRewardAmount();
    }

    // --- Governor-gated treasury actions ---------------------------------------------------------

    function governorSetPaused(bool paused) external {
        vm.prank(governor);
        staking.setRewardsPaused(paused);
    }

    function governorSetDuration(uint256 durationDays) external {
        durationDays = bound(durationDays, 1, 365);
        vm.prank(governor);
        staking.setRewardsDuration(durationDays * 1 days);
    }

    function governorLiquidate(uint256 durationIntervals) external {
        if (wrapper.balanceOf(address(staking)) == 0) return;
        if (block.timestamp < staking.pendingLiquidationExpiration()) return;
        // MIN_LIQUIDATION_DURATION is 24 intervals at a 1-hour expirationInterval; bias the range to mostly
        // valid (>=24) so the fuzzer keeps exercising a successful, in-progress liquidation most of the time,
        // while still occasionally hitting the LiquidationTooShort revert path via the low end.
        durationIntervals = bound(durationIntervals, 20, 120);
        // Can still legitimately revert (NothingToLiquidate) if nothing is currently safe to
        // liquidate (everything is vested) -- that's correct behavior, not a precondition this
        // handler should try to predict and dodge in advance.
        vm.prank(governor);
        try staking.liquidateTreasury(durationIntervals) {} catch {}
    }

    // Permissionless, callable by anyone at any time -- exercises repeated partial claims
    // interleaved with everything else, not just a single claim after full expiration.
    function claimLiquidated(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try staking.claimLiquidatedTst() {} catch {}
    }

    // --- Dividends ---------------------------------------------------------------------------------

    // Simulates a real xStock dividend/rebase: mints raw asset straight to the VAULT's own address
    // (no deposit(), no new shares) -- exactly how MockWrappedStock's own docstring says a real
    // dividend raises the wrapper's exchange rate, leaving share count untouched. StocksStaking
    // deliberately does nothing with this (the dividend just rides along in the treasury's share
    // value until liquidation), so the invariants must hold with no phantom reward ever appearing.
    function simulateDividend(uint256 amount) external {
        amount = bound(amount, 1, 200_000e18);
        rawStock.mint(address(wrapper), amount);
    }

    // --- Time -------------------------------------------------------------------------------------

    function warpTime(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 40 days);
        vm.warp(block.timestamp + secondsForward);
    }
}
