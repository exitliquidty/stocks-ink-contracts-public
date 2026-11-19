// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Sherlock #28 fix review, second follow-up. The leftover recorded at a duration cut is what restarts
/// protect. A liquidation or a redemption can take that stock out of the stream afterwards; the recorded amount
/// has to follow it down, or the next inflow would be spread over the old window to protect stock that is gone.
contract SherlockDurationCutStaleSnapshotTest is Test {
    MockERC20 tst;
    MockERC20 stock;
    MockHookV5 hook;
    StocksStaking staking;

    address governor = address(0x6046);
    address honest = address(0xA11CE);
    address whale = address(0x3A1E);

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
        tst.mint(honest, 1_000e18);
        vm.startPrank(honest);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _inflow(uint256 amount) internal {
        stock.mint(address(staking), amount);
        staking.notifyRewardAmount();
    }

    function _leftover() internal view returns (uint256) {
        uint256 pf = staking.periodFinish();
        return _now() >= pf ? 0 : (pf - _now()) * staking.rewardRate();
    }

    /// @dev A 30-day stream, cut to 1 day after 10 days: two thirds of it are recorded as the protected leftover.
    function _streamThenCut() internal {
        _inflow(1e18);
        vm.warp(_now() + 10 days);
        vm.prank(governor);
        staking.setRewardsDuration(1 days);
        assertApproxEqAbs(staking.leftoverAtDurationCut(), uint256(2e18) / 3, 1e13, "two thirds recorded at the cut");
    }

    /// @dev The reviewer's example: the liquidation zeroes the rate, so nothing is left to protect and the next
    /// inflow must vest over the configured day, not over the 20 days the old period still had.
    function test_Liquidation_ClearsTheRecordedLeftover_NextInflowUsesTheNewDuration() public {
        _streamThenCut();
        vm.prank(governor);
        staking.liquidateTreasury(24);
        assertEq(staking.rewardRate(), 0, "the liquidation took the whole stream");
        assertEq(staking.leftoverAtDurationCut(), 0, "nothing is left to protect");
        assertGt(staking.periodFinish(), _now() + 1 days, "the old period's end is still ahead");

        _inflow(1e18);
        assertEq(staking.periodFinish(), _now() + 1 days, "the inflow vests over the configured duration");
    }

    /// @dev A redemption that takes most of the stream lowers the recorded leftover to what is still streaming.
    /// An inflow more than ten times that remainder then restarts over the configured day.
    function test_Redemption_LowersTheRecordedLeftover_ToWhatIsStillStreaming() public {
        _streamThenCut();
        // The whale holds 99% of the supply and redeems all of it, which takes most of the stream.
        uint256 amount = tst.totalSupply() * 99;
        tst.mint(whale, amount);
        vm.startPrank(whale);
        tst.approve(address(staking), amount);
        staking.redeem(amount, 0);
        vm.stopPrank();

        uint256 live = _leftover();
        // The redeemer's flywheel cost stays behind, so a little under a tenth of the stream survives.
        assertLt(live, 1e17, "under a tenth of the stream is left");
        assertLe(staking.leftoverAtDurationCut(), live + 20 days, "recorded leftover follows the stream down");

        _inflow(1e18); // far more than ten times what is left
        assertEq(staking.periodFinish(), _now() + 1 days, "the inflow vests over the configured duration");
    }

    /// @dev Control: with nothing taken out of the stream the recorded leftover is untouched and still protected.
    function test_Control_UntouchedLeftoverIsStillProtected() public {
        _streamThenCut();
        uint256 recorded = staking.leftoverAtDurationCut();
        uint256 stalePf = staking.periodFinish();
        _inflow(1e18); // material, but under ten times the recorded leftover
        assertEq(staking.leftoverAtDurationCut(), recorded, "unchanged");
        assertEq(staking.periodFinish(), stalePf, "the restart keeps the time left");
    }
}
