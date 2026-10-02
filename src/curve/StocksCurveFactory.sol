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

import {StocksCurve} from "./StocksCurve.sol";

/// @title StocksCurveFactory
/// @notice Deploys bonding curves. It exists only to keep the curve's creation code out of the launch
/// factory's own bytecode.
/// @dev Stateless and permissionless. A curve records whoever called `deploy` as its `factory`, and the price
/// attestation it verifies is signed over that same address, so a curve deployed by anyone other than the real
/// launch factory cannot reuse a real attestation and is never recognised by the graduator.
contract StocksCurveFactory {
    /// @notice Deploys a curve whose factory is the caller.
    /// @dev All validation happens in the curve's constructor; this function only forwards.
    /// @param tstToken The TST the curve will sell.
    /// @param stockToken The tokenized stock the curve is priced in.
    /// @param trustedSigner Signer the price attestation must recover to.
    /// @param price Attested USD price of one whole stock token, 18 decimals.
    /// @param priceTimestamp Time of the attestation.
    /// @param signature Signature over (caller, stockToken, price, priceTimestamp).
    /// @param rewardsDuration Reward period for the staking contract created at graduation.
    /// @param graduationUsdThreshold USD (18 decimals) of stock the curve must collect to graduate.
    /// @param minRewardsDuration Lower bound `rewardsDuration` is checked against.
    /// @param maxRewardsDuration Upper bound `rewardsDuration` is checked against.
    /// @return curve The new curve.
    function deploy(
        address tstToken,
        address stockToken,
        address trustedSigner,
        uint256 price,
        uint256 priceTimestamp,
        bytes calldata signature,
        uint256 rewardsDuration,
        uint256 graduationUsdThreshold,
        uint256 minRewardsDuration,
        uint256 maxRewardsDuration
    ) external returns (address curve) {
        curve = address(
            new StocksCurve(
                tstToken,
                stockToken,
                trustedSigner,
                price,
                priceTimestamp,
                signature,
                rewardsDuration,
                msg.sender,
                graduationUsdThreshold,
                minRewardsDuration,
                maxRewardsDuration
            )
        );
    }
}
