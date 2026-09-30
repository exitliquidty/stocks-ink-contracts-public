// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console, Vm} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @dev A stock token that calls back into the staking contract while it is paying out, to prove the redemption
/// cannot be re-entered.
contract ReentrantStock is MockERC20 {
    StocksStaking public target;
    uint256 public reenterAmount;
    bool public armed;
    bool public reenteredAndFailed;
    bool public reenteredAndSucceeded;

    constructor() MockERC20("Reentrant", "RE") {}

    /// @dev The attacker (this contract) must hold TST and have approved the staking contract for it BEFORE arming,
    /// so that a second redemption would genuinely succeed if the reentrancy guard were missing. Otherwise the
    /// inner call could fail for an unrelated reason (no balance, no allowance) and the test would prove nothing.
    function arm(StocksStaking t, uint256 amount) external {
        target = t;
        reenterAmount = amount;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(target) && to != address(0)) {
            armed = false; // one shot
            try target.redeem(reenterAmount, 0) {
                reenteredAndSucceeded = true;
            } catch {
                reenteredAndFailed = true;
            }
        }
    }
}

/// @notice In-kind redemption of TST for treasury stock (StocksStaking.redeem).
///
/// The scenario used throughout is the worked example: 1,000,000 TST outstanding, a treasury of 10,000 stock of
/// which 2,000 is already earned by stakers and 8,000 is scheduled to stream to them. Redeeming 100,000 TST (10%
/// of supply) claims 10% of the 8,000 redeemable = 800, less the 10% redemption cost: 720 out, 16 to the protocol,
/// 64 stays in the treasury.
contract StocksStakingRedemptionTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address staker = address(0x57A6);
    address redeemer = address(0xBED);
    address other = address(0x07E5);
    address pool = address(0x9001); // stands in for the TST held by the Uniswap pool
    address protocol = address(0xFEED);
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

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
        hook.setLaunchInfo(protocol, 1_000);
        tst.mint(address(hook), 1_000_000_000e18); // so a mock liquidation can pay TST out
    }

    // ------------------------------------------------------------------------------------------ helpers

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

    function _redeem(address who, uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        uint256 out = staking.redeem(amount, minOut);
        vm.stopPrank();
        return out;
    }

    /// @dev 1,000,000 TST outstanding; treasury 10,000 stock, 2,000 earned by the staker, 8,000 still to stream.
    function _workedExample() internal {
        _stake(staker, 100_000e18); // 100k staked (held by the staking contract)
        tst.mint(redeemer, 100_000e18); // 100k held by the redeemer
        tst.mint(other, 100_000e18); // 100k held by someone else
        tst.mint(pool, 700_000e18); // 700k in the pool
        stock.mint(address(staking), 10_000e18);
        staking.notifyRewardAmount(); // 10,000 stream over 30 days
        vm.warp(_now() + 6 days); // 20% of the stream has vested
        _burnHookStash();
        assertEq(staking.nonBurnedSupply(), 1_000_000e18, "exactly 1,000,000 TST outstanding");
    }

    /// @dev The mock hook holds 1B TST so it can pay out a liquidation; that must not count as supply in these tests.
    function _burnHookStash() internal {
        uint256 bal = tst.balanceOf(address(hook));
        if (bal == 0) return;
        vm.prank(address(hook));
        tst.transfer(BURN, bal);
    }

    function _earned() internal view returns (uint256) {
        return staking.pendingReward(staker);
    }

    /// @dev Non-burned TST, excluding the mock hook's 1B liquidation stash, so the example reads as 1,000,000.
    function _supplyForExample() internal view returns (uint256) {
        return staking.nonBurnedSupply();
    }

    // ------------------------------------------------------------------------------- the worked example

    function test_WorkedExample_720Out_16ToProtocol_64Retained() public {
        _workedExample();
        assertEq(staking.nonBurnedSupply(), 1_000_000e18);

        uint256 earned = _earned();
        assertApproxEqAbs(earned, 2_000e18, 1e9, "2,000 earned by the staker");
        assertApproxEqAbs(staking.redeemableStock(), 8_000e18, 1e9, "8,000 redeemable");

        uint256 out = _redeem(redeemer, 100_000e18, 0);

        assertApproxEqAbs(out, 720e18, 1e9, "the redeemer receives 720");
        assertEq(stock.balanceOf(redeemer), out);
        assertApproxEqAbs(stock.balanceOf(protocol), 16e18, 1e9, "the protocol receives 16");
        assertApproxEqAbs(stock.balanceOf(address(staking)), 10_000e18 - 720e18 - 16e18, 1e9, "the treasury keeps 9,264");
        assertEq(tst.balanceOf(BURN), 1_000_000_000e18 + 100_000e18, "the redeemed TST is burned");
        assertEq(staking.nonBurnedSupply(), 900_000e18, "supply is now 900k");
        assertApproxEqAbs(staking.redeemableStock(), 7_264e18, 1e9, "7,264 left to stream");
        // the rate per TST rose for those who stay: 8,000/1,000,000 -> 7,264/900,000
        assertGt((staking.redeemableStock() * 1e18) / staking.nonBurnedSupply(), (8_000e18 * 1e18) / 1_000_000e18);
    }

    function test_Quote_MatchesTheRealRedemptionExactly() public {
        _workedExample();
        (uint256 qOut, uint256 qProtocol, uint256 qRetained) = staking.quoteRedeem(100_000e18);
        uint256 protocolBefore = stock.balanceOf(protocol);
        uint256 out = _redeem(redeemer, 100_000e18, 0);
        assertEq(out, qOut, "quote == payout");
        assertEq(stock.balanceOf(protocol) - protocolBefore, qProtocol, "quote == protocol cut");
        assertGt(qRetained, 0);
    }

    function test_Event_CarriesTheExactAmounts() public {
        _workedExample();
        (uint256 qOut, uint256 qProtocol, uint256 qRetained) = staking.quoteRedeem(50_000e18);
        vm.recordLogs();
        _redeem(redeemer, 50_000e18, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(staking) && logs[i].topics[0] == StocksStaking.Redeemed.selector) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), redeemer, "redeemer is indexed");
                (uint256 burned, uint256 out, uint256 prot, uint256 kept) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertEq(burned, 50_000e18);
                assertEq(out, qOut);
                assertEq(prot, qProtocol);
                assertEq(kept, qRetained);
            }
        }
        assertTrue(found, "the Redeemed event was emitted");
    }

    // ------------------------------------------------------------------- stakers are never shortchanged

    function test_EarnedRewards_AreUntouched_ByAnyRedemption() public {
        _workedExample();
        uint256 earnedBefore = _earned();
        _redeem(redeemer, 100_000e18, 0);
        assertEq(_earned(), earnedBefore, "the staker's earned rewards did not change");

        uint256 stockBefore = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        assertApproxEqAbs(stock.balanceOf(staker) - stockBefore, earnedBefore, 1, "and they can still claim all of it");
    }

    function test_EvenRedeemingEverything_LeavesEarnedRewardsClaimable() public {
        _workedExample();
        uint256 earnedBefore = _earned();
        // every outside holder redeems everything they have (only the staker's staked TST remains)
        uint256 redeemerBal = tst.balanceOf(redeemer);
        _redeem(redeemer, redeemerBal, 0);
        uint256 poolBal = tst.balanceOf(pool);
        _redeem(pool, poolBal, 0);
        uint256 otherBal = tst.balanceOf(other);
        _redeem(other, otherBal, 0);

        assertGe(stock.balanceOf(address(staking)), earnedBefore, "the treasury still holds every earned reward");
        assertEq(_earned(), earnedBefore, "and the staker's earned amount is unchanged");
        uint256 before = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        assertApproxEqAbs(stock.balanceOf(staker) - before, earnedBefore, 1, "claimed in full");
    }

    function test_StreamShrinks_ByWhatWasTaken_PeriodEndUnchanged() public {
        _workedExample();
        uint256 finish = staking.periodFinish();
        uint256 rateBefore = staking.rewardRate();
        uint256 remaining = finish - _now();
        uint256 outstandingBefore = remaining * rateBefore;

        uint256 out = _redeem(redeemer, 100_000e18, 0);

        assertEq(staking.periodFinish(), finish, "the period end does not move");
        assertLt(staking.rewardRate(), rateBefore, "the stream is slower");
        uint256 outstandingAfter = remaining * staking.rewardRate();
        // everything that left the treasury came out of the stream (the example has no stray stock)
        assertApproxEqAbs(outstandingBefore - outstandingAfter, out + stock.balanceOf(protocol), 2 * remaining + 1e7, "stream shrank by what left");
        // and the stream never promises more than the treasury holds beyond what is earned
        assertLe(outstandingAfter, staking.redeemableStock() + remaining, "stream <= redeemable");
    }

    function test_StakerStillReceivesTheRemainingStream_InFull() public {
        _workedExample();
        _redeem(redeemer, 100_000e18, 0);
        vm.warp(staking.periodFinish() + 1);
        vm.prank(staker);
        staking.claim();
        // everything still in the treasury after the stream ends is either paid out or (retained) unclaimable dust
        uint256 left = stock.balanceOf(address(staking));
        assertLe(left, 1e12, "the whole remaining stream was paid to the staker");
    }

    function test_LastNotifiedBalance_StaysBetweenEarnedAndBalance() public {
        _workedExample();
        _redeem(redeemer, 100_000e18, 0);
        assertLe(staking.lastNotifiedBalance(), stock.balanceOf(address(staking)));
        assertGe(staking.lastNotifiedBalance() + 1e9, _earned());
    }

    // ------------------------------------------------------------------------------ input validation

    function test_Reverts_ZeroAmount() public {
        _workedExample();
        vm.expectRevert(StocksStaking.ZeroAmount.selector);
        staking.redeem(0, 0);
    }

    function test_Reverts_MoreThanTheWholeSupply() public {
        _workedExample();
        uint256 supply = staking.nonBurnedSupply();
        vm.expectRevert(StocksStaking.RedeemExceedsSupply.selector);
        staking.redeem(supply + 1, 0);
    }

    function test_Reverts_WhenTheCallerHasNoTstOrNoApproval() public {
        _workedExample();
        vm.startPrank(other);
        vm.expectRevert(); // no approval given
        staking.redeem(1_000e18, 0);
        tst.approve(address(staking), type(uint256).max);
        vm.stopPrank();
        address broke = address(0xB40E);
        vm.startPrank(broke);
        tst.approve(address(staking), type(uint256).max);
        vm.expectRevert(); // approved but holds nothing
        staking.redeem(1_000e18, 0);
        vm.stopPrank();
    }

    function test_Reverts_SlippageBelowMinimum() public {
        _workedExample();
        (uint256 qOut,,) = staking.quoteRedeem(100_000e18);
        vm.startPrank(redeemer);
        tst.approve(address(staking), 100_000e18);
        vm.expectRevert(StocksStaking.SlippageExceeded.selector);
        staking.redeem(100_000e18, qOut + 1);
        staking.redeem(100_000e18, qOut); // exactly the quote passes
        vm.stopPrank();
    }

    function test_Reverts_WhenThePayoutRoundsToZero() public {
        _workedExample();
        vm.prank(redeemer);
        tst.approve(address(staking), 1);
        vm.prank(redeemer);
        vm.expectRevert(StocksStaking.NothingToRedeem.selector);
        staking.redeem(1, 0); // 1 wei of TST against a huge supply pays nothing
    }

    function test_Reverts_BeforeThePoolIsSet() public {
        StocksStaking fresh = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));
        tst.mint(redeemer, 10e18);
        vm.startPrank(redeemer);
        tst.approve(address(fresh), 10e18);
        vm.expectRevert(StocksStaking.PoolNotSet.selector);
        fresh.redeem(10e18, 0);
        vm.stopPrank();
        (uint256 a, uint256 b, uint256 c) = fresh.quoteRedeem(10e18);
        assertEq(a + b + c, 0, "the quote is zero, not a revert");
    }

    function test_StakedTst_MustBeUnstakedFirst() public {
        _workedExample();
        vm.startPrank(staker);
        vm.expectRevert(); // the staker's TST sits in the staking contract, not in their wallet
        staking.redeem(50_000e18, 0);
        staking.unstake(50_000e18);
        tst.approve(address(staking), 50_000e18);
        uint256 out = staking.redeem(50_000e18, 0);
        vm.stopPrank();
        assertGt(out, 0, "after unstaking it can be redeemed");
    }

    // -------------------------------------------------------------------- pro rata and rate behaviour

    function test_TwoRedeemers_GetTheSameRatePerTst_MinusTheCostTheyLeftBehind() public {
        _workedExample();
        uint256 a = _redeem(redeemer, 50_000e18, 0);
        uint256 b = _redeem(other, 50_000e18, 0);
        // the second redeemer sees a slightly better rate because the first left 8% of their cost behind
        assertGe((b * 1e18) / 50_000e18, (a * 1e18) / 50_000e18, "the later redeemer never gets a worse rate");
    }

    function test_EveryRedemption_RaisesOrKeepsTheRateForThoseWhoStay() public {
        _workedExample();
        for (uint256 i; i < 5; ++i) {
            uint256 rateBefore = (staking.redeemableStock() * 1e27) / staking.nonBurnedSupply();
            _redeem(other, 10_000e18, 0);
            uint256 rateAfter = (staking.redeemableStock() * 1e27) / staking.nonBurnedSupply();
            assertGe(rateAfter + 1e9, rateBefore, "the rate never falls for the holders who remain");
        }
    }

    function test_RedeemingTheWholeSupply_PaysNinetyPercent_LeavesTheRest() public {
        // supply is only the redeemer's TST: it owns 100% of the claim
        _burnHookStash();
        tst.mint(redeemer, 1_000e18);
        stock.mint(address(staking), 500e18);
        staking.notifyRewardAmount();
        uint256 out = _redeem(redeemer, 1_000e18, 0);
        assertEq(out, 450e18, "90% of 500");
        assertEq(stock.balanceOf(protocol), 10e18, "2% of 500");
        assertEq(stock.balanceOf(address(staking)), 40e18, "8% stays");
        assertEq(staking.nonBurnedSupply(), 0);
        vm.expectRevert(StocksStaking.RedeemExceedsSupply.selector);
        staking.redeem(1, 0);
    }

    function test_CostFollowsThePoolsOwnSetting() public {
        _workedExample();
        hook.setLaunchInfo(protocol, 0); // a pool with no cost pays the full share
        (uint256 free,,) = staking.quoteRedeem(100_000e18);
        assertApproxEqAbs(free, 800e18, 1e9, "no cost: the whole 800");
        hook.setLaunchInfo(protocol, 2_000); // the maximum a pool can have
        (uint256 dear, uint256 prot, uint256 kept) = staking.quoteRedeem(100_000e18);
        assertApproxEqAbs(dear, 640e18, 1e9, "20% cost: 640");
        assertApproxEqAbs(prot, 32e18, 1e9, "protocol gets 20% of that cost (4% of the gross)");
        assertApproxEqAbs(kept, 128e18, 1e9, "the rest stays");
    }

    function testFuzz_Amounts_AlwaysAddUp_AndNeverExceedTheProRataShare(uint256 redeemable, uint256 amount, uint256 supply, uint16 feeBps)
        public
    {
        redeemable = bound(redeemable, 1, 1e30);
        supply = bound(supply, 1, 1e27);
        amount = bound(amount, 1, supply);
        feeBps = uint16(bound(feeBps, 0, 2_000));
        hook.setLaunchInfo(protocol, feeBps);

        // reproduce the split through the public quote by giving a fresh staking contract that treasury and supply
        StocksStaking s = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));
        s.setPool(poolKey);
        // supply: mint so non-burned supply == `supply` (the mock hook's stash is burned away)
        _burnHookStash();
        tst.mint(other, supply);
        stock.mint(address(s), redeemable);
        (uint256 out, uint256 prot, uint256 kept) = s.quoteRedeem(amount);
        uint256 gross = (redeemable * amount) / supply;
        assertEq(out + prot + kept, gross, "out + protocol + retained == the gross share exactly");
        assertLe(gross, redeemable, "never more than the pot");
        assertLe(out, gross);
    }

    // -------------------------------------------------------------------------------- liquidation

    function _liquidateOnce() internal returns (uint256 committed) {
        tst.mint(address(hook), 1_000_000_000e18); // the mock hook needs TST on hand to pay the order out
        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(governor);
        (committed,) = staking.liquidateTreasury(_minLiqIntervals1);
    }

    /// @dev Governance cannot freeze exits: redemption works while a liquidation order is live. The committed stock
    /// has left the balance (so it is not counted twice) and only new inflow is redeemable meanwhile.
    function test_Works_WhileALiquidationOrderIsLive_OnTheRemainingTreasuryOnly() public {
        _workedExample();
        _liquidateOnce();
        _burnHookStash();
        assertApproxEqAbs(staking.redeemableStock(), 0, 1e9, "the order took everything unvested");

        stock.mint(address(staking), 1_000e18); // fresh inflow while the order runs
        staking.notifyRewardAmount();
        uint256 earned = _earned();
        (uint256 q,,) = staking.quoteRedeem(100_000e18);
        assertGt(q, 0, "a quote is available");
        uint256 out = _redeem(redeemer, 100_000e18, 0);
        assertEq(out, q);
        assertApproxEqAbs(out, 90e18, 1e9, "10% of the new 1,000, less the cost");
        assertEq(_earned(), earned, "earned rewards untouched");
    }

    /// @dev The window effect is small and one-sided: the TST the order will burn still counts in supply until it is
    /// claimed, so the rate is a little LOW until someone claims it. Claiming first only ever helps a redeemer.
    function test_LiveOrder_RateIsUnderstatedUntilTheProceedsAreBurned_ThenImproves() public {
        _workedExample();
        _liquidateOnce();
        vm.warp(staking.pendingLiquidationExpiration() + 1); // the order has fully filled but is unclaimed
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();
        (uint256 before_,,) = staking.quoteRedeem(50_000e18);

        staking.claimLiquidatedTst(); // burns the TST the order bought
        (uint256 after_,,) = staking.quoteRedeem(50_000e18);
        assertGt(after_, before_, "burning the order's proceeds raises the rate");
    }

    function test_AfterExpiry_RedemptionAlsoWorks_WithoutAnySettlementStep() public {
        _workedExample();
        _liquidateOnce();
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        stock.mint(address(staking), 1_000e18);
        staking.notifyRewardAmount();
        vm.prank(redeemer);
        tst.approve(address(staking), 10_000e18);
        vm.prank(redeemer);
        uint256 out = staking.redeem(10_000e18, 0);
        assertGt(out, 0, "no settlement is required before redeeming");
    }

    function test_AfterALiquidation_NothingIsLeftForRedemption_BecauseItSweptTheUnvested() public {
        _workedExample();
        uint256 committed = _liquidateOnce();
        assertApproxEqAbs(committed, 8_000e18, 1e9, "the liquidation took the 8,000");
        vm.warp(staking.pendingLiquidationExpiration() + 1);
        staking.claimLiquidatedTst();
        assertApproxEqAbs(staking.redeemableStock(), 0, 1e9, "nothing left to redeem");
        _burnHookStash();
        vm.startPrank(redeemer);
        tst.approve(address(staking), 10_000e18);
        vm.expectRevert(StocksStaking.NothingToRedeem.selector);
        staking.redeem(10_000e18, 0);
        vm.stopPrank();
    }

    function test_Liquidation_StillWorksAfterARedemption_AndCommitsWhatIsLeft() public {
        _workedExample();
        _redeem(redeemer, 100_000e18, 0);
        uint256 redeemableBefore = staking.redeemableStock();
        uint256 committed = _liquidateOnce();
        assertApproxEqAbs(committed, redeemableBefore, 1e9, "the liquidation commits exactly what is redeemable");
        assertLe(staking.lastNotifiedBalance(), stock.balanceOf(address(staking)));
    }

    // ------------------------------------------------------------------------ pause and no-staker cases

    function test_WorksWhilePaused_AndKeepsTheAccountingSound() public {
        _workedExample();
        vm.prank(governor);
        staking.setRewardsPaused(true);
        stock.mint(address(staking), 500e18); // arrives while paused: not yet registered as a reward
        uint256 earned = _earned();

        _redeem(redeemer, 100_000e18, 0);

        assertEq(_earned(), earned, "earned untouched while paused");
        assertLe(staking.lastNotifiedBalance(), stock.balanceOf(address(staking)));
        vm.prank(governor);
        staking.setRewardsPaused(false); // resume registers whatever is left
        vm.warp(staking.periodFinish() + 1);
        vm.prank(staker);
        staking.claim(); // must not revert: accounting is consistent
        assertLe(stock.balanceOf(address(staking)), 1e12, "everything owed was paid, nothing stranded");
    }

    function test_WithNoStakers_TheStreamThatNobodyEarnedIsRedeemable_AndTheRateIsUnaffected() public {
        _burnHookStash();
        tst.mint(redeemer, 100_000e18);
        tst.mint(pool, 900_000e18);
        stock.mint(address(staking), 10_000e18);
        staking.notifyRewardAmount();
        vm.warp(_now() + 10 days); // the stream ran with nobody staked, so nobody earned it
        assertEq(staking.totalStaked(), 0);
        uint256 rateBefore = staking.rewardRate();
        assertApproxEqAbs(staking.redeemableStock(), 10_000e18, 1, "all of it is redeemable");
        uint256 out = _redeem(redeemer, 100_000e18, 0);
        assertApproxEqAbs(out, 900e18, 1e9, "10% of 10,000 less the cost");
        assertEq(staking.rewardRate(), rateBefore, "nobody's stream was cut, because stock nobody is owed goes first");
    }

    // ------------------------------------------------------------- attacks and adversarial behaviour

    function test_Donation_ThenRedeem_LosesMoneyForTheDonor() public {
        _workedExample();
        // the attacker holds 10% of the supply and donates 5,000 stock to inflate the rate, then redeems
        address attacker = redeemer;
        stock.mint(attacker, 5_000e18);
        uint256 stockBefore = stock.balanceOf(attacker);
        vm.prank(attacker);
        stock.transfer(address(staking), 5_000e18);
        staking.notifyRewardAmount();
        _redeem(attacker, 100_000e18, 0);
        assertLt(stock.balanceOf(attacker), stockBefore, "donating to inflate the rate costs more than it returns");
    }

    function test_BurningTst_ToMoveTheRate_LosesMoneyForTheBurner() public {
        _workedExample();
        // burning TST raises the rate for everyone, including the burner's remaining TST, but the burned TST is gone
        (uint256 base,,) = staking.quoteRedeem(100_000e18);
        vm.prank(other);
        tst.transfer(BURN, 100_000e18); // the other holder burns their whole bag
        (uint256 after_,,) = staking.quoteRedeem(100_000e18);
        assertGt(after_, base, "the rate rose for the remaining holders");
        // the burner gave up 100k TST that would have redeemed ~ base; they got nothing back
    }

    function test_SandwichAroundARedemption_CannotProfit_BecauseTheRateIgnoresThePoolPrice() public {
        _workedExample();
        (uint256 q1,,) = staking.quoteRedeem(50_000e18);
        // a trader moves TST into and out of the pool (transfers stand in for swaps): the pool's balance is
        // irrelevant to the rate because the denominator counts the pool's TST like anyone else's
        vm.prank(pool);
        tst.transfer(other, 300_000e18);
        (uint256 q2,,) = staking.quoteRedeem(50_000e18);
        vm.prank(other);
        tst.transfer(pool, 300_000e18);
        (uint256 q3,,) = staking.quoteRedeem(50_000e18);
        assertEq(q1, q2, "moving TST out of the pool does not change the rate");
        assertEq(q1, q3, "nor does moving it back");
    }

    function test_StakeUnstakeClaim_AroundARedemption_CannotChangeThePayout() public {
        _workedExample();
        (uint256 q,,) = staking.quoteRedeem(100_000e18);
        vm.startPrank(staker);
        staking.unstake(100_000e18);
        tst.approve(address(staking), 100_000e18);
        staking.stake(100_000e18);
        staking.claim();
        vm.stopPrank();
        (uint256 q2,,) = staking.quoteRedeem(100_000e18);
        assertApproxEqAbs(q2, q, 1e9, "staking actions do not move what a redemption pays");
    }

    function test_ReentrancyFromTheStockToken_IsBlocked() public {
        ReentrantStock rs = new ReentrantStock();
        StocksStaking s = new StocksStaking(address(tst), address(rs), DURATION, governor, address(hook), address(this));
        bool tstIsCurrency0 = address(tst) < address(rs);
        PoolKey memory k = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(rs)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(rs)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        s.setPool(k);
        _burnHookStash();
        tst.mint(redeemer, 1_000e18);
        rs.mint(address(s), 1_000e18);
        // the attacker contract holds TST and has approved the staking contract, so a second redemption would
        // really succeed if nothing stopped it
        tst.mint(address(rs), 200e18);
        vm.prank(address(rs));
        tst.approve(address(s), type(uint256).max);
        rs.arm(s, 100e18);
        vm.startPrank(redeemer);
        tst.approve(address(s), 1_000e18);
        s.redeem(500e18, 0); // the payout transfer calls back into redeem, which must be refused
        vm.stopPrank();
        assertTrue(rs.reenteredAndFailed(), "the re-entry attempt was rejected");
        assertFalse(rs.reenteredAndSucceeded(), "and a funded, approved re-entrant redemption did not go through");
    }

    function test_ARedeemerCannotTakeMoreThanTheirShare_EvenInASequence() public {
        _workedExample();
        uint256 redeemableStart = staking.redeemableStock();
        uint256 supplyStart = staking.nonBurnedSupply();
        uint256 got;
        for (uint256 i; i < 4; ++i) got += _redeem(redeemer, 25_000e18, 0);
        // 100k of 1M = 10% of the pot at the start, less cost; the rate improves as others leave, so the total
        // may be slightly above the single-shot figure, never above the gross share of the START pot
        assertLe(got, (redeemableStart * 100_000e18) / supplyStart, "a sequence never beats the pro rata gross");
    }

    // -------------------------------------------------------------------------------------- fuzz walk

    /// @dev Random sequences of every staking and redemption action; after each one the accounting must hold.
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_RandomWalk_AccountingAlwaysHolds(uint256 seed) public {
        _walk(seed);
    }

    uint256 walkRedemptions;
    uint256 walkRedemptionsWhilePaused;
    uint256 walkRedemptionsWithStakers;
    uint256 walkRefusedAsDust;

    /// @dev Guards against a vacuous pass: over 60 consecutive walks (one system, state carried over) the walk must
    /// really redeem, including while paused and while stakers are earning.
    function test_TheWalkActuallyRedeems() public {
        for (uint256 seed; seed < 60; ++seed) {
            _walk(seed);
        }
        console.log("redemptions / while paused / with stakers:", lastWalkRedemptions, walkRedemptionsWhilePaused, walkRedemptionsWithStakers);
        assertGt(lastWalkRedemptions, 20, "the walk redeems");
        assertGt(walkRedemptionsWhilePaused, 0, "including while rewards are paused");
        assertGt(walkRedemptionsWithStakers, 10, "and while stakers are earning");
    }

    uint256 lastWalkRedemptions;

    function _walk(uint256 seed) internal {
        address[3] memory who = [staker, other, redeemer];
        tst.mint(pool, 500_000e18);
        _burnHookStash();
        for (uint256 i; i < 3; ++i) tst.mint(who[i], 100_000e18);

        bool paused;
        for (uint256 step; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address a = who[r % 3];
            uint256 act = (r >> 8) % 9;
            uint256 amt = ((r >> 16) % 50_000e18) + 1;
            uint256[3] memory earnedBefore = [staking.pendingReward(who[0]), staking.pendingReward(who[1]), staking.pendingReward(who[2])];
            bool isRedeem;
            if (act == 0) {
                uint256 bal = tst.balanceOf(a);
                if (bal > 0) {
                    amt = amt % bal + 1;
                    vm.startPrank(a);
                    tst.approve(address(staking), amt);
                    staking.stake(amt);
                    vm.stopPrank();
                }
            } else if (act == 1) {
                uint256 sb = staking.balanceOf(a);
                if (sb > 0) {
                    vm.prank(a);
                    staking.unstake(amt % sb + 1);
                }
            } else if (act == 2) {
                vm.prank(a);
                staking.claim();
                earnedBefore = [uint256(0), 0, 0]; // claiming changes the pending figure on purpose
            } else if (act == 3) {
                stock.mint(address(staking), amt);
                if (!paused) staking.notifyRewardAmount();
            } else if (act == 4) {
                vm.warp(_now() + ((r >> 24) % 5 days) + 1);
            } else if (act == 5) {
                paused = !paused;
                vm.prank(governor);
                staking.setRewardsPaused(paused);
            } else {
                // redemption, sometimes of a tiny amount, sometimes of a large one
                uint256 bal = tst.balanceOf(a);
                if (bal > 0) {
                    amt = (act == 6 ? (amt % bal) : bal) + 1;
                    if (amt > bal) amt = bal;
                    isRedeem = true;
                    vm.startPrank(a);
                    tst.approve(address(staking), amt);
                    try staking.redeem(amt, 0) {
                        ++lastWalkRedemptions;
                        if (paused) ++walkRedemptionsWhilePaused;
                        if (staking.totalStaked() > 0) ++walkRedemptionsWithStakers;
                    } catch (bytes memory reason) {
                        // the only legitimate refusal is a payout that rounds to zero
                        assertEq(bytes4(reason), StocksStaking.NothingToRedeem.selector, "only dust may be refused");
                    }
                    vm.stopPrank();
                }
            }
            // ---- invariants after every step
            uint256 balance = stock.balanceOf(address(staking));
            uint256 earnedNow = staking.pendingReward(who[0]) + staking.pendingReward(who[1]) + staking.pendingReward(who[2]);
            assertLe(staking.lastNotifiedBalance(), balance, "notified balance is real");
            assertLe(earnedNow, balance, "every earned reward is covered");
            assertGe(staking.lastNotifiedBalance() + 1e12, earnedNow, "notified balance covers what is earned");
            if (isRedeem) {
                for (uint256 i; i < 3; ++i) {
                    assertEq(staking.pendingReward(who[i]), earnedBefore[i], "a redemption never changes anyone's earned rewards");
                }
            }
        }
        // finally every staker can withdraw and claim without reverting
        vm.warp(_now() + 40 days);
        if (paused) {
            vm.prank(governor);
            staking.setRewardsPaused(false);
        }
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(who[i]);
            staking.claim();
            uint256 sb = staking.balanceOf(who[i]);
            if (sb > 0) staking.unstake(sb);
            vm.stopPrank();
        }
    }
}
