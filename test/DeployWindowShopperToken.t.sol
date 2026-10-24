// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployWindowShopperToken} from "../script/DeployWindowShopperToken.s.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

contract DeployWindowShopperTokenTest is Test {
    function test_deployMintsSupplyToTheScriptAsDeployer() public {
        DeployWindowShopperToken deployer = new DeployWindowShopperToken();
        WindowShopperToken token = deployer.deploy();
        assertEq(token.name(), "IMDwindowshopper");
        assertEq(token.symbol(), "WWW");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 ether);
    }
}
