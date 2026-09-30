// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice The three situations that matter most for redemption, end to end on the REAL production stack (real
/// factory, hook, TWAMM, staking, governor, and a real Uniswap v4 PoolManager):
///   1. stakers are actively earning while someone redeems,
///   2. a governance proposal to liquidate the treasury is waiting to be executed while someone redeems,
///   3. a real TWAMM liquidation order is live (or has expired and is not yet settled) while someone redeems.
contract StocksRedemptionScenariosTest is StocksRedemptionAdversarialTest {
    // ------------------------------------------------------------------------------------------ helpers

    function _sellTst(address who, uint256 amountIn) internal {
        vm.startPrank(who);
        tst.approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tstIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev The holder delegates, proposes to liquidate the treasury over 24 hours, and the vote passes. Returns what is
    /// needed to execute it later.
    function _passLiquidationProposal()
        internal
        returns (StocksGovernor gov, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descHash)
    {
        gov = StocksGovernor(payable(curve.governor()));
        vm.prank(holder);
        TSTToken(address(tst)).delegate(holder);
        vm.warp(_now() + 1);

        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(staking);
        calldatas[0] = abi.encodeCall(StocksStaking.liquidateTreasury, (24));
        string memory description = "Liquidate the treasury over 24 hours";
        descHash = keccak256(bytes(description));

        vm.prank(holder);
        uint256 id = gov.propose(targets, values, calldatas, description);
        vm.warp(_now() + gov.votingDelay() + 1);
        vm.prank(holder);
        gov.castVote(id, 1);
        vm.warp(_now() + gov.votingPeriod() + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded), "the proposal passed");
    }

    // ------------------------------------------------------- 1. staking is going on while someone redeems

    /// @dev Stakers are mid-stream. A holder redeems. Compared against an identical world where nobody redeemed, the
    /// stakers keep everything already earned, and lose only the stock that left the treasury from the stream still
    /// to come; the treasury pays out every last unit it owes.
    function test_Staking_Active_RedeemMidStream_StakersLoseOnlyWhatLeft() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(2_000e18);
        vm.warp(_now() + 5 days);
        uint256 earnedBefore = staking.pendingReward(staker);
        assertGt(earnedBefore, 0, "the staker has earned something");

        uint256 snap = vm.snapshotState();

        // world A: someone redeems half of what they hold, mid-stream
        uint256 amt = tst.balanceOf(holder) / 2;
        (uint256 qOut, uint256 qProtocol,) = staking.quoteRedeem(amt);
        _redeem(holder, amt);
        assertEq(staking.pendingReward(staker), earnedBefore, "what the staker had earned did not change");
        vm.warp(staking.periodFinish() + 1);
        uint256 stockBeforeA = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        uint256 totalA = stock.balanceOf(staker) - stockBeforeA;
        uint256 leftoverA = stock.balanceOf(address(staking));

        vm.revertToState(snap);

        // world B: nobody redeems
        vm.warp(staking.periodFinish() + 1);
        uint256 stockBeforeB = stock.balanceOf(staker);
        vm.prank(staker);
        staking.claim();
        uint256 totalB = stock.balanceOf(staker) - stockBeforeB;

        assertLe(totalA, totalB, "a redemption never increases what stakers receive");
        assertApproxEqAbs(totalB - totalA, qOut + qProtocol, 1e13, "stakers lose exactly the stock that left the treasury");
        assertLe(leftoverA, 1e13, "and the treasury paid out everything it owed, nothing stranded");
    }

    /// @dev A staker who also redeems: unstake first, then redeem; their remaining stake keeps earning.
    function test_Staking_TheStakerCanUnstakeSomeAndRedeemIt_WhileTheRestKeepsEarning() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(1_000e18);
        vm.warp(_now() + 3 days);
        uint256 staked = staking.balanceOf(staker);
        vm.prank(staker);
        staking.unstake(staked / 2);
        uint256 earnedBefore = staking.pendingReward(staker);
        _redeem(staker, staked / 2);
        assertEq(staking.pendingReward(staker), earnedBefore, "the redemption did not touch their earned rewards");
        assertEq(staking.balanceOf(staker), staked - staked / 2, "the rest is still staked");
        vm.warp(_now() + 3 days);
        assertGt(staking.pendingReward(staker), earnedBefore, "and it keeps earning");
    }

    // ------------------------------------- 2. a liquidation proposal is waiting while someone redeems

    /// @dev The vote has passed but nobody has executed it yet, and the biggest holder redeems everything they own
    /// first (vote, then redeem). The proposal still executes: it liquidates whatever is redeemable at that moment,
    /// which is less. It cannot be blocked, because a redemption can never take the whole pot (the pool's and the
    /// stakers' TST stay outstanding).
    function test_ProposalPending_TheVoterRedeemsEverythingBeforeExecution_ProposalStillExecutes() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(3_000e18);
        (StocksGovernor gov, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descHash) =
            _passLiquidationProposal();

        uint256 snap = vm.snapshotState();

        // world A: the voter burns every TST they hold first
        uint256 redeemableBefore = staking.redeemableStock();
        uint256 all = tst.balanceOf(holder);
        _redeem(holder, all);
        uint256 redeemableAfter = staking.redeemableStock();
        assertLt(redeemableAfter, redeemableBefore, "the pot shrank");
        assertGt(redeemableAfter, 0, "but a redemption can never empty it (pool and staked TST stay outstanding)");

        gov.execute(targets, values, calldatas, descHash);
        assertGt(staking.pendingLiquidationExpiration(), _now(), "the liquidation order is live");
        uint256 committedA = redeemableAfter - staking.redeemableStock();

        vm.revertToState(snap);

        // world B: nobody redeems
        uint256 redeemableB = staking.redeemableStock();
        gov.execute(targets, values, calldatas, descHash);
        uint256 committedB = redeemableB - staking.redeemableStock();

        assertLt(committedA, committedB, "the redemption reduced what the liquidation could sell");
        assertGt(committedA, 0, "but the proposal still liquidated the rest");
    }

    /// @dev Redeeming between the vote and the execution changes nothing about who can execute or when.
    function test_ProposalPending_RedeemDuringTheVotingWindow_DoesNotBreakTheVote() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(1_000e18);
        StocksGovernor gov = StocksGovernor(payable(curve.governor()));
        vm.prank(holder);
        TSTToken(address(tst)).delegate(holder);
        vm.warp(_now() + 1);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(staking);
        calldatas[0] = abi.encodeCall(StocksStaking.liquidateTreasury, (12));
        vm.prank(holder);
        uint256 id = gov.propose(targets, values, calldatas, "liquidate");
        vm.warp(_now() + gov.votingDelay() + 1);

        // during the voting window the voter redeems part of what they hold; their vote weight was snapshotted
        // when the proposal started, so it still counts in full
        _redeem(holder, tst.balanceOf(holder) / 2);
        vm.prank(holder);
        gov.castVote(id, 1);
        vm.warp(_now() + gov.votingPeriod() + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded), "the vote weight was fixed at the snapshot");
    }

    // ------------------------------------------ 3. a real TWAMM liquidation order is live or unsettled

    function test_LiveTwammOrder_RedeemDuringIt_AfterItExpires_AndAfterSettlement_EverythingStaysSound() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(3_000e18);
        (StocksGovernor gov, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descHash) =
            _passLiquidationProposal();
        gov.execute(targets, values, calldatas, descHash);
        uint256 expiry = staking.pendingLiquidationExpiration();
        assertGt(expiry, _now(), "a real TWAMM order is live");
        uint256 earned = staking.pendingReward(staker);

        // --- while the order is live: new sells bring fresh stock into the treasury, and redemption works on it
        vm.warp(_now() + 2 hours);
        uint256 got = _buyTst(trader, 200e18);
        _sellTst(trader, got / 2);
        uint256 amt = tst.balanceOf(holder) / 4;
        (uint256 q,,) = staking.quoteRedeem(amt);
        assertGt(q, 0, "the fresh inflow is redeemable while the order runs");
        uint256 out = _redeem(holder, amt);
        assertEq(out, q, "and pays its quote");
        assertGe(staking.pendingReward(staker), earned, "the staker's earned rewards did not fall");
        assertGe(stock.balanceOf(address(hook)) + 4, hook.tokensOwed(Currency.wrap(address(stock)), address(staking)), "hook stock is backed");
        assertGe(tst.balanceOf(address(hook)) + 4, hook.tokensOwed(Currency.wrap(address(tst)), address(staking)), "hook TST is backed");

        // --- the order expires and a swap finishes its execution, but nobody has settled it yet
        vm.warp(expiry + 1 hours);
        _buyTst(trader, 1e18);
        _sellTst(trader, tst.balanceOf(trader) / 3);
        (uint256 qUnsettled,,) = staking.quoteRedeem(1_000_000e18);
        uint256 out2 = _redeem(holder, tst.balanceOf(holder) / 4);
        assertGt(out2, 0, "redemption works after expiry, before anyone settles the order");

        // --- settling burns the TST the order bought, which can only raise the rate for everyone who remains
        staking.claimLiquidatedTst();
        (uint256 qSettled,,) = staking.quoteRedeem(1_000_000e18);
        assertGt(qSettled, 0);
        assertGe(qSettled + 1e9, qUnsettled, "settling never lowers the redemption rate");
        assertEq(hook.tokensOwed(Currency.wrap(address(tst)), address(staking)), 0, "everything the order bought was claimed");

        // --- and after that, redemption and the staking stream carry on as normal
        _redeem(holder, tst.balanceOf(holder) / 4);
        vm.warp(staking.periodFinish() + 1);
        vm.prank(staker);
        staking.claim();
        uint256 stakedTst = staking.balanceOf(staker);
        vm.prank(staker);
        staking.unstake(stakedTst);
        assertEq(staking.totalStaked(), 0, "every staker can leave in full");
        assertGe(stock.balanceOf(address(staking)) + 1, staking.lastNotifiedBalance(), "the notified balance is real");
    }

    /// @dev After a liquidation and redemptions in between, a second liquidation proposal still works (or refuses
    /// cleanly with NothingToLiquidate), never leaves the contract stuck.
    function test_SecondLiquidationAfterRedemptions_WorksOrRefusesCleanly() public {
        vm.warp(_now() + 1 days);
        _fundTreasury(2_000e18);
        (StocksGovernor gov, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descHash) =
            _passLiquidationProposal();
        gov.execute(targets, values, calldatas, descHash);
        vm.warp(staking.pendingLiquidationExpiration() + 2 hours);
        _buyTst(trader, 1e18);
        staking.claimLiquidatedTst();

        // more stock arrives, someone redeems, then governance liquidates again
        _fundTreasury(500e18);
        _redeem(holder, tst.balanceOf(holder) / 3);
        uint256 redeemable = staking.redeemableStock();
        uint256 minIntervalsAgain = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(address(gov));
        if (redeemable > 0) {
            (uint256 committed,) = staking.liquidateTreasury(minIntervalsAgain);
            assertApproxEqAbs(committed, redeemable, 1e13, "it commits exactly what is redeemable");
        } else {
            vm.expectRevert(StocksStaking.NothingToLiquidate.selector);
            staking.liquidateTreasury(minIntervalsAgain);
        }
        assertLe(staking.lastNotifiedBalance(), stock.balanceOf(address(staking)), "accounting still consistent");
    }
}
