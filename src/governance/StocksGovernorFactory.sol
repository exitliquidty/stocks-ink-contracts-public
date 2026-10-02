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

/// @title StocksGovernorFactory
/// @notice Deploys governors. It exists only to keep the governor creation code out of the curve.
/// @dev Stateless and permissionless. A governor has power only where another contract names it as its
/// governor, so one deployed by a stranger controls nothing.
contract StocksGovernorFactory {
    /// @notice Deploys a governor.
    /// @dev The governor's own constructor enforces its floors and reverts on a bad value.
    /// @param name_ Governor name. Also its EIP-712 domain name, so it must fit in 31 bytes.
    /// @param token The vote token.
    /// @param votingDelay Seconds between proposal creation and the vote snapshot.
    /// @param votingPeriod Seconds the vote stays open.
    /// @param proposalThreshold Proposal threshold in basis points of circulating supply.
    /// @param quorumNumerator Quorum as a percentage of circulating supply.
    /// @return governor The new governor.
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
