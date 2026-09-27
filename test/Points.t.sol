// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Points} from "../src/Points.sol";

contract PointsTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    Points token;
    address deployer = makeAddr("factory");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(deployer);
        token = new Points();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Points");
        assertEq(token.symbol(), "PNTS");
        assertEq(token.decimals(), 18);
    }

    function test_wholeSupplyMintedToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_transferMovesExactlyWhatWasAsked() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromRespectsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 500e18);
        vm.prank(alice);
        token.transferFrom(deployer, alice, 500e18);
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.allowance(deployer, alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], deployer, uint256(1));
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorTakesNoArguments() public view {
        // The factory deploys from creation code alone; the code must not expect appended args.
        bytes memory creationCode = type(Points).creationCode;
        assertGt(creationCode.length, 0);
        assertEq(address(token).code.length > 0, true);
    }

    function testFuzz_transfersConserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
