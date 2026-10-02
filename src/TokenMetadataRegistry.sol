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

/// @title TokenMetadataRegistry
/// @notice A shared, write-once record of each token's metadata URI.
/// @dev Deployed once and reused by every factory generation. Anyone may write an entry, but only once per
/// token and only for an address that already has code. The launch factory writes a new token's entry in the
/// same transaction that creates it, so no one else can get there first.
contract TokenMetadataRegistry {
    /// @notice The metadata URI recorded for a token. Empty if none was recorded or an empty one was chosen.
    mapping(address => string) public metadataURI;

    /// @notice Whether a token's entry has been written. Tracked separately so an empty URI is still final.
    mapping(address => bool) public metadataDecided;

    /// @notice Emitted when a token's entry is written.
    /// @param token The token.
    /// @param uri The URI recorded for it.
    event MetadataURISet(address indexed token, string uri);

    /// @notice The token's entry has already been written.
    error AlreadySet();
    /// @notice The address has no code, so it cannot be a deployed token.
    error TokenHasNoCode();

    /// @notice Records a token's metadata URI, permanently.
    /// @dev The code-size check is what stops an entry being claimed for a token address before that token is
    /// deployed, which would otherwise make the launch that deploys it revert on every attempt.
    /// @param token The token to record metadata for. Must already be deployed.
    /// @param uri The URI to record. May be empty.
    function setMetadataURI(address token, string calldata uri) external {
        if (token.code.length == 0) revert TokenHasNoCode();
        if (metadataDecided[token]) revert AlreadySet();
        metadataDecided[token] = true;
        metadataURI[token] = uri;
        emit MetadataURISet(token, uri);
    }
}
