// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice V5 sibling of StockStakingGovernable.fuzz.t.sol. Drops the two TWAP/reserve-ratio fuzz
/// tests entirely -- that whole mechanism (MAX_LIQUIDATE_BPS, LIQUIDATE_SLIPPAGE_BPS,
/// MIN_TWAP_WINDOW) doesn't exist in this contract; TWAMM's structural sandwich-resistance is
/// already fuzz/invariant-tested upstream by its own two independent audits (see
/// src/dex/v4/twamm/vendor/TWAMM.sol's own header) and proven against a real PoolManager fork by
/// StocksLaunchFactory.freshfork.t.sol -- re-deriving that coverage here would test TWAMM's
/// pricing, not this contract's own logic. Keeps the two fuzz tests that check UNCHANGED behavior
/// (reward-duration floor, pause-cycle solvency), and adds new fuzz coverage for what actually
/// changed: liquidateTreasury's vested-floor computation and rewardRate reduction across a wide
/// range of magnitudes, staking states, and durationIntervals choices.
contract StocksStakingFuzzTest is Test {
    address governor = address(0x6046);
    address hookStub = address(0xF00D); // only used by test_Fuzz_RewardsDurationFloor, which never calls liquidateTreasury
    address alice = address(0xA11CE);

    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function _freshTst() internal returns (MockERC20) {
        return new MockERC20("Acme", "ACME");
    }

    function _freshStock() internal returns (MockERC20) {
        return new MockERC20("Tesla xStock", "TSLAx");
    }

    function _deploy(uint256 rate)
        internal
        returns (StocksStaking staking_, MockERC20 tst_, MockERC20 stock_, MockHookV5 hook_)
    {
        tst_ = _freshTst();
        stock_ = _freshStock();
        hook_ = new MockHookV5(stock_, tst_, EXPIRATION_INTERVAL, rate);
        staking_ = new StocksStaking(address(tst_), address(stock_), 30 days, governor, address(hook_), address(this));

        bool tstIsCurrency0 = address(tst_) < address(stock_);
        PoolKey memory key = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst_)) : Currency.wrap(address(stock_)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(stock_)) : Currency.wrap(address(tst_)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook_))
        });
        staking_.setPool(key);

        tst_.mint(address(hook_), 1_000_000_000_000e18);
    }

    /// @dev Fuzzes treasury size, staked/vested amounts, and durationIntervals across many orders
    /// of magnitude -- the invariant that must hold regardless of the specific numbers:
    /// liquidateTreasury never commits more than (balance - vestedButUnclaimed), and never reverts
    /// with NothingToLiquidate as long as that difference is genuinely positive.
    function testFuzz_LiquidateTreasury_CommitsExactlyBalanceMinusVestedFloor(
        uint256 treasuryBalance,
        uint256 stakeAmount,
        uint256 rewardAmount,
        uint256 warpBeforeLiquidate,
        uint256 durationIntervals
    ) public {
        treasuryBalance = bound(treasuryBalance, 1e6, 1_000_000_000_000e18);
        stakeAmount = bound(stakeAmount, 1e6, 1_000_000_000e18);
        // Kept well under treasuryBalance so there's always a genuine non-vested excess left --
        // this test is about the excess-commitment math, not the "fully vested, nothing left"
        // edge case (covered separately below).
        rewardAmount = bound(rewardAmount, 1, treasuryBalance / 4 + 1);
        warpBeforeLiquidate = bound(warpBeforeLiquidate, 0, 30 days);
        // MIN_LIQUIDATION_DURATION / a 1-hour interval = 24
        durationIntervals = bound(durationIntervals, 24, 240);

        (StocksStaking staking_, MockERC20 tst_, MockERC20 stock_,) = _deploy(1);

        tst_.mint(alice, stakeAmount);
        vm.startPrank(alice);
        tst_.approve(address(staking_), stakeAmount);
        staking_.stake(stakeAmount);
        vm.stopPrank();

        stock_.mint(address(staking_), rewardAmount);
        staking_.notifyRewardAmount();
        vm.warp(block.timestamp + warpBeforeLiquidate);

        stock_.mint(address(staking_), treasuryBalance); // true excess, on top of whatever's mid-stream

        uint256 balanceBefore = stock_.balanceOf(address(staking_));

        vm.prank(governor);
        (uint256 stockCommitted,) = staking_.liquidateTreasury(durationIntervals);

        assertGt(stockCommitted, 0, "a genuine non-vested excess must always be liquidatable");
        assertLe(stockCommitted, balanceBefore, "can never commit more than the treasury actually held");
        assertEq(
            stock_.balanceOf(address(staking_)),
            balanceBefore - stockCommitted,
            "post-liquidation balance must reflect exactly what was committed, nothing more"
        );
    }

    /// @dev The other edge: when the ENTIRE balance is genuinely vested-and-owed, liquidateTreasury
    /// must never commit more than a small, PRECISION-scale amount of dust -- NOT a hard "always
    /// reverts" expectation, which turns out not to hold in general. Even with rewardAmount rounded
    /// to an exact multiple of rewardsDuration (avoiding rewardRate's own truncation dust -- see
    /// that constant's own comment below), rewardPerToken()'s fixed-point math has a SECOND,
    /// independent floor-division layer (`(rewardPerTokenStored * totalStaked - sumBalanceTimesPaid)
    /// / PRECISION`), which can legitimately leave up to just under PRECISION (1e18) wei
    /// unrecognized as vested -- confirmed empirically via this exact fuzz test finding a real,
    /// reproducible counterexample where the naive "always reverts" version failed. That residual
    /// is real, bounded, and correctly liquidatable dust (same "accepted dust" class as
    /// StockStakingGovernable.overflow.t.sol documents elsewhere), not a floor-protection defect --
    /// this test asserts the bound holds, not that liquidation is impossible.
    function testFuzz_LiquidateTreasury_NeverCommitsMoreThanDustWhenFullyVested(uint256 stakeAmount, uint256 rewardAmount)
        public
    {
        stakeAmount = bound(stakeAmount, 1e18, 1_000_000_000e18);
        // Rounded to an EXACT multiple of rewardsDuration (30 days = 2,592,000 seconds): below
        // that floor, rewardRate = reward / rewardsDuration truncates to 0 and NOTHING ever vests
        // at all, which wouldn't exercise this test's actual point either.
        rewardAmount = bound(rewardAmount, 1e18, 1_000_000_000e18);
        uint256 rewardsDurationSeconds = 30 days;
        rewardAmount = ((rewardAmount / rewardsDurationSeconds) + 1) * rewardsDurationSeconds;

        (StocksStaking staking_, MockERC20 tst_, MockERC20 stock_,) = _deploy(1);

        tst_.mint(alice, stakeAmount);
        vm.startPrank(alice);
        tst_.approve(address(staking_), stakeAmount);
        staking_.stake(stakeAmount);
        vm.stopPrank();

        stock_.mint(address(staking_), rewardAmount);
        staking_.notifyRewardAmount();
        // Fully vest to alice alone -- warp well past the reward duration.
        vm.warp(block.timestamp + 31 days);

        // Treasury holds ~exactly the vested reward, modulo fixed-point dust -- committing more
        // than a small, PRECISION-bounded amount would mean the vested-floor protection is broken,
        // not just imprecise.
        uint256 minIntervalsHere = staking_.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        try staking_.liquidateTreasury(minIntervalsHere) returns (uint256 stockCommitted, bytes32) {
            assertLt(stockCommitted, 1e18, "liquidation committed far more than fixed-point dust while fully vested");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), StocksStaking.NothingToLiquidate.selector, "unexpected revert reason");
        }
    }

    /// @dev Same property StockStakingGovernable.fuzz.t.sol already checks -- unchanged constructor
    /// logic, confirmed to still hold on the V5 constructor (which takes `_hook` in the same
    /// position `_router` used to occupy).
    function test_Fuzz_RewardsDurationFloor(uint256 duration) public {
        duration = bound(duration, 0, 365 days);
        address c = address(_freshTst());
        address s = address(_freshStock());

        StocksStaking staking_;
        if (duration < 1 hours) {
            vm.expectRevert(StocksStaking.RewardsDurationTooShort.selector);
            staking_ = new StocksStaking(c, s, duration, governor, hookStub, address(this));
        } else {
            staking_ = new StocksStaking(c, s, duration, governor, hookStub, address(this));
            assertEq(staking_.rewardsDuration(), duration);
        }
    }

    /// @dev Same property StockStakingGovernable.fuzz.t.sol already checks, unchanged pause logic.
    function test_Fuzz_PendingRewardNeverExceedsTotalRewardsAdded(
        uint96 stakeAmount,
        uint96 rewardBeforePause,
        uint96 rewardDuringPause,
        uint32 warpBeforePause,
        uint32 warpAfterUnpause
    ) public {
        vm.assume(stakeAmount > 0 && stakeAmount < 1e30);
        vm.assume(rewardBeforePause > 0 && rewardBeforePause < 1e30);
        vm.assume(rewardDuringPause < 1e30);
        warpBeforePause = uint32(bound(warpBeforePause, 0, 60 days));
        warpAfterUnpause = uint32(bound(warpAfterUnpause, 0, 120 days));

        (StocksStaking staking_, MockERC20 tst_, MockERC20 stock_,) = _deploy(1);

        tst_.mint(alice, stakeAmount);
        vm.startPrank(alice);
        tst_.approve(address(staking_), stakeAmount);
        staking_.stake(stakeAmount);
        vm.stopPrank();

        stock_.mint(address(staking_), rewardBeforePause);
        staking_.notifyRewardAmount();

        vm.warp(block.timestamp + warpBeforePause);

        vm.prank(governor);
        staking_.setRewardsPaused(true);

        if (rewardDuringPause > 0) {
            stock_.mint(address(staking_), rewardDuringPause);
            staking_.notifyRewardAmount();
        }

        vm.prank(governor);
        staking_.setRewardsPaused(false);

        vm.warp(block.timestamp + warpAfterUnpause);

        assertLe(staking_.pendingReward(alice), staking_.totalRewardsAdded());
        assertEq(staking_.totalRewardsAdded(), uint256(rewardBeforePause) + uint256(rewardDuringPause));
    }
}
