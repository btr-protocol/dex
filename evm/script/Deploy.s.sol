// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/*
  BTR DEX — chain-agnostic deploy entrypoint.

  Replaces DeployBSCFork.s.sol (deleted per Cohort B Round 1 §4): chain selection is now via
  --fork-url + a chain-config JSON in `dex/evm/deployments/<chain>.json` rather than baked
  constants. TestDeploy.s.sol kept for local-anvil smoke (separate file).

  Run (BSC fork):
    forge script script/Deploy.s.sol:Deploy \
      --fork-url $RPC_BSC_FORK \
      --private-key $DEPLOYER_PK \
      --broadcast --slow

  Required env:
    DEPLOYER_PK
  Optional env:
    DEPLOYER, TREASURY (DeployBase resolves via _resolveDeployer/_resolveTreasury)

  TODO Cohort B 42B.9b: parse `dex/evm/deployments/<chain>.json` via _loadChain + vm.parseJson
  and migrate the CREATE3 / module wiring blocks from the old DeployBSCFork.s.sol.
*/

import {DeployBase} from "@btr-shared-script/Deploy.base.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {console2} from "forge-std/Script.sol";

contract Deploy is DeployBase {
  function run() external {
    address deployer = _resolveDeployer();
    address treasury = _resolveTreasury(deployer);

    vm.startBroadcast(deployer);
    AccessControl ac = _deployAC(deployer, treasury);
    console2.log("AccessControl:", address(ac));
    // TODO 42B.9b: pool proxy + router + module wiring (migrated from DeployBSCFork).
    vm.stopBroadcast();
  }
}
