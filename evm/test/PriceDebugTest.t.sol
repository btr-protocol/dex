// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {DeployBSCFork} from "../script/DeployBSCFork.s.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {LibMaths} from "../src/libraries/LibMaths.sol";

contract PriceDebugTest is Test {
    DeployBSCFork public deployment;
    IPool public poolZero;

    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant WBTC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.binance.org"));
        vm.createSelectFork(rpcUrl);

        deployment = new DeployBSCFork();
        deployment.run();

        poolZero = IPool(address(deployment.poolZero()));
    }

    function test_checkOraclePrices() public {
        console2.log("=== Checking Oracle Prices ===");

        // Get mid prices via pool (this uses the oracle internally)
        uint256 wethMid = poolZero.getMidPrice(WETH);
        uint256 btcMid = poolZero.getMidPrice(WBTC);
        uint256 usdcMid = poolZero.getMidPrice(USDC);
        console2.log("WETH mid price:", wethMid);
        console2.log("Expected WETH ~3500e18:", uint256(3500 * 1e18));
        console2.log("WBTC mid price:", btcMid);
        console2.log("Expected WBTC ~95000e18:", uint256(95000 * 1e18));
        console2.log("USDC mid price:", usdcMid);
        console2.log("Expected USDC 1e18:", uint256(1e18));

        // Get asset info
        IPool.Asset memory wethAsset = poolZero.getAsset(WETH);
        console2.log("\n=== WETH Asset ===");
        console2.log("reserves:", wethAsset.reserves);
        console2.log("liabilities:", wethAsset.liabilities);
        console2.log("anchor:", wethAsset.anchor);
        console2.log("decimals:", wethAsset.decimals);
    }

    function test_quoteSimple() public {
        console2.log("=== Quote Tests ===");

        // Quote USDC -> WETH
        uint256 usdcIn = 10000 * 1e18; // $10000 USDC
        IPool.SwapQuote memory quote1 = poolZero.getSwapQuote(USDC, WETH, usdcIn);
        console2.log("$10000 USDC -> WETH:");
        console2.log("  amountOut:", quote1.amountOut);
        console2.log("  expected ~2.86 WETH:", uint256(2857 * 1e15)); // 2.857e18

        // Quote WETH -> USDC
        uint256 wethIn = 1e18; // 1 WETH
        IPool.SwapQuote memory quote2 = poolZero.getSwapQuote(WETH, USDC, wethIn);
        console2.log("\n1 WETH -> USDC:");
        console2.log("  amountOut:", quote2.amountOut);
        console2.log("  expected ~$3500:", uint256(3500 * 1e18));
    }
}
