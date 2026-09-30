// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWrappedStock} from "./mocks/MockWrappedStock.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Locks in the dividend design now that StocksStaking has no wrap/unwrap/claimDividends:
/// a dividend raises the wrapper's exchange rate (raw asset minted straight to the vault, no new
/// shares) and StocksStaking does nothing with it. The treasury's shares simply become worth more
/// raw stock, stakers are paid in those same shares, and nothing about the rate rising may ever be
/// mistaken for new reward income.
contract StocksStakingDividendCompoundTest is Test {
    MockERC20 tst;
    MockERC20 rawStock;
    MockWrappedStock wrapper;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address staker = address(0xCAFE);

    uint256 constant DURATION = 30 days;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function setUp() public {
        tst = new MockERC20("ACME", "ACME");
        rawStock = new MockERC20("Tesla Stock", "TSLA");
        wrapper = new MockWrappedStock(IERC20(address(rawStock)));
        hook = new MockHookV5(IERC20(address(wrapper)), tst, EXPIRATION_INTERVAL, 1);

        staking = new StocksStaking(address(tst), address(wrapper), DURATION, governor, address(hook), address(this));

        bool tstIsCurrency0 = address(tst) < address(wrapper);
        poolKey = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(wrapper)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(wrapper)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(poolKey);

        tst.mint(address(hook), 1_000_000_000e18);

        tst.mint(staker, 1_000e18);
        vm.startPrank(staker);
        tst.approve(address(staking), 1_000e18);
        staking.stake(1_000e18);
        vm.stopPrank();
    }

    /// @dev Deposits `rawAmount` into the wrapper on behalf of the staking contract, the same shape
    /// as the flywheel's stock side landing on the treasury, then recognizes it as reward.
    function _fundTreasury(uint256 rawAmount) internal returns (uint256 shares) {
        rawStock.mint(address(this), rawAmount);
        rawStock.approve(address(wrapper), rawAmount);
        shares = wrapper.deposit(rawAmount, address(staking));
        staking.notifyRewardAmount();
    }

    /// @dev A dividend: raw asset appears in the vault with no new shares, so every share becomes
    /// redeemable for more. Share count is untouched, which is exactly why balance-diff detection
    /// can never see it.
    function _dividend(uint256 rawAmount) internal {
        rawStock.mint(address(wrapper), rawAmount);
    }

    function test_Dividend_RaisesShareValue_ButIsNeverMistakenForReward() public {
        uint256 shares = _fundTreasury(1_000e18);
        uint256 rewardsBefore = staking.totalRewardsAdded();
        uint256 valueBefore = wrapper.convertToAssets(shares);
        assertEq(rewardsBefore, shares, "the deposit itself is recognized as reward, once");

        _dividend(100e18);

        assertGt(wrapper.convertToAssets(shares), valueBefore, "sanity: the dividend raised the shares' raw value");
        assertEq(wrapper.balanceOf(address(staking)), shares, "share count untouched by a dividend");

        // Any reward-touching call, by anyone, must see nothing new.
        staking.notifyRewardAmount();
        assertEq(staking.totalRewardsAdded(), rewardsBefore, "a rising rate must never register as new reward income");
    }

    function test_Liquidation_CapturesTheDividend_InRawTerms() public {
        uint256 shares = _fundTreasury(1_000e18);
        // Let the whole reward stream vest, so everything above what stakers are owed is liquidatable.
        vm.warp(block.timestamp + DURATION + 1);

        uint256 valueAtStart = wrapper.convertToAssets(shares);
        _dividend(100e18);
        uint256 valueAfterDividend = wrapper.convertToAssets(shares);
        assertGt(valueAfterDividend, valueAtStart);

        // Everything vested is owed to the single staker, so nothing is liquidatable until they claim.
        vm.prank(staker);
        staking.claim();
        assertGt(wrapper.balanceOf(staker), 0, "staker is paid in wrapped shares");

        // Fresh inflow after the dividend: the treasury now holds shares bought at the higher rate.
        uint256 newShares = _fundTreasury(500e18);
        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 committed,) = staking.liquidateTreasury(_minLiqIntervals1);
        // Only the treasury's own shares, plus the reward stream's integer-division dust (rewardRate =
        // reward / duration floors, so at most `DURATION` wei per stream is left unclaimable).
        assertLe(committed, newShares + DURATION, "liquidation only ever commits the treasury's own shares");
        assertGe(committed, newShares, "and it commits all of them");
    }

    function test_Staker_ReceivesWrapped_ThatRedeemsForMoreAfterADividend() public {
        _fundTreasury(1_000e18);
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(staker);
        staking.claim();
        uint256 claimedShares = wrapper.balanceOf(staker);
        assertGt(claimedShares, 0);

        uint256 rawValueAtClaim = wrapper.convertToAssets(claimedShares);

        _dividend(500e18);

        vm.prank(staker);
        uint256 rawOut = wrapper.redeem(claimedShares, staker, staker);
        assertGt(rawOut, rawValueAtClaim, "the same shares must convert into more raw stock after a dividend");
        assertEq(rawStock.balanceOf(staker), rawOut);
    }

    function test_TreasuryShares_WorthMoreRawAfterDividend_WithNoAction() public {
        uint256 shares = _fundTreasury(1_000e18);
        uint256 before_ = wrapper.convertToAssets(shares);
        _dividend(250e18);
        assertGt(wrapper.convertToAssets(shares), before_, "treasury compounds with nobody doing anything");
        assertApproxEqAbs(wrapper.convertToAssets(shares), 1_250e18, 2, "the whole dividend accrues to the shares");
    }

    /// @dev The whole wrap/unwrap/dividend-claim surface must be gone, not merely unused.
    function test_RemovedFunctions_AreGone() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("wrapTreasuryStock(uint256,uint256)", uint256(1), uint256(0)),
            abi.encodeWithSignature("unwrapTreasuryStock(uint256,uint256)", uint256(1), uint256(0)),
            abi.encodeWithSignature("claimDividends()"),
            abi.encodeWithSignature("lastUnwrapAt()"),
            abi.encodeWithSignature("UNWRAP_COOLDOWN()")
        ];
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(staking).call(calls[i]);
            assertFalse(ok, "removed function selector must not exist");
        }
    }

    /// @dev Staking on a plain (non-wrapper) stock token, which several real fixtures use, must be
    /// entirely unaffected: no code path probes for a wrapper anymore.
    function test_PlainStockToken_LiquidationStillWorks() public {
        MockERC20 plain = new MockERC20("Plain", "PLN");
        MockHookV5 plainHook = new MockHookV5(IERC20(address(plain)), tst, EXPIRATION_INTERVAL, 1);
        StocksStaking plainStaking =
            new StocksStaking(address(tst), address(plain), DURATION, governor, address(plainHook), address(this));
        bool tstIsCurrency0 = address(tst) < address(plain);
        plainStaking.setPool(
            PoolKey({
                currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(plain)),
                currency1: tstIsCurrency0 ? Currency.wrap(address(plain)) : Currency.wrap(address(tst)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(plainHook))
            })
        );
        tst.mint(address(plainHook), 1_000_000e18);

        plain.mint(address(plainStaking), 5_000e18);
        uint256 _minLiqIntervals2 = plainStaking.MIN_LIQUIDATION_DURATION() / EXPIRATION_INTERVAL;
        vm.prank(governor);
        (uint256 committed,) = plainStaking.liquidateTreasury(_minLiqIntervals2);
        assertGt(committed, 0);
    }
}
