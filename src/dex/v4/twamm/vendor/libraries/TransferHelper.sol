// SPDX-License-Identifier: GPL-2.0-or-later
// Taken from the Uniswap v4 codebase.

pragma solidity ^0.8.15;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

library TransferHelper {

    function safeTransfer(IERC20Minimal token, address to, uint256 value) internal {
        bool success;

        assembly {

            let freeMemoryPointer := mload(0x40)

            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), to)
            mstore(add(freeMemoryPointer, 36), value)

            success :=
                and(

                    or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),

                    call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
                )
        }

        require(success, "TRANSFER_FAILED");
    }

    function safeTransferFrom(IERC20Minimal token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "STF");
    }
}
