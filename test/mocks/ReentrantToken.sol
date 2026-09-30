// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock token whose transferFrom calls back into an arbitrary target mid-transfer —
/// simulates a malicious/hook-enabled ERC20 (ERC777-style) used as `stockToken`, to prove
/// MemeLaunchFactory's reentrancy guard holds even though standard ERC20s can't do this.
contract ReentrantToken is ERC20 {
    address public reenterTarget;
    bytes public reenterCalldata;
    bool public armed;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterCalldata = data;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false; // one-shot, avoid infinite recursion
            (bool ok,) = reenterTarget.call(reenterCalldata);
            require(ok, "reenter call failed");
        }
        return super.transferFrom(from, to, amount);
    }
}
