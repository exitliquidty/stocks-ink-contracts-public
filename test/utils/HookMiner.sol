// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Hand-rolled in place of vendoring `Uniswap/v4-periphery`'s test-utils copy -- see
/// BaseHook.sol's own docstring for why that dependency isn't installed on this machine (Windows
/// MAX_PATH, deeply nested submodules). This is the same well-known, short, standard CREATE2
/// salt-mining pattern used across the V4 hook ecosystem: brute-force salts from a deployer's
/// nonce-independent CREATE2 address space until the low 14 bits (the hook permission flags) match
/// what's wanted, starting from two disjoint offsets so two hooks mined in the same test run never
/// collide on a salt.
library HookMiner {
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);
    uint256 internal constant MAX_LOOP = 200_000;

    error HookAddressMiningFailed();

    /// @param deployer The address that will CREATE2-deploy the hook (a factory/create2 deployer,
    /// or the test contract itself if it deploys directly via `new Hook{salt: salt}(...)`).
    /// @param flags The exact permission bits wanted in the deployed address's low 14 bits.
    /// @param creationCode The contract's creation bytecode (`type(Hook).creationCode`).
    /// @param constructorArgs ABI-encoded constructor arguments, appended to `creationCode` the
    /// same way Solidity's own `new` does.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        flags = flags & FLAG_MASK;

        for (uint256 i; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = _computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert HookAddressMiningFailed();
    }

    function _computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
