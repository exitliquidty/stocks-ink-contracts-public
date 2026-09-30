// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Regression test for MIN_LIQUIDATION_INTERVALS: liquidateTreasury's minimum-duration
/// check used to be purely wall-clock (duration = interval * durationIntervals >= 1 day), which
/// only actually bounds the interval-boundary front-load defect to "about 1/24" *because* every
/// deployment so far uses a 1-hour expirationInterval, making the 1-day wall-clock floor happen
/// to equal 24 intervals. Nothing enforced that relationship: DeployFactoryV12 only caps
/// expirationInterval at 30 days, with no floor tying it to this contract's own minimum. A
/// generation deployed with a large expirationInterval (here: 1 day, well within the deploy
/// script's allowed range) could satisfy the wall-clock floor with durationIntervals = 1 -- a
/// single slice, zero gradual-selling protection, silently reopening the exact defect
/// MIN_LIQUIDATION_DURATION was built to bound.
///
/// Every other liquidation test in this codebase uses the standard 1-hour expirationInterval, so
/// this file exists specifically to exercise the case they don't: a deployment where the two
/// floors (wall-clock and interval-count) actually diverge.
contract StocksStakingMinLiquidationIntervalsRegressionTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address protocol = address(0xFEED);
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 constant DURATION = 30 days;
    // Deliberately large -- still well inside DeployFactoryV12's own <= 30 days cap, so this is a
    // realistic deploy-time choice, not a contrived out-of-range value.
    uint256 constant LARGE_EXPIRATION_INTERVAL = 1 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new MockERC20("Stock", "STK");
        hook = new MockHookV5(stock, tst, LARGE_EXPIRATION_INTERVAL, 1);
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
        hook.setLaunchInfo(protocol, 1_000);
        stock.mint(address(staking), 10_000e18);
    }

    /// @dev Under the old, wall-clock-only check this would have PASSED: duration = 1 interval *
    /// 1 day = 1 day, which is not less than MIN_LIQUIDATION_DURATION (1 day). It must now revert,
    /// because a single interval provides zero gradual-selling protection regardless of how long
    /// that one interval happens to be.
    function test_OneIntervalAtALargeExpirationInterval_StillRevertsAsTooShort() public {
        vm.prank(governor);
        vm.expectRevert(StocksStaking.LiquidationTooShort.selector);
        staking.liquidateTreasury(1);
    }

    /// @dev Confirms the fix isn't just rejecting everything at this interval size: the real
    /// minimum (24 intervals) still succeeds, now genuinely spanning 24 days of gradual selling
    /// rather than the single day the old check alone would have permitted.
    function test_TheRealMinimumIntervalCount_StillSucceeds() public {
        // Materialized before vm.prank, not inline in liquidateTreasury's own argument list -- a
        // nested view call there would consume the prank before liquidateTreasury itself runs.
        uint256 minIntervals = staking.MIN_LIQUIDATION_INTERVALS();
        vm.prank(governor);
        (uint256 stockCommitted,) = staking.liquidateTreasury(minIntervals);
        assertGt(stockCommitted, 0, "the order was actually submitted");
    }

    /// @dev The boundary one below the real minimum must still fail, same reasoning as the
    /// single-interval case above.
    function test_OneIntervalBelowTheMinimum_StillReverts() public {
        uint256 belowMin = staking.MIN_LIQUIDATION_INTERVALS() - 1;
        vm.prank(governor);
        vm.expectRevert(StocksStaking.LiquidationTooShort.selector);
        staking.liquidateTreasury(belowMin);
    }

    /// @dev Sanity check against the standard 1-hour deployment config (every other liquidation
    /// test in this codebase): the fix must be a genuine no-op there, since 24 intervals * 1 hour
    /// already equals exactly the pre-existing 1-day wall-clock floor.
    function test_AtTheStandardOneHourInterval_TheFixChangesNothing() public {
        MockHookV5 standardHook = new MockHookV5(stock, tst, 1 hours, 1);
        StocksStaking standardStaking =
            new StocksStaking(address(tst), address(stock), DURATION, governor, address(standardHook), address(this));
        bool tstIsCurrency0 = address(tst) < address(stock);
        PoolKey memory k = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(standardHook))
        });
        standardStaking.setPool(k);
        standardHook.setLaunchInfo(protocol, 1_000);
        stock.mint(address(standardStaking), 10_000e18);

        // 23 intervals (< 24) must still revert -- unchanged from before this fix.
        vm.prank(governor);
        vm.expectRevert(StocksStaking.LiquidationTooShort.selector);
        standardStaking.liquidateTreasury(23);

        // 24 intervals (the pre-existing 1-day floor) must still succeed -- unchanged from before.
        vm.prank(governor);
        (uint256 stockCommitted,) = standardStaking.liquidateTreasury(24);
        assertGt(stockCommitted, 0);
    }
}
