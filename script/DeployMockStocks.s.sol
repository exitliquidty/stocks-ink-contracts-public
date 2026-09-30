// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice LOCAL TEST ONLY. Deploys a few mock ERC20s standing in for xStocks so the frontend's
/// stock-select dropdown has real, working options on a local Anvil chain. Not for Ink — real
/// xStock addresses replace these once confirmed.
contract MockStock is ERC20 {
    constructor(string memory name_, string memory symbol_, address mintTo, uint256 amount)
        ERC20(name_, symbol_)
    {
        _mint(mintTo, amount);
    }
}

contract DeployMockStocks is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        address tsla = address(new MockStock("Tesla xStock", "TSLAx", deployer, 1_000_000e18));
        address aapl = address(new MockStock("Apple xStock", "AAPLx", deployer, 1_000_000e18));
        address nvda = address(new MockStock("NVIDIA xStock", "NVDAx", deployer, 1_000_000e18));

        vm.stopBroadcast();

        console.log("TSLAx:", tsla);
        console.log("AAPLx:", aapl);
        console.log("NVDAx:", nvda);
    }
}
