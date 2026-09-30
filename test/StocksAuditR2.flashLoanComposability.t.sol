// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

/// @dev Borrows stock from the real pool via PoolManager's own flash-accounting (take now, settle before
/// the unlock ends -- a real, uncollateralized-until-repayment flash loan, no lending protocol needed),
/// swaps it for TST, redeems some of that TST for stock through StocksStaking (an ordinary external call,
/// entirely outside PoolManager's delta system), swaps what's left of the TST back, then repays the
/// borrowed stock -- all in ONE atomic transaction. Whatever stock is left over afterward is the
/// attacker's profit.
contract FlashComposabilityAttacker is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    PoolKey public key;
    bool public tstIsCurrency0;
    IERC20 public tst;
    IERC20 public stock;
    StocksStaking public staking;

    constructor(IPoolManager _manager, PoolKey memory _key, bool _tstIsCurrency0, IERC20 _tst, IERC20 _stock, StocksStaking _staking) {
        manager = _manager;
        key = _key;
        tstIsCurrency0 = _tstIsCurrency0;
        tst = _tst;
        stock = _stock;
        staking = _staking;
    }

    struct Plan {
        uint256 flashBorrowStock;
        uint256 redeemFractionBps; // how much of the acquired TST to redeem vs. swap straight back
    }

    function attack(Plan calldata plan) external returns (int256 stockProfit) {
        bytes memory result = manager.unlock(abi.encode(plan));
        stockProfit = abi.decode(result, (int256));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        Plan memory plan = abi.decode(rawData, (Plan));

        Currency stockCurrency = tstIsCurrency0 ? key.currency1 : key.currency0;
        Currency tstCurrency = tstIsCurrency0 ? key.currency0 : key.currency1;

        // 1) flash-borrow stock straight out of the pool via take() -- no collateral, must be settled
        // before this unlock() call returns.
        manager.take(stockCurrency, address(this), plan.flashBorrowStock);

        // 2) swap the entire borrowed stock for TST on the real pool.
        BalanceDelta d1 = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !tstIsCurrency0,
                amountSpecified: -int256(plan.flashBorrowStock),
                sqrtPriceLimitX96: !tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 tstReceived = tstIsCurrency0 ? d1.amount0() : d1.amount1();
        require(tstReceived > 0, "swap1 produced no TST");
        // settle what's owed to the pool for this swap (the stock side) using the flash-borrowed tokens
        // already sitting in this contract's own balance (not PoolManager's), and take the TST credit.
        stockCurrency.settle(manager, address(this), plan.flashBorrowStock, false);
        tstCurrency.take(manager, address(this), uint256(uint128(tstReceived)), false);

        uint256 tstHeld = uint256(uint128(tstReceived));
        uint256 toRedeem = (tstHeld * plan.redeemFractionBps) / 10_000;
        uint256 toSwapBack = tstHeld - toRedeem;

        // 3) redeem a slice of the acquired TST for stock through StocksStaking -- entirely outside
        // PoolManager's own delta accounting, an ordinary external call and ERC20 transfer.
        uint256 stockFromRedeem;
        if (toRedeem > 0) {
            tst.approve(address(staking), toRedeem);
            try staking.redeem(toRedeem, 0) returns (uint256 out) {
                stockFromRedeem = out;
            } catch {
                // redemption can legitimately refuse (e.g. exceeds circulating supply for a huge borrow);
                // fall through and just swap everything back instead.
                toSwapBack = tstHeld;
            }
        }

        // 4) swap whatever TST is left back to stock on the same pool.
        uint256 stockFromSwapBack;
        if (toSwapBack > 0) {
            BalanceDelta d2 = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: tstIsCurrency0,
                    amountSpecified: -int256(toSwapBack),
                    sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 stockBack = tstIsCurrency0 ? d2.amount1() : d2.amount0();
            require(stockBack > 0, "swap2 produced no stock");
            tstCurrency.settle(manager, address(this), toSwapBack, false);
            stockCurrency.take(manager, address(this), uint256(uint128(stockBack)), false);
            stockFromSwapBack = uint256(uint128(stockBack));
        }

        // 5) repay the original flash-borrowed stock out of what was reacquired above (already sitting in
        // this contract's real ERC20 balance from steps 3 and 4 -- redeem() and the swap's take() both pay
        // this contract directly, not through PoolManager's transient delta system), topping up from a
        // pre-funded bailout buffer if there's a genuine shortfall, so the transaction always completes and
        // the actual profit/loss is directly measured rather than inferred from an early revert.
        uint256 totalStockBack = stockFromRedeem + stockFromSwapBack;
        stockCurrency.settle(manager, address(this), plan.flashBorrowStock, false);

        int256 profit = int256(totalStockBack) - int256(plan.flashBorrowStock);
        return abi.encode(profit);
    }
}

/// @notice Round 10's own top-down pass flagged flash-loan composability across buy/sell/redeem/
/// liquidateTreasury, chained in one transaction, as not yet reached with its own specific checklist
/// (round 4 covers governance-voting flash loans only; the redemption-adversarial suite covers
/// flash-borrow-and-repay against redeem() in isolation, not chained with a swap on both sides).
/// liquidateTreasury itself is excluded here on purpose: it is onlyGovernor, and round 4 already proves
/// structurally that a real governance vote can never be flash-loaned (the snapshot is always in the real
/// future), so no atomic single-transaction attack can ever reach it regardless of what else is chained.
contract StocksAuditR2FlashLoanComposabilityTest is StocksRedemptionAdversarialTest {
    function test_FlashBorrow_SwapRedeemSwapBack_ChainedAtomically_NeverProfits() public {
        FlashComposabilityAttacker attacker = new FlashComposabilityAttacker(
            IPoolManager(address(pm)), key, tstIsCurrency0, tst, stock, staking
        );

        uint256 poolStockDepth = stock.balanceOf(address(pm));
        console.log("real pool stock depth (wei):", poolStockDepth);

        // a range of borrow sizes relative to real pool depth, and a range of how much of the acquired
        // TST gets redeemed vs. swapped straight back
        uint256[3] memory borrowFractionsOfDepth = [uint256(20), 5, 2]; // depth/20, depth/5, depth/2
        uint256[3] memory redeemBpsOptions = [uint256(0), 5000, 10000]; // all swapped back, half, all redeemed

        for (uint256 i = 0; i < borrowFractionsOfDepth.length; i++) {
            for (uint256 j = 0; j < redeemBpsOptions.length; j++) {
                uint256 snap = vm.snapshotState();
                uint256 borrowAmount = poolStockDepth / borrowFractionsOfDepth[i];

                FlashComposabilityAttacker.Plan memory plan = FlashComposabilityAttacker.Plan({
                    flashBorrowStock: borrowAmount,
                    redeemFractionBps: redeemBpsOptions[j]
                });

                // A pre-funded bailout buffer, generous relative to the borrow size, so a genuine shortfall
                // (there almost always is one -- every individual leg of this chain is independently proven
                // lossy) can still be SETTLED in full and the transaction completes, rather than reverting
                // and hiding the actual measured loss behind a generic revert. The buffer itself is never
                // counted as attacker capital in the profit figure below -- only the delta matters.
                uint256 bailout = borrowAmount * 2;
                stock.transfer(address(attacker), bailout);

                try attacker.attack(plan) returns (int256 profit) {
                    console.log("borrow (wei), redeemBps, profit (stock wei):");
                    console.log(borrowAmount, redeemBpsOptions[j]);
                    console.logInt(profit);
                    assertLe(profit, 0, "a chained flash-borrowed buy+redeem+sell-back must never profit the attacker");
                    // consistency check: the attacker contract's real leftover balance must equal exactly
                    // the untouched bailout plus the measured profit (which is <= 0 here) -- confirms the
                    // returned figure isn't just a number, it's what the contract's own balance shows too.
                    uint256 leftover = stock.balanceOf(address(attacker));
                    assertEq(int256(leftover), int256(bailout) + profit, "returned profit matches the contract's real leftover balance");
                } catch (bytes memory reason) {
                    // an outright revert (e.g. redeem() refusing an oversized amount, or the swap hitting
                    // its own price limit at extreme borrow sizes) is an acceptable, safe failure mode --
                    // the attacker simply cannot complete the sequence, which is not a fund-safety issue.
                    console.log("borrow (wei), redeemBps: reverted cleanly");
                    console.log(borrowAmount, redeemBpsOptions[j]);
                    reason;
                }

                assertEq(tst.balanceOf(address(attacker)), 0, "attacker contract holds no leftover TST");

                vm.revertToState(snap);
            }
        }
    }
}
