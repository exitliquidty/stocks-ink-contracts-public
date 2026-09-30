// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice A stock token that calls back into `notifyRewardAmount()` (not `redeem()` -- see
/// ReentrantStock in StocksStaking.redemption.t.sol for that variant) the moment the staking
/// contract pays stock OUT to someone. Same one-shot `_update`-hook pattern as that mock, applied
/// to a different target function.
contract ReentrantStockForNotify is MockERC20 {
    StocksStaking public target;
    bool public armed;
    bool public reenteredAndReverted;
    bool public reenteredAndSucceeded;

    constructor() MockERC20("Reentrant", "RE") {}

    function arm(StocksStaking t) external {
        target = t;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(target) && to != address(0)) {
            armed = false; // one shot
            try target.notifyRewardAmount() {
                reenteredAndSucceeded = true;
            } catch {
                reenteredAndReverted = true;
            }
        }
    }
}

/// @notice Regression test for the fix that added `nonReentrant` to
/// `StocksStaking.notifyRewardAmount()`.
///
/// Both `claim()` and `redeem()` lower `lastNotifiedBalance` by the amount they are about to pay
/// out BEFORE making that payout transfer (`lastNotifiedBalance -= reward` in claim, and
/// `_shrinkRewardsBy` inside redeem). `notifyRewardAmount()` -> `_notifyReward()` treats any gap
/// between the contract's real stock balance and `lastNotifiedBalance` as fresh reward income. A
/// stock token that calls back into the staking contract mid-payout -- before its own transfer
/// has actually reduced the staking contract's real balance -- could previously reach
/// `notifyRewardAmount()` (it carried no reentrancy guard of its own) and have `_notifyReward()`
/// see the still-unreduced real balance against the already-lowered `lastNotifiedBalance`,
/// mis-registering the about-to-leave amount as new reward. Bounded (never inflates the caller's
/// own payout) and unreachable with a standard, hook-free ERC20 stock token, but a real gap
/// against a malicious one. Fixed by simply adding `nonReentrant` to `notifyRewardAmount()`
/// itself -- OpenZeppelin's guard is one shared contract-wide lock, so `claim()`/`redeem()`
/// already being `nonReentrant` was never enough on its own to block re-entry into a *different*,
/// unguarded function.
contract StocksStakingNotifyReentrancyRegressionTest is Test {
    MockERC20 tst;
    ReentrantStockForNotify stock;
    MockHookV5 hook;
    StocksStaking staking;

    address governor = address(0x6046);
    address staker = address(0x57A6);
    address protocol = address(0xFEED);
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new ReentrantStockForNotify();
        hook = new MockHookV5(stock, tst, 1 hours, 1);
        staking = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));
        bool tstIsCurrency0 = address(tst) < address(stock);
        PoolKey memory k = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(k);
        hook.setLaunchInfo(protocol, 1_000);
        uint256 hookStash = tst.balanceOf(address(hook));
        if (hookStash > 0) {
            vm.prank(address(hook));
            tst.transfer(BURN, hookStash);
        }
    }

    function _stake(address who, uint256 amount) internal {
        tst.mint(who, amount);
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @dev The reentrant call must genuinely revert (caught by the new guard), not merely fail
    /// to find anything to register -- distinguishing "blocked" from "harmlessly a no-op".
    function test_ReentrantNotifyDuring_Claim_IsBlocked() public {
        _stake(staker, 1_000e18);
        stock.mint(address(staking), 3_000e18);
        staking.notifyRewardAmount();
        vm.warp(vm.getBlockTimestamp() + DURATION);

        uint256 rewardsAddedBefore = staking.totalRewardsAdded();

        stock.arm(staking);
        vm.prank(staker);
        staking.claim();

        assertTrue(stock.reenteredAndReverted(), "the reentrant notifyRewardAmount() call must revert");
        assertFalse(stock.reenteredAndSucceeded(), "it must never succeed");
        // No phantom reward was registered from the payout the claim itself was mid-transfer of.
        assertEq(staking.totalRewardsAdded(), rewardsAddedBefore, "no bogus reward registered during the payout");
    }

    function test_ReentrantNotifyDuring_Redeem_IsBlocked() public {
        address redeemer = address(0xBED);
        tst.mint(redeemer, 1_000_000e18);
        stock.mint(address(staking), 10_000e18);
        staking.notifyRewardAmount();

        uint256 rewardsAddedBefore = staking.totalRewardsAdded();

        stock.arm(staking);
        vm.startPrank(redeemer);
        tst.approve(address(staking), 100_000e18);
        staking.redeem(100_000e18, 0);
        vm.stopPrank();

        assertTrue(stock.reenteredAndReverted(), "the reentrant notifyRewardAmount() call must revert");
        assertFalse(stock.reenteredAndSucceeded(), "it must never succeed");
        assertEq(staking.totalRewardsAdded(), rewardsAddedBefore, "no bogus reward registered during the payout");
    }

    /// @dev The hook's own best-effort reward ping (a raw, return-value-ignored `.call`) must stay
    /// exactly as tolerant of failure as before -- this fix must not turn a merely-unlucky ping
    /// into something that reverts the swap it's attached to. Calling notifyRewardAmount() from a
    /// plain, non-reentrant context (no lock already held) must still succeed normally.
    function test_NotifyRewardAmount_StillWorksNormally_OutsideAnyReentrantContext() public {
        stock.mint(address(staking), 500e18);
        staking.notifyRewardAmount();
        assertEq(staking.totalRewardsAdded(), 500e18);
    }
}
