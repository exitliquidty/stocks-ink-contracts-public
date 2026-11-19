// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Scenario sweep for the leftover bar from the Sherlock #28 fix review: a restart keeps the time left
/// only while the leftover recorded at the duration cut is at least a tenth of the inflows since the cut. Covers
/// the griefer before and after the cut, the attacker who pays to compress a real leftover, immaterial pings, the
/// pause, and conservation when the window moves earlier. The per-swap trickle is in SherlockFix.durationCutTrickle.
contract SherlockLeftoverBarScenariosTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;

    address governor = address(0x6046);
    address honest = address(0xA11CE);
    address attacker = address(0xB16);
    address griefer = address(0xBAD);

    uint256 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        tst = new MockERC20("ACME", "ACME");
        stock = new MockERC20("Stock", "STK");
        hook = new MockHookV5(stock, tst, 1 hours, 1);
        staking = new StocksStaking(address(tst), address(stock), DURATION, governor, address(hook), address(this));
        bool tstIsCurrency0 = address(tst) < address(stock);
        staking.setPool(
            PoolKey({
                currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock)),
                currency1: tstIsCurrency0 ? Currency.wrap(address(stock)) : Currency.wrap(address(tst)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            })
        );
        tst.mint(address(hook), 1_000_000_000e18);
    }

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

    function _inflowFrom(address who, uint256 amount) internal {
        stock.mint(who, amount);
        vm.prank(who);
        stock.transfer(address(staking), amount);
        vm.prank(who);
        staking.notifyRewardAmount();
    }

    function _inflow(uint256 amount) internal {
        stock.mint(address(staking), amount);
        staking.notifyRewardAmount();
    }

    function _leftover() internal view returns (uint256) {
        uint256 pf = staking.periodFinish();
        return _now() >= pf ? 0 : (pf - _now()) * staking.rewardRate();
    }

    function _setDuration(uint256 d) internal {
        vm.prank(governor);
        staking.setRewardsDuration(d);
    }

    // ============ the griefer ============

    /// @dev Griefer keeps a dust stream alive BEFORE the duration change, then keeps pinging AFTER it with amounts
    /// at the bar (so the stale window is still protected). The window must only decay, never extend, and the
    /// first real inflow must still vest over the new duration.
    function test_Griefer_PingsAroundTheDurationChange_CannotExtendOrPinTheWindow() public {
        _stake(honest, 1_000e18);
        for (uint256 i; i < 4; ++i) {
            _inflowFrom(griefer, DURATION); // rate 1 wei/s, window renewed to 30 days each time
            vm.warp(_now() + 7 days);
        }
        uint256 pfBefore = staking.periodFinish();
        assertGt(pfBefore, _now(), "dust window is alive");
        _setDuration(1 days);

        // Post-change pings sized to the bar: leftover*10 >= ping, so the protection branch runs. Each such ping
        // grows the dust stream elevenfold, so staying at the bar quickly stops being free.
        uint256 pingsTotal;
        for (uint256 i; i < 10; ++i) {
            uint256 leftover = _leftover();
            uint256 ping = leftover * 10;
            if (ping == 0) break;
            _inflowFrom(griefer, ping);
            pingsTotal += ping;
            assertLe(staking.periodFinish(), pfBefore, "protected restarts never push the window later");
            vm.warp(_now() + 1 days);
        }
        assertLt(pingsTotal, 1e17, "ten pings at the bar still cost the griefer under a tenth of a token");

        // Now the real money.
        uint256 earnedBefore = staking.pendingReward(honest);
        _inflow(200e18);
        assertEq(staking.periodFinish() - _now(), 1 days, "real inflow vests over the configured 1 day");
        vm.warp(_now() + 1 days);
        uint256 got = staking.pendingReward(honest) - earnedBefore;
        assertGe(got, 200e18 - 1e9, "all of the real inflow in a day");
        assertLe(got, 200e18 + pingsTotal, "plus at most what the griefer itself put in");
    }

    /// @dev To keep a stale window alive against a real inflow the griefer needs a leftover of a tenth of that
    /// inflow streaming. That is no longer dust: it is a tenth of the real money, paid to stakers, and getting it
    /// in place resets the window to the new duration anyway.
    function test_Griefer_ProtectingTheWindowCostsATenthOfWhatIsDelayed() public {
        _stake(honest, 1_000e18);
        _inflowFrom(griefer, DURATION);
        vm.warp(_now() + 2 days);
        _setDuration(1 days);
        uint256 realInflow = 200e18;
        uint256 need = realInflow / 10;
        _inflowFrom(griefer, need); // > 10x the dust leftover: restarts over 1 day
        assertEq(staking.periodFinish() - _now(), 1 days, "the big ping itself resets to the new duration");
        _inflow(realInflow);
        assertEq(staking.periodFinish() - _now(), 1 days, "no stale window left to protect");
    }

    /// @dev Many immaterial pings accumulate in `inflowsSinceRestart`; the rate rises by reward / remaining, which
    /// is zero for dust. They cannot build a leftover that passes the bar, and whatever they trigger leaves the
    /// window at either the protected remainder or the new duration.
    function test_Griefer_ManyImmaterialPings_DoNotBuildAProtectedLeftover() public {
        _stake(honest, 1_000e18);
        _inflow(100e18);
        vm.warp(_now() + 5 days);
        _setDuration(1 days);
        uint256 leftover = _leftover();
        for (uint256 i; i < 50; ++i) {
            _inflowFrom(griefer, leftover / 200);
        }
        uint256 w = staking.periodFinish() - _now();
        assertTrue(w == 1 days || w == 25 days, "window is the protected remainder or the new duration");
        assertLe(staking.rewardRate() * w, 100e18 + (leftover / 200) * 50, "never owes more than was delivered");
    }

    // ============ the attacker ============

    /// @dev Attacker holds share s of the stake and donates just over 10x the leftover to compress it into 1 day.
    /// For every s up to 90% the attacker ends with less stock than it donated.
    function test_Attacker_CompressingARealLeftover_LosesMoneyUpTo90PercentShare() public {
        uint256[6] memory shares = [uint256(10), 25, 50, 75, 85, 90];
        for (uint256 k; k < shares.length; ++k) {
            uint256 snap = vm.snapshotState();
            _stake(honest, 1_000e18);
            _inflow(1_000e18);
            vm.warp(_now() + 10 days);
            _setDuration(1 days);
            vm.prank(honest);
            staking.claim(); // settle the first 10 days so the conservation check below covers only the restart
            uint256 honestBefore = stock.balanceOf(honest);
            uint256 s = shares[k];
            uint256 attackerStake = (1_000e18 * s) / (100 - s);
            _stake(attacker, attackerStake);
            uint256 leftover = _leftover();
            uint256 donation = leftover * 10 + 1;
            _inflowFrom(attacker, donation);
            assertEq(staking.periodFinish() - _now(), 1 days, "compressed");
            vm.warp(_now() + 1 days);
            vm.prank(attacker);
            staking.claim();
            uint256 got = stock.balanceOf(attacker);
            assertLt(got, donation, "attacker gets back less than it paid");
            vm.prank(honest);
            staking.claim();
            assertApproxEqAbs(stock.balanceOf(honest) - honestBefore + got, leftover + donation, 1e9, "conservation");
            vm.revertToState(snap);
        }
    }

    /// @dev The sniping the original rule prevents: the cheapest material restart (a tenth of the leftover)
    /// still cannot compress a real leftover.
    function test_Attacker_CheapestMaterialRestart_StillCannotCompress() public {
        _stake(honest, 1_000e18);
        _inflow(1_000e18);
        vm.warp(_now() + 1 days);
        _setDuration(1 days);
        _stake(attacker, 100_000e18);
        uint256 leftover = _leftover();
        _inflowFrom(attacker, leftover / 10 + 1);
        assertEq(staking.periodFinish() - _now(), 29 days, "not compressed");
    }

    /// @dev A natural inflow more than 10x the leftover lands after governance lowered the duration. The leftover
    /// IS compressed, but a late joiner only gains its share of it (under 9% of the pot), and the pot vests over
    /// the duration governance chose for new money.
    function test_NaturalBigInflow_LateJoinerGainsAtMostItsShareOfASmallLeftover() public {
        _stake(honest, 1_000e18);
        _inflow(100e18);
        vm.warp(_now() + 10 days);
        _setDuration(1 days);
        _stake(attacker, 1_000e18); // 50%
        uint256 leftover = _leftover();
        _inflow(1_000e18); // 15x the leftover
        assertEq(staking.periodFinish() - _now(), 1 days);
        vm.warp(_now() + 1 days);
        uint256 got = staking.pendingReward(attacker);
        assertLe(got, 500e18 + leftover / 2 + 1e9, "extra over the governed share is at most half the leftover");
        assertGe(got, 500e18 - 1e9, "late joiner does earn its share of the new money, as governance intended");
    }

    // ============ accounting when the window moves earlier ============

    /// @dev periodFinish moving earlier must not lose or double-count rewards: two stakers, claims mid-way and at
    /// the end; total paid equals total added within rounding.
    function test_WindowMovesEarlier_ConservationHolds() public {
        _stake(honest, 3_000e18);
        _stake(attacker, 1_000e18);
        _inflow(40e18);
        vm.warp(_now() + 12 days);
        _setDuration(1 days);
        vm.prank(honest);
        staking.claim();
        uint256 pfOld = staking.periodFinish();
        _inflow(1_000e18); // > 10x the ~24e18 leftover: window becomes 1 day, earlier than pfOld
        assertLt(staking.periodFinish(), pfOld, "window moved earlier");
        vm.warp(_now() + 12 hours);
        vm.prank(attacker);
        staking.claim();
        vm.warp(_now() + 2 days);
        vm.prank(honest);
        staking.claim();
        vm.prank(attacker);
        staking.claim();
        uint256 paid = stock.balanceOf(honest) + stock.balanceOf(attacker);
        assertLe(paid, 1_040e18, "never overpays");
        assertGe(paid, 1_040e18 - 1e9, "pays everything but rounding dust");
        assertEq(staking.pendingReward(honest) + staking.pendingReward(attacker), 0, "nothing left pending");
    }

    /// @dev Zero-rate case from the original #28 still behaves.
    function test_ZeroRate_StillRestartsOverTheNewDuration() public {
        _stake(honest, 1_000e18);
        _inflow(100e18);
        vm.warp(_now() + DURATION + 1);
        _inflowFrom(griefer, 1); // rate 0, window 30 days
        assertEq(staking.rewardRate(), 0);
        _setDuration(1 days);
        _inflow(100e18);
        assertEq(staking.periodFinish() - _now(), 1 days);
    }

    /// @dev Paused: arrivals are not recognised; on resume everything is one inflow and the bar applies then.
    function test_Paused_DustCannotPinAWindowThroughTheResume() public {
        _stake(honest, 1_000e18);
        _inflowFrom(griefer, DURATION); // dust stream, 30 days
        vm.warp(_now() + 2 days);
        _setDuration(1 days);
        vm.prank(governor);
        staking.setRewardsPaused(true);
        _inflowFrom(griefer, 1_000); // ignored while paused
        stock.mint(address(staking), 200e18); // real money arrives while paused
        vm.warp(_now() + 1 days);
        vm.prank(governor);
        staking.setRewardsPaused(false);
        assertEq(staking.periodFinish() - _now(), 1 days, "resume restarts over the new duration, not the dust window");
    }

    // ============ fuzz: the rule, stated once ============

    function testFuzz_Rule(uint256 elapsed, uint256 newDays, uint256 reward, uint256 firstInflow) public {
        elapsed = bound(elapsed, 1, DURATION - 1);
        newDays = bound(newDays, 1, 365);
        firstInflow = bound(firstInflow, 1, 1_000_000e18);
        _stake(honest, 1_000e18);
        _inflow(firstInflow);
        vm.warp(_now() + elapsed);
        _setDuration(newDays * 1 days);
        uint256 remaining = staking.periodFinish() - _now();
        uint256 leftover = _leftover();
        reward = bound(reward, leftover / 10 + 1, 10_000_000e18); // material
        _inflow(reward);
        uint256 window = staking.periodFinish() - _now();
        if (leftover * 10 >= reward && remaining > newDays * 1 days) {
            assertEq(window, remaining, "material leftover keeps its remainder");
        } else {
            assertEq(window, newDays * 1 days, "otherwise the configured duration");
        }
        assertLe(staking.rewardRate() * window, reward + leftover, "never streams more than owed");
        assertGe(staking.rewardRate() * window + window, reward + leftover, "loses at most one rounding step");
    }
}
