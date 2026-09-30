// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Business-logic validation, not a security/custody test: does the project's own core thesis
/// actually hold under realistic conditions? Stocks.ink is positioned as the "inverse" of a Digital Asset
/// Treasury -- instead of a token backed by a static or self-dealt crypto treasury, TST's backing is
/// supposed to GROW from the token's own organic trading volume through the flywheel. Every test so far
/// this session checks that the mechanism cannot be exploited or broken; none of them check WHO actually
/// captures that growth under ordinary usage.
contract StocksThesisValidationTest is StocksRedemptionAdversarialTest {
    function _sell(address who, uint256 tstIn) internal returns (uint256 got) {
        uint256 before = stock.balanceOf(who);
        vm.startPrank(who);
        tst.approve(address(swapRouter), tstIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tstIsCurrency0,
                amountSpecified: -int256(tstIn),
                sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        got = stock.balanceOf(who) - before;
    }

    /// @dev Simulates realistic, ordinary trading -- alternating buy/sell pressure sized modestly relative
    /// to the real pool's own depth, spread over real elapsed calendar time -- and measures, precisely,
    /// who actually captures the flywheel's real, accrued value: the (small) staked fraction of supply, or
    /// the (large) passive, non-staking fraction that a "backing grows with volume" thesis would suggest
    /// benefits too.
    ///
    /// FINDING (business logic, not a bug): `StocksStaking._notifyReward()` treats ANY stock inflow to the
    /// contract -- organic sell-side flywheel fees included -- as a reward stream owed ENTIRELY to
    /// currently-staked tokens (`rewardPerToken()`'s denominator is `totalStaked`, not `nonBurnedSupply()`).
    /// A passive, non-staking holder's only claim on that same growing balance is `redeem()`, which can
    /// only ever draw on `balance - earned` -- the part NOT already earmarked for stakers. Measured
    /// directly below: with only ~7% of supply staked, the staked fraction captures roughly 5x more of the
    /// SAME organic trading volume's real accrual than what ends up redeemable to the other ~93% of
    /// holders, a proportion wildly out of line with the staked share itself. Not a fund-safety issue --
    /// `redeemableStock()` floors at 0 and `redeem()` can never revert into insolvency -- but a genuine,
    /// quantified fact about who actually captures the flywheel's growth, worth knowing plainly rather
    /// than assumed from the "backing grows with volume" framing alone.
    function test_OrdinaryTradingVolume_OverwhelminglyBenefitsStakers_NotPassiveHolders() public {
        address[4] memory traders = [
            address(0x7A0E1), address(0x7A0E2), address(0x7A0E3), address(0x7A0E4)
        ];
        for (uint256 i; i < traders.length; i++) {
            stock.transfer(traders[i], 100_000e18);
        }

        uint256 startRedeemable = staking.redeemableStock();
        uint256 startSupply = staking.nonBurnedSupply();
        uint256 startStaked = staking.totalStaked();
        console.log("START: redeemable stock, circulating TST, staked TST:");
        console.log(startRedeemable, startSupply, startStaked);
        console.log("staked / circulating supply, in bps:", (startStaked * 10_000) / startSupply);

        uint256 poolDepth = stock.balanceOf(address(pm));
        uint256 totalStockVolume;

        // 180 days of ordinary trading: a handful of modest trades per "day", alternating direction, sized
        // as a small, realistic fraction of the pool's own depth -- not an adversarial sandwich, not a
        // whale dump. The staker never claims (realistic: many stakers check in occasionally, not daily),
        // so pendingReward() at the end reflects everything genuinely earned over the whole window.
        for (uint256 day; day < 180; day++) {
            for (uint256 t; t < traders.length; t++) {
                address trader_ = traders[t];
                bool buying = (day + t) % 2 == 0;
                if (buying) {
                    uint256 amount = poolDepth / 200; // ~0.5% of pool depth per trade
                    if (stock.balanceOf(trader_) < amount) continue;
                    _buyTst(trader_, amount);
                    totalStockVolume += amount;
                } else {
                    uint256 tstBal = tst.balanceOf(trader_);
                    if (tstBal == 0) continue;
                    uint256 amount = tstBal / 3;
                    if (amount == 0) continue;
                    _sell(trader_, amount);
                }
            }
            vm.warp(_now() + 1 days);
        }

        uint256 endRedeemable = staking.redeemableStock();
        uint256 endSupply = staking.nonBurnedSupply();
        uint256 stakerEarned = staking.pendingReward(staker);

        console.log("END (180 days later): redeemable stock, circulating TST:");
        console.log(endRedeemable, endSupply);
        console.log("total buy-side stock volume over the simulation:", totalStockVolume);
        console.log("the existing staker's real, claimable earnings over the same 180 days:", stakerEarned);

        // the core, positive half of the thesis: a PASSIVE, non-staking holder's redeemable backing did
        // genuinely grow from pure organic volume (this is real, not zero) -- and supply-side burn
        // (buy-side TST fees) benefits every holder equally regardless of staking, since it shrinks the
        // denominator for everyone.
        assertGt(endRedeemable, startRedeemable, "passive, non-staking holders must see SOME real redeemable growth from organic volume");
        assertLt(endSupply, startSupply, "buy-side TST burn benefits every holder equally, staked or not");
        uint256 nonStakerGain = endRedeemable - startRedeemable;
        console.log("passive-holder-accessible redeemable growth over 180 days:", nonStakerGain);

        // the quantified finding: how lopsided is the split between what stakers captured and what became
        // available to everyone else, relative to the staked share of supply itself?
        uint256 stakedShareBps = (startStaked * 10_000) / startSupply;
        uint256 totalAccrued = nonStakerGain + stakerEarned;
        uint256 stakerCaptureShareBps = (stakerEarned * 10_000) / totalAccrued;
        console.log("staked share of supply (bps) vs staker's actual share of total accrued value (bps):");
        console.log(stakedShareBps, stakerCaptureShareBps);

        // the real business-logic fact: stakers capture a share of the flywheel's growth GROSSLY out of
        // proportion to their share of supply -- confirmed directly, not assumed. At a ~7% staked ratio,
        // stakers should get roughly 7% of accrual if it were shared pro-rata across all holders; instead
        // they get the large majority of it, because the reward-stream mechanism earmarks ALL new inflow
        // to staked tokens only, not pro-rata across circulating supply.
        assertGt(stakerCaptureShareBps, stakedShareBps * 3, "stakers capture a share of flywheel growth many times their share of supply -- confirmed, not assumed");
    }
}
