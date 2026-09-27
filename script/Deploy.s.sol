// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Points} from "../src/Points.sol";
import {SwapPointsHook} from "../src/SwapPointsHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title Deploy
/// @notice Reference deployment of PNTS and SwapPointsHook. The production launch goes through the
/// IdentityMD factory, which deploys both from the attested creation code and mines the hook salt
/// itself; this script exists so the same shape can be rehearsed on a fork or a devnet, and so the
/// tests can exercise `deploy` directly. It reads no environment variables: the network and the
/// signer come from the forge command line, everything else is a constant below.
///
/// Example (Sepolia, dry run):
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC --sender <deployer>
/// Add `--broadcast --private-key ...` to send. Nothing here is authorised by this repository.
contract Deploy is Script {
    /// @notice The Uniswap v4 PoolManager on Sepolia (chain id 11155111).
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice The deterministic CREATE2 proxy forge broadcasts salted creations through.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Upper bound on the salt search; 0x1040 needs ~16k tries on average.
    uint256 public constant MAX_SALT_ITERATIONS = 2_000_000;

    function run() external returns (Points token, SwapPointsHook hook) {
        vm.startBroadcast();
        (token, hook) = deploy(SEPOLIA_POOL_MANAGER, CREATE2_DEPLOYER);
        vm.stopBroadcast();
    }

    /// @notice Init code for the hook bound to `poolManager`, the bytes a factory hashes and attests.
    function hookCreationCode(address poolManager) public pure returns (bytes memory) {
        return abi.encodePacked(type(SwapPointsHook).creationCode, abi.encode(poolManager));
    }

    /// @notice Mines the salt that places the hook on an address carrying exactly 0x1040 when
    /// `create2Deployer` executes CREATE2.
    function mineSalt(address poolManager, address create2Deployer)
        public
        pure
        returns (address hookAddress, bytes32 salt)
    {
        return HookMiner.find(
            create2Deployer, HookFlags.SWAP_POINTS_HOOK, hookCreationCode(poolManager), MAX_SALT_ITERATIONS
        );
    }

    /// @notice Deploys the token (supply to the caller of this script) and the hook at its mined address.
    /// @param poolManager The PoolManager the hook will trust.
    /// @param create2Deployer The address that will execute the CREATE2: the forge proxy when
    /// broadcasting, or this contract when called directly from a test.
    function deploy(address poolManager, address create2Deployer) public returns (Points token, SwapPointsHook hook) {
        token = new Points();
        (address predicted, bytes32 salt) = mineSalt(poolManager, create2Deployer);
        hook = new SwapPointsHook{salt: salt}(IPoolManager(poolManager));
        require(address(hook) == predicted, "hook address mismatch");
    }
}
