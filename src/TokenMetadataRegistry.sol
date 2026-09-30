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

contract TokenMetadataRegistry {
    mapping(address => string) public metadataURI;

    mapping(address => bool) public metadataDecided;

    event MetadataURISet(address indexed token, string uri);

    error AlreadySet();
    error TokenHasNoCode();

    function setMetadataURI(address token, string calldata uri) external {
        if (token.code.length == 0) revert TokenHasNoCode();
        if (metadataDecided[token]) revert AlreadySet();
        metadataDecided[token] = true;
        metadataURI[token] = uri;
        emit MetadataURISet(token, uri);
    }
}
