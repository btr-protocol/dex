// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

contract SimpleStorage {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract TestDeploy is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER", msg.sender);
        console2.log("Deploying SimpleStorage with:", deployer);

        vm.startBroadcast(deployer);

        SimpleStorage simple = new SimpleStorage();
        console2.log("SimpleStorage deployed to:", address(simple));

        simple.setValue(42);
        console2.log("Value set to 42");

        vm.stopBroadcast();
    }
}
