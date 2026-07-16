// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TestnetFaucet} from "../src/testnet/TestnetFaucet.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";

/// @notice Redeploy whitelist+caps faucet on Chapel without touching tokens/pools.
/// @dev Reads token addresses from deployments/<chainId>.deploy.json; mints via existing
///      TestnetERC20.minter (deployer) then funds the new faucet.
/// @dev Run: forge script script/RedeployFaucet.s.sol:RedeployFaucet --rpc-url chapel --broadcast --with-gas-price 100000000
contract RedeployFaucet is Script {
  using stdJson for string;

  function run() external {
    string memory path = vm.envOr(
      "DEPLOY_JSON", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
    string memory json = vm.readFile(path);

    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);

    address usdc = json.readAddress(".usdc");
    address usdt = json.readAddress(".usdt");
    address usd1 = json.readAddress(".usd1");
    address usde = json.readAddress(".usde");
    address fdusd = json.readAddress(".fdusd");
    address btcb = json.readAddress(".btcb");
    address eth_ = json.readAddress(".eth");
    address wbnb = json.readAddress(".wbnb");
    address cake = json.readAddress(".cake");
    address xaut = json.readAddress(".xaut");
    address oldFaucet = json.readAddress(".faucet");

    vm.startBroadcast(pk);

    TestnetFaucet faucet = new TestnetFaucet(deployer);

    // Caps mirror TestnetDeploy._configureFaucet for tokens present in deploy JSON.
    address[] memory tokens = new address[](10);
    uint256[] memory caps = new uint256[](10);
    tokens[0] = usdc;
    caps[0] = 10_000 ether;
    tokens[1] = usdt;
    caps[1] = 10_000 ether;
    tokens[2] = usd1;
    caps[2] = 10_000 ether;
    tokens[3] = usde;
    caps[3] = 10_000 ether;
    tokens[4] = fdusd;
    caps[4] = 10_000 ether;
    tokens[5] = btcb;
    caps[5] = 0.1 ether;
    tokens[6] = eth_;
    caps[6] = 5 ether;
    tokens[7] = wbnb;
    caps[7] = 10 ether;
    tokens[8] = cake;
    caps[8] = 4_000 ether;
    tokens[9] = xaut;
    caps[9] = 1 ether;
    faucet.setCaps(tokens, caps);
    // constructor already whitelists owner/deployer

    for (uint256 i; i < tokens.length; ++i) {
      uint256 amt = 1_000_000 ether;
      if (tokens[i] == btcb) amt = 100 ether;
      if (tokens[i] == xaut) amt = 1_000 ether;
      TestnetERC20(tokens[i]).mint(deployer, amt);
      IERC20(tokens[i]).approve(address(faucet), amt);
      faucet.fund(tokens[i], amt);
    }

    vm.stopBroadcast();

    console2.log("New faucet:", address(faucet));
    console2.log("Old faucet (abandon):", oldFaucet);

    // Patch deploy JSON faucet field in-place (JSON string value).
    vm.writeJson(string.concat('"', vm.toString(address(faucet)), '"'), path, ".faucet");
  }
}
