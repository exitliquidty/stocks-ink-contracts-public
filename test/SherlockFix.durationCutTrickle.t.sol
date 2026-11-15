// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Sherlock #28 fix review, the per-swap shape of the inflow. The hook delivers the treasury's share of
/// every swap separately, so a pool's inflow is a trickle of small pieces rather than a lump. A bar judged against
/// each piece on its own could be passed by a dust leftover, and then the pieces landing in the stale window would
/// become the protected leftover for the pieces after them. The fix measures the leftover once, when governance
/// cuts the duration, and protects it only until the inflows since the cut reach ten times it.
contract SherlockDurationCutTrickleTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;

    address governor = address(0x6046);
    address honest = address(0xA11CE);
    address griefer = address(0xBAD);
    address attacker = address(0xB16);

    uint256 constant DURATION = 30 days;
    uint256 constant PIECE = 1e15; // one swap's treasury share, 0.001 stock

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
        tst.mint(honest, 1_000e18);
        vm.startPrank(honest);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
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

    function _cut(uint256 d) internal {
        vm.prank(governor);
        staking.setRewardsDuration(d);
    }

    function _leftover() internal view returns (uint256) {
        uint256 pf = staking.periodFinish();
        return _now() >= pf ? 0 : (pf - _now()) * staking.rewardRate();
    }

    /// @dev The reviewer's counterexample. Dormant pool, griefer parks 0.0002 stock as a 30-day dust stream,
    /// governance cuts to 1 day, then 200 swaps trickle in over 20 days. The stale window must collapse within the
    /// first few pieces and nearly everything delivered must have vested by the end.
    function test_Trickle_DustLeftoverCannotPinTheWindow() public {
        _inflowFrom(griefer, 2e14);
        vm.warp(_now() + 1 days);
        _cut(1 days);
        uint256 stalePf = staking.periodFinish();
        assertEq(staking.leftoverAtDurationCut(), _leftover(), "the dust leftover was recorded at the cut");

        uint256 collapsedAt = type(uint256).max;
        for (uint256 i; i < 200; ++i) {
            _inflow(PIECE);
            if (collapsedAt == type(uint256).max && staking.periodFinish() < stalePf) collapsedAt = i;
            assertLe(staking.periodFinish(), stalePf, "the window never moves later than the stale end");
            vm.warp(_now() + 20 days / 200);
        }
        assertLe(collapsedAt, 3, "the stale window collapses within the first three pieces");
        assertLe(staking.periodFinish() - _now(), 1 days, "pieces now vest over the configured 1 day");
        // Pieces land every 2.4 hours and vest over a day, so about ten are always in flight: the same as the
        // control below, which is the point.
        assertLe(_leftover(), 10 * PIECE, "only the pieces of the last day are still vesting");
    }

    /// @dev Control for the test above: with no griefer the trickle behaves the same way, so the fix removed the
    /// griefer's effect rather than changing the pool's normal life.
    function test_Trickle_Control_NoGriefer() public {
        vm.warp(_now() + 1 days);
        _cut(1 days);
        for (uint256 i; i < 200; ++i) {
            _inflow(PIECE);
            assertLe(staking.periodFinish() - _now(), 1 days);
            vm.warp(_now() + 20 days / 200);
        }
        assertLe(_leftover(), 10 * PIECE);
    }

    /// @dev A real leftover and a trickle: the pieces ride the protected window (they are immaterial), and the
    /// window holds until the pieces since the cut add up to ten times what was left at the cut. Then it goes.
    function test_Trickle_RealLeftoverIsProtectedUntilTenTimesItHasArrived() public {
        _inflow(1e18); // 1 stock over 30 days
        vm.warp(_now() + 10 days);
        _cut(1 days);
        uint256 recorded = staking.leftoverAtDurationCut();
        assertApproxEqAbs(recorded, uint256(2e18) / 3, 1e13, "two thirds were left at the cut");
        uint256 stalePf = staking.periodFinish();

        uint256 delivered;
        uint256 piece = recorded / 100; // each piece 1% of the recorded leftover: immaterial on its own
        while (delivered + piece <= recorded * 10) {
            _inflow(piece);
            delivered += piece;
            assertEq(staking.periodFinish(), stalePf, "window holds while under ten times the recorded leftover");
            vm.warp(_now() + 1 minutes); // a busy pool: a thousand pieces land well inside the 20-day window
        }
        // The pieces have been crossing the materiality bar repeatedly on the way (added since the last restart
        // vs. the growing leftover), each such restart protected. Ten times the recorded leftover has now arrived,
        // so the next material restart runs over the new duration.
        _inflow(recorded * 2);
        assertEq(staking.periodFinish() - _now(), 1 days, "once ten times has arrived the window is the new duration");
    }

    /// @dev Geometric growth after the cut: a griefer pings with amounts ten times the current leftover each time.
    /// Under a per-inflow bar every ping is protected and the dust grows elevenfold per ping while the window
    /// holds. Under the cut snapshot the second ping already passes ten times the recorded dust and compresses.
    function test_GeometricGrowth_DiesAtTheSecondPing() public {
        _inflowFrom(griefer, DURATION); // 1 wei a second
        vm.warp(_now() + 2 days);
        _cut(1 days);
        uint256 stalePf = staking.periodFinish();
        _inflowFrom(griefer, _leftover() * 10); // cumulative exactly ten times: still protected
        assertEq(staking.periodFinish(), stalePf, "first ping at the bar is protected");
        _inflowFrom(griefer, _leftover() * 10);
        assertEq(staking.periodFinish() - _now(), 1 days, "second ping compresses to the new duration");
    }

    /// @dev Anyone can un-pin a dust window before the trickle resumes, and it is cheap: ten times the dust plus one.
    function test_AnyoneCanClearADustWindowForDust() public {
        _inflowFrom(griefer, DURATION);
        vm.warp(_now() + 2 days);
        _cut(1 days);
        uint256 dust = _leftover();
        _inflow(dust * 10 + 1);
        assertEq(staking.periodFinish() - _now(), 1 days);
        assertLt(dust * 10 + 1, 1e9, "a few hundred million wei");
    }

    /// @dev A cut made while rewards are paused measures the time left from the frozen clock, so the leftover that
    /// resumes is still protected, and a cut made after a long pause that outlived the period records zero.
    function test_CutWhilePaused_RecordsTheFrozenLeftover() public {
        _inflow(100e18);
        vm.warp(_now() + 10 days);
        vm.prank(governor);
        staking.setRewardsPaused(true);
        vm.warp(_now() + 40 days); // longer than the whole period: by the wall clock it looks finished
        _cut(1 days);
        assertApproxEqAbs(staking.leftoverAtDurationCut(), uint256(200e18) / 3, 1e6, "measured from the frozen clock");
        vm.prank(governor);
        staking.setRewardsPaused(false);
        assertEq(staking.periodFinish() - _now(), 20 days, "the pause pushed the end out; 20 days left");

        // A material inflow under ten times the recorded leftover is protected after the resume.
        _inflowFrom(attacker, 100e18);
        assertEq(staking.periodFinish() - _now(), 20 days, "protected");
        // Over ten times: compressed, as it should be.
        _inflowFrom(attacker, 700e18);
        assertEq(staking.periodFinish() - _now(), 1 days, "cumulative over ten times lapses the protection");
    }

    /// @dev Raising the duration records nothing, and a later cut re-records from the current stream.
    function test_RaiseThenCut_RecordsAtTheCut() public {
        _inflow(100e18);
        vm.warp(_now() + 5 days);
        _cut(60 days);
        assertEq(staking.leftoverAtDurationCut(), 0, "a raise protects nothing, nothing can be compressed");
        vm.warp(_now() + 5 days);
        _cut(1 days);
        assertApproxEqAbs(staking.leftoverAtDurationCut(), uint256(200e18) / 3, 1e6, "re-recorded at the second cut");
    }

    /// @dev A cut while nothing is running records zero and nothing afterwards can be protected: fresh periods run
    /// over the new duration, so the time left never exceeds it.
    function test_CutWhileIdle_NeverCreatesAProtectedWindow() public {
        _cut(1 days);
        assertEq(staking.leftoverAtDurationCut(), 0);
        _inflowFrom(griefer, 1 days); // 1 wei a second for 1 day
        _inflow(100e18);
        assertEq(staking.periodFinish() - _now(), 1 days);
    }

    /// @dev Zero-rate leftover (liquidation committed the stream) records zero; the first inflow after a cut runs
    /// over the new duration however long the stale window.
    function test_ZeroRateAtTheCut_IsNotProtected() public {
        vm.warp(_now() + 1);
        _inflowFrom(griefer, 1); // rate 0, 30-day window
        assertEq(staking.rewardRate(), 0);
        _cut(1 days);
        assertEq(staking.leftoverAtDurationCut(), 0);
        _inflow(100e18);
        assertEq(staking.periodFinish() - _now(), 1 days);
    }

    /// @dev Sniping economics with the snapshot: compressing a real leftover needs cumulative inflows over ten
    /// times what was left at the cut, so the attacker ends with less than it put in at any share up to 90%.
    function test_Attacker_StillLosesAtNinetyPercentShare() public {
        _inflow(1_000e18);
        vm.warp(_now() + 10 days);
        _cut(1 days);
        vm.prank(honest);
        staking.claim();
        uint256 honestBefore = stock.balanceOf(honest);
        tst.mint(attacker, 9_000e18); // 90% of the stake
        vm.startPrank(attacker);
        tst.approve(address(staking), 9_000e18);
        staking.stake(9_000e18);
        vm.stopPrank();
        uint256 recorded = staking.leftoverAtDurationCut();
        uint256 donation = recorded * 10 + 1;
        _inflowFrom(attacker, donation);
        assertEq(staking.periodFinish() - _now(), 1 days, "compressed");
        vm.warp(_now() + 1 days);
        vm.prank(attacker);
        staking.claim();
        uint256 got = stock.balanceOf(attacker);
        assertLt(got, donation, "the attacker is out of pocket");
        vm.prank(honest);
        staking.claim();
        assertApproxEqAbs(stock.balanceOf(honest) - honestBefore + got, recorded + donation, 1e9, "conservation");
    }
}
