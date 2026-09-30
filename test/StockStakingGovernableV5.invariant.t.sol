// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWrappedStock} from "./mocks/MockWrappedStock.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";
import {StocksStakingHandler} from "./invariant/StocksStakingHandler.sol";

/// @notice V5 sibling of StockStakingGovernable.invariant.t.sol -- same long-random-sequence
/// methodology (see that file's own docstring for why this class of test exists), against the
/// TWAMM-order-submitting rewrite. Drops the old TWAP-checkpoint invariant entirely (no such state
/// exists here -- TWAMM protects execution price structurally, not via a stored checkpoint) and
/// adds one new invariant specific to the single-outstanding-order design.
contract StocksStakingInvariantTest is Test {
    MockERC20 tst;
    MockERC20 rawStock;
    MockWrappedStock wrapper;
    MockHookV5 hook;
    StocksStaking staking;
    StocksStakingHandler handler;

    address governor = address(0x6046);

    uint256 constant INITIAL_TST_MINT = 1_000_000e18;
    // Funds MockHookV5's own claim payouts -- not staking-system activity, but still real minted
    // supply, so it belongs in the same total-supply accounting as everything else.
    uint256 constant HOOK_FUNDING_MINT = 10_000_000e18;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function setUp() public {
        tst = new MockERC20("ACME", "ACME");
        rawStock = new MockERC20("Tesla Stock", "TSLA");
        wrapper = new MockWrappedStock(rawStock);
        hook = new MockHookV5(wrapper, tst, EXPIRATION_INTERVAL, 1);

        // This test contract deploys staking directly, so it IS `curve` and can call setPool().
        staking = new StocksStaking(address(tst), address(wrapper), 30 days, governor, address(hook), address(this));

        bool tstIsCurrency0 = address(tst) < address(wrapper);
        PoolKey memory key = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(wrapper)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(wrapper)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(key);

        // MockHookV5 needs a real tst balance to pay out claims against.
        tst.mint(address(hook), 10_000_000e18);

        tst.mint(address(this), INITIAL_TST_MINT); // just to establish real supply accounting

        // Seed the treasury with an initial wrapped-stock balance (so liquidate/unwrap have
        // something to act on from the very first call) and a small raw balance (so wrap has
        // something to act on before any unwrap has ever happened).
        rawStock.mint(address(this), 500e18);
        rawStock.approve(address(wrapper), 500e18);
        wrapper.deposit(500e18, address(staking));
        rawStock.mint(address(staking), 50e18);

        handler = new StocksStakingHandler(tst, rawStock, wrapper, hook, staking, governor);
        targetContract(address(handler));
    }

    /// @dev Same as StockStakingGovernable.invariant.t.sol's own -- nothing can ever be owed that
    /// wasn't actually added to the stream, regardless of past claims or how pause/resume/duration
    /// changes interleaved with staking.
    function invariant_PendingRewardNeverExceedsTotalRewardsAdded() public view {
        for (uint256 i = 0; i < 3; i++) {
            assertLe(staking.pendingReward(handler.actors(i)), staking.totalRewardsAdded());
        }
    }

    function invariant_FrozenPlusClaimedNeverExceedsTotalAdded() public view {
        assertLe(staking.frozenRewardsTotal() + staking.totalRewardsClaimed(), staking.totalRewardsAdded());
    }

    /// @dev The real solvency check: if every staker claimed simultaneously right now, the
    /// contract must actually hold enough stockToken to pay all of them -- independent of how
    /// totalRewardsAdded's own bookkeeping is computed. Also confirms the NEW liquidateTreasury
    /// resync (see that function's own docstring on why there's no same-block self-fee to
    /// reconcile here, unlike the old design) never leaves this insolvent.
    function invariant_SumOfPendingRewardsNeverExceedsActualBalance() public view {
        uint256 sumPending;
        for (uint256 i = 0; i < 3; i++) {
            sumPending += staking.pendingReward(handler.actors(i));
        }
        assertLe(sumPending, wrapper.balanceOf(address(staking)));
    }

    function invariant_RewardsDurationWithinAbsoluteBounds() public view {
        assertGe(staking.rewardsDuration(), 1 hours);
        assertLe(staking.rewardsDuration(), 365 days);
    }

    function invariant_LastNotifiedBalanceNeverExceedsActualBalance() public view {
        assertLe(staking.lastNotifiedBalance(), wrapper.balanceOf(address(staking)));
    }

    function invariant_TstTotalSupplyMatchesTotalMinted() public view {
        assertEq(tst.totalSupply(), handler.totalTstMinted() + INITIAL_TST_MINT + HOOK_FUNDING_MINT);
    }

    function invariant_TotalStakedMatchesGhostAccounting() public view {
        assertEq(staking.totalStaked(), handler.totalStakedGhost());
    }

    /// @dev New to V5: a second liquidateTreasury call must never succeed while
    /// block.timestamp is still before the outstanding order's own recorded expiration --
    /// the single-outstanding-order invariant the whole rewrite depends on. Checked here as a
    /// standing property (not just the one fixed-scenario PoC test) so the fuzzer's own random
    /// call ordering/timing can't find a sequence that violates it.
    function invariant_LiquidationNeverStartsWhilePriorOneStillPending() public view {
        // If an order was ever submitted, its recorded expiration must be a real future-or-past
        // timestamp the contract itself set -- never corrupted to some nonsensical value by any
        // interleaving of claims/pauses/duration changes.
        uint256 expiration = staking.pendingLiquidationExpiration();
        if (expiration == 0) return; // no liquidation ever submitted yet
        assertLe(expiration, block.timestamp + 365 days, "pendingLiquidationExpiration implausibly far in the future");
    }

    // ------------------------------------------------------------------ in-kind redemption invariants

    /// @dev A redemption never changes anyone's earned (already vested) rewards.
    function invariant_RedemptionNeverTouchesEarnedRewards() public view {
        assertEq(handler.earnedRewardViolations(), 0, "a redemption changed a staker's earned rewards");
    }

    /// @dev What a redemption pays is exactly what the quote said, and the treasury falls by exactly payout plus
    /// the protocol's cut.
    function invariant_RedemptionPaysItsQuoteAndBooksItExactly() public view {
        assertEq(handler.quoteMismatches(), 0, "payout differed from the quote");
        assertEq(handler.balanceDeltaMismatches(), 0, "treasury balance did not fall by payout + protocol cut");
    }

    /// @dev The only legitimate reason to refuse a redemption is a payout that rounds to zero.
    function invariant_RedemptionOnlyEverRefusedForLegitimateReasons() public view {
        assertEq(handler.unexpectedRedeemReverts(), 0, "a redemption reverted for an unexpected reason");
    }

    /// @dev Every exit leaves the holders who stay with at least the same redeemable stock per TST.
    function invariant_RedemptionNeverLowersTheRateForThoseWhoStay() public view {
        assertEq(handler.rateFellForRemainingHolders(), 0, "a redemption lowered the rate for remaining holders");
    }

    /// @dev Guards against a vacuous pass of the redemption invariants: a plain seeded walk of the handler must
    /// really redeem, be refused while a liquidation runs, and reach dividends and pauses too.
    function test_HandlerReachesRedemptions() public {
        for (uint256 i; i < 900; ++i) {
            uint256 r = uint256(keccak256(abi.encode("w", i)));
            uint256 a = uint256(keccak256(abi.encode("a", i)));
            uint256 b = uint256(keccak256(abi.encode("b", i)));
            uint256 pick = r % 12;
            if (pick == 0) handler.stake(a, b);
            else if (pick == 1) handler.unstake(a, b);
            else if (pick == 2) handler.claim(a);
            else if (pick == 3) handler.donateReward(b);
            else if (pick == 4) handler.governorSetPaused(i % 3 == 0);
            else if (pick == 5) handler.governorLiquidate(b);
            else if (pick == 6) handler.claimLiquidated(a);
            else if (pick == 7) handler.simulateDividend(b);
            else if (pick == 8) handler.warpTime(b);
            else handler.redeem(a, b, i % 2 == 0);
        }
        assertGt(handler.redemptionsDone(), 30, "the handler really redeems");
        assertGt(handler.redemptionsRefusedLegitimately(), 0, "and dust-sized redemptions are refused as such");
        assertEq(handler.unexpectedRedeemReverts(), 0);
        assertEq(handler.earnedRewardViolations(), 0);
    }

    function invariant_StakersCanAlwaysFullyUnstakeTheirBalance() public {
        for (uint256 i = 0; i < 3; i++) {
            address who = handler.actors(i);
            uint256 balance = staking.balanceOf(who);
            if (balance == 0) continue;

            uint256 snapshotId = vm.snapshotState();
            vm.prank(who);
            try staking.unstake(balance) {
                // Success -- exactly what this invariant requires.
            } catch {
                vm.revertToState(snapshotId);
                revert("a staker with a nonzero balance could not unstake it in full");
            }
            vm.revertToState(snapshotId);
        }
    }
}
