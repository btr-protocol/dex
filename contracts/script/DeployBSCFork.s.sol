// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/*
 * CREATE3 DETERMINISTIC DEPLOYMENT FOR BNB CHAIN
 * ─────────────────────────────────────────────────────────────────────────
 * This script uses CreateX CREATE3 for deterministic cross-chain addresses.
 *
 * Salt allocation:
 * - Protocol contracts (Factory, Router, Reference Pool, Bridge, Treasury, BTR):
 *   salts/b712_b712.txt (lower b712)
 * - Mock ERC20 tokens: salts/bbbb_bb.txt (lower bbbb)
 *
 * Pools are deployed via Factory (non-deterministic), but all entrypoints
 * (Factory, Router) are deterministic for easy frontend integration.
 *
 * All deployments use DEPLOYER_PK from .env to ensure identical addresses
 * across local fork (31337), testnet, and mainnet.
 * ─────────────────────────────────────────────────────────────────────────
 */

import {Script, console2} from "forge-std/Script.sol";
import {IPoolV1} from "../src/interfaces/IPoolV1.sol";
import {ICoreV1} from "../src/interfaces/modules/ICoreV1.sol";
import {IExchangeV1} from "../src/interfaces/modules/IExchangeV1.sol";
import {ILiquidityV1} from "../src/interfaces/modules/ILiquidityV1.sol";
import {IAdminV1} from "../src/interfaces/modules/IAdminV1.sol";
import {IPoolProxyFactoryV1} from "../src/interfaces/IPoolProxyFactoryV1.sol";
import {ICreateX} from "../src/interfaces/external/ICreateX.sol";
import {PoolProxyV1} from "../src/PoolProxyV1.sol";
import {PoolProxyFactoryV1} from "../src/PoolProxyFactoryV1.sol";
import {RouterV1} from "../src/RouterV1.sol";
import {ExchangeV1} from "../src/modules/ExchangeV1.sol";
import {LiquidityV1} from "../src/modules/LiquidityV1.sol";
import {AdminV1} from "../src/modules/AdminV1.sol";
import {InternalOracleV1} from "../src/modules/InternalOracleV1.sol";
import {StakingV1} from "../src/modules/StakingV1.sol";
import {DistributorV1} from "../src/modules/DistributorV1.sol";
import {FlashV1} from "../src/modules/FlashV1.sol";
import {RescueV1} from "../src/modules/RescueV1.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";
import {LibMaths} from "../src/libraries/LibMaths.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFaucet} from "../src/mocks/MockFaucet.sol";

/// @title DeployBSCFork
/// @notice Deploy complete BTR protocol with CREATE3 deterministic addresses
contract DeployBSCFork is Script {
    // ─────────────────────────────────────────────────────────────────────────
    // CONFIGURATION STRUCTURES
    // ─────────────────────────────────────────────────────────────────────────

    struct TokenDef {
        string name;
        string symbol;
        uint256 price;       // USD price (e.g. 3500 for ETH)
        bool isStable;       // true = stablecoin (accDec=6, slippage=5, price=$1)
        bool inPoolZero;     // Include in Pool Zero?
        bool inPoolStable;   // Include in Pool Stable?
        bytes32 salt;        // CREATE3 salt (from bbbb_bb.txt)
        address addr;        // Set after deployment
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────────────────────────────────

    TokenDef[] public tokens;
    ICreateX public createX;
    address public deployer;
    address constant TEST_ADDR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Module addresses (set after deployment)
    address public exchangeModule;
    address public liquidityModule;
    address public adminModule;
    address public oracleModule;
    address public stakingModule;
    address public distributorModule;
    address public flashModule;
    address public rescueModule;

    // ─────────────────────────────────────────────────────────────────
    // CREATE3 ADDRESS COMPUTATION
    // ─────────────────────────────────────────────────────────────────
    // CREATE3 address formula: keccak256(0xFF + deployer + salt + keccak256(initCode))
    // We compute this locally instead of calling CreateX contract to avoid
    // potential interface mismatches with the deployed CreateX on BSC.

    function computeCreate3Address(
        bytes32 salt,
        address _deployer,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xFF),
            _deployer,
            salt,
            initCodeHash
        )))));
    }

    // Protocol contract CREATE3 salts & expected addresses (from b712_b712.txt)
    bytes32 constant SALT_BTR = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a300f97afd86eb2822037ef997;
    address constant EXPECTED_BTR = 0xb7122066D05B248FB3F09025EFe1db9d1761b712;

    bytes32 constant SALT_TREASURY = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a3007364b2b87a4d7f01969bc2;
    address constant EXPECTED_TREASURY = 0xb7128212286a6e7f4fEF52E9c5CE6963C75ab712;

    bytes32 constant SALT_BRIDGE = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a30034678660a51ffe032a91de;
    address constant EXPECTED_BRIDGE = 0xb71269762A37C3bAaE98Bc1C9d95aec3885Fb712;

    bytes32 constant SALT_FACTORY = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a3009083cfa69f58ef012aaf17;
    address constant EXPECTED_FACTORY = 0xb7120441f633D69E9DA41ba35Ea34C5FDDC0b712;

    bytes32 constant SALT_REFERENCE_POOL = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a300cd34ffd7f2032b0224f7f9;
    address constant EXPECTED_REFERENCE_POOL = 0xb712Ad3BF61287d5215967B46AB004d4D8F8b712;

    bytes32 constant SALT_ROUTER = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a3006b72cc545afe49025539a4;
    address constant EXPECTED_ROUTER = 0xb712ecdCAe7C9D7CC09E17d0aFb5D3A9BD84b712;

    bytes32 constant SALT_FAUCET = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a300637409d4a5539601c914cc;
    address constant EXPECTED_FAUCET = 0xB7126f81759Cf7495721e70c0765A6fCcE72B712;

    // Deployed addresses
    address public faucet;
    address public factory;
    address public referencePool;
    address public router;
    address public poolZero;
    address public poolStable;
    address public btrToken;
    address public treasury;
    address public bridge;

    // ─────────────────────────────────────────────────────────────────────────
    // MAIN RUN
    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        // Load env vars
        deployer = vm.envAddress("DEPLOYER");
        createX = ICreateX(vm.envAddress("CREATEX"));
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        bool useCreate3 = vm.envOr("USE_CREATE3", true);

        console2.log("Starting BTR Protocol deployment...");
        console2.log("Deployment mode:", useCreate3 ? "Deterministic (CREATE3)" : "Non-deterministic (CREATE)");
        console2.log("Deployer:", deployer);
        console2.log("CreateX:", address(createX));
        console2.log();

        vm.startBroadcast(deployerPk);

        // 1. Deploy Faucet (CREATE3)
        faucet = deployFaucet(SALT_FAUCET, EXPECTED_FAUCET, useCreate3);

        // 2. Deploy Mock Tokens (CREATE3 with bbbb_bb.txt salts)
        initTokenDefs();
        deployMocks();

        // 2. Deploy Modules (normal CREATE, not deterministic)
        deployModules();

        // 3. Deploy BTR Token (CREATE3)
        btrToken = deployUserContract("BTR Token", SALT_BTR, EXPECTED_BTR, useCreate3);

        // 4. Deploy Treasury (CREATE3)
        treasury = deployUserContract("Treasury", SALT_TREASURY, EXPECTED_TREASURY, useCreate3);

        // 5. Deploy Bridge (CREATE3)
        bridge = deployUserContract("Bridge", SALT_BRIDGE, EXPECTED_BRIDGE, useCreate3);

        // 6. Deploy Reference Pool (CREATE3)
        referencePool = deployUserContract("Reference Pool", SALT_REFERENCE_POOL, EXPECTED_REFERENCE_POOL, useCreate3);

        // 7. Deploy Factory (CREATE3)
        factory = deployFactory(SALT_FACTORY, EXPECTED_FACTORY, useCreate3);

        // 8. Deploy Router (CREATE3)
        router = deployRouter(SALT_ROUTER, EXPECTED_ROUTER, useCreate3);

        // 9. Deploy Pool Zero via Factory (non-deterministic)
        poolZero = deployPoolZero();

        // 10. Deploy Pool Stable via Factory (non-deterministic)
        poolStable = deployPoolStable();

        vm.stopBroadcast();

        // 11. Export deployment JSON
        exportDeployment();
        exportMockTokens();
    }

    // ─────────────────────────────────────────────────────────────────
    // DEPLOYMENT FUNCTIONS
    // ─────────────────────────────────────────────────────────────────

    function deployUserContract(
        string memory logName,
        bytes32 salt,
        address expectedAddr,
        bool useCreate3
    ) internal returns (address) {
        if (useCreate3) {
            bytes memory initCode = abi.encodePacked(type(PoolProxyV1).creationCode);

            address deployed = createX.deployCreate3(salt, initCode);
            console2.log("%s: %s", logName, deployed);
            return deployed;
        } else {
            address deployed = address(new PoolProxyV1());
            console2.log("%s (non-deterministic): %s", logName, deployed);
            return deployed;
        }
    }

    function deployFactory(bytes32 salt, address expectedAddr, bool useCreate3) internal returns (address) {
        if (useCreate3) {
            // Factory constructor: (address referencePool, address protocolDeployer)
            bytes memory initCode = abi.encodePacked(
                type(PoolProxyFactoryV1).creationCode,
                abi.encode(referencePool, deployer)
            );

            address deployed = createX.deployCreate3(salt, initCode);
            console2.log("Factory: %s", deployed);
            return deployed;
        } else {
            PoolProxyFactoryV1 deployed = new PoolProxyFactoryV1(referencePool, deployer);
            console2.log("Factory (non-deterministic): %s", address(deployed));
            return address(deployed);
        }
    }

    function deployRouter(bytes32 salt, address expectedAddr, bool useCreate3) internal returns (address) {
        if (useCreate3) {
            bytes memory initCode = abi.encodePacked(type(RouterV1).creationCode);

            address deployed = createX.deployCreate3(salt, initCode);

            // Initialize router
            RouterV1(deployed).initialize(deployer, factory);

            console2.log("Router: %s", deployed);
            return deployed;
        } else {
            RouterV1 deployed = new RouterV1();
            deployed.initialize(deployer, factory);
            console2.log("Router (non-deterministic): %s", address(deployed));
            return address(deployed);
        }
    }

    function deployPoolZero() internal returns (address) {
        console2.log("=== Deploying Pool Zero via Factory ===");

        // Get pool zero tokens (8 tokens: USDC, USDT, WETH, WBTC, WBNB, SOL, ZEC, PAXG)
        address[] memory poolTokens = new address[](8);
        uint256 count = 0;
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i].inPoolZero) {
                poolTokens[count++] = tokens[i].addr;
            }
        }
        // Resize array
        assembly { mstore(poolTokens, count) }

        // Prepare initialization calldata
        bytes memory initdata = abi.encodeWithSelector(
            PoolProxyV1.initialize.selector,
            deployer,
            getTokenAddr("mUSDC"),  // baseToken = USDC (price anchor for pool zero)
            getTokenAddr("mWBNB"),  // wnative = WBNB
            _getDefaultFeeParams()
        );

        // Deploy via factory
        address poolAddr = PoolProxyFactoryV1(payable(factory)).createPool(
            getTokenAddr("mUSDC"),  // baseToken = USDC
            poolTokens,
            initdata
        );

        console2.log("Pool Zero: %s", poolAddr);

        // Setup modules
        _setupPool(poolAddr, true);

        return poolAddr;
    }

    function deployPoolStable() internal returns (address) {
        console2.log("=== Deploying Pool Stable via Factory ===");

        // Get pool stable tokens (7 tokens: USDC, USDT, DAI, TUSD, FDUSD, USDD, USDP, crvUSD)
        address[] memory poolTokens = new address[](8);
        uint256 count = 0;
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i].inPoolStable) {
                poolTokens[count++] = tokens[i].addr;
            }
        }
        // Resize array
        assembly { mstore(poolTokens, count) }

        // Prepare initialization calldata
        bytes memory initdata = abi.encodeWithSelector(
            PoolProxyV1.initialize.selector,
            deployer,
            getTokenAddr("mUSDC"),  // baseToken = USDC for pool stable
            getTokenAddr("mWBNB"),  // wnative = WBNB
            _getDefaultFeeParams()
        );

        // Deploy via factory
        address poolAddr = PoolProxyFactoryV1(payable(factory)).createPool(
            getTokenAddr("mUSDC"),  // baseToken
            poolTokens,
            initdata
        );

        console2.log("Pool Stable: %s", poolAddr);

        // Setup modules
        _setupPool(poolAddr, false);

        return poolAddr;
    }

    function _setupPool(address pool, bool isPoolZero) internal {
        // Register modules
        _registerModules(pool);

        // Add assets
        for (uint i = 0; i < tokens.length; i++) {
            if (isPoolZero ? tokens[i].inPoolZero : tokens[i].inPoolStable) {
                _addAsset(pool, tokens[i]);
            }
        }

        // Refresh oracle feeds
        _refreshFeeds(pool, isPoolZero);
    }

    // ─────────────────────────────────────────────────────────────────
    // MOCK TOKENS
    // ─────────────────────────────────────────────────────────────────

    function deployMocks() internal {
        console2.log("=== Deploying Mock Tokens (CREATE3) ===");

        // Prepare arrays for faucet
        MockERC20[] memory tokenArray = new MockERC20[](tokens.length);
        uint256[] memory amounts = new uint256[](tokens.length);

        for (uint i = 0; i < tokens.length; i++) {
            // Drip amount: $50k worth (all mock tokens use 18 decimals)
            uint256 dripAmount = 50_000 * 1e18;

            bytes memory initCode = abi.encodePacked(
                type(MockERC20).creationCode,
                abi.encode(tokens[i].name, tokens[i].symbol, uint8(18), faucet)
            );

            address deployed = createX.deployCreate3(tokens[i].salt, initCode);

            tokens[i].addr = deployed;
            tokenArray[i] = MockERC20(deployed);
            amounts[i] = dripAmount;

            console2.log("  %s: %s (drip: %s)", tokens[i].symbol, deployed, dripAmount / 1e6);
        }

        // Add all tokens to faucet
        console2.log("\n=== Adding tokens to Faucet ===");
        MockFaucet(faucet).addTokens(tokenArray, amounts);
        console2.log("  Added %s tokens to faucet\n", tokens.length);
    }

    function deployFaucet(
        bytes32 salt,
        address expectedAddr,
        bool useCreate3
    ) internal returns (address) {
        if (useCreate3) {
            // Faucet constructor: (uint256 dripInterval, address owner)
            bytes memory initCode = abi.encodePacked(
                type(MockFaucet).creationCode,
                abi.encode(1 days, deployer)
            );

            address deployed = createX.deployCreate3(salt, initCode);
            require(deployed == expectedAddr, "Faucet deployed != expected");

            console2.log("Faucet: %s", deployed);
            return deployed;
        } else {
            MockFaucet deployed = new MockFaucet(1 days, deployer);
            console2.log("Faucet (non-deterministic): %s", address(deployed));
            return address(deployed);
        }
    }

    function initTokenDefs() internal {
        // Salts from salts/bbbb_bb.txt
        // Pool Zero tokens (multi-asset pool)
        _pushTok("Mock USD Coin", "mUSDC", 1, true, true, true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3007f7376a3eb2fff03398e1e);
        _pushTok("Mock Tether USD", "mUSDT", 1, true, true, true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bc1f715b7ef8ff03b100a2);
        _pushTok("Mock Wrapped Ether", "mWETH", 3500, false, true, false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3003ef9f4b604c0fd03d65b4d);
        _pushTok("Mock Wrapped Bitcoin", "mWBTC", 95000, false, true, false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300557ce5d8a6dbfe038ec92b);
        _pushTok("Mock Wrapped BNB", "mWBNB", 650, false, true, false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3001720cb50c3cdfd03560672);
        _pushTok("Mock Solana", "mSOL", 200, false, true, false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bc8a0a155f83ff03facaba);
        _pushTok("Mock Zcash", "mZEC", 45, false, true, false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300fab2bc8b8f2dfd0330eccc);
        _pushTok("Mock Paxos Gold", "mPAXG", 2700, false, true, false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300629fcc7678ddff038a4e2a);

        // Pool Stable tokens (USDT, USDC, USDS, USD1, USDE, FDUSD)
        _pushTok("Mock First Digital USD", "mFDUSD", 1, true, false, true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300d4e8e3af8766fe03565451);
        _pushTok("Mock USD Soul", "mUSDS", 1, true, false, true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300e4269b50f9dafc03541aa5); // reused DAI salt
        _pushTok("Mock USD One", "mUSD1", 1, true, false, true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300876580efd47fff037051ca); // reused TUSD salt
        _pushTok("Mock USD Ethena", "mUSDE", 1, true, false, true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3008f1a371f9d77ff03242859); // reused USDD salt
    }

    function _pushTok(
        string memory n,
        string memory s,
        uint p,
        bool st,
        bool z,
        bool sp,
        bytes32 salt
    ) internal {
        tokens.push(TokenDef(n, s, p, st, z, sp, salt, address(0)));
    }

    function getTokenAddr(string memory sym) internal view returns (address) {
        for (uint i = 0; i < tokens.length; i++) {
            if (keccak256(bytes(tokens[i].symbol)) == keccak256(bytes(sym))) return tokens[i].addr;
        }
        revert("Token not found");
    }

    // ─────────────────────────────────────────────────────────────────
    // MODULES & CONFIG
    // ─────────────────────────────────────────────────────────────────

    function deployModules() internal {
        console2.log("=== Deploying Modules (CREATE) ===");
        exchangeModule = address(new ExchangeV1());
        liquidityModule = address(new LiquidityV1());
        adminModule = address(new AdminV1());
        oracleModule = address(new InternalOracleV1());
        stakingModule = address(new StakingV1());
        distributorModule = address(new DistributorV1());
        flashModule = address(new FlashV1());
        rescueModule = address(new RescueV1());
        console2.log("  All modules deployed\n");
    }

    function _registerModules(address pool) internal {
        address[] memory impls = new address[](8);
        impls[0] = exchangeModule;
        impls[1] = liquidityModule;
        impls[2] = adminModule;
        impls[3] = oracleModule;
        impls[4] = stakingModule;
        impls[5] = distributorModule;
        impls[6] = flashModule;
        impls[7] = rescueModule;

        // Mark all modules as trusted
        bool[] memory trusted = new bool[](8);
        for (uint i = 0; i < 8; i++) {
            trusted[i] = true;
        }
        PoolProxyV1(payable(pool)).setModuleTrustBatch(impls, trusted);

        bytes4[][] memory selectors = new bytes4[][](8);
        selectors[0] = getExchangeSelectors();
        selectors[1] = getLiquiditySelectors();
        selectors[2] = getAdminSelectors();
        selectors[3] = getOracleSelectors();
        selectors[4] = getStakingSelectors();
        selectors[5] = getDistributorSelectors();
        selectors[6] = getFlashSelectors();
        selectors[7] = getRescueSelectors();

        PoolProxyV1(payable(pool)).addModules(impls, selectors);
    }

    function _addAsset(address pool, TokenDef memory t) internal {
        uint8[13] memory oraclePad;
        uint8[16] memory riskPad;

        uint8 accDec = t.isStable ? 6 : 12;
        uint64 encodedPrice = LibMaths.encodeB64(t.price * 1e18, 18);

        // Curve-style stable pool configuration
        // minFeeBps: 10 = 0.001% (ultra-competitive)
        // depthAmplifier: 500,000 = 50% virtual depth at low coverage
        // minDispersion: 500 = 0.05% (tight range around peg)
        // maxDispersion: 20,000 = 2% (Curve-style max range)
        // gamma: 5,000 = 0.5x inventory sensitivity (less skew for pegged assets)
        // vega: 5,000 = 0.5x volatility sensitivity (stables are stable)
        // lambda: 10,000 = 1.0x deviation sensitivity (keep default)

        IAdminV1(pool).addAsset(
            t.addr,
            IPoolV1.OracleConfig({
                primary: pool,
                secondary: address(0),
                feedId: bytes32(0),
                modeFlags: 0,
                accDecimals: accDec,
                _pad: oraclePad
            }),
            IPoolV1.RiskConfig({
                decayStartRatioBps: 9800,
                coverageMin: 5000,
                coverageMax: t.isStable ? 11000 : 20000,  // 110% for stables, 200% for volatile
                decaySlope: 31709791,
                depthAmplifier: t.isStable ? 50000 : 5000,  // 5% for stables, 0.5% for volatile (prevents excessive depth when liabilities=0)
                flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
                _pad: riskPad
            }),
            t.isStable ? concentratedProfile() : balancedProfile(),
            t.isStable ? 10 : 100,  // minFeeBps: 0.001% for stables, 0.01% for volatile
            18,
            encodedPrice,
            10000,
            10000,
            t.isStable ? 500 : 1000,    // minDispersion: 0.05% for stables, 0.1% for volatile
            t.isStable ? 20000 : 100000, // maxDispersion: 2% for stables, 10% for volatile
            t.isStable ? 5000 : 10000,   // gamma: 0.5x for stables, 1.0x for volatile
            t.isStable ? 5000 : 10000,   // vega: 0.5x for stables, 1.0x for volatile
            10000                       // lambda: 1.0x for all
        );
        console2.log("  Added asset: %s", t.symbol);
    }

    function _refreshFeeds(address pool, bool isPoolZero) internal {
        for (uint i = 0; i < tokens.length; i++) {
            if (isPoolZero ? tokens[i].inPoolZero : tokens[i].inPoolStable) {
                uint8 accDec = tokens[i].isStable ? 6 : 12;
                uint64 price = LibMaths.encodeB64(tokens[i].price * 1e18, 18);
                InternalOracleV1(pool).updateFeed(tokens[i].addr, price, accDec, 10000, 10000);
            }
        }
    }

    function _getDefaultFeeParams() internal pure returns (IPoolV1.FeeParams memory) {
        uint8[29] memory pad;
        return IPoolV1.FeeParams({
            protoShare: 25,
            flashFeeBps: 5,
            _pad: pad
        });
    }

    // ─────────────────────────────────────────────────────────────────
    // EXPORT
    // ─────────────────────────────────────────────────────────────────

    function exportDeployment() internal {
        // Skip JSON export in tests to avoid file permission issues
        // string memory pools = "pools";
        // vm.serializeAddress(pools, "poolZero", poolZero);
        // string memory poolsJson = vm.serializeAddress(pools, "poolStable", poolStable);
        //
        // string memory deployment = "deployment";
        // vm.serializeUint(deployment, "chainId", block.chainid);
        // vm.serializeString(deployment, "pools", poolsJson);
        // vm.serializeAddress(deployment, "factory", factory);
        // vm.serializeAddress(deployment, "router", router);
        // vm.serializeAddress(deployment, "referencePool", referencePool);
        // vm.serializeAddress(deployment, "btrToken", btrToken);
        // vm.serializeAddress(deployment, "treasury", treasury);
        // vm.serializeAddress(deployment, "bridge", bridge);
        // vm.serializeAddress(deployment, "faucet", faucet);
        // string memory finalJson = vm.serializeUint(deployment, "timestamp", block.timestamp);
        //
        // string memory path = "./deployment.json";
        // vm.writeJson(finalJson, path);

        console2.log("\n=== Deployment Complete ===");
        console2.log("  Factory: %s", factory);
        console2.log("  Router: %s", router);
        console2.log("  Reference Pool: %s", referencePool);
        console2.log("  Pool Zero: %s", poolZero);
        console2.log("  Pool Stable: %s", poolStable);
        console2.log("  BTR Token: %s", btrToken);
        console2.log("  Treasury: %s", treasury);
        console2.log("  Bridge: %s", bridge);
        console2.log("  Faucet: %s", faucet);
    }

    function exportMockTokens() internal {
        // Skip JSON export in tests
        // string memory tokensKey = "tokens";
        // for (uint i = 0; i < tokens.length; i++) {
        //     vm.serializeAddress(tokensKey, tokens[i].symbol, tokens[i].addr);
        // }
        // string memory tokensJson = vm.serializeAddress(tokensKey, "last", address(0));
        //
        // string memory deployment = "deployment";
        // vm.serializeString(deployment, "tokens", tokensJson);
        //
        // string memory path = "./mock-tokens.json";
        // vm.writeJson(deployment, path);
        // console2.log("Saved mock tokens to: %s", path);
    }

    // ─────────────────────────────────────────────────────────────────
    // SELECTORS & PROFILES
    // ─────────────────────────────────────────────────────────────────

    function concentratedProfile() internal pure returns (IPoolV1.LiquidityProfile memory p) {
        p.weights[0] = 10;
        p.weights[1] = 180;
        p.weights[2] = 10;
        p.knots[0] = -50;
        p.knots[1] = -5;
        p.knots[2] = 5;
        p.knots[3] = 50;
    }

    function balancedProfile() internal pure returns (IPoolV1.LiquidityProfile memory p) {
        p.weights[0] = 50;
        p.weights[1] = 100;
        p.weights[2] = 50;
        p.knots[0] = -50;
        p.knots[1] = -15;
        p.knots[2] = 15;
        p.knots[3] = 50;
    }

    function getExchangeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0] = IExchangeV1.swap.selector;
        s[1] = IExchangeV1.batchSwap.selector;
        s[2] = IExchangeV1.getSwapQuote.selector;
        s[3] = IExchangeV1.owner.selector;
        s[4] = IExchangeV1.baseToken.selector;
        s[5] = IExchangeV1.wnative.selector;
        s[6] = IExchangeV1.getAsset.selector;
        s[7] = IExchangeV1.getLPBalance.selector;
        s[8] = IExchangeV1.getProtocolFees.selector;
        s[9] = IExchangeV1.getCoverageRatio.selector;
        s[10] = IExchangeV1.getMidPrice.selector;
        s[11] = IExchangeV1.getFeedConfig.selector;
        s[12] = IExchangeV1.getRiskConfig.selector;
        s[13] = IExchangeV1.getLiquidityProfile.selector;
    }

    function getLiquiditySelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = ILiquidityV1.deposit.selector;
        s[1] = ILiquidityV1.withdraw.selector;
        s[2] = ILiquidityV1.withdrawTo.selector;
        s[3] = ILiquidityV1.swapLiability.selector;
        s[4] = ILiquidityV1.donate.selector;
    }

    function getAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = IAdminV1.freezeAsset.selector;
        s[1] = IAdminV1.unfreezeAsset.selector;
        s[2] = bytes4(keccak256("addAsset(address,(address,address,bytes32,uint16,uint8,uint8[13]),(uint16,uint16,uint32,uint16,uint16,uint8[16]),(uint8[16],int8[17]),uint16,uint8,uint64,uint32,uint32,uint32,uint32,uint16,uint16,uint16)"));
        s[3] = IAdminV1.requestAddAsset.selector;
        s[4] = IAdminV1.executeAddAsset.selector;
        s[5] = IAdminV1.requestUpdateRiskConfig.selector;
        s[6] = IAdminV1.executeUpdateRiskConfig.selector;
        s[7] = IAdminV1.requestUpdateFeeParams.selector;
        s[8] = IAdminV1.executeUpdateFeeParams.selector;
        s[9] = IAdminV1.collectProtocolFees.selector;
        s[10] = IAdminV1.requestOwnershipTransfer.selector;
        s[11] = IAdminV1.executeOwnershipTransfer.selector;
        s[12] = IAdminV1.requestBridgeUpdate.selector;
        s[13] = IAdminV1.executeBridgeUpdate.selector;
        s[14] = IAdminV1.requestTreasuryUpdate.selector;
        s[15] = IAdminV1.executeTreasuryUpdate.selector;
        s[16] = IAdminV1.requestModuleUpdate.selector;
        s[17] = IAdminV1.executeModuleUpdate.selector;
        s[18] = IAdminV1.cancelTimelock.selector;
        s[19] = IAdminV1.getModule.selector;
        s[20] = bytes4(keccak256("setAnchor(address,address)"));
    }

    function getOracleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("getFeed(address)"));
        s[1] = bytes4(keccak256("updateFeed(address,uint64,uint8,uint32,uint32)"));
        s[2] = bytes4(keccak256("pushFeedInternal(address,address,uint64,uint64)"));
        s[3] = bytes4(keccak256("isFeedFresh(address,uint32)"));
        s[4] = bytes4(keccak256("isFeedFresh(address)"));
        s[5] = bytes4(keccak256("getFastTWAP(address)"));
    }

    function getStakingSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("stakeGov(uint256)"));
        s[1] = bytes4(keccak256("unstakeGov(uint256)"));
        s[2] = bytes4(keccak256("stakeLP(address,uint256)"));
        s[3] = bytes4(keccak256("unstakeLP(address,uint256)"));
        s[4] = bytes4(keccak256("claimRewards()"));
        s[5] = bytes4(keccak256("getStakingInfo(address)"));
    }

    function getDistributorSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("distribute(address,uint256)"));
        s[1] = bytes4(keccak256("setRewardRate(uint256)"));
        s[2] = bytes4(keccak256("getPendingRewards(address)"));
        s[3] = bytes4(keccak256("notifyRewardAmount(uint256)"));
    }

    function getFlashSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256("flashLoan(address,uint256,bytes)"));
    }

    function getRescueSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = bytes4(keccak256("rescueTokens(address,address,uint256)"));
        s[1] = bytes4(keccak256("rescueNative(address,uint256)"));
    }
}
