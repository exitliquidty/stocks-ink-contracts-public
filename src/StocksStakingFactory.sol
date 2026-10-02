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

/// @title StocksStakingFactory
/// @notice Deploys staking contracts. It exists only to keep the staking creation code out of the curve.
/// @dev Stateless and permissionless. The caller becomes the new contract's `curve`, the only address allowed
/// to set its pool, so a staking contract deployed by a stranger has no connection to any real launch.
contract StocksStakingFactory {
    /// @notice Deploys a staking contract whose `curve` is the caller.
    /// @param tstToken The token that is staked.
    /// @param stockToken The token rewards are paid in and the treasury holds.
    /// @param rewardsDuration Initial reward period, in seconds.
    /// @param governor The only address allowed to call the governed functions.
    /// @param hook The v4 hook, used for treasury liquidation orders.
    /// @return staking The new staking contract.
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
