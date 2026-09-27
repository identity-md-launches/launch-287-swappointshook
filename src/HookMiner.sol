// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook at an address carrying exactly the wanted
/// permission bits. Pure and internal: it is used by tests and the deploy script, never on chain
/// by the hook itself.
library HookMiner {
    error NoSaltFound(uint160 flags, uint256 iterations);

    /// @notice The address CREATE2 produces for (`deployer`, `salt`, `initCodeHash`).
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Searches salts 0, 1, 2, ... until one yields an address whose low 14 bits equal `flags`.
    /// @param deployer The address that will execute CREATE2 (the factory, a test, or the
    /// deterministic deployer proxy a forge script broadcasts through).
    /// @param flags The permission bits the address must carry, e.g. `HookFlags.SWAP_POINTS_HOOK`.
    /// @param creationCode The full init code, constructor arguments already appended.
    /// @param maxIterations Upper bound on the search; two bits out of fourteen need ~16k tries on average.
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 maxIterations)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < maxIterations; ++i) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hookAddress, flags)) return (hookAddress, salt);
        }
        revert NoSaltFound(flags, maxIterations);
    }
}
