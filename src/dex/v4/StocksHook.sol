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

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {TWAMM} from "./twamm/vendor/TWAMM.sol";
import {ITWAMM} from "./twamm/vendor/ITWAMM.sol";

/// @title StocksHook
/// @notice The single Uniswap v4 hook behind every graduated TST pool. It charges the flywheel cost on each
/// trade, sends the stock part of it to the token's treasury, burns the TST part, and lets anyone place
/// time-weighted (TWAMM) orders against the pool.
/// @dev Built on a vendored TWAMM hook (see ./twamm/vendor), whose order book and execution maths are
/// inherited unchanged. What this contract adds:
///
///  - Pool registry. Only `poolDeployer` (the graduator) can register and initialize a pool, so every pool on
///    this hook belongs to a real launch. Each pool records its TST, stock token, treasury, protocol address
///    and cost rate.
///  - The flywheel cost on swaps. Pools have an LP fee of 0; the hook charges `feeBps` (10%) instead, always
///    in a way that ends up as stock for the treasury/protocol or as burned TST:
///      * selling TST for stock: `feeBps` of the stock out is taken in `afterSwap`; 80% goes to the treasury
///        (the staking contract) and 20% to the protocol;
///      * buying TST with stock: the protocol's 20% share is taken from the stock IN, in `beforeSwap`, and
///        the remaining 80% share is taken from the TST OUT in `afterSwap` and burned.
///    Only exact-input swaps are supported; exact-output swaps revert.
///  - The same cost on TWAMM orders. The hook's own TWAMM swaps do not pass through its swap hooks, so orders
///    are charged separately: the protocol's stock share when a stock-selling order is submitted, and the
///    rest on proceeds each time an order is synced.
///  - Fail-open TWAMM catch-up. Pending orders are executed at the start of every swap and liquidity change.
///    If that execution reverts the user's action still goes ahead, unless the revert looks like deliberate
///    gas starvation.
///  - Full-range liquidity only, so a narrow position cannot be used to convert tokens around the cost.
///
/// The hook holds funds: unsold TWAMM order deposits, proceeds owed to order owners, and a small reserve of
/// each token left by the graduator to absorb rounding. Balances of a token are shared across every pool that
/// uses it. Ownership of the inherited TWAMM is renounced in the constructor, so its kill switch is dead.
contract StocksHook is TWAMM {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // What the hook knows about one registered pool.
    struct LaunchInfo {
        // True once the graduator has registered the pool.
        bool registered;
        // Whether the TST is the pool's currency0 (tokens are sorted by address).
        bool tstIsCurrency0;
        // The pool's TST.
        address tstToken;
        // The pool's stock token.
        address stockToken;
        // The token's staking contract; receives the treasury's share of the cost.
        address treasury;
        // Receives the protocol's share of the cost.
        address protocol;
        // The flywheel cost for this pool, in basis points.
        uint256 feeBps;
    }

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOM = 10_000;
    /// @notice Highest flywheel cost a pool may be registered with (20%).
    uint256 public constant MAX_FEE_BPS = 2_000;
    /// @notice The protocol's share of the flywheel cost (20% of it). The rest goes to the treasury or is burned.
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 2_000;
    /// @notice Where burned TST is sent.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The only address allowed to register and initialize pools: the graduator.
    address public immutable poolDeployer;

    /// @notice Registration record of each pool.
    mapping(PoolId => LaunchInfo) public launches;
    /// @notice Uniswap-v2-style cumulative price of currency0, updated on swaps through the hook.
    mapping(PoolId => uint256) public price0CumulativeLast;
    /// @notice Uniswap-v2-style cumulative price of currency1, updated on swaps through the hook.
    mapping(PoolId => uint256) public price1CumulativeLast;
    /// @notice Timestamp of each pool's last accumulator update.
    mapping(PoolId => uint32) public blockTimestampLast;
    /// @dev Virtual reserve of currency0 as of the last accumulator update.
    mapping(PoolId => uint112) private _reserve0Cached;
    /// @dev Virtual reserve of currency1 as of the last accumulator update.
    mapping(PoolId => uint112) private _reserve1Cached;

    /// @notice Emitted when the graduator registers a pool.
    /// @param poolId The pool's id.
    /// @param tstToken The pool's TST.
    /// @param stockToken The pool's stock token.
    /// @param treasury The token's staking contract.
    /// @param protocol Recipient of the protocol's share.
    /// @param feeBps The flywheel cost, in basis points.
    event PoolRegistered(
        bytes32 indexed poolId, address tstToken, address stockToken, address treasury, address protocol, uint256 feeBps
    );
    /// @notice Emitted when the protocol's share is taken from the stock paid into a buy.
    /// @param poolId The pool's id.
    /// @param stockIn The stock the buyer specified.
    /// @param protocolStockCut The part of it sent to the protocol.
    event ProtocolStockCutTakenPreSwap(bytes32 indexed poolId, uint256 stockIn, uint256 protocolStockCut);

    /// @notice Emitted when the protocol's share is taken from a stock-selling TWAMM order at submission.
    /// @param poolId The pool's id.
    /// @param owner The order's owner.
    /// @param protocolStockCut Stock sent to the protocol.
    event TwammOrderInputFeeCharged(bytes32 indexed poolId, address indexed owner, uint256 protocolStockCut);

    /// @notice Emitted when the cost is taken from a TWAMM order's proceeds at sync.
    /// @param poolId The pool's id.
    /// @param owner The order's owner.
    /// @param feeAmount Amount taken from the proceeds.
    /// @param feeIsTst True if the proceeds, and so the amount taken, are TST (burned); false if stock.
    event TwammOrderProceedsFeeCharged(bytes32 indexed poolId, address indexed owner, uint256 feeAmount, bool feeIsTst);
    /// @notice Emitted on every swap through the hook, in a Uniswap-v2-like shape for indexers.
    /// @dev `to` is taken from `hookData` when it is exactly 32 bytes and is otherwise the swap's sender. It is
    /// supplied by the caller and is informational only; nothing on-chain relies on it.
    /// @param poolId The pool's id.
    /// @param sender The address that called the PoolManager (usually a router).
    /// @param amount0In Currency0 paid in, including any pre-swap cut.
    /// @param amount1In Currency1 paid in, including any pre-swap cut.
    /// @param amount0Out Currency0 received, net of the cost.
    /// @param amount1Out Currency1 received, net of the cost.
    /// @param feeToken0 Cost charged in currency0.
    /// @param feeToken1 Cost charged in currency1.
    /// @param to The recipient named by the caller.
    event Swap(
        bytes32 indexed poolId,
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 feeToken0,
        uint256 feeToken1,
        address indexed to
    );
    /// @notice The caller is not the graduator.
    error NotPoolDeployer();
    /// @notice An address argument was zero.
    error ZeroAddress();
    /// @notice The TST and the stock token are the same address.
    error IdenticalTokens();
    /// @notice The cost exceeds `MAX_FEE_BPS`.
    error FeeTooHigh();
    /// @notice The pool is already registered.
    error AlreadyRegistered();
    /// @notice The pool key does not use this hook, or its currencies are not the two tokens given.
    error InvalidPoolKey();
    /// @notice The pool was not registered before initialization.
    error NotRegisteredBeforeInitialize();
    /// @notice An amount does not fit its type, or the hook received a different amount than it took.
    error Overflow();
    /// @notice Exact-output swaps are not supported.
    error ExactOutputNotSupported();
    /// @notice TWAMM catch-up failed with almost no gas left, which is treated as gas starvation rather than
    /// as a failure to ignore.
    error TwammExecutionOutOfGas();
    /// @notice Only full-range liquidity may be added.
    error NonFullRangeLiquidityNotAllowed();
    /// @notice A price limit truncated a buy so far that the cut already taken would be at least the whole fill.
    error PreSwapCutWouldExceedActualFill();
    /// @notice `pumpTwammBacklog` was called with zero steps, a zero step, or for an uninitialized pool.
    error NothingToPump();

    /// @dev Restricts a function to the graduator.
    modifier onlyPoolDeployer() {
        if (msg.sender != poolDeployer) revert NotPoolDeployer();
        _;
    }

    /// @notice Deploys the hook and gives up ownership of the inherited TWAMM at once.
    /// @dev Must be deployed at an address whose low bits encode `getHookPermissions()`. With ownership
    /// renounced, `killHook` can never be called.
    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param poolDeployer_ The graduator: the only address allowed to register and initialize pools.
    /// @param expirationInterval_ Length of a TWAMM interval in seconds. Orders expire only on its multiples and
    /// pending orders are executed one whole interval at a time.
    constructor(IPoolManager poolManager_, address poolDeployer_, uint256 expirationInterval_)
        TWAMM(poolManager_, expirationInterval_, msg.sender)
    {
        if (poolDeployer_ == address(0)) revert ZeroAddress();
        poolDeployer = poolDeployer_;
        // The inherited TWAMM has an owner-only kill switch. Nobody should hold it, so ownership is dropped at once
        // and can never be taken back.
        renounceOwnership();
    }

    /// @notice The hook callbacks this contract implements. They must match the flags encoded in its address.
    /// @return The permission set.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Records a new pool's tokens, treasury, protocol address and cost. Graduator only, once per pool.
    /// @param key The pool key. Its hook must be this contract and its currencies the two tokens below.
    /// @param tstToken_ The pool's TST.
    /// @param stockToken_ The pool's stock token.
    /// @param treasury_ The token's staking contract.
    /// @param protocol_ Recipient of the protocol's share.
    /// @param feeBps_ The flywheel cost in basis points, at most `MAX_FEE_BPS`.
    function registerPool(
        PoolKey calldata key,
        address tstToken_,
        address stockToken_,
        address treasury_,
        address protocol_,
        uint256 feeBps_
    ) external onlyPoolDeployer {
        PoolId poolId = key.toId();
        if (launches[poolId].registered) revert AlreadyRegistered();
        if (
            tstToken_ == address(0) || stockToken_ == address(0) || treasury_ == address(0)
                || protocol_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (tstToken_ == stockToken_) revert IdenticalTokens();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        // The key must point at this hook and its two currencies must be exactly the TST and the stock token.
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();

        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == tstToken_;
        if (!tstIsCurrency0 && Currency.unwrap(key.currency1) != tstToken_) revert InvalidPoolKey();
        // Whichever currency is not the TST has to be the stock token.
        address expectedStock = tstIsCurrency0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        if (expectedStock != stockToken_) revert InvalidPoolKey();

        launches[poolId] = LaunchInfo({
            registered: true,
            tstIsCurrency0: tstIsCurrency0,
            tstToken: tstToken_,
            stockToken: stockToken_,
            treasury: treasury_,
            protocol: protocol_,
            feeBps: feeBps_
        });

        // Start the price accumulator's clock. A zero here is how the accumulator recognises an unregistered pool.
        blockTimestampLast[poolId] = uint32(block.timestamp % 2 ** 32);

        emit PoolRegistered(PoolId.unwrap(poolId), tstToken_, stockToken_, treasury_, protocol_, feeBps_);
    }

    /// @notice Allows a pool to be initialized only by the graduator and only after registration, then starts
    /// its TWAMM clock.
    /// @param sender The address initializing the pool.
    /// @param key The pool key.
    /// @return The hook selector.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Nobody but the graduator can open a pool on this hook, so a pool cannot be initialized ahead of a
        // graduation at a price of someone else's choosing.
        if (sender != poolDeployer) revert NotPoolDeployer();
        if (!launches[key.toId()].registered) revert NotRegisteredBeforeInitialize();

        if (key.currency0.isAddressZero()) revert PoolWithNativeNotSupported();
        // Start the pool's TWAMM clock at the beginning of the current interval.
        initialize(_getTWAMM(key));

        return IHooks.beforeInitialize.selector;
    }

    /// @param key The pool whose pending orders to execute.
    /// @dev Shared by beforeSwap, beforeAddLiquidity and beforeRemoveLiquidity: fails open (lets the caller's action
    /// proceed against whatever TWAMM state currently exists) unless the failure itself looks like deliberate gas
    /// gaming (see the F-1 audit history on beforeSwap -- the same reasoning now covers all three entry points
    /// instead of leaving beforeAddLiquidity fully unguarded and beforeRemoveLiquidity guarded without the gas check).
    function _safeTwammExecute(PoolKey calldata key) private {
        // An out-of-gas revert leaves at most 1/64 of the gas it was given, far under 1/8. Any other revert leaves
        // much more, and is ignored so that a TWAMM problem can never block ordinary trading.
        uint256 gasBefore = gasleft();
        try this.executeTWAMMOrders(key) {}
        catch {
            if (gasleft() < gasBefore / 8) revert TwammExecutionOutOfGas();
        }
    }

    // Audit round 13 (external review, reopened lead): a narrow (non-full-range) position added just ahead
    // of the current price, left in place while an ordinary swap (someone else's, paying the full fee on
    // their own trade) pushes price through it, then removed, converts one token into the other exactly the
    // way a swap would -- but through modifyLiquidity, which beforeSwap/afterSwap never see, so the
    // flywheel's 10% cost is never charged on that conversion. Confirmed and quantified directly
    // (test/StocksHook.rangeOrderFeeBypass.t.sol): the same input converted via this path yields materially
    // more output than an honest sell(), with zero of it reaching the treasury. This protocol's own design
    // never wanted third-party concentrated liquidity in the first place -- the graduator seeds exactly one
    // permanent full-range position and nothing else was ever meant to exist alongside it -- so rejecting
    // anything narrower than full-range closes the mechanism outright rather than trying to price it.
    // afterAddLiquidity/ReturnDelta stay disabled (see getHookPermissions): charging a fee here instead of
    // simply refusing the range would need those flags, which are baked into this hook's own mined address,
    // so it isn't available to the already-deployed hook regardless -- this is what a fix confined to
    // beforeAddLiquidity's existing, already-enabled permission can actually do.
    /// @notice Rejects anything but full-range liquidity, then catches up pending TWAMM orders.
    /// @param key The pool key.
    /// @param params The liquidity change. Its range must be the whole usable tick range.
    /// @return The hook selector.
    function beforeAddLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Full range only. See the note above.
        if (params.tickLower != TickMath.minUsableTick(key.tickSpacing) || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)) {
            revert NonFullRangeLiquidityNotAllowed();
        }
        _safeTwammExecute(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Catches up pending TWAMM orders before liquidity is removed.
    /// @param key The pool key.
    /// @return The hook selector.
    function beforeRemoveLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _safeTwammExecute(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Catches up pending TWAMM orders, then, on a buy of TST, takes the protocol's share out of the
    /// stock being paid in.
    /// @dev Catch-up runs first, so a swap can never trade ahead of orders that were already due. The cut is
    /// returned as a positive specified-currency delta, which makes the PoolManager swap that much less and
    /// charge the swapper for it. Exact-output swaps pass through here untouched and are rejected in `afterSwap`.
    /// @param key The pool key.
    /// @param params The swap parameters.
    /// @return The hook selector.
    /// @return The hook's delta: the pre-swap cut in the specified currency, nothing in the other.
    /// @return Always zero; the hook does not override the LP fee.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        _safeTwammExecute(key);

        // Exact-output swap: nothing to do here, `afterSwap` rejects it.
        if (params.amountSpecified > 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        LaunchInfo memory info = launches[poolId];
        if (!info.registered) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool feeIsCurrency0 = !specifiedIsCurrency0;
        bool feeIsTst = feeIsCurrency0 == info.tstIsCurrency0;
        // A sale of TST: the whole cost is taken from the stock coming out, in `afterSwap`.
        if (!feeIsTst) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 stockIn = uint256(-params.amountSpecified);
        // The protocol's share of the cost, as a fraction of the stock being paid in: feeBps * 20% (2% at 10%).
        uint256 protocolStockCut = (stockIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;
        if (protocolStockCut == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // The cut is returned as an int128 delta below, so it has to fit one.
        if (protocolStockCut > uint256(uint128(type(int128).max))) revert Overflow();

        // Take the cut out of the PoolManager now and pass it straight on to the protocol. The hook's resulting
        // debt is cancelled by the positive delta returned below, which the PoolManager charges to the swapper.
        Currency stockCurrency = specifiedIsCurrency0 ? key.currency0 : key.currency1;
        _takeExact(stockCurrency, info.stockToken, protocolStockCut);
        IERC20(info.stockToken).safeTransfer(info.protocol, protocolStockCut);

        emit ProtocolStockCutTakenPreSwap(PoolId.unwrap(poolId), stockIn, protocolStockCut);

        // Positive delta in the specified (stock) currency: the pool swaps that much less.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(protocolStockCut)), 0), 0);
    }

    /// @notice Charges the flywheel cost on the swap's output and routes it.
    /// @dev On a sale of TST the output is stock: `feeBps` of it is taken and split between treasury and
    /// protocol. On a buy of TST the output is TST: the treasury's 80% share of `feeBps` is taken and burned (the
    /// protocol's share was already taken in `beforeSwap`). The amount taken is returned as the hook's delta in
    /// the unspecified currency, so the swapper simply receives that much less.
    /// @param sender The address that called the PoolManager.
    /// @param key The pool key.
    /// @param params The swap parameters.
    /// @param delta The swap's balance delta, before this hook's adjustment.
    /// @param hookData Optional 32-byte recipient, used only for the Swap event.
    /// @return The hook selector.
    /// @return The amount of the unspecified currency the hook took.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // An exact-output swap would need the cost charged on the input side, which this hook does not do.
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        PoolId poolId = key.toId();
        // Record the price before looking at what to charge. Unregistered pools cannot exist, but the accumulator
        // is harmless for them.
        _updateAccumulator(poolId);

        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return (IHooks.afterSwap.selector, 0);

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool feeIsCurrency0 = !specifiedIsCurrency0;
        bool feeIsTst = feeIsCurrency0 == info.tstIsCurrency0;

        uint256 preSwapStockCut;
        // A buy of TST: recompute the cut `beforeSwap` took, to check it against the fill and to report it.
        if (feeIsTst && params.amountSpecified < 0) {
            uint256 stockIn = uint256(-params.amountSpecified);
            preSwapStockCut = (stockIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;

            // Audit round 13 (external review lead): beforeSwap sizes preSwapStockCut off the trader's full
            // SPECIFIED input, before it's known whether a tight sqrtPriceLimitX96 will truncate the actual
            // core fill. If it does, the cut (already taken, unconditionally, in beforeSwap) can end up
            // disproportionate to -- or even exceed -- the entire trade that actually went through. Rather
            // than attempting a partial refund here (afterSwap's own returned delta can only adjust the
            // UNSPECIFIED/output currency, never the specified/input stock side the cut was taken from, and a
            // raw ERC20 refund to `sender` risks landing in a router contract instead of the real trader), the
            // trade simply reverts outright when the cut would consume the entire real fill or more, so the
            // trader gets nothing worse than "try again with a wider limit," never a one-sided loss. Normal,
            // untruncated trades are unaffected: the cut is only ~2% of stockIn, always far below the ~98%
            // that actually reaches the pool.
            uint256 actualCoreStockSwapped =
                uint256(uint128(specifiedIsCurrency0 ? -delta.amount0() : -delta.amount1()));
            if (preSwapStockCut >= actualCoreStockSwapped) revert PreSwapCutWouldExceedActualFill();
        }

        // The swap's output. Not positive only if nothing was filled, in which case there is nothing to charge.
        int128 unspecifiedAmount = feeIsCurrency0 ? delta.amount0() : delta.amount1();
        if (unspecifiedAmount <= 0) {
            _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, 0, preSwapStockCut, hookData);
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 effectiveFeeBps = feeIsTst ? info.feeBps - _protocolShareBps(info.feeBps) : info.feeBps;

        // The cost is a fraction of what the swap paid out, before the swapper receives it.
        uint256 grossOut = uint256(uint128(unspecifiedAmount));
        uint256 feeAmount = (grossOut * effectiveFeeBps) / BPS_DENOM;
        if (feeAmount == 0) {
            _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, 0, preSwapStockCut, hookData);
            return (IHooks.afterSwap.selector, 0);
        }

        // Pull the cost out of the PoolManager into the hook, then send it where it belongs.
        Currency feeCurrency = feeIsCurrency0 ? key.currency0 : key.currency1;
        address feeCurrencyAddr = Currency.unwrap(feeCurrency);
        _takeExact(feeCurrency, feeCurrencyAddr, feeAmount);

        if (feeIsTst) {
            IERC20(info.tstToken).safeTransfer(BURN_ADDRESS, feeAmount);
        } else {
            _routeStockFee(info, feeAmount);
        }

        _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, feeAmount, preSwapStockCut, hookData);
        // Positive delta in the unspecified (output) currency: the swapper receives that much less.
        return (IHooks.afterSwap.selector, int128(uint128(feeAmount)));
    }

    /// @dev Emits the Swap event from the PoolManager's delta plus what the hook charged around it.
    /// @param poolId The pool's id.
    /// @param sender The address that called the PoolManager.
    /// @param delta The swap's balance delta, before the hook's adjustment.
    /// @param feeIsCurrency0 Whether the output, and so the cost, is in currency0.
    /// @param feeAmount Cost taken from the output.
    /// @param preSwapStockCut Cut taken from the input before the swap, if any.
    /// @param hookData Optional 32-byte recipient.
    function _emitSwapEvent(
        PoolId poolId,
        address sender,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bool feeIsCurrency0,
        uint256 feeAmount,
        uint256 preSwapStockCut,
        bytes calldata hookData
    ) private {
        bool specifiedIsCurrency0 = !feeIsCurrency0;
        // What the swapper paid in total: what reached the pool plus the cut taken before the swap.
        uint256 inputAmount =
            uint256(uint128(specifiedIsCurrency0 ? -delta.amount0() : -delta.amount1())) + preSwapStockCut;
        int128 grossOutRaw = feeIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 grossOut = grossOutRaw > 0 ? uint256(uint128(grossOutRaw)) : 0;
        uint256 netOut = grossOut > feeAmount ? grossOut - feeAmount : 0;

        // Routers may pass the end recipient here so indexers can attribute the trade. Purely informational.
        address to = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;

        emit Swap(
            PoolId.unwrap(poolId),
            sender,
            specifiedIsCurrency0 ? inputAmount : 0,
            specifiedIsCurrency0 ? 0 : inputAmount,
            feeIsCurrency0 ? netOut : 0,
            feeIsCurrency0 ? 0 : netOut,
            feeIsCurrency0 ? feeAmount : preSwapStockCut,
            feeIsCurrency0 ? preSwapStockCut : feeAmount,
            to
        );
    }

    /// @dev Withdraws `amount` of `currency` from the PoolManager to this contract and requires that exactly
    /// that amount arrived. A token that delivers less (a cut on transfer) makes every charged swap revert.
    /// @param currency The currency to take.
    /// @param token The same currency as a token address.
    /// @param amount The amount to take.
    function _takeExact(Currency currency, address token, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        poolManager.take(currency, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        // Every amount this hook routes onward must have arrived in full.
        if (received != amount) revert Overflow();
    }

    /// @dev The protocol's share of a cost rate, as its own rate.
    /// @param feeBps_ The full cost rate in basis points.
    /// @return The protocol's part of it in basis points.
    function _protocolShareBps(uint256 feeBps_) private pure returns (uint256) {
        return (feeBps_ * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
    }

    /// @dev Splits a stock cost between the treasury and the protocol and tells the treasury it arrived.
    /// The notification's result is ignored on purpose: the staking contract refuses it while one of its own
    /// guarded functions is running, and it picks the stock up on its next interaction either way.
    /// @param info The pool's registration record.
    /// @param feeAmount The stock to distribute.
    function _routeStockFee(LaunchInfo memory info, uint256 feeAmount) private {
        // 20% of the cost to the protocol, the other 80% to the treasury.
        uint256 protocolCut = (feeAmount * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
        uint256 remainder = feeAmount - protocolCut;
        if (remainder > 0) {
            IERC20(info.stockToken).safeTransfer(info.treasury, remainder);
            // Best-effort ping so the treasury adds the stock to its reward stream right away. Low-level and unchecked:
            // a treasury that refuses or reverts must never block a swap.
            (bool notified,) = info.treasury.call(abi.encodeWithSignature("notifyRewardAmount()"));
            notified;
        }
        if (protocolCut > 0) IERC20(info.stockToken).safeTransfer(info.protocol, protocolCut);
    }

    /// @notice Places a TWAMM order: sell `amountIn` evenly over `duration`.
    /// @dev Permissionless and uncapped. An order cannot be cancelled or changed. For a stock-selling order the
    /// protocol's share is charged up front on the full amount and the order is placed for the rest.
    /// @param params Pool key, direction, duration (a multiple of the interval) and amount.
    /// @return orderId The order's id.
    /// @return orderKey The order's key (owner, expiration, direction), needed to sync it later.
    function submitOrder(ITWAMM.SubmitOrderParams calldata params)
        external
        override
        returns (bytes32 orderId, OrderKey memory orderKey)
    {
        return _submitOrder(_chargeOrderInputFeeAndReduce(params));
    }

    /// @notice Places several TWAMM orders in one call, each charged like `submitOrder`.
    /// @param orders The orders to place.
    /// @return orderIds Their ids.
    /// @return orderKeys Their keys.
    function batchSubmitOrders(ITWAMM.SubmitOrderParams[] calldata orders)
        external
        override
        returns (bytes32[] memory orderIds, OrderKey[] memory orderKeys)
    {
        orderIds = new bytes32[](orders.length);
        orderKeys = new OrderKey[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            (orderIds[i], orderKeys[i]) = _submitOrder(_chargeOrderInputFeeAndReduce(orders[i]));
        }
    }

    /// @dev Takes the protocol's share from a stock-selling order's input and returns the order reduced by it.
    /// Orders that sell TST, and orders on unregistered pools, are returned unchanged.
    /// @param params The order as submitted.
    /// @return adjusted The order to actually place.
    function _chargeOrderInputFeeAndReduce(ITWAMM.SubmitOrderParams calldata params)
        private
        returns (ITWAMM.SubmitOrderParams memory adjusted)
    {
        adjusted = ITWAMM.SubmitOrderParams({
            key: params.key,
            zeroForOne: params.zeroForOne,
            duration: params.duration,
            amountIn: params.amountIn
        });

        PoolId poolId = params.key.toId();
        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return adjusted;

        // Only orders that sell stock are charged up front; orders that sell TST are charged entirely on proceeds.
        bool sellingStock = params.zeroForOne != info.tstIsCurrency0;
        if (!sellingStock) return adjusted;

        uint256 protocolCut = (params.amountIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;
        if (protocolCut == 0) return adjusted;

        // Straight from the order's owner to the protocol; the hook never holds it.
        IERC20(info.stockToken).safeTransferFrom(msg.sender, info.protocol, protocolCut);
        // The order is placed for what is left.
        adjusted.amountIn = params.amountIn - protocolCut;
        emit TwammOrderInputFeeCharged(PoolId.unwrap(poolId), msg.sender, protocolCut);
    }

    /// @notice Credits an order's owner with what the order has bought so far, less the flywheel cost.
    /// @dev Only the order's owner may call. Every route that pays out TWAMM proceeds goes through here, so the
    /// cost cannot be skipped. Proceeds in TST are charged the treasury's 80% share, which is burned; proceeds
    /// in stock are charged the full rate, split between treasury and protocol.
    /// @param params The pool key and the order's key.
    /// @return tokens0OwedDelta Currency0 newly credited to the owner, net of the cost.
    /// @return tokens1OwedDelta Currency1 newly credited to the owner, net of the cost.
    function sync(ITWAMM.SyncParams calldata params)
        public
        override
        returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta)
    {
        // The inherited sync checks the caller is the order's owner, executes pending orders and credits the gross
        // proceeds. Everything below only takes the cost back out of that credit.
        (tokens0OwedDelta, tokens1OwedDelta) = super.sync(params);

        PoolId poolId = params.key.toId();
        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return (tokens0OwedDelta, tokens1OwedDelta);

        // A zeroForOne order sells currency0 and buys currency1, and the other way round.
        bool boughtCurrency0 = !params.orderKey.zeroForOne;
        uint256 buyDelta = boughtCurrency0 ? tokens0OwedDelta : tokens1OwedDelta;
        if (buyDelta == 0) return (tokens0OwedDelta, tokens1OwedDelta);

        // The cost is charged in whatever the order buys. If that is TST, the protocol's share was already taken
        // from the stock at submission, so only the remaining 80% is charged here, and burned.
        bool feeIsTst = params.orderKey.zeroForOne != info.tstIsCurrency0;
        uint256 effectiveFeeBps = feeIsTst ? info.feeBps - _protocolShareBps(info.feeBps) : info.feeBps;
        uint256 feeAmount = (buyDelta * effectiveFeeBps) / BPS_DENOM;
        if (feeAmount == 0) return (tokens0OwedDelta, tokens1OwedDelta);

        Currency buyCurrency = boughtCurrency0 ? params.key.currency0 : params.key.currency1;
        // The inherited sync has just credited the gross proceeds; take the cost back out of that credit.
        tokensOwed[buyCurrency][params.orderKey.owner] -= feeAmount;
        if (boughtCurrency0) {
            tokens0OwedDelta -= feeAmount;
        } else {
            tokens1OwedDelta -= feeAmount;
        }

        if (feeIsTst) {
            IERC20(info.tstToken).safeTransfer(BURN_ADDRESS, feeAmount);
        } else {
            _routeStockFee(info, feeAmount);
        }

        emit TwammOrderProceedsFeeCharged(PoolId.unwrap(poolId), params.orderKey.owner, feeAmount, feeIsTst);
    }

    // Audit round 13 follow-up (gas-griefing lead, found and quantified via directed adversarial testing,
    // not a report claim): TWAMM._submitOrder and TWAMM.sync both call executeTWAMMOrders(key) directly, with
    // none of _safeTwammExecute's fail-open protection that beforeSwap/beforeAddLiquidity/beforeRemoveLiquidity
    // already have. Regular user orders have no minimum size (only SellRateCannotBeZero), so an attacker can
    // cheaply submit many orders staggered across distinct interval boundaries to inflate the gas cost of a
    // LATER submitOrder/liquidateTreasury/sync/claimLiquidatedTst call that has to catch up across the whole
    // window -- measured directly at ~46,000-53,000 extra gas per staggered segment, scaling linearly (not
    // worse) with segment count.
    //
    // Not a fund-safety issue and not a permanent block: the backlog is never lost, only deferred, and the
    // vendored executeTWAMMOrders(key, targetTimestamp) overload is ALREADY public and callable by anyone,
    // proven directly (test/StocksStaking.liquidationAdversarial.t.sol) to fully defuse an inflated backlog
    // in small, cheap, separate steps, after which the expensive call returns to its normal baseline cost.
    // This function only closes the OPERATIONAL gap that proof exposed: doing that manually needs one
    // transaction per step, which is exactly the friction a griefer is counting on someone not bothering
    // with. This bundles it into one transaction, capped by the caller's own maxSteps/gas choice the same way
    // any other transaction already is -- it grants no new capability beyond what calling the existing public
    // function repeatedly, by hand, already allowed.
    /// @notice Executes a pool's pending TWAMM orders in bounded steps.
    /// @param key The pool key.
    /// @param stepSeconds How far to advance per step.
    /// @param maxSteps The most steps to take in this call.
    function pumpTwammBacklog(PoolKey calldata key, uint256 stepSeconds, uint256 maxSteps) external {
        if (stepSeconds == 0 || maxSteps == 0) revert NothingToPump();
        // Walk forward from where execution last stopped, one step at a time, never past the present.
        uint256 target = this.lastVirtualOrderTimestamp(key.toId());
        if (target == 0) revert NothingToPump();
        for (uint256 i; i < maxSteps && target < block.timestamp; ++i) {
            target += stepSeconds;
            // The vendored execution rejects a target in the future.
            if (target > block.timestamp) target = block.timestamp;
            executeTWAMMOrders(key, target);
        }
    }

    /// @notice A pool's virtual reserves, derived from its current price and liquidity.
    /// @dev Live spot values, not a manipulation-resistant price.
    /// @param poolId The pool's id.
    /// @return reserve0 Virtual reserve of currency0.
    /// @return reserve1 Virtual reserve of currency1.
    /// @return lastUpdate Timestamp of the last accumulator update.
    function getReserves(PoolId poolId) public view returns (uint112 reserve0, uint112 reserve1, uint32 lastUpdate) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        // For a full-range position, reserves follow directly from liquidity and price: L / sqrtP and L * sqrtP.
        uint256 r0 = sqrtPriceX96 == 0 ? 0 : FullMath.mulDiv(uint256(liquidity), 1 << 96, sqrtPriceX96);
        uint256 r1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96);
        // Kept in the Uniswap v2 width. Not reachable with 18-decimal tokens of any realistic supply.
        if (r0 > type(uint112).max || r1 > type(uint112).max) revert Overflow();
        reserve0 = uint112(r0);
        reserve1 = uint112(r1);
        lastUpdate = blockTimestampLast[poolId];
    }

    /// @dev Adds the time elapsed at the previously cached reserves to both price accumulators, then caches the
    /// current reserves. Arithmetic is unchecked on purpose, as in Uniswap v2: consumers take differences.
    /// @param poolId The pool's id.
    function _updateAccumulator(PoolId poolId) private {
        // Timestamps wrap at 32 bits, as in Uniswap v2. The subtraction below is meant to wrap with them.
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast[poolId];
        }
        uint112 oldReserve0 = _reserve0Cached[poolId];
        uint112 oldReserve1 = _reserve1Cached[poolId];
        // Accumulate price * time at the reserves that held since the last update. Skipped on the first update and
        // within the same second.
        if (timeElapsed > 0 && blockTimestampLast[poolId] != 0 && oldReserve0 != 0 && oldReserve1 != 0) {
            unchecked {
                price0CumulativeLast[poolId] += (uint256(oldReserve1) << 112) / oldReserve0 * timeElapsed;
                price1CumulativeLast[poolId] += (uint256(oldReserve0) << 112) / oldReserve1 * timeElapsed;
            }
        }
        (uint112 newReserve0, uint112 newReserve1,) = getReserves(poolId);
        _reserve0Cached[poolId] = newReserve0;
        _reserve1Cached[poolId] = newReserve1;
        blockTimestampLast[poolId] = blockTimestamp;
    }

    /// @notice A pool's TST.
    /// @param poolId The pool's id.
    /// @return The TST address.
    function tstToken(PoolId poolId) external view returns (address) {
        return launches[poolId].tstToken;
    }

    /// @notice A pool's stock token.
    /// @param poolId The pool's id.
    /// @return The stock token address.
    function stockToken(PoolId poolId) external view returns (address) {
        return launches[poolId].stockToken;
    }

    /// @notice A pool's treasury (the token's staking contract).
    /// @param poolId The pool's id.
    /// @return The treasury address.
    function treasury(PoolId poolId) external view returns (address) {
        return launches[poolId].treasury;
    }

    /// @notice A pool's flywheel cost.
    /// @param poolId The pool's id.
    /// @return The cost in basis points.
    function feeBps(PoolId poolId) external view returns (uint256) {
        return launches[poolId].feeBps;
    }
}
