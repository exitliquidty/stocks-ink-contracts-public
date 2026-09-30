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

contract TSTToken is ERC20Votes {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient)
        ERC20(name_, symbol_)
        EIP712(name_, "1")
    {
        _mint(recipient, totalSupply_);
    }

    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public view override returns (string memory) {
        return ERC6372Utils.timestampClockMode(clock);
    }
}
