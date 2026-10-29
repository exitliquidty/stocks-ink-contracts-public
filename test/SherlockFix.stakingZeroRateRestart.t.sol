// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Sherlock issue #28, StocksStaking `_notifyReward`: once `rewardRate` is 0 while `periodFinish` is
/// still ahead, `leftover` is 0 and every inflow counts as material, so a 1-wei inflow restarted the period over
/// `max(rewardsDuration, remaining)`. Repeated 1-wei inflows kept a zero-rate window alive and the next real
/// inflow vested over that window instead of the duration governance had set.
///
/// The fix: with nothing left to stream a restart uses `rewardsDuration` only. The longer-of-the-two rule still
/// applies while there is a leftover to protect.
contract SherlockStakingZeroRateRestartTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;

    address governor = address(0x6046);
    address staker = address(0xA11CE);
    address griefer = address(0xBAD);

    uint256 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new MockERC20("Stock", "STK");
        hook = new MockHookV5(stock, tst, 1 hours, 1);
        staking = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));
        bool tstIsCurrency0 = address(tst) < address(stock);
        staking.setPool(
            PoolKey({
                currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
                currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            })
        );
        tst.mint(address(hook), 1_000_000_000e18);

        tst.mint(staker, 1_000e18);
        vm.startPrank(staker);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();

        // A normal 30-day period runs and ends.
        stock.mint(address(staking), 100e18);
        staking.notifyRewardAmount();
        vm.warp(_now() + DURATION + 1);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _ping() internal {
        stock.mint(griefer, 1);
        vm.prank(griefer);
        stock.transfer(address(staking), 1);
        vm.prank(griefer);
        staking.notifyRewardAmount();
    }

    function _realInflow() internal {
        stock.mint(address(staking), 100e18);
        staking.notifyRewardAmount();
    }

    /// @dev The scenario from the issue: daily 1-wei pings hold a zero-rate window open, then governance sets a
    /// 1-day duration and a real inflow arrives. It must vest over 1 day, not over the dust-held window.
    function test_DustPingsOnZeroRatePeriod_DoNotStretchTheNextRealInflow() public {
        _ping();
        assertEq(staking.rewardRate(), 0, "a 1-wei period streams nothing");
        for (uint256 i; i < 5; ++i) {
            vm.warp(_now() + 1 days);
            _ping();
            assertEq(staking.rewardRate(), 0);
        }

        vm.prank(governor);
        staking.setRewardsDuration(1 days);
        uint256 earnedBefore = staking.pendingReward(staker);
        _realInflow();

        assertEq(staking.periodFinish() - _now(), 1 days, "a restart with nothing to protect uses rewardsDuration");

        vm.warp(_now() + 1 days);
        assertApproxEqAbs(staking.pendingReward(staker) - earnedBefore, 100e18, 1e6, "whole inflow vested in 1 day");
    }

    /// @dev Same outcome as with no pings at all (the control case from the issue).
    function test_Control_NoPings_InflowVestsOverTheConfiguredDuration() public {
        vm.warp(_now() + 5 days);
        vm.prank(governor);
        staking.setRewardsDuration(1 days);
        uint256 earnedBefore = staking.pendingReward(staker);
        _realInflow();
        assertEq(staking.periodFinish() - _now(), 1 days);
        vm.warp(_now() + 1 days);
        assertApproxEqAbs(staking.pendingReward(staker) - earnedBefore, 100e18, 1e6);
    }

    /// @dev The protection the longer-of-the-two rule exists for is untouched: with a real leftover, lowering
    /// the duration below the time left still restarts over the time left.
    function test_WithLeftover_RestartStillNeverShortensVesting() public {
        _realInflow(); // fresh 30-day period at a real rate
        vm.warp(_now() + 10 days); // 20 days left
        vm.prank(governor);
        staking.setRewardsDuration(1 days);
        _realInflow(); // material: restarts
        assertEq(staking.periodFinish() - _now(), 20 days, "leftover keeps its remaining schedule");
    }
}
