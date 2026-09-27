// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Points} from "../src/Points.sol";
import {SwapPointsHook} from "../src/SwapPointsHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployScriptTest is Test {
    Deploy deployer;
    PoolManager manager;

    function setUp() public {
        deployer = new Deploy();
        manager = new PoolManager(address(this));
    }

    function test_deployPlacesTheHookOnItsFlagsAndMintsToTheDeployer() public {
        (Points token, SwapPointsHook hook) = deployer.deploy(address(manager), address(deployer));

        assertEq(HookFlags.flagsOf(address(hook)), 0x1040);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(deployer)), token.totalSupply(), "supply goes to whoever deploys");
    }

    function test_mineSaltIsDeterministicForTheForgeCreate2Proxy() public view {
        (address a, bytes32 s) = deployer.mineSalt(deployer.SEPOLIA_POOL_MANAGER(), deployer.CREATE2_DEPLOYER());
        (address b, bytes32 t) = deployer.mineSalt(deployer.SEPOLIA_POOL_MANAGER(), deployer.CREATE2_DEPLOYER());
        assertEq(a, b);
        assertEq(s, t);
        assertTrue(HookFlags.matches(a, HookFlags.SWAP_POINTS_HOOK));
    }

    function test_constants() public view {
        assertEq(deployer.SEPOLIA_POOL_MANAGER(), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(deployer.CREATE2_DEPLOYER(), 0x4e59b44847b379578588920cA78FbF26c0B4956C);
    }
}
