// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolV1} from "../src/interfaces/IPoolV1.sol";
import {ICoreV1} from "../src/interfaces/modules/ICoreV1.sol";
import {IAdminV1} from "../src/interfaces/modules/IAdminV1.sol";
import {PoolProxyV1} from "../src/PoolProxyV1.sol";
import {CoreV1} from "../src/modules/CoreV1.sol";
import {AdminV1} from "../src/modules/AdminV1.sol";
import {InternalOracleV1} from "../src/modules/InternalOracleV1.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";
import {LibMaths} from "../src/libraries/LibMaths.sol";

/// @title DeployBSCFork
/// @notice Deploy AIMM pools on local BSC fork: Pool Zero (multi-asset) and Pool Stable (stablecoins)
contract DeployBSCFork is Script {
    // ═══════════════════════════════════════════════════════════════════════════
    // BSC MAINNET TOKEN ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    // Pool Zero Tokens
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;  // Binance-Peg USDC
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;  // Binance-Peg USDT
    address constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;  // Binance-Peg ETH
    address constant WBTC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;  // Binance-Peg BTCB
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;  // Wrapped BNB
    address constant SOL = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;   // Solana Token
    address constant ZEC = 0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb;   // Binance-Peg ZEC
    address constant PAXG = 0x7950865a9140cB519342433146Ed5b40c6F210f7;  // Paxos Gold

    // Pool Stable Additional Tokens
    address constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;   // Binance-Peg DAI
    address constant TUSD = 0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9;  // TrueUSD
    address constant FDUSD = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409; // First Digital USD
    address constant USDD = 0xd17479997F34dd9156Deef8F95A52D81D265be9c;  // Decentralized USD
    address constant USDP = 0xb3c11196A4f3b1da7c23d9FB0A3dDE9c6340934F;  // Pax Dollar
    address constant crvUSD = 0xe2fb3F127f5450DeE44afe054385d74C392BdeF4; // Curve USD
    address constant lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5; // Lista USD
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;  // Agora Dollar
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df; // Frax USD

    // Token decimals
    uint8 constant DECIMALS_USDC = 18;
    uint8 constant DECIMALS_USDT = 18;
    uint8 constant DECIMALS_WETH = 18;
    uint8 constant DECIMALS_WBTC = 18;
    uint8 constant DECIMALS_WBNB = 18;
    uint8 constant DECIMALS_SOL = 18;
    uint8 constant DECIMALS_ZEC = 18;
    uint8 constant DECIMALS_PAXG = 18;
    uint8 constant DECIMALS_DAI = 18;
    uint8 constant DECIMALS_TUSD = 18;
    uint8 constant DECIMALS_FDUSD = 18;
    uint8 constant DECIMALS_USDD = 18;
    uint8 constant DECIMALS_USDP = 18;
    uint8 constant DECIMALS_crvUSD = 18;
    uint8 constant DECIMALS_lisUSD = 18;
    uint8 constant DECIMALS_AUSD = 18;
    uint8 constant DECIMALS_frxUSD = 18;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYED CONTRACTS
    // ═══════════════════════════════════════════════════════════════════════════

    PoolProxyV1 public poolZero;
    PoolProxyV1 public poolStable;
    CoreV1 public coreModule;
    AdminV1 public adminModule;
    InternalOracleV1 public oracleModule;

    address public deployer;

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        deployer = vm.envOr("DEPLOYER", msg.sender);

        console2.log("Deploying on BSC fork with deployer:", deployer);

        vm.startBroadcast(deployer);

        // 1. Deploy shared modules
        deployModules();

        // 2. Deploy and configure Pool Zero
        deployPoolZero();

        // 3. Deploy and configure Pool Stable
        deployPoolStable();

        // 4. Refresh all oracle feeds (counteract vm.warp staleness)
        refreshOracleFeeds();

        vm.stopBroadcast();

        // Print summary
        printDeploymentSummary();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODULE DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function deployModules() internal {
        console2.log("\n=== Deploying Modules ===");

        coreModule = new CoreV1();
        console2.log("CoreV1:", address(coreModule));

        adminModule = new AdminV1();
        console2.log("AdminV1:", address(adminModule));

        oracleModule = new InternalOracleV1();
        console2.log("InternalOracleV1:", address(oracleModule));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL ZERO DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function deployPoolZero() internal {
        console2.log("\n=== Deploying Pool Zero ===");

        // Deploy proxy
        poolZero = new PoolProxyV1();
        console2.log("Pool Zero Proxy:", address(poolZero));

        // Initialize with USDC as base
        uint8[29] memory feePad;
        IPoolV1.FeeParams memory feeParams = IPoolV1.FeeParams({
            protoShare: 25,      // 25% protocol share
            flashFeeBps: 5,      // 0.0005% flash fee
            _pad: feePad
        });

        poolZero.initialize(deployer, USDC, WBNB, feeParams);

        // Register modules
        registerModules(address(poolZero));

        // Add base token (USDC) as root
        addAssetPoolZero(USDC, DECIMALS_USDC, address(0), true);  // Stablecoin

        // Add USDT (stablecoin anchored to USDC)
        addAssetPoolZero(USDT, DECIMALS_USDT, USDC, true);

        // Add volatile assets (all anchored to USDC)
        addAssetPoolZero(WETH, DECIMALS_WETH, USDC, false);
        addAssetPoolZero(WBTC, DECIMALS_WBTC, USDC, false);
        addAssetPoolZero(WBNB, DECIMALS_WBNB, USDC, false);
        addAssetPoolZero(SOL, DECIMALS_SOL, USDC, false);
        addAssetPoolZero(ZEC, DECIMALS_ZEC, USDC, false);
        addAssetPoolZero(PAXG, DECIMALS_PAXG, USDC, false);

        console2.log("Pool Zero configured with 8 assets");
    }

    function addAssetPoolZero(address token, uint8 decimals, address anchor, bool isStable) internal {
        // Oracle config - internal oracle with appropriate decimals
        uint8[13] memory oraclePad;
        IPoolV1.OracleConfig memory oracleCfg = IPoolV1.OracleConfig({
            primary: address(poolZero),
            secondary: address(0),
            feedId: bytes32(0),
            modeFlags: 0,
            accDecimals: isStable ? 6 : 12,  // Stables: 6, Volatiles: 12
            _pad: oraclePad
        });

        // Risk config (same for all assets per spec)
        uint8[18] memory riskPad;
        IPoolV1.RiskConfig memory riskCfg = IPoolV1.RiskConfig({
            decayStartRatioBps: 9800,           // 98%
            coverageFloor: 5000,                // 50%
            decaySlope: 31709791,               // ~1%/year
            depthAmplifier: 20000,              // 2% (scaled by 1e6 in formula = 0.02)
            flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
            _pad: riskPad
        });

        // Liquidity profile
        IPoolV1.LiquidityProfile memory profile = isStable
            ? concentratedProfile()  // Stables: [-50, -5, 5, 50] with [5, 90, 5]
            : balancedProfile();     // Volatiles: [-50, -15, 15, 50] with [25, 50, 25]

        // Determine initial price based on token
        uint64 initialPrice = getInitialPrice(token, decimals);

        // Request asset addition
        IPoolV1(address(poolZero)).requestAddAsset(
            token,
            oracleCfg,
            riskCfg,
            profile,
            isStable ? 5 : 100,  // minFeeBps: stables=0.0005%, volatiles=0.01%
            decimals,
            initialPrice,
            10000,  // Initial fast vol EMA
            10000   // Initial slow vol EMA
        );

        // Warp past timelock and execute
        vm.warp(block.timestamp + C.LOW_TIMELOCK + 1);
        IPoolV1(address(poolZero)).executeAddAsset(token);

        // Set anchor if not root
        if (anchor != address(0)) {
            IAdminV1(address(poolZero)).setAnchor(token, anchor);
        }

        console2.log("Added asset:", token);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL STABLE DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function deployPoolStable() internal {
        console2.log("\n=== Deploying Pool Stable ===");

        // Deploy proxy
        poolStable = new PoolProxyV1();
        console2.log("Pool Stable Proxy:", address(poolStable));

        // Initialize with USDC as base
        uint8[29] memory feePad;
        IPoolV1.FeeParams memory feeParams = IPoolV1.FeeParams({
            protoShare: 25,
            flashFeeBps: 5,
            _pad: feePad
        });

        poolStable.initialize(deployer, USDC, WBNB, feeParams);

        // Register modules
        registerModules(address(poolStable));

        // Add USDC as root
        addAssetPoolStable(USDC, DECIMALS_USDC, address(0));

        // Add all other stablecoins anchored to USDC
        addAssetPoolStable(USDT, DECIMALS_USDT, USDC);
        addAssetPoolStable(DAI, DECIMALS_DAI, USDC);
        addAssetPoolStable(USDP, DECIMALS_USDP, USDC);
        addAssetPoolStable(lisUSD, DECIMALS_lisUSD, USDC);
        addAssetPoolStable(AUSD, DECIMALS_AUSD, USDC);
        addAssetPoolStable(TUSD, DECIMALS_TUSD, USDC);
        addAssetPoolStable(USDD, DECIMALS_USDD, USDC);
        addAssetPoolStable(FDUSD, DECIMALS_FDUSD, USDC);
        addAssetPoolStable(crvUSD, DECIMALS_crvUSD, USDC);
        addAssetPoolStable(frxUSD, DECIMALS_frxUSD, USDC);

        console2.log("Pool Stable configured with 11 assets");
    }

    function addAssetPoolStable(address token, uint8 decimals, address anchor) internal {
        // Oracle config
        uint8[13] memory oraclePad;
        IPoolV1.OracleConfig memory oracleCfg = IPoolV1.OracleConfig({
            primary: address(poolStable),
            secondary: address(0),
            feedId: bytes32(0),
            modeFlags: 0,
            accDecimals: 6,  // All stablecoins use 6
            _pad: oraclePad
        });

        // Risk config (same for all stables)
        uint8[18] memory riskPad;
        IPoolV1.RiskConfig memory riskCfg = IPoolV1.RiskConfig({
            decayStartRatioBps: 9800,
            coverageFloor: 5000,
            decaySlope: 31709791,
            depthAmplifier: 20000,              // 2%
            flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
            _pad: riskPad
        });

        // Concentrated profile for all stables
        IPoolV1.LiquidityProfile memory profile = concentratedProfile();

        // $1.00 initial price for all stables
        uint64 initialPrice = LibMaths.encodeB64(10 ** decimals, decimals);

        // Request and execute
        IPoolV1(address(poolStable)).requestAddAsset(
            token,
            oracleCfg,
            riskCfg,
            profile,
            5,  // 0.0005% min fee
            decimals,
            initialPrice,
            10000,
            10000
        );

        vm.warp(block.timestamp + C.LOW_TIMELOCK + 1);
        IPoolV1(address(poolStable)).executeAddAsset(token);

        if (anchor != address(0)) {
            IAdminV1(address(poolStable)).setAnchor(token, anchor);
        }

        console2.log("Added stable:", token);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODULE REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function registerModules(address pool) internal {
        // Core selectors
        bytes4[] memory coreSelectors = new bytes4[](17);
        coreSelectors[0] = ICoreV1.swap.selector;
        coreSelectors[1] = ICoreV1.getSwapQuote.selector;
        coreSelectors[2] = ICoreV1.deposit.selector;
        coreSelectors[3] = ICoreV1.withdraw.selector;
        coreSelectors[4] = ICoreV1.withdrawTo.selector;
        coreSelectors[5] = ICoreV1.swapLiability.selector;
        coreSelectors[6] = ICoreV1.donate.selector;
        coreSelectors[7] = ICoreV1.owner.selector;
        coreSelectors[8] = ICoreV1.baseToken.selector;
        coreSelectors[9] = ICoreV1.wnative.selector;
        coreSelectors[10] = ICoreV1.getAsset.selector;
        coreSelectors[11] = ICoreV1.getLPBalance.selector;
        coreSelectors[12] = ICoreV1.getProtocolFees.selector;
        coreSelectors[13] = ICoreV1.getCoverageRatio.selector;
        coreSelectors[14] = ICoreV1.getMidPrice.selector;
        coreSelectors[15] = IPoolV1.getFeedConfig.selector;
        coreSelectors[16] = IPoolV1.getRiskConfig.selector;

        updateModuleDirect(pool, address(coreModule), coreSelectors);

        // Admin selectors
        bytes4[] memory adminSelectors = new bytes4[](20);
        adminSelectors[0] = IAdminV1.freezeAsset.selector;
        adminSelectors[1] = IAdminV1.unfreezeAsset.selector;
        adminSelectors[2] = IAdminV1.requestAddAsset.selector;
        adminSelectors[3] = IAdminV1.executeAddAsset.selector;
        adminSelectors[4] = IAdminV1.requestUpdateRiskConfig.selector;
        adminSelectors[5] = IAdminV1.executeUpdateRiskConfig.selector;
        adminSelectors[6] = IAdminV1.requestUpdateFeeParams.selector;
        adminSelectors[7] = IAdminV1.executeUpdateFeeParams.selector;
        adminSelectors[8] = IAdminV1.collectProtocolFees.selector;
        adminSelectors[9] = IAdminV1.requestOwnershipTransfer.selector;
        adminSelectors[10] = IAdminV1.executeOwnershipTransfer.selector;
        adminSelectors[11] = IAdminV1.requestBridgeUpdate.selector;
        adminSelectors[12] = IAdminV1.executeBridgeUpdate.selector;
        adminSelectors[13] = IAdminV1.requestTreasuryUpdate.selector;
        adminSelectors[14] = IAdminV1.executeTreasuryUpdate.selector;
        adminSelectors[15] = IAdminV1.requestModuleUpdate.selector;
        adminSelectors[16] = IAdminV1.executeModuleUpdate.selector;
        adminSelectors[17] = IAdminV1.cancelTimelock.selector;
        adminSelectors[18] = IAdminV1.getModule.selector;
        adminSelectors[19] = bytes4(keccak256("setAnchor(address,address)"));

        updateModuleDirect(pool, address(adminModule), adminSelectors);

        // Oracle selectors
        bytes4[] memory oracleSelectors = new bytes4[](6);
        oracleSelectors[0] = bytes4(keccak256("getFeed(address)"));
        oracleSelectors[1] = bytes4(keccak256("updateFeed(address,uint64,uint8,uint32,uint32)"));
        oracleSelectors[2] = bytes4(keccak256("pushFeedInternal(address,address,uint64,uint64)"));
        oracleSelectors[3] = bytes4(keccak256("isFeedFresh(address,uint32)"));
        oracleSelectors[4] = bytes4(keccak256("isFeedFresh(address)"));
        oracleSelectors[5] = bytes4(keccak256("getFastTWAP(address)"));

        updateModuleDirect(pool, address(oracleModule), oracleSelectors);
    }

    function updateModuleDirect(address pool, address impl, bytes4[] memory selectors) internal {
        // modules mapping is at offset 13 in PoolStorage from CORE_STORAGE_LOC
        // (treasury + initialized pack into one slot, so 5 addresses + 8 mappings = 13)
        bytes32 modulesSlot = bytes32(uint256(C.CORE_STORAGE_LOC) + 13);

        for (uint256 i = 0; i < selectors.length; i++) {
            // For mapping(bytes4 => address), slot = keccak256(abi.encode(key, mappingSlot))
            // bytes4 is left-aligned and right-padded to 32 bytes in abi.encode
            bytes32 slot = keccak256(abi.encode(selectors[i], modulesSlot));
            vm.store(pool, slot, bytes32(uint256(uint160(impl))));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY PROFILES
    // ═══════════════════════════════════════════════════════════════════════════

    function concentratedProfile() internal pure returns (IPoolV1.LiquidityProfile memory profile) {
        // knots: [-50, -5, 5, 50]
        // weights: [10, 180, 10] (sum=200, 3 segments)
        profile.weights[0] = 10;
        profile.weights[1] = 180;
        profile.weights[2] = 10;

        profile.knots[0] = -50;
        profile.knots[1] = -5;
        profile.knots[2] = 5;
        profile.knots[3] = 50;
    }

    function balancedProfile() internal pure returns (IPoolV1.LiquidityProfile memory profile) {
        // knots: [-50, -15, 15, 50]
        // weights: [50, 100, 50] (sum=200)
        profile.weights[0] = 50;
        profile.weights[1] = 100;
        profile.weights[2] = 50;

        profile.knots[0] = -50;
        profile.knots[1] = -15;
        profile.knots[2] = 15;
        profile.knots[3] = 50;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function getInitialPrice(address token, uint8 decimals) internal pure returns (uint64) {
        // Stablecoins: $1.00
        if (token == USDC || token == USDT) {
            return LibMaths.encodeB64(10 ** decimals, decimals);
        }

        // Major cryptos (rough BSC prices as of late 2024)
        if (token == WETH) return LibMaths.encodeB64(3500 * (10 ** decimals), decimals);  // $3500
        if (token == WBTC) return LibMaths.encodeB64(95000 * (10 ** decimals), decimals); // $95k
        if (token == WBNB) return LibMaths.encodeB64(650 * (10 ** decimals), decimals);   // $650
        if (token == SOL) return LibMaths.encodeB64(200 * (10 ** decimals), decimals);    // $200
        if (token == ZEC) return LibMaths.encodeB64(45 * (10 ** decimals), decimals);     // $45
        if (token == PAXG) return LibMaths.encodeB64(2700 * (10 ** decimals), decimals);  // $2700 (gold)

        // Default: $1.00
        return LibMaths.encodeB64(10 ** decimals, decimals);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE REFRESH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Refresh all oracle feeds to current timestamp
    /// @dev Needed because vm.warp during asset addition makes feeds stale
    function refreshOracleFeeds() internal {
        console2.log("\n=== Refreshing Oracle Feeds ===");

        // Pool Zero assets
        address[8] memory poolZeroTokens = [USDC, USDT, WETH, WBTC, WBNB, SOL, ZEC, PAXG];
        for (uint256 i = 0; i < poolZeroTokens.length; i++) {
            refreshFeed(address(poolZero), poolZeroTokens[i]);
        }

        // Pool Stable assets
        address[11] memory poolStableTokens = [USDC, USDT, DAI, USDP, lisUSD, AUSD, TUSD, USDD, FDUSD, crvUSD, frxUSD];
        for (uint256 i = 0; i < poolStableTokens.length; i++) {
            refreshFeed(address(poolStable), poolStableTokens[i]);
        }

        console2.log("All feeds refreshed");
    }

    function refreshFeed(address pool, address token) internal {
        // Get current price and decimals
        uint64 price = getInitialPrice(token, 18);
        uint8 accDec = (token == USDC || token == USDT || token == DAI || token == TUSD ||
                       token == FDUSD || token == USDD || token == USDP || token == crvUSD ||
                       token == lisUSD || token == AUSD || token == frxUSD) ? 6 : 12;

        // Call updateFeed via delegatecall through the pool
        InternalOracleV1(pool).updateFeed(token, price, accDec, 10000, 10000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SUMMARY
    // ═══════════════════════════════════════════════════════════════════════════

    function printDeploymentSummary() internal view {
        console2.log("\n=== Deployment Summary ===");
        console2.log("Deployer:", deployer);
        console2.log("");
        console2.log("Modules:");
        console2.log("  CoreV1:", address(coreModule));
        console2.log("  AdminV1:", address(adminModule));
        console2.log("  InternalOracleV1:", address(oracleModule));
        console2.log("");
        console2.log("Pool Zero (Multi-Asset):", address(poolZero));
        console2.log("  Base: USDC");
        console2.log("  Assets: USDC, USDT, WETH, WBTC, WBNB, SOL, ZEC, PAXG");
        console2.log("");
        console2.log("Pool Stable (Stablecoins):", address(poolStable));
        console2.log("  Base: USDC");
        console2.log("  Assets: USDC, USDT, DAI, USDP, lisUSD, AUSD, TUSD, USDD, FDUSD, crvUSD, frxUSD");
    }
}
