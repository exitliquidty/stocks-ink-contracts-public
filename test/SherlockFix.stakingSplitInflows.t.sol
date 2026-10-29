// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Sherlock review, StocksStaking `_notifyReward`: the materiality check was applied to each inflow on
/// its own, so a material inflow split into immaterial pieces never restarted the period. Near the end of a
/// period those pieces were streamed over whatever time was left, and a stake that joined just before them
/// collected almost all of it.
///
/// The fix: inflows are counted cumulatively since the last period start or restart
/// (`inflowsSinceRestart`), and the period restarts once that total reaches the threshold. The threshold is
/// 1/10 of what is left to stream.
contract SherlockStakingSplitInflowsTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address honest = address(0xA11CE);
    address whale = address(0xB16);

    uint256 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new MockERC20("Stock", "STK");
        hook = new MockHookV5(stock, tst, 1 hours, 1);
        staking = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));

        bool tstIsCurrency0 = address(tst) < address(stock);
        poolKey = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(poolKey);
        tst.mint(address(hook), 1_000_000_000e18);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _stake(address who, uint256 amount) internal {
        tst.mint(who, amount);
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _inflow(uint256 amount) internal {
        stock.mint(address(staking), amount);
        staking.notifyRewardAmount();
    }

    function _leftover() internal view returns (uint256) {
        uint256 pf = staking.periodFinish();
        return _now() >= pf ? 0 : (pf - _now()) * staking.rewardRate();
    }

    /// @notice The reported scenario. One hour before the period ends a whale stakes 100x the honest stake,
    /// then 100 stock arrives in pieces that are each under 1% of what is left at that moment, the size that
    /// never restarted the period before the fix. Before the fix the whale collected about 99 of the 100 in
    /// that hour.
    function test_SplitInflowsNearPeriodEnd_RestartThePeriod_SniperGetsAlmostNothing() public {
        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(3_000e18); // a 30-day period paying 100 a day

        vm.warp(t0 + DURATION - 1 hours); // about 4.17 left to stream
        _stake(whale, 100_000e18);

        uint256 total = 100e18;
        uint256 sent;
        uint256 pieces;
        while (sent < total) {
            uint256 piece = _leftover() / 101;
            if (piece == 0) piece = 1;
            if (piece > total - sent) piece = total - sent;
            _inflow(piece);
            sent += piece;
            pieces++;
        }
        console.log("pieces sent:", pieces);

        assertGt(staking.periodFinish(), t0 + DURATION + 29 days, "the split inflow restarted the period");

        vm.warp(t0 + DURATION + 1);
        vm.prank(whale);
        staking.claim();
        console.log("whale reward for its hour, in wei (was about 99e18):", stock.balanceOf(whale));
        assertLt(stock.balanceOf(whale), 2e18, "the whale only earns an hour of a 30-day stream");
    }

    /// @notice Small inflows are added to the running period until together they reach the threshold.
    function test_SmallInflowsAccumulate_ThenRestart() public {
        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(3_000e18);
        uint256 originalFinish = staking.periodFinish();

        vm.warp(t0 + 15 days);
        uint256 piece = _leftover() / 25; // 4% of what is left

        _inflow(piece);
        assertEq(staking.periodFinish(), originalFinish, "4% alone does not restart");
        assertEq(staking.inflowsSinceRestart(), piece);

        _inflow(piece);
        assertEq(staking.periodFinish(), originalFinish, "8% in total does not restart");
        assertEq(staking.inflowsSinceRestart(), 2 * piece);

        _inflow(piece);
        assertEq(staking.periodFinish(), _now() + DURATION, "12% in total restarts");
        assertEq(staking.inflowsSinceRestart(), 0, "a restart clears the counter");
    }

    /// @notice A single inflow at or above the threshold still restarts at once, as before.
    function test_SingleMaterialInflow_StillRestarts() public {
        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(3_000e18);
        vm.warp(t0 + 15 days);
        _inflow(_leftover() / 10 + 1);
        assertEq(staking.periodFinish(), _now() + DURATION);
        assertEq(staking.inflowsSinceRestart(), 0);
    }

    /// @notice Dust still cannot push the period out: the counter only reaches the threshold when real stock
    /// worth a tenth of the stream has arrived.
    function test_DustDonations_CannotRestart() public {
        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(3_000e18);
        uint256 originalFinish = staking.periodFinish();

        vm.warp(t0 + 15 days);
        for (uint256 i; i < 50; i++) {
            _inflow(1);
        }
        assertEq(staking.periodFinish(), originalFinish);
        assertEq(staking.inflowsSinceRestart(), 50);
    }

    /// @notice A fresh period starts the count from zero.
    function test_NewPeriodAfterTheOldOneEnded_ClearsTheCounter() public {
        uint256 t0 = _now();
        _stake(honest, 1_000e18);
        _inflow(3_000e18);
        vm.warp(t0 + 15 days);
        _inflow(1e18);
        assertEq(staking.inflowsSinceRestart(), 1e18);

        vm.warp(t0 + DURATION + 1);
        _inflow(500e18);
        assertEq(staking.periodFinish(), _now() + DURATION);
        assertEq(staking.inflowsSinceRestart(), 0);
    }
}
