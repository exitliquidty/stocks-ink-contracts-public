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

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksHook} from "./StocksHook.sol";

/// @title StocksPoolView
/// @notice A read-only handle for one graduated pool, giving it an address of its own.
/// @dev A Uniswap v4 pool lives inside the PoolManager and has no address. Front ends and indexers that
/// expect a pair contract are given this instead: it stores the pool key and forwards every read to the hook.
/// It holds no funds and has no state-changing function.
contract StocksPoolView {
    using PoolIdLibrary for PoolKey;

    /// @notice The hook the pool was created on.
    StocksHook public immutable hook;
    /// @notice The pool's id inside the PoolManager.
    PoolId public immutable poolId;
    /// @dev The full pool key. Kept in storage because a struct cannot be immutable.
    PoolKey private _poolKey;

    /// @notice Records the pool this view stands for.
    /// @param hook_ The hook the pool was created on.
    /// @param poolKey_ The pool's key.
    constructor(StocksHook hook_, PoolKey memory poolKey_) {
        hook = hook_;
        _poolKey = poolKey_;
        poolId = poolKey_.toId();
    }

    /// @notice The pool's key, as needed to trade against it through the PoolManager.
    /// @return The pool key.
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice The pool's lower-sorted token.
    /// @return Address of currency0.
    function token0() external view returns (address) {
        return Currency.unwrap(_poolKey.currency0);
    }

    /// @notice The pool's higher-sorted token.
    /// @return Address of currency1.
    function token1() external view returns (address) {
        return Currency.unwrap(_poolKey.currency1);
    }

    /// @notice The TST side of the pool.
    /// @return The TST address registered with the hook.
    function tstToken() external view returns (address) {
        return hook.tstToken(poolId);
    }

    /// @notice The stock side of the pool.
    /// @return The stock token address registered with the hook.
    function stockToken() external view returns (address) {
        return hook.stockToken(poolId);
    }

    /// @notice Where the treasury's share of the flywheel cost is sent: the token's staking contract.
    /// @return The treasury address registered with the hook.
    function treasury() external view returns (address) {
        return hook.treasury(poolId);
    }

    /// @notice The flywheel cost charged on trades in this pool, in basis points.
    /// @return The cost registered with the hook.
    function feeBps() external view returns (uint256) {
        return hook.feeBps(poolId);
    }

    /// @notice The pool's virtual reserves, derived from its current price and liquidity.
    /// @dev Live spot values. They move with every trade and are not a manipulation-resistant price.
    /// @return reserve0 Virtual reserve of currency0.
    /// @return reserve1 Virtual reserve of currency1.
    /// @return blockTimestampLast Timestamp of the last accumulator update.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return hook.getReserves(poolId);
    }

    /// @notice Cumulative price of currency0 in currency1, in the Uniswap v2 format.
    /// @dev Updated only on swaps that pass through the hook; the hook's own TWAMM swaps do not update it.
    /// @return The accumulator value.
    function price0CumulativeLast() external view returns (uint256) {
        return hook.price0CumulativeLast(poolId);
    }

    /// @notice Cumulative price of currency1 in currency0, in the Uniswap v2 format.
    /// @dev Same caveat as `price0CumulativeLast`.
    /// @return The accumulator value.
    function price1CumulativeLast() external view returns (uint256) {
        return hook.price1CumulativeLast(poolId);
    }
}
