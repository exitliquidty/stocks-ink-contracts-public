// SPDX-License-Identifier: UNLICENSED
// Derived from akshatmittal/v4-twamm-hook, used with the author's permission. Do not redistribute.

pragma solidity ^0.8.15;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {OrderPool} from "./libraries/OrderPool.sol";

interface ITWAMM {

    error PoolWithNativeNotSupported();

    error InvalidTargetTimestamp();

    error InvalidExpirationInterval();

    error ExpirationNotOnInterval(uint256 expiration);

    error ExpirationLessThanBlockTime(uint256 expiration);

    error NotInitialized();

    error OrderAlreadyExists(OrderKey orderKey);

    error OrderDoesNotExist(OrderKey orderKey);

    error SellRateCannotBeZero();

    error HookKilled();

    error Unauthorized();

    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    struct TWAMMState {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => Order) orders;
    }

    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    struct SyncParams {
        PoolKey key;
        OrderKey orderKey;
    }

    struct SubmitOrderParams {
        PoolKey key;
        bool zeroForOne;
        uint256 duration;
        uint256 amountIn;
    }

    event SubmitOrder(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        address indexed owner,
        uint256 amountIn,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    event ClaimTokens(Currency indexed token, address indexed owner, uint256 amount);

    event SyncOrder(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        bool assetsRemoved,
        uint256 tokens0OwedDelta,
        uint256 tokens1OwedDelta,
        uint256 earningsFactorLast
    );

    event Fulfillment(PoolId indexed poolId, uint256 sellRate0for1, uint256 sellRate1for0);

    event SwapExecuted(PoolId indexed poolId, BalanceDelta delta);

    function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256 timestamp);

    function killHook() external;

    function getOrder(PoolKey calldata poolKey, OrderKey calldata orderKey)
        external
        view
        returns (Order memory order);

    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent);

    function batchSyncAndClaimTokens(SyncParams[] calldata params, Currency[] calldata currencies)
        external
        returns (uint256[] memory tokensClaimed);

    function syncAndClaimTokens(SyncParams calldata params)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);

    function submitOrder(SubmitOrderParams calldata params)
        external
        returns (bytes32 orderId, OrderKey memory orderKey);

    function batchSubmitOrders(SubmitOrderParams[] calldata orders)
        external
        returns (bytes32[] memory orderIds, OrderKey[] memory orderKeys);

    function sync(SyncParams calldata params) external returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta);

    function claimTokensByPoolKey(PoolKey calldata key)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);

    function claimTokensByCurrencies(Currency[] calldata currencies)
        external
        returns (uint256[] memory tokensClaimed);

    function executeTWAMMOrders(PoolKey memory key) external;

    function executeTWAMMOrders(PoolKey memory key, uint256 targetTimestamp) external;
}
