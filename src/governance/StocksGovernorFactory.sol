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

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {StocksGovernor} from "./StocksGovernor.sol";

contract StocksGovernorFactory {
    function deploy(
        string memory name_,
        IVotes token,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumNumerator
    ) external returns (address governor) {
        governor =
            address(new StocksGovernor(name_, token, votingDelay, votingPeriod, proposalThreshold, quorumNumerator));
    }
}
