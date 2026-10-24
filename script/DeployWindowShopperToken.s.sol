// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

/// @notice Deploys {WindowShopperToken}. The token takes no constructor arguments: whoever sends
///         the creation transaction receives the whole supply. On the IMD launch that is the
///         factory, which then pays the supply out; this script exists for local and review
///         deployments only and reads nothing from the environment.
/// @dev `deploy()` is the unit the tests call directly; `run()` only wraps it in a broadcast.
contract DeployWindowShopperToken is Script {
    /// @notice Deploys the token and returns it. Pure function of the caller: no configuration.
    function deploy() public returns (WindowShopperToken token) {
        token = new WindowShopperToken();
    }

    function run() external returns (WindowShopperToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
