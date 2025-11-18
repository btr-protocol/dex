// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMM} from "../src/bamm/BAMM.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";
import {IBAMM} from "../src/interfaces/IBAMM.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @title Mock ERC20 for testing
contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployAnvil
/// @notice Comprehensive deployment script for local Anvil testing
/// @dev Deploys factory, pool, mock tokens, configures oracles, and adds liquidity
contract DeployAnvil is Script {
    // Anvil default account
    address constant ANVIL_DEFAULT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Oracle prices (in USD with 18 decimals)
    uint256 constant ETH_PRICE = 4000e18;    // $4,000
    uint256 constant WBTC_PRICE = 100000e18; // $100,000

    // Initial liquidity amounts (in USD)
    uint256 constant INITIAL_LIQUIDITY_USD = 1000e18; // $1,000 each

    function run() external {
        vm.startBroadcast(ANVIL_DEFAULT);

        console2.log("\n========== DEPLOYING TO ANVIL ==========");
        console2.log("Deployer:", ANVIL_DEFAULT);

        // 1. Deploy mock tokens
        console2.log("\n[1/6] Deploying mock tokens...");
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        console2.log("USDC:", address(usdc));
        console2.log("WBTC:", address(wbtc));

        // 2. Deploy BAMM implementation and factory
        console2.log("\n[2/6] Deploying BAMM...");
        BAMM implementation = new BAMM();
        console2.log("Implementation:", address(implementation));

        BAMMFactory factory = new BAMMFactory(address(implementation), ANVIL_DEFAULT);
        console2.log("Factory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));

        // 3. Deploy pool with USDC as numeraire
        console2.log("\n[3/6] Deploying pool (USDC as numeraire)...");

        address pool = factory.deployPool(
            address(usdc),            // baseToken (USDC numeraire)
            address(0),               // baseMainOracle (will set internal oracle later)
            address(0),               // baseFallbackOracle (none)
            1000,                     // baseMinLiquidity (0.001 USDC min)
            ANVIL_DEFAULT,            // poolOwner
            ANVIL_DEFAULT,            // guardian
            address(0),               // treasury (defaults to owner)
            30,                       // baseFee (0.30%)
            1000,                     // maxFee (10%)
            0,                        // withdrawalFee (0%)
            500,                      // maxTWAPChange (5%)
            1000,                     // protocolFeeBps (10%)
            0,                        // flashFeeBps (0%, free)
            false                     // enableDarkPool
        );
        console2.log("Pool:", pool);

        IBAMM bamm = IBAMM(pool);

        // 4. Add tokens to pool with oracle configs
        console2.log("\n[4/6] Adding tokens to pool...");

        // Prepare empty liquidity profile (constant breadth)
        IBAMM.LiquidtyConfig memory emptyProfile = IBAMM.LiquidtyConfig({
            weights: new uint8[](0),
            endOffsets: new int8[](0),
            slopes: new int32[](0),
            baseBreadth: 100000,  // 0.1% base breadth
            maxBreadth: 1000000,  // 1% max breadth
            volKappa: 1000000     // 1x volatility sensitivity
        });

        // Add native ETH (wrapped automatically by contract)
        console2.log("Adding ETH (native, wrapped by contract)...");

        bytes memory ethExtension = abi.encode(
            uint64(ETH_PRICE),   // price: $4,000
            uint32(100000),      // fastVolEMA: 10% annualized
            uint32(80000),       // slowVolEMA: 8% annualized
            uint16(500),         // maxTWAPChange: 5%
            uint32(300),         // fastWindow: 5 minutes
            uint32(3600)         // slowWindow: 1 hour
        );

        bamm.addAsset(
            address(0),   // Native ETH
            IBAMM.FeeConfig({
                depositFeeBps: 0,
                withdrawalFeeBps: 0,
                minFeeBps: 30,        // 0.30%
                maxFeeBps: 1000,      // 10%
                flashFeeBps: 0,       // Free flash loans
                protocolFeeBps: 1000  // 10% protocol fee
            }),
            IBAMM.OracleConfig({
                mainOracle: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),    // Internal oracle
                fallbackOracle: address(0),
                extension: ethExtension
            }),
            IBAMM.RiskConfig({
                minLiquidity: 0.001e18,        // 0.001 ETH minimum
                reservePrice: 0,               // No reserve price floor
                refFeed: bytes32(0),           // No reference feed
                maxBetaDeviationBps: 0,        // Disabled
                maxFastDeviationBps: 0,        // Disabled
                maxSlowDeviationBps: 0,        // Disabled
                decayStartRatioBps: 9800,      // Start decay at 98% coverage
                decayAmplification: 10000,     // Linear decay
                decaySlope: 0,                 // No decay
                flags: 0x001E                  // swapEnabled | liabilitySwapEnabled | flashEnabled
            }),
            emptyProfile
        );

        // Add WBTC
        console2.log("Adding WBTC...");

        bytes memory wbtcExtension = abi.encode(
            uint64(WBTC_PRICE),  // price: $100,000
            uint32(120000),      // fastVolEMA: 12% annualized
            uint32(90000),       // slowVolEMA: 9% annualized
            uint16(500),         // maxTWAPChange: 5%
            uint32(300),         // fastWindow: 5 minutes
            uint32(3600)         // slowWindow: 1 hour
        );

        bamm.addAsset(
            address(wbtc),
            IBAMM.FeeConfig({
                depositFeeBps: 0,
                withdrawalFeeBps: 0,
                minFeeBps: 30,        // 0.30%
                maxFeeBps: 1000,      // 10%
                flashFeeBps: 0,       // Free flash loans
                protocolFeeBps: 1000  // 10% protocol fee
            }),
            IBAMM.OracleConfig({
                mainOracle: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),    // Internal oracle
                fallbackOracle: address(0),
                extension: wbtcExtension
            }),
            IBAMM.RiskConfig({
                minLiquidity: 0.00001e8,       // 0.00001 WBTC minimum
                reservePrice: 0,               // No reserve price floor
                refFeed: bytes32(0),           // No reference feed
                maxBetaDeviationBps: 0,        // Disabled
                maxFastDeviationBps: 0,        // Disabled
                maxSlowDeviationBps: 0,        // Disabled
                decayStartRatioBps: 9800,      // Start decay at 98% coverage
                decayAmplification: 10000,     // Linear decay
                decaySlope: 0,                 // No decay
                flags: 0x001E                  // swapEnabled | liabilitySwapEnabled | flashEnabled
            }),
            emptyProfile
        );

        // 5. Add initial liquidity ($1,000 of each token)
        console2.log("\n[5/6] Adding initial liquidity...");

        // Calculate token amounts for $1,000 each
        // ETH: $1,000 / $4,000 = 0.25 ETH
        uint256 ethAmount = (INITIAL_LIQUIDITY_USD * 1e18) / ETH_PRICE;
        console2.log("Adding ETH:", ethAmount, "(0.25 ETH)");
        bamm.deposit{value: ethAmount}(address(0), ethAmount, 0);

        // WBTC: $1,000 / $100,000 = 0.01 WBTC
        uint256 wbtcAmount = (INITIAL_LIQUIDITY_USD * 1e8) / WBTC_PRICE;
        console2.log("Adding WBTC:", wbtcAmount, "(0.01 WBTC)");
        wbtc.mint(ANVIL_DEFAULT, wbtcAmount);
        wbtc.approve(pool, wbtcAmount);
        bamm.deposit(address(wbtc), wbtcAmount, 0);

        // USDC: $1,000 = 1,000 USDC
        uint256 usdcAmount = 1000e6;  // 1,000 USDC (6 decimals)
        console2.log("Adding USDC:", usdcAmount, "(1,000 USDC)");
        usdc.mint(ANVIL_DEFAULT, usdcAmount);
        usdc.approve(pool, usdcAmount);
        bamm.deposit(address(usdc), usdcAmount, 0);

        vm.stopBroadcast();

        // Print deployment summary
        console2.log("\n========== DEPLOYMENT COMPLETE ==========");
        console2.log("Factory:", address(factory));
        console2.log("Pool:", pool);
        console2.log("USDC:", address(usdc));
        console2.log("WBTC:", address(wbtc));
        console2.log("ETH: Native (wrapped by contract)");
        console2.log("\nOracle Prices:");
        console2.log("  ETH:  $4,000");
        console2.log("  WBTC: $100,000");
        console2.log("  USDC: $1 (numeraire)");
        console2.log("\nInitial Liquidity (each $1,000):");
        console2.log("  ETH:  0.25 ETH");
        console2.log("  WBTC: 0.01 WBTC");
        console2.log("  USDC: 1,000 USDC");
        console2.log("=========================================\n");

        // Save addresses to file for frontend
        string memory addresses = string(abi.encodePacked(
            '{\n',
            '  "factory": "', vm.toString(address(factory)), '",\n',
            '  "pool": "', vm.toString(pool), '",\n',
            '  "usdc": "', vm.toString(address(usdc)), '",\n',
            '  "wbtc": "', vm.toString(address(wbtc)), '",\n',
            '  "eth": "0x0000000000000000000000000000000000000000",\n',
            '  "deployer": "', vm.toString(ANVIL_DEFAULT), '"\n',
            '}'
        ));

        vm.writeFile("../front/src/contracts/addresses.json", addresses);
        console2.log("Addresses saved to front/src/contracts/addresses.json");
    }
}
