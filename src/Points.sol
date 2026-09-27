// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Points (PNTS)
/// @notice Fixed-supply ERC-20 launched on Sepolia as the currency1 of the SwapPointsHook pool.
/// @dev The whole supply is minted once, in the constructor, to `msg.sender` (the launch factory).
/// There is no owner, no admin, no mint, no burn, no pause and no upgrade path: the bytecode
/// deployed is the bytecode that runs forever. The token itself carries no points logic; points
/// live in `SwapPointsHook` and are a separate, non-transferable tally.
///
/// PNTS is a Sepolia test toy. It has no value and nothing here promises a return.
contract Points is ERC20 {
    /// @notice 1,000,000,000 PNTS with 18 decimals, the only supply that will ever exist.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Mints the entire supply to the deployer. Takes no arguments by design so a factory
    /// can deploy it from creation code alone.
    constructor() ERC20("Points", "PNTS") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
