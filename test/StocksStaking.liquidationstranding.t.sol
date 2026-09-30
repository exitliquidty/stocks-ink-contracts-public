// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice AUDIT FIX regression suite for a single-slot order-reference stranding bug in
/// liquidateTreasury/claimLiquidatedTst -- pendingLiquidationExpiration is a single slot; before
/// this fix, a second liquidateTreasury call
/// (allowed once the first order's own expiration passed, per LiquidationInProgress's own
/// time-only check) could overwrite it before anyone had called claimLiquidatedTst for the first
/// order, permanently discarding the only reference to it. TWAMM's own sync() requires
/// msg.sender == orderKey.owner (always address(this) here), so once overwritten NOTHING could
/// ever recover the first order's real, already-executed liquidation proceeds -- treasury stock
/// that was correctly extracted from the pool but would never reach the burn address. Unlike the
/// sweep fix, this can't use try/catch (claimLiquidatedTst and liquidateTreasury both carry
/// nonReentrant, and calling `this.claimLiquidatedTst()` from inside an already-nonReentrant
/// liquidateTreasury would itself revert) -- instead it checks getOrder(...).sellRate != 0 (a
/// real, non-reverting lookup) before calling the internal _claimLiquidatedTst() helper directly.
contract StocksStakingLiquidationStrandingTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address staker = address(0xCAFE);

    uint256 constant DURATION = 30 days;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function setUp() public {
        tst = new MockERC20("ACME", "ACME");
        stock = new MockERC20("Tesla Stock", "TSLA");
        hook = new MockHookV5(stock, tst, EXPIRATION_INTERVAL, 1);

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

        tst.mint(staker, 1_000e18);
        vm.startPrank(staker);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();
    }

    /// @dev Reproduces the exact scenario that used to strand funds: liquidation A's order fully
    /// expires (LiquidationInProgress's own time-only check clears), but nobody ever calls
    /// claimLiquidatedTst for it before governance starts liquidation B. Confirms B's own
    /// submission auto-claims and burns A's real, already-earned proceeds first, rather than
    /// discarding them.
    function test_SecondLiquidationAfterFirstExpires_AutoClaimsFirstBeforeStartingSecond() public {
        stock.mint(address(staking), 5_000e18);
        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 committedA,) = staking.liquidateTreasury(_minLiqIntervals1);
        assertGt(committedA, 0);

        // Let order A fully expire without anyone ever calling claimLiquidatedTst.
        vm.warp(staking.pendingLiquidationExpiration() + 1);

        uint256 burnBefore = tst.balanceOf(0x000000000000000000000000000000000000dEaD);

        stock.mint(address(staking), 3_000e18);
        uint256 _minLiqIntervalsB1 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 committedB,) = staking.liquidateTreasury(_minLiqIntervalsB1); // must auto-claim + burn order A's proceeds first
        assertGt(committedB, 0);

        uint256 burnAfter = tst.balanceOf(0x000000000000000000000000000000000000dEaD);
        assertGt(burnAfter, burnBefore, "starting liquidation B must have auto-burned liquidation A's real proceeds, not discarded them");

        // Order B itself still works normally afterward.
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedFromB = staking.claimLiquidatedTst();
        assertGt(burnedFromB, 0, "second order must still work normally afterward");
    }

    /// @dev The very first liquidation ever (pendingLiquidationExpiration starts at 0, no prior
    /// order exists) must not be broken by the new pre-check -- getOrder on a never-submitted
    /// OrderKey must read as sellRate == 0 (nothing to auto-claim), not revert or misfire.
    function test_FirstLiquidationEver_StillWorksNormally() public {
        stock.mint(address(staking), 5_000e18);
        uint256 _minLiqIntervals2 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 committed,) = staking.liquidateTreasury(_minLiqIntervals2);
        assertGt(committed, 0);

        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burned = staking.claimLiquidatedTst();
        assertGt(burned, 0);
    }

    /// @dev Normal, well-behaved usage (claim before liquidating again) must keep working exactly
    /// as before -- the pre-check must correctly read the already-claimed order as sellRate == 0
    /// and skip the redundant auto-claim, never blocking or double-processing the new liquidation.
    function test_LiquidateAfterAlreadyManuallyClaimed_StillWorksNormally() public {
        stock.mint(address(staking), 5_000e18);
        uint256 _minLiqIntervals3 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        staking.liquidateTreasury(_minLiqIntervals3);

        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedManually = staking.claimLiquidatedTst();
        assertGt(burnedManually, 0);

        stock.mint(address(staking), 3_000e18);
        uint256 _minLiqIntervalsB2 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 committedB,) = staking.liquidateTreasury(_minLiqIntervalsB2); // must not misbehave despite order A already fully claimed
        assertGt(committedB, 0);
    }

    /// @dev A second liquidation while the first is STILL genuinely in progress (not yet expired)
    /// must still revert exactly as before -- the new auto-claim step doesn't weaken this existing
    /// protection, it only changes what happens once the block.timestamp check has already passed.
    function test_SecondLiquidation_StillRevertsWhileFirstStillInProgress() public {
        stock.mint(address(staking), 5_000e18);
        uint256 _minLiqIntervals4 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        staking.liquidateTreasury(_minLiqIntervals4);

        uint256 _minLiqIntervalsC = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        vm.expectRevert(StocksStaking.LiquidationInProgress.selector);
        staking.liquidateTreasury(_minLiqIntervalsC);
    }
}
