// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Stocks.ink. All rights reserved. No license to use, copy, modify, deploy or distribute this code is granted without the written permission of Stocks.ink.

// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                  ║
// ║   S T O C K S . I N K                                            ║
// ║                                                                  ║
// ║   Tokenized Stock Treasuries (TSTs): the inverse of a Digital    ║
// ║   Asset Treasury (DAT).                                          ║
// ║                                                                  ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// A TST turns its own trading volume into a growing on-chain treasury of
// tokenized equities, directed by its community and distributed to stakers.

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {StocksHook} from "./StocksHook.sol";
import {StocksPoolView} from "./StocksPoolView.sol";

/// @notice The part of the launch factory the graduator authenticates its caller against.
interface ICurveRegistry {
    /// @notice The curve the launch factory deployed for `token`, or zero if it deployed none.
    function curveOf(address token) external view returns (address);
}

/// @title StocksGraduator
/// @notice Creates a token's Uniswap v4 pool at graduation and locks its liquidity for good.
/// @dev Called exactly once per token, by that token's curve. It registers the pool with the hook, opens it at
/// the price implied by the two amounts it was handed, and mints a single full-range position owned by this
/// contract. There is no function that removes or transfers that position, so the liquidity is permanent. It
/// also leaves a small reserve of each token with the hook to absorb the hook's TWAMM rounding. This contract
/// keeps no balance between calls: whatever is left over is burned (TST) or sent to the treasury (stock).
contract StocksGraduator is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @notice Where leftover TST is sent.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Tick spacing of every pool this contract creates.
    int24 public constant TICK_SPACING = 60;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOM = 10_000;
    /// @notice Smallest TST seed accepted, in basis points of the token's total supply (1%). A smaller seed would
    /// make a pool too thin to trade against, so graduation reverts instead and can be retried once selling on
    /// the curve has brought the seed back up.
    uint256 public constant MIN_TST_SEED_SUPPLY_BPS = 100;

    /// @notice TST handed to the hook at graduation to cover rounding in its TWAMM accounting.
    uint256 public constant HOOK_TST_RESERVE_WEI = 1e20;
    /// @notice Stock handed to the hook at graduation to cover rounding in its TWAMM accounting.
    uint256 public constant HOOK_STOCK_RESERVE_WEI = 1e12;

    /// @notice The launch factory whose curves may graduate through this contract.
    address public immutable factory;

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The hook every pool is created on. It accepts pool registration and initialization only from here.
    StocksHook public immutable hook;

    /// @notice Emitted once per graduation.
    /// @param poolView The pool's view contract.
    /// @param tstToken The TST.
    /// @param stockToken The stock token.
    /// @param tstAmount TST actually received from the curve.
    /// @param stockAmount Stock actually received from the curve.
    event Graduated(address indexed poolView, address tstToken, address stockToken, uint256 tstAmount, uint256 stockAmount);

    /// @notice An amount is zero, as requested or as actually received.
    error ZeroAmount();
    /// @notice A constructor address argument was zero.
    error ZeroAddress();
    /// @notice `unlockCallback` was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice The amounts are too small to mint any liquidity.
    error NoLiquidityMinted();
    /// @notice The seed is at or below the hook reserve, or the TST seed is under 1% of total supply.
    error SeedTooSmall();
    /// @notice The caller is not the curve the factory recorded for this token.
    error NotCurve();

    /// @notice Wires the graduator to its PoolManager, hook and factory.
    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param hook_ The hook, which must have been deployed with this contract as its pool deployer.
    /// @param factory_ The launch factory whose curves may call `graduate`.
    constructor(IPoolManager poolManager_, StocksHook hook_, address factory_) {
        if (address(poolManager_) == address(0) || address(hook_) == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        factory = factory_;
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Seeds a token's v4 pool with everything its curve hands over.
    /// @dev Only the curve registered for `tstToken` may call. Amounts are measured as received, not as
    /// requested. A token that takes a cut on transfer cannot graduate: the PoolManager credits only what it
    /// receives, the position cannot be settled, and the call reverts with the PoolManager's own
    /// `CurrencyNotSettled`, leaving the curve untouched (pinned by
    /// test/StocksGraduator.feeOnTransferSettlement.t.sol).
    /// @param tstToken The TST.
    /// @param stockToken The stock token.
    /// @param treasury The token's staking contract, which receives the treasury's share of the flywheel cost.
    /// @param protocol Recipient of the protocol's share.
    /// @param feeBps The flywheel cost, in basis points, to register for the pool.
    /// @param tstAmount TST to pull from the curve.
    /// @param stockAmount Stock to pull from the curve.
    /// @return poolView The view contract deployed for the new pool.
    function graduate(
        address tstToken,
        address stockToken,
        address treasury,
        address protocol,
        uint256 feeBps,
        uint256 tstAmount,
        uint256 stockAmount
    ) external nonReentrant returns (address poolView) {
        // Only the curve the real factory deployed for this token. Without this anyone could seed a pool for a
        // token of their own and have the hook treat it as a real launch.
        if (msg.sender != ICurveRegistry(factory).curveOf(tstToken)) revert NotCurve();
        if (tstAmount == 0 || stockAmount == 0) revert ZeroAmount();

        // External audit finding (AuditAgent, 2026-09-30): unlike StocksCurve.buy(), this used to pull
        // `tstAmount`/`stockAmount` via a plain safeTransferFrom and trust the caller-supplied nominal
        // figures for every downstream check and calculation -- a token that charges a fee on THIS
        // specific curve-to-graduator transfer (distinct from, and not caught by, the curve's own
        // inbound-fee handling on its OWN buy() transfers) could leave the graduator holding less than
        // `stockAmount`/`tstAmount`, while every size/seed check and the pool-seeding math still used the
        // larger nominal figures. Fixed to mirror buy()'s own actualStockIn pattern exactly: measure the
        // real balance delta after each transfer, and re-run every check against the ACTUAL amounts
        // received, not the nominal ones requested. Currently theoretical, not reachable -- the real
        // 723-wrapper sweep already confirms none of the currently-attestable tokens charge any transfer
        // fee -- fixed for the same defense-in-depth reason as StocksCurve.sell()'s equivalent fix.
        uint256 tstBalanceBefore = IERC20(tstToken).balanceOf(address(this));
        IERC20(tstToken).safeTransferFrom(msg.sender, address(this), tstAmount);
        tstAmount = IERC20(tstToken).balanceOf(address(this)) - tstBalanceBefore;

        uint256 stockBalanceBefore = IERC20(stockToken).balanceOf(address(this));
        IERC20(stockToken).safeTransferFrom(msg.sender, address(this), stockAmount);
        stockAmount = IERC20(stockToken).balanceOf(address(this)) - stockBalanceBefore;

        if (tstAmount == 0 || stockAmount == 0) revert ZeroAmount();
        // There must be something left for the pool after the hook's reserve is set aside.
        if (tstAmount <= HOOK_TST_RESERVE_WEI || stockAmount <= HOOK_STOCK_RESERVE_WEI) revert SeedTooSmall();
        // And the TST side must be at least 1% of supply, or the pool would be too thin to be worth opening.
        if (tstAmount * BPS_DENOM < IERC20(tstToken).totalSupply() * MIN_TST_SEED_SUPPLY_BPS) {
            revert SeedTooSmall();
        }

        // v4 sorts a pool's currencies by address.
        bool tstIsCurrency0 = tstToken < stockToken;
        (Currency c0, Currency c1) = tstIsCurrency0
            ? (Currency.wrap(tstToken), Currency.wrap(stockToken))
            : (Currency.wrap(stockToken), Currency.wrap(tstToken));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});

        // Registration must come before initialization: the hook refuses to initialize an unregistered pool.
        hook.registerPool(key, tstToken, stockToken, treasury, protocol, feeBps);

        // The hook's rounding reserve. It comes out of the seed, not out of anyone's balance.
        IERC20(tstToken).safeTransfer(address(hook), HOOK_TST_RESERVE_WEI);
        IERC20(stockToken).safeTransfer(address(hook), HOOK_STOCK_RESERVE_WEI);
        uint256 poolTst = tstAmount - HOOK_TST_RESERVE_WEI;
        uint256 poolStock = stockAmount - HOOK_STOCK_RESERVE_WEI;

        (uint256 amount0, uint256 amount1) = tstIsCurrency0 ? (poolTst, poolStock) : (poolStock, poolTst);
        // Open the pool at the price the two amounts imply, so both are used in full by a full-range position.
        uint160 sqrtPriceX96 = SafeCast.toUint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
        poolManager.initialize(key, sqrtPriceX96);

        // The largest full-range position the two amounts can fund at that price.
        uint128 liquidity = _liquidityForAmounts(sqrtPriceX96, amount0, amount1);
        if (liquidity == 0) revert NoLiquidityMinted();
        // Mint the position inside the PoolManager's lock; see unlockCallback.
        poolManager.unlock(abi.encode(key, liquidity));

        // An address for front ends and indexers to refer to the pool by.
        poolView = address(new StocksPoolView(hook, key));

        // Rounding leaves a few wei of each token behind. Nothing may stay here.
        uint256 tstDust = IERC20(tstToken).balanceOf(address(this));
        if (tstDust > 0) IERC20(tstToken).safeTransfer(BURN_ADDRESS, tstDust);
        uint256 stockDust = IERC20(stockToken).balanceOf(address(this));
        if (stockDust > 0) IERC20(stockToken).safeTransfer(treasury, stockDust);

        emit Graduated(poolView, tstToken, stockToken, tstAmount, stockAmount);
    }

    /// @notice PoolManager callback that mints the full-range position and pays for it.
    /// @dev The position is owned by this contract with a zero salt and is never touched again.
    /// @param data ABI-encoded pool key and liquidity amount, as passed to `unlock`.
    /// @return Empty bytes.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));

        // Full range, owned by this contract, zero salt. The hook allows no other range on its pools.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        _settleCurrency(key.currency0, delta.amount0());
        _settleCurrency(key.currency1, delta.amount1());

        return "";
    }

    /// @dev Pays the PoolManager what the new position owes in one currency.
    /// @param currency The currency to pay.
    /// @param amount The position's delta in that currency; negative means owed.
    function _settleCurrency(Currency currency, int128 amount) private {
        // A negative delta is what this contract owes the PoolManager. Nothing is ever owed the other way here.
        if (amount >= 0) return;
        uint256 owed = uint256(uint128(-amount));
        address token = Currency.unwrap(currency);
        // v4's settle pattern: checkpoint the PoolManager's balance, transfer, then settle the difference.
        poolManager.sync(currency);
        IERC20(token).safeTransfer(address(poolManager), owed);
        poolManager.settle();
    }

    /// @dev Liquidity of a position spanning the whole price range that the two amounts can fund at the given
    /// price: the smaller of the two single-sided results.
    /// @param sqrtRatioX96 The pool's opening sqrt price.
    /// @param amount0 Amount of currency0 available.
    /// @param amount1 Amount of currency1 available.
    /// @return liquidity The liquidity to mint.
    function _liquidityForAmounts(uint160 sqrtRatioX96, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint128 liquidity)
    {
        // The range's two ends. Using the absolute price bounds instead of the usable ticks understates liquidity
        // by a negligible amount, which only leaves a few more wei of dust.
        uint160 sqrtRatioAX96 = TickMath.MIN_SQRT_PRICE;
        uint160 sqrtRatioBX96 = TickMath.MAX_SQRT_PRICE;

        // Liquidity fundable by the currency0 amount alone, between the current price and the upper bound.
        uint256 liquidity0 = FullMath.mulDiv(
            amount0, FullMath.mulDiv(sqrtRatioX96, sqrtRatioBX96, 1 << 96), sqrtRatioBX96 - sqrtRatioX96
        );
        // Liquidity fundable by the currency1 amount alone, between the lower bound and the current price.
        uint256 liquidity1 = FullMath.mulDiv(amount1, 1 << 96, sqrtRatioX96 - sqrtRatioAX96);
        // The position can only be as large as the scarcer side allows.
        uint256 result = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        liquidity = SafeCast.toUint128(result);
    }
}
