// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Mock replicating USDT's real, notorious behavior: transfer/transferFrom/approve
/// return nothing at all (no bool), which breaks any integration using the plain IERC20
/// interface's `require(token.transfer(...))` pattern instead of SafeERC20. Every contract
/// here uses SafeERC20 specifically because of tokens like this in production.
contract NoReturnValueToken {
    string public name = "Tether-like";
    string public symbol = "USDx";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
