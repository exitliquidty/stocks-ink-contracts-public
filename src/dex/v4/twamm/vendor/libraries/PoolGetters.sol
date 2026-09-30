// SPDX-License-Identifier: UNLICENSED
// Derived from akshatmittal/v4-twamm-hook, used with the author's permission. Do not redistribute.

pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";

library PoolGetters {
    using StateLibrary for IPoolManager;

    function getNextInitializedTickWithinOneWord(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);

                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);

                uint256 tickBitmap = poolManager.getTickBitmap(poolId, wordPos);
                uint256 masked = tickBitmap & mask;

                initialized = masked != 0;

                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {

                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);

                uint256 mask = ~((1 << bitPos) - 1);
                uint256 tickBitmap = poolManager.getTickBitmap(poolId, wordPos);
                uint256 masked = tickBitmap & mask;

                initialized = masked != 0;

                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
