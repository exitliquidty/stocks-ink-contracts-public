// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice V5 sibling of StockStakingGovernable.poc.t.sol -- same PoC (does a last-second whale
/// stake let anyone grief a passed liquidateTreasury vote by inflating the protection floor, with
/// no real economic loss to the attacker?), against the TWAMM-order-submitting rewrite instead of
/// the old instant-capped-swap version. The vested-floor computation itself is byte-identical
/// between the two contracts -- this confirms that carried over correctly, not that it changed.
/// Uses MockHookV5 (see its own docstring) rather than a real PoolManager/TWAMM, since the real
/// order-matching/pricing machinery is already proven against a live fork by
/// StocksLaunchFactory.freshfork.t.sol -- this file is about StocksStaking's OWN
/// accounting in isolation.
contract StocksStakingPocTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address lp = address(0xABCD);
    address realStaker = address(0xCAFE);
    address attacker = address(0xBAD);

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

        // MockHookV5 needs a real tst balance to pay out claims against.
        tst.mint(address(hook), 1_000_000_000e18);
        // lp is unused directly (no real pool here) but documents the mock's real-pool analogue.
        lp;

        // A real staker earns a real, small, genuinely vested-and-unclaimed reward.
        tst.mint(realStaker, 1_000e18);
        vm.startPrank(realStaker);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();

        stock.mint(address(staking), 10e18);
        staking.notifyRewardAmount(); // reward = 10e18 over 30 days
        vm.warp(block.timestamp + DURATION); // fully vests to realStaker alone

        // Treasury also holds a large TRUE-EXCESS balance, never promised to anyone.
        stock.mint(address(staking), 5_000e18);
    }

    function test_PoC_FlashStakeDoesNotInflateFloor_LiquidationStillSucceeds() public {
        uint256 vestedReward = staking.pendingReward(realStaker);
        console.log("realStaker's genuinely vested reward:", vestedReward);
        assertApproxEqAbs(vestedReward, 10e18, 1e12, "sanity: ~10e18 should be vested");

        uint256 balanceBefore = stock.balanceOf(address(staking));
        console.log("treasury stockToken balance:", balanceBefore);

        // Attacker mints/acquires a huge amount of tstToken (freely mintable/tradeable) and
        // stakes it in the block immediately before the governor's liquidateTreasury call executes.
        uint256 attackerStake = 1_000_000_000e18;
        tst.mint(attacker, attackerStake);
        vm.startPrank(attacker);
        tst.approve(address(staking), attackerStake);
        staking.stake(attackerStake);
        vm.stopPrank();

        uint256 correctedFloor = (staking.rewardPerTokenStored() * staking.totalStaked() - staking.sumBalanceTimesPaid())
            / 1e18 + staking.frozenRewardsTotal();
        console.log("protection floor AFTER flash-stake (corrected):", correctedFloor);
        assertApproxEqAbs(correctedFloor, vestedReward, 1e12, "flash-stake must not inflate the protection floor");

        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 stockCommitted,) = staking.liquidateTreasury(_minLiqIntervals1);
        console.log("liquidateTreasury SUCCEEDED despite flash-stake, committed:", stockCommitted);
        assertGt(stockCommitted, 0, "legitimate liquidation must not be blockable by a costless flash-stake");
        assertApproxEqAbs(stockCommitted, balanceBefore - vestedReward, 1e12, "should commit exactly the non-vested excess");

        // Attacker's flash-stake is still fully recoverable (no loss beyond gas).
        vm.prank(attacker);
        staking.unstake(attackerStake);
        assertEq(tst.balanceOf(attacker), attackerStake, "attacker recovered their full stake");

        // realStaker's genuine reward must still be fully intact and claimable.
        assertApproxEqAbs(staking.pendingReward(realStaker), vestedReward, 1e12, "real staker's reward must be untouched");

        // And the order itself actually pays out and burns correctly once it completes.
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 burnedBefore = tst.balanceOf(0x000000000000000000000000000000000000dEaD);
        uint256 tstBurned = staking.claimLiquidatedTst();
        uint256 burnedAfter = tst.balanceOf(0x000000000000000000000000000000000000dEaD);
        assertGt(tstBurned, 0, "claimLiquidatedTst should have burned something");
        assertEq(burnedAfter - burnedBefore, tstBurned, "burn address should receive exactly what was claimed");
    }

    /// @notice A second liquidateTreasury call must revert while the first order is still running,
    /// purely on elapsed time -- not on whether anyone has claimed the first order yet.
    function test_SecondLiquidation_BlockedUntilFirstOrderExpires() public {
        uint256 _minLiqIntervals2 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        staking.liquidateTreasury(_minLiqIntervals2);

        uint256 _minLiqIntervalsD1 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        vm.expectRevert(StocksStaking.LiquidationInProgress.selector);
        staking.liquidateTreasury(_minLiqIntervalsD1);

        // Still blocked one second before expiration...
        vm.warp(staking.pendingLiquidationExpiration() - 1);
        uint256 _minLiqIntervalsD2 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        vm.expectRevert(StocksStaking.LiquidationInProgress.selector);
        staking.liquidateTreasury(_minLiqIntervalsD2);

        // ...but allowed the instant it expires, with nobody having claimed the first order at all.
        vm.warp(staking.pendingLiquidationExpiration());
        stock.mint(address(staking), 1_000e18); // give it something fresh to liquidate again
        uint256 _minLiqIntervals3 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 stockCommitted,) = staking.liquidateTreasury(_minLiqIntervals3);
        assertGt(stockCommitted, 0, "liquidation should succeed once the prior order's duration has fully elapsed");
    }

    /// @notice claimLiquidatedTst is permissionless and repeatable mid-order -- confirms partial
    /// fills burn correctly rather than requiring the caller to wait for full expiration.
    function test_ClaimLiquidatedTst_PartialFillMidOrder() public {
        uint256 _minLiqIntervals4 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 stockCommitted,) = staking.liquidateTreasury(_minLiqIntervals4);

        uint256 duration = staking.pendingLiquidationExpiration() - block.timestamp;
        vm.warp(block.timestamp + duration / 2);

        address rando = makeAddr("rando");
        vm.prank(rando); // permissionless: not the governor, not a staker
        uint256 tstBurnedPartial = staking.claimLiquidatedTst();
        assertGt(tstBurnedPartial, 0, "partial claim should have released something");
        assertApproxEqRel(tstBurnedPartial, stockCommitted / 2, 0.01e18, "roughly half should have vested at the midpoint");

        vm.warp(staking.pendingLiquidationExpiration() + 1);
        uint256 tstBurnedRest = staking.claimLiquidatedTst();
        assertGt(tstBurnedRest, 0, "final claim should have released the remainder");
    }
}
