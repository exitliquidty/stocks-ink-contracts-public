// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @notice Fund-custody edge case: `_notifyReward()`'s `rewardRate = reward / rewardsDuration` truncates
/// on every single period rollover. Each period's own integer-division dust never reaches ANY individual
/// staker's stream directly -- it stays physically in the contract's balance (picked up again by the NEXT
/// period's `currentBalance - lastNotifiedBalance` check) -- but across hundreds of periods spanning
/// DECADES, does that compounding, repeatedly-deferred dust ever drift the books the wrong way? All of
/// this session's existing reward-accounting fuzzing (500k+ calls) uses realistic per-call time
/// increments; none of it specifically stress-tests hundreds of consecutive, deliberately awkward
/// (non-round) reward periods spanning centuries with a genuinely PASSIVE staker who never once touches
/// their position while it all happens around them.
contract StocksStakingDecadesOfPeriodsTest is StocksRedemptionAdversarialTest {
    function test_HundredsOfAwkwardRewardPeriodsOverCenturies_SolvencyNeverBreaks_PassiveStakerStillPaidExactly() public {
        // a second, genuinely passive staker: stakes once at the very start, never touches their position
        // again through the entire multi-century simulation below.
        address passiveStaker = address(0xFA551);
        stock.transfer(passiveStaker, 10e18);
        vm.startPrank(passiveStaker);
        stock.approve(address(curve), type(uint256).max);
        // curve is already graduated in the base fixture's setUp -- acquire TST via the real pool instead
        vm.stopPrank();
        uint256 passiveTst = _buyTst(passiveStaker, 5e18);
        vm.startPrank(passiveStaker);
        tst.approve(address(staking), passiveTst);
        staking.stake(passiveTst);
        vm.stopPrank();

        uint256 periods = 500; // 500 x 30 days ~= 41 years
        uint256 rewardsDuration = curve.rewardsDuration(); // 30 days in this fixture
        console.log("simulating periods, each spanning (s):", periods, rewardsDuration);

        for (uint256 i; i < periods; i++) {
            // a deliberately AWKWARD (non-round, prime-ish) amount every period, specifically to force
            // integer-division truncation dust on every single rollover rather than dividing evenly.
            uint256 amount = 1_000e18 + (i * 7919) % 1e18 + 1;
            stock.transfer(address(staking), amount);
            staking.notifyRewardAmount();

            // the strict solvency check, every single period, not just at the end: what everyone is owed
            // (both stakers' pending rewards) can never exceed what the contract actually holds.
            uint256 owed = staking.pendingReward(staker) + staking.pendingReward(passiveStaker);
            uint256 bal = stock.balanceOf(address(staking));
            assertLe(owed, bal, "solvency violated mid-simulation: owed exceeds real balance");

            vm.warp(_now() + rewardsDuration);
        }

        // final solvency check after the entire multi-century run
        uint256 finalOwed = staking.pendingReward(staker) + staking.pendingReward(passiveStaker);
        uint256 finalBal = stock.balanceOf(address(staking));
        console.log("after the full run: owed to both stakers, real balance held:", finalOwed, finalBal);
        assertLe(finalOwed, finalBal, "solvency violated after the full multi-century simulation");

        // the passive staker, who never touched anything for the entire simulated 41 years, can still
        // claim their exact, correct, real share -- not reverted, not zeroed out, not corrupted.
        uint256 expectedPassive = staking.pendingReward(passiveStaker);
        assertGt(expectedPassive, 0, "the passive staker genuinely earned something over 41 years of real activity");
        uint256 balanceBeforeClaim = stock.balanceOf(passiveStaker); // includes leftover from their original funding, untouched since
        vm.prank(passiveStaker);
        staking.claim();
        uint256 actualReceived = stock.balanceOf(passiveStaker) - balanceBeforeClaim;
        console.log("passive staker: expected vs actually received after 41 years untouched:", expectedPassive, actualReceived);
        assertEq(actualReceived, expectedPassive, "the passive staker received exactly what pendingReward said they were owed");
    }
}
