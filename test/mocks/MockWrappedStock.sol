// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Minimal stand-in for the real xStocks ERC-4626 wrapper (see frontend/lib/
/// stockWrapper.ts) -- built on OpenZeppelin's own audited ERC4626, not hand-rolled. A dividend is
/// simulated in tests simply by minting the underlying MockERC20 raw asset straight to this
/// vault's own address (no new shares issued) -- exactly how a real dividend/rebase raises the
/// wrapper's exchange rate: existing shares become redeemable for more of the underlying asset.
contract MockWrappedStock is ERC4626 {
    constructor(IERC20 asset_) ERC20("Wrapped Stock", "wSTOCK") ERC4626(asset_) {}
}
