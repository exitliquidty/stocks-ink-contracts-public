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

contract StocksCurveFactory {
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
