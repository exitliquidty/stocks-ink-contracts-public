// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Regression test for the notifyRewardAmount() reward-rate griefing bug: before this fix,
/// `_notifyReward()` unconditionally reset `periodFinish = block.timestamp + rewardsDuration` and
/// recomputed `rewardRate = (reward + leftover) / rewardsDuration` on every single call -- callable
/// permissionlessly (notifyRewardAmount() itself, plus stake()/unstake()/claim() all call it too).
/// Since `reward` can be as little as 1 wei of stockToken, anyone could grief the stream for
/// near-zero cost by sending dust and calling notifyRewardAmount() repeatedly: each call diluted
/// rewardRate (dividing whatever was left to pay out by the FULL duration again instead of by the
/// time actually remaining) and pushed periodFinish permanently back out to "now + full duration",
/// with no owner able to intervene (this contract is deliberately keyless). Same bug class
/// independently documented in Code4rena 2022-02-concur-findings#183 ("StakingRewards reward rate
/// can be dragged out and diluted") and Sherlock 2025-03-symm-io-stacking-judging#126/#535.
///
/// The fix: only reset periodFinish to a fresh full-duration window when the previous one has
/// actually finished. While a stream is active, fold new reward into the rate over whatever time
/// is genuinely left (`remaining = periodFinish - block.timestamp`), never touching periodFinish.
/// This makes rewardRate monotonically non-decreasing from any legitimate top-up, however small --
/// there is no longer anything to grief.
///
/// UPDATE (audit finding F-2, reward sniping): never restarting turned out to compress late-cycle inflows
/// into the short window left, letting a large stake join just after one and take almost all of it (see
/// StocksStaking.rewardsniping.regression.t.sol). The rule is now: a MATERIAL inflow (at least 1/100 of
/// what is left to stream) restarts the full period, spreading it and the leftover over a full duration;
/// an immaterial one still never moves periodFinish. Dust donations, the actual griefing vector this file
/// guards against, are immaterial by construction, so every dust test below is unchanged and still passes.
contract StocksStakingRewardGriefingTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;

    address governor = address(0x6046);
    address realStaker = address(0xCAFE);
    address attacker = address(0xBAD);

    uint256 constant DURATION = 30 days;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function setUp() public {
        tst = new MockERC20("Acme", "ACME");
        stock = new MockERC20("Tesla Stock", "TSLA");
        hook = new MockHookV5(stock, tst, EXPIRATION_INTERVAL, 1);
        staking = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));

        tst.mint(realStaker, 1_000e18);
        vm.startPrank(realStaker);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();
    }

    /// @notice The core regression: repeated dust-triggered notifyRewardAmount() calls, spread
    /// across the whole 30-day window, must never lower rewardRate below its value from the
    /// previous call, and must never move periodFinish away from its original schedule.
    function test_DustGriefing_NeverDilutesRateOrMovesPeriodFinish() public {
        // A real reward funds the first period, exactly as a real trading fee would.
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();

        uint256 originalPeriodFinish = staking.periodFinish();
        uint256 lastRate = staking.rewardRate();
        assertGt(lastRate, 0, "sanity: real reward must produce a nonzero rate");

        // Attacker repeatedly grieves with 1 wei of stockToken at different points across the
        // window -- exactly the cheapest possible version of the attack.
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 2 days);
            if (block.timestamp >= originalPeriodFinish) break;

            vm.prank(attacker);
            stock.mint(attacker, 1);
            vm.prank(attacker);
            stock.transfer(address(staking), 1);
            vm.prank(attacker);
            staking.notifyRewardAmount();

            assertGe(staking.rewardRate(), lastRate, "dust top-up must never decrease rewardRate");
            assertEq(staking.periodFinish(), originalPeriodFinish, "dust top-up must never move periodFinish");
            lastRate = staking.rewardRate();
        }

        // The real staker's reward still fully vests on the ORIGINAL schedule -- nothing was
        // dragged out, nothing was lost to griefing.
        vm.warp(originalPeriodFinish);
        assertApproxEqAbs(
            staking.pendingReward(realStaker), 1_000e18, 1e12, "full real reward must vest by the original periodFinish"
        );
    }

    /// @notice A large, legitimate top-up mid-stream (MATERIAL: at least 1/100 of what is left to stream)
    /// restarts the full period, spreading the top-up and the unstreamed leftover over a full duration. Both
    /// deposits still vest in full, by the NEW periodFinish.
    function test_MaterialTopUp_MidStream_RestartsPeriod_AndBothDepositsVestByTheNewFinish() public {
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();

        vm.warp(vm.getBlockTimestamp() + 10 days);

        // A second real trading fee lands, same size as the first.
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();

        assertEq(staking.periodFinish(), vm.getBlockTimestamp() + DURATION, "a material top-up restarts the period");

        vm.warp(staking.periodFinish());
        assertApproxEqAbs(
            staking.pendingReward(realStaker), 2_000e18, 1e12, "both real deposits must fully vest by the new periodFinish"
        );
    }

    /// @notice A top-up that is small next to what is left to stream (under 1/100) is folded into the
    /// rate over the time remaining and never moves periodFinish, exactly as before.
    function test_ImmaterialTopUp_MidStream_RaisesRateWithoutMovingPeriodFinish() public {
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();
        uint256 originalPeriodFinish = staking.periodFinish();
        uint256 rateBefore = staking.rewardRate();

        vm.warp(vm.getBlockTimestamp() + 10 days);

        stock.mint(address(staking), 1e18); // ~0.15% of the ~667 still streaming
        staking.notifyRewardAmount();

        assertGt(staking.rewardRate(), rateBefore, "a genuine top-up should raise the rate");
        assertEq(staking.periodFinish(), originalPeriodFinish, "an immaterial top-up should not move periodFinish");

        vm.warp(originalPeriodFinish);
        assertApproxEqAbs(
            staking.pendingReward(realStaker), 1_001e18, 1e12, "both deposits must fully vest by the original periodFinish"
        );
    }

    /// @notice Once a period has genuinely finished, the next notify must still correctly start a
    /// fresh full-duration window -- the fix only removes the MID-stream reset, not the legitimate
    /// one that begins a brand new period.
    function test_AfterPeriodFinish_NextNotifyStartsFreshWindow() public {
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();
        uint256 firstPeriodFinish = staking.periodFinish();

        vm.warp(firstPeriodFinish + 1 days); // let it fully lapse, with a gap of no activity

        stock.mint(address(staking), 3_000e18);
        staking.notifyRewardAmount();

        assertEq(staking.periodFinish(), block.timestamp + DURATION, "a fresh period must start a full new window");
        assertApproxEqAbs(staking.rewardRate(), 3_000e18 / DURATION, 1e6, "fresh period's rate must reflect only the new reward");
    }
}
