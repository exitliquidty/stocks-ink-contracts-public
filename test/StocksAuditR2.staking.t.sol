// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 2, staking business logic on the real stack: who captures the reward stream when few or no
/// stakers are present, just-in-time staking around an inflow, and the split between stream and redemption pot.
contract StocksAuditR2StakingTest is StocksRedemptionAdversarialTest {
    function _thirty() internal view returns (uint256) {
        return _now() + 30 days;
    }

    /// @notice C6 quantified. While nobody is staked the stream keeps running in time but pays no one; that stock
    /// stays in the contract, unallocated, and is redeemable by every holder. A single dust staker who joins takes the
    /// stream from that moment on, and only from that moment: they cannot claim what streamed while the pool was empty.
    function test_C6_DustStakerEarnsOnlyWhileTheyAreStaked_NotTheEmptyPeriod() public {
        // the only staker leaves; fund the treasury; the stream starts with nobody to pay
        uint256 staked = staking.balanceOf(staker);
        vm.prank(staker);
        staking.unstake(staked);
        _fundTreasury(100e18);
        uint256 redeemableAtStart = staking.redeemableStock();
        assertGt(redeemableAtStart, 99e18, "an unstaked treasury is entirely redeemable at first");

        vm.warp(_now() + 10 days); // an empty third of the stream
        assertEq(staking.pendingReward(address(0xD05)), 0);

        // a dust staker (1 wei) joins
        address dust = address(0xD05);
        vm.prank(holder);
        tst.transfer(dust, 1);
        vm.startPrank(dust);
        tst.approve(address(staking), 1);
        staking.stake(1);
        vm.stopPrank();

        vm.warp(_now() + 20 days); // the stream's last two thirds
        uint256 earned = staking.pendingReward(dust);
        console.log("stream funded (wei):", uint256(100e18));
        console.log("dust staker (1 wei) earned over the last 20 days (wei):", earned);
        // it earns the remaining two thirds of the stream (minus the protocol-side cut already taken at funding), no more
        assertLe(earned, (redeemableAtStart * 2) / 3 + 1e15, "no more than the part that streamed while staked");
        assertGt(earned, (redeemableAtStart * 2) / 3 - 1e15, "it does capture the whole live stream, as any sole staker would");

        // the empty first third stayed in the pot: still redeemable for every holder
        assertGt(staking.redeemableStock(), redeemableAtStart / 3 - 1e15, "the empty period's stock is still in the redeemable pot");
    }

    /// @notice A holder stakes right before a big inflow, then unstakes a minute later. The inflow is spread over the
    /// whole reward duration, so the just-in-time staker earns only their share of that one minute.
    function test_JustInTimeStaking_CapturesOnlyItsMinute() public {
        vm.warp(_now() + 1 days);
        uint256 jit = tst.balanceOf(holder);
        vm.startPrank(holder);
        tst.approve(address(staking), jit);
        staking.stake(jit);
        vm.stopPrank();
        uint256 stockBefore = stock.balanceOf(holder);

        _fundTreasury(1_000e18); // the big inflow lands after the holder is already in
        vm.warp(_now() + 60);
        vm.prank(holder);
        staking.unstake(jit);
        vm.prank(holder);
        staking.claim();
        uint256 captured = stock.balanceOf(holder) - stockBefore;
        console.log("JIT staker captured (wei) of a 1000 stock inflow:", captured);
        // a minute of a 30-day stream is 1/43200 of it; even holding most of the stake it stays below 0.01% of the inflow
        assertLt(captured, 1_000e18 / 5_000, "a minute of staking earns a minute of the stream");
    }

    /// @notice Unstaking never lets a staker take stock that belongs to someone else: what a staker can claim over any
    /// sequence of stake/unstake/claim calls never exceeds the stream's total.
    function testFuzz_ClaimsNeverExceedTheStream(uint256 seed) public {
        uint256 fund = bound(seed, 1e18, 500e18);
        uint256 treasuryBefore = stock.balanceOf(address(staking));
        _fundTreasury(fund);
        uint256 totalIn = stock.balanceOf(address(staking)) - treasuryBefore;
        address[3] memory who = [staker, holder, trader];
        // give holder and trader some TST to play with
        _buyTst(trader, 5e18);
        uint256 claimed;
        for (uint256 i = 0; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address a = who[seed % 3];
            vm.warp(_now() + (seed >> 8) % 3 days);
            uint256 action = (seed >> 16) % 3;
            uint256 bal = tst.balanceOf(a);
            if (action == 0 && bal > 0) {
                uint256 amt = bound(seed >> 24, 1, bal);
                vm.startPrank(a);
                tst.approve(address(staking), amt);
                staking.stake(amt);
                vm.stopPrank();
            } else if (action == 1 && staking.balanceOf(a) > 0) {
                uint256 amt = bound(seed >> 24, 1, staking.balanceOf(a));
                vm.prank(a);
                staking.unstake(amt);
            } else {
                uint256 before = stock.balanceOf(a);
                vm.prank(a);
                staking.claim();
                claimed += stock.balanceOf(a) - before;
            }
        }
        for (uint256 j = 0; j < 3; j++) {
            uint256 before = stock.balanceOf(who[j]);
            vm.prank(who[j]);
            staking.claim();
            claimed += stock.balanceOf(who[j]) - before;
        }
        assertLe(claimed, totalIn, "stakers can never claim more than what flowed in");
        assertGe(stock.balanceOf(address(staking)) + claimed + 1e6, totalIn, "and the rest is still in the contract");
    }
}
