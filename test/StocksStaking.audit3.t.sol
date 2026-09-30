// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @dev A 10%-fee-on-transfer ERC20: the sender's balance always decreases by exactly the
/// requested `amount` (standard fee-on-transfer behavior -- the fee is skimmed OUT of what the
/// receiver gets, not added on top of what the sender pays), but the recipient only ever receives
/// 90% of it. Used here to test StocksStaking's OWN balance-diff-based accounting, not to model
/// any specific real xStock wrapper -- this project's own convention is that `stockToken` is
/// always a trusted wrapper for THIS purpose, but StocksStaking's raw-balance-reading functions
/// (`_notifyReward`, `liquidateTreasury`) don't actually know or enforce that, so it's worth
/// proving their own arithmetic tolerates it rather than assuming.
contract FeeOnTransferMockERC20 is ERC20 {
    uint256 public constant FEE_BPS = 1_000; // 10%
    address public constant FEE_SINK = address(0xFEEE);

    constructor() ERC20("FeeStock", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, FEE_SINK, fee);
    }
}

/// @notice Round-3 formal audit of StocksStaking.sol: does this contract share the fee-on-transfer
/// `stockToken` exposure already confirmed (CONFIRMED Medium) against StocksHook/StocksLaunchFactory
/// (graduation bricking) and StocksCurve.sell() (seller shortchanged)? Answer: no, on both paths
/// actually tested here -- StocksStaking's own accounting is balance-diff-based (rewards) or
/// self-referential to its own balance delta (liquidation), not quote-trusting, so it doesn't
/// inherit the same class of bug. See this file's own test-level docstrings for the reasoning
/// behind each claim, and the accompanying report for the one claim (liquidateTreasury's
/// `lastNotifiedBalance` bookkeeping under a fee-on-transfer stockToken) verified by direct
/// code-level arithmetic reasoning rather than a full MockHookV5 integration PoC, and why that's
/// sufficient here.
contract StocksStakingAudit3Test is Test {
    FeeOnTransferMockERC20 feeStock;
    MockERC20 tst;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address staker = address(0xCAFE);

    uint256 constant DURATION = 30 days;

    function setUp() public {
        tst = new MockERC20("ACME", "ACME");
        feeStock = new FeeOnTransferMockERC20();
        hook = new MockHookV5(feeStock, tst, 1 hours, 1);

        staking = new StocksStaking(
            address(tst), address(feeStock), DURATION, governor, address(hook), address(this)
        );

        bool tstIsCurrency0 = address(tst) < address(feeStock);
        poolKey = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(feeStock)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(feeStock)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(poolKey);

        tst.mint(staker, 1_000e18);
        vm.startPrank(staker);
        tst.approve(address(staking), type(uint256).max);
        staking.stake(1_000e18);
        vm.stopPrank();
    }

    /// @notice PROVEN SAFE: _notifyReward() reads `stockToken.balanceOf(address(this))` directly
    /// (a real balance-diff, exactly like StocksCurve.buy()'s already-proven-safe `actualStockIn`
    /// pattern) rather than trusting any caller-supplied or hook-asserted amount. A fee-on-transfer
    /// stockToken can only ever result in a SMALLER real balance increase being credited as reward
    /// -- never a larger, phantom one that would let rewards be over-distributed relative to what
    /// the contract actually holds to pay out.
    function test_AUDIT_NotifyReward_FeeOnTransferStock_CreditsOnlyTheRealAmountReceived() public {
        uint256 grossSent = 1_000e18;
        uint256 expectedNet = grossSent - (grossSent * FeeOnTransferMockERC20(address(feeStock)).FEE_BPS()) / 10_000;

        // Simulates the real hook's own fee-routing safeTransfer of collected swap fees into this
        // contract -- the "reward arrives" event, from the staking contract's own point of view,
        // regardless of what upstream mechanism produced it.
        feeStock.mint(address(this), grossSent);
        feeStock.transfer(address(staking), grossSent);
        assertEq(feeStock.balanceOf(address(staking)), expectedNet, "sanity: contract only ever holds the net amount");

        staking.notifyRewardAmount();

        assertEq(staking.totalRewardsAdded(), expectedNet, "must credit exactly the real, net amount received");
        assertEq(staking.rewardRate(), expectedNet / DURATION, "rewardRate must be derived from the real amount, not the gross");

        console.log("CONFIRMED SAFE: notifyRewardAmount() credits only the real, fee-adjusted balance increase");
    }

    /// @notice PROVEN SAFE (by direct arithmetic, not just informal reasoning): liquidateTreasury's
    /// `lastNotifiedBalance = balance - stockCommitted` tracks what leaves THIS contract's OWN
    /// balance during the hook's transferFrom pull. Standard fee-on-transfer tokens deduct their
    /// fee from what the RECIPIENT receives, not from what the SENDER's balance decreases by --
    /// i.e. a transferFrom(this, hook, stockCommitted) call reduces this contract's balance by
    /// exactly `stockCommitted` regardless of any fee skimmed on the receiving end. This test
    /// confirms that arithmetic holds for a real fee-on-transfer token via MockHookV5 (which
    /// performs a real OZ-token transferFrom pull, not a stubbed one) -- it does NOT re-test
    /// whether a real TWAMM's own internal accounting (a separate, already-in-scope question for
    /// the StocksHook/TWAMM audit track) correctly handles receiving less than requested; this
    /// test only proves StocksStaking's own local bookkeeping doesn't drift.
    function test_AUDIT_LiquidateTreasury_FeeOnTransferStock_LocalAccountingStaysConsistent() public {
        feeStock.mint(address(staking), 1_000e18);
        uint256 balanceBefore = feeStock.balanceOf(address(staking));

        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(governor);
        (uint256 stockCommitted,) = staking.liquidateTreasury(_minLiqIntervals1);

        uint256 realBalanceAfter = feeStock.balanceOf(address(staking));
        assertEq(
            staking.lastNotifiedBalance(),
            realBalanceAfter,
            "lastNotifiedBalance must match the REAL post-pull balance, not an assumed one"
        );
        assertEq(balanceBefore - stockCommitted, realBalanceAfter, "sender-side balance drop must equal exactly stockCommitted");

        console.log("CONFIRMED SAFE: liquidateTreasury's local accounting matches the real balance after a fee-on-transfer pull");
    }
}
