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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {ERC6372Utils} from "@openzeppelin/contracts/utils/ERC6372Utils.sol";

/// @title TSTToken
/// @notice A Tokenized Stock Treasury token: a fixed-supply ERC20 with vote checkpoints.
/// @dev There is no mint or burn function. "Burning" elsewhere in the protocol means transferring to the dead
/// address, so `totalSupply()` never changes and circulating supply is always computed as total supply minus
/// the dead address's balance. Transfers make no external calls. As with any ERC20Votes token, a balance only
/// counts as voting power once its holder has delegated (to itself or to someone else).
contract TSTToken is ERC20Votes {
    /// @notice Mints the whole supply once.
    /// @dev `name_` also becomes the EIP-712 domain name, which this OpenZeppelin release stores as a short
    /// string, so a name longer than 31 bytes reverts here.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param totalSupply_ The entire supply.
    /// @param recipient Receives the entire supply (the launch factory, which forwards it to the curve).
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient)
        ERC20(name_, symbol_)
        EIP712(name_, "1")
    {
        _mint(recipient, totalSupply_);
    }

    /// @notice The clock used for vote checkpoints: block timestamp, not block number.
    /// @dev Timestamps keep governance durations meaningful on a chain whose block time may change.
    /// @return The current block timestamp.
    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    /// @notice Machine-readable description of `clock()`, per ERC-6372.
    /// @return The string "mode=timestamp".
    function CLOCK_MODE() public view override returns (string memory) {
        return ERC6372Utils.timestampClockMode(clock);
    }
}
