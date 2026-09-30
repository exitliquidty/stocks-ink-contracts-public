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

import {StocksStaking} from "./StocksStaking.sol";

contract StocksStakingFactory {
    function deploy(
        address tstToken,
        address stockToken,
        uint256 rewardsDuration,
        address governor,
        address hook
    ) external returns (address staking) {
        staking = address(
            new StocksStaking(tstToken, stockToken, rewardsDuration, governor, hook, msg.sender)
        );
    }
}
