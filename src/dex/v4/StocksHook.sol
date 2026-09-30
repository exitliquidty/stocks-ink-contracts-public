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

contract StocksHook is TWAMM {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct LaunchInfo {
        bool registered;
        bool tstIsCurrency0;
        address tstToken;
        address stockToken;
        address treasury;
        address protocol;
        uint256 feeBps;
    }

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 2_000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable poolDeployer;

    mapping(PoolId => LaunchInfo) public launches;
    mapping(PoolId => uint256) public price0CumulativeLast;
    mapping(PoolId => uint256) public price1CumulativeLast;
    mapping(PoolId => uint32) public blockTimestampLast;
    mapping(PoolId => uint112) private _reserve0Cached;
    mapping(PoolId => uint112) private _reserve1Cached;

    event PoolRegistered(
        bytes32 indexed poolId, address tstToken, address stockToken, address treasury, address protocol, uint256 feeBps
    );
    event ProtocolStockCutTakenPreSwap(bytes32 indexed poolId, uint256 stockIn, uint256 protocolStockCut);

    event TwammOrderInputFeeCharged(bytes32 indexed poolId, address indexed owner, uint256 protocolStockCut);

    event TwammOrderProceedsFeeCharged(bytes32 indexed poolId, address indexed owner, uint256 feeAmount, bool feeIsTst);
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
    error NotPoolDeployer();
    error ZeroAddress();
    error IdenticalTokens();
    error FeeTooHigh();
    error AlreadyRegistered();
    error InvalidPoolKey();
    error NotRegisteredBeforeInitialize();
    error Overflow();
    error ExactOutputNotSupported();
    error TwammExecutionOutOfGas();
    error NonFullRangeLiquidityNotAllowed();
    error PreSwapCutWouldExceedActualFill();
    error NothingToPump();

    modifier onlyPoolDeployer() {
        if (msg.sender != poolDeployer) revert NotPoolDeployer();
        _;
    }

    constructor(IPoolManager poolManager_, address poolDeployer_, uint256 expirationInterval_)
        TWAMM(poolManager_, expirationInterval_, msg.sender)
    {
        if (poolDeployer_ == address(0)) revert ZeroAddress();
        poolDeployer = poolDeployer_;
        renounceOwnership();
    }

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
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();

        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == tstToken_;
        if (!tstIsCurrency0 && Currency.unwrap(key.currency1) != tstToken_) revert InvalidPoolKey();
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

        blockTimestampLast[poolId] = uint32(block.timestamp % 2 ** 32);

        emit PoolRegistered(PoolId.unwrap(poolId), tstToken_, stockToken_, treasury_, protocol_, feeBps_);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != poolDeployer) revert NotPoolDeployer();
        if (!launches[key.toId()].registered) revert NotRegisteredBeforeInitialize();

        if (key.currency0.isAddressZero()) revert PoolWithNativeNotSupported();
        initialize(_getTWAMM(key));

        return IHooks.beforeInitialize.selector;
    }

    /// @dev Shared by beforeSwap, beforeAddLiquidity and beforeRemoveLiquidity: fails open (lets the caller's action
    /// proceed against whatever TWAMM state currently exists) unless the failure itself looks like deliberate gas
    /// gaming (see the F-1 audit history on beforeSwap -- the same reasoning now covers all three entry points
    /// instead of leaving beforeAddLiquidity fully unguarded and beforeRemoveLiquidity guarded without the gas check).
    function _safeTwammExecute(PoolKey calldata key) private {
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
    function beforeAddLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (params.tickLower != TickMath.minUsableTick(key.tickSpacing) || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)) {
            revert NonFullRangeLiquidityNotAllowed();
        }
        _safeTwammExecute(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _safeTwammExecute(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        _safeTwammExecute(key);

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
        if (!feeIsTst) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 stockIn = uint256(-params.amountSpecified);
        uint256 protocolStockCut = (stockIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;
        if (protocolStockCut == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (protocolStockCut > uint256(uint128(type(int128).max))) revert Overflow();

        Currency stockCurrency = specifiedIsCurrency0 ? key.currency0 : key.currency1;
        _takeExact(stockCurrency, info.stockToken, protocolStockCut);
        IERC20(info.stockToken).safeTransfer(info.protocol, protocolStockCut);

        emit ProtocolStockCutTakenPreSwap(PoolId.unwrap(poolId), stockIn, protocolStockCut);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(protocolStockCut)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        PoolId poolId = key.toId();
        _updateAccumulator(poolId);

        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return (IHooks.afterSwap.selector, 0);

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool feeIsCurrency0 = !specifiedIsCurrency0;
        bool feeIsTst = feeIsCurrency0 == info.tstIsCurrency0;

        uint256 preSwapStockCut;
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

        int128 unspecifiedAmount = feeIsCurrency0 ? delta.amount0() : delta.amount1();
        if (unspecifiedAmount <= 0) {
            _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, 0, preSwapStockCut, hookData);
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 effectiveFeeBps = feeIsTst ? info.feeBps - _protocolShareBps(info.feeBps) : info.feeBps;

        uint256 grossOut = uint256(uint128(unspecifiedAmount));
        uint256 feeAmount = (grossOut * effectiveFeeBps) / BPS_DENOM;
        if (feeAmount == 0) {
            _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, 0, preSwapStockCut, hookData);
            return (IHooks.afterSwap.selector, 0);
        }

        Currency feeCurrency = feeIsCurrency0 ? key.currency0 : key.currency1;
        address feeCurrencyAddr = Currency.unwrap(feeCurrency);
        _takeExact(feeCurrency, feeCurrencyAddr, feeAmount);

        if (feeIsTst) {
            IERC20(info.tstToken).safeTransfer(BURN_ADDRESS, feeAmount);
        } else {
            _routeStockFee(info, feeAmount);
        }

        _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, feeAmount, preSwapStockCut, hookData);
        return (IHooks.afterSwap.selector, int128(uint128(feeAmount)));
    }

    function _emitSwapEvent(
        PoolId poolId,
        address sender,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bool feeIsCurrency0,
        uint256 feeAmount,
        uint256 preSwapStockCut,
        bytes calldata hookData
    ) private {
        bool specifiedIsCurrency0 = !feeIsCurrency0;
        uint256 inputAmount =
            uint256(uint128(specifiedIsCurrency0 ? -delta.amount0() : -delta.amount1())) + preSwapStockCut;
        int128 grossOutRaw = feeIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 grossOut = grossOutRaw > 0 ? uint256(uint128(grossOutRaw)) : 0;
        uint256 netOut = grossOut > feeAmount ? grossOut - feeAmount : 0;

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

    function _takeExact(Currency currency, address token, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        poolManager.take(currency, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert Overflow();
    }

    function _protocolShareBps(uint256 feeBps_) private pure returns (uint256) {
        return (feeBps_ * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
    }

    function _routeStockFee(LaunchInfo memory info, uint256 feeAmount) private {
        uint256 protocolCut = (feeAmount * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
        uint256 remainder = feeAmount - protocolCut;
        if (remainder > 0) {
            IERC20(info.stockToken).safeTransfer(info.treasury, remainder);
            info.treasury.call(abi.encodeWithSignature("notifyRewardAmount()"));
        }
        if (protocolCut > 0) IERC20(info.stockToken).safeTransfer(info.protocol, protocolCut);
    }

    function submitOrder(ITWAMM.SubmitOrderParams calldata params)
        external
        override
        returns (bytes32 orderId, OrderKey memory orderKey)
    {
        return _submitOrder(_chargeOrderInputFeeAndReduce(params));
    }

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

        bool sellingStock = params.zeroForOne != info.tstIsCurrency0;
        if (!sellingStock) return adjusted;

        uint256 protocolCut = (params.amountIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;
        if (protocolCut == 0) return adjusted;

        IERC20(info.stockToken).safeTransferFrom(msg.sender, info.protocol, protocolCut);
        adjusted.amountIn = params.amountIn - protocolCut;
        emit TwammOrderInputFeeCharged(PoolId.unwrap(poolId), msg.sender, protocolCut);
    }

    function sync(ITWAMM.SyncParams calldata params)
        public
        override
        returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta)
    {
        (tokens0OwedDelta, tokens1OwedDelta) = super.sync(params);

        PoolId poolId = params.key.toId();
        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return (tokens0OwedDelta, tokens1OwedDelta);

        bool boughtCurrency0 = !params.orderKey.zeroForOne;
        uint256 buyDelta = boughtCurrency0 ? tokens0OwedDelta : tokens1OwedDelta;
        if (buyDelta == 0) return (tokens0OwedDelta, tokens1OwedDelta);

        bool feeIsTst = params.orderKey.zeroForOne != info.tstIsCurrency0;
        uint256 effectiveFeeBps = feeIsTst ? info.feeBps - _protocolShareBps(info.feeBps) : info.feeBps;
        uint256 feeAmount = (buyDelta * effectiveFeeBps) / BPS_DENOM;
        if (feeAmount == 0) return (tokens0OwedDelta, tokens1OwedDelta);

        Currency buyCurrency = boughtCurrency0 ? params.key.currency0 : params.key.currency1;
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
    function pumpTwammBacklog(PoolKey calldata key, uint256 stepSeconds, uint256 maxSteps) external {
        if (stepSeconds == 0 || maxSteps == 0) revert NothingToPump();
        uint256 target = this.lastVirtualOrderTimestamp(key.toId());
        if (target == 0) revert NothingToPump();
        for (uint256 i; i < maxSteps && target < block.timestamp; ++i) {
            target += stepSeconds;
            if (target > block.timestamp) target = block.timestamp;
            executeTWAMMOrders(key, target);
        }
    }

    function getReserves(PoolId poolId) public view returns (uint112 reserve0, uint112 reserve1, uint32 lastUpdate) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        uint256 r0 = sqrtPriceX96 == 0 ? 0 : FullMath.mulDiv(uint256(liquidity), 1 << 96, sqrtPriceX96);
        uint256 r1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96);
        if (r0 > type(uint112).max || r1 > type(uint112).max) revert Overflow();
        reserve0 = uint112(r0);
        reserve1 = uint112(r1);
        lastUpdate = blockTimestampLast[poolId];
    }

    function _updateAccumulator(PoolId poolId) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast[poolId];
        }
        uint112 oldReserve0 = _reserve0Cached[poolId];
        uint112 oldReserve1 = _reserve1Cached[poolId];
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

    function tstToken(PoolId poolId) external view returns (address) {
        return launches[poolId].tstToken;
    }

    function stockToken(PoolId poolId) external view returns (address) {
        return launches[poolId].stockToken;
    }

    function treasury(PoolId poolId) external view returns (address) {
        return launches[poolId].treasury;
    }

    function feeBps(PoolId poolId) external view returns (uint256) {
        return launches[poolId].feeBps;
    }
}
