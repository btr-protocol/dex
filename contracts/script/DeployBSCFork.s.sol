// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
 * CREATE3 DETERMINISTIC DEPLOYMENT
 * ─────────────────────────────────────────────────────────────────────────
 * This script uses CreateX CREATE3 for deterministic cross-chain addresses.
 *
 * Salt allocation:
 * - Core contracts (pools, bridge, treasury): salts/b712_b712.txt (lower b712)
 * - Mock ERC20 tokens: salts/bbbb_bb.txt
 *
 * All deployments use DEPLOYER_PK from .env to ensure identical addresses
 * across local fork (31337), testnet, and mainnet.
 * ─────────────────────────────────────────────────────────────────────────
 */

import {Script, console2} from "forge-std/Script.sol";
import {IPoolV1} from "../src/interfaces/IPoolV1.sol";
import {ICoreV1} from "../src/interfaces/modules/ICoreV1.sol";
import {IAdminV1} from "../src/interfaces/modules/IAdminV1.sol";
import {ICreateX} from "../src/interfaces/external/ICreateX.sol";
import {PoolProxyV1} from "../src/PoolProxyV1.sol";
import {ExchangeV1} from "../src/modules/ExchangeV1.sol";
import {LiquidityV1} from "../src/modules/LiquidityV1.sol";
import {AdminV1} from "../src/modules/AdminV1.sol";
import {InternalOracleV1} from "../src/modules/InternalOracleV1.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";
import {LibMaths} from "../src/libraries/LibMaths.sol";
import {LibCast} from "../src/libraries/LibCast.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title DeployBSCFork
/// @notice Deploy AIMM pools with CREATE3 deterministic addresses
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

    struct ModuleConfig {
        address exchange;
        address liquidity;
        address admin;
        address oracle;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────────────────────────────────

    TokenDef[] public tokens;
    ModuleConfig public modules;
    ICreateX public createX;
    address public deployer;
    address constant TEST_ADDR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Pool CREATE3 salts & expected addresses (from b712_b712.txt - lower b712)
    bytes32 constant SALT_POOL_ZERO = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a30030d6f06d1a2b1002c664a2;
    address constant EXPECTED_POOL_ZERO = 0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712;

    bytes32 constant SALT_POOL_STABLE = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bd8547f48cdb0302ad4c3e;
    address constant EXPECTED_POOL_STABLE = 0xb712dCA09c4327daC7789EA34574783dC554b712;

    // BTR Token CREATE3 salt & expected address (from b712_b712.txt - lower b712)
    bytes32 constant SALT_BTR = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a3002066d05b248fb3f09025efe1db9d1761b712;
    address constant EXPECTED_BTR = 0xb7122066D05B248FB3F09025EFe1db9d1761b712;

    // Treasury CREATE3 salt & expected address (from b712_b712.txt - lower b712)
    bytes32 constant SALT_TREASURY = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a3008212286a6e7f4fEF52E9c5CE6963C75ab712;
    address constant EXPECTED_TREASURY = 0xb7128212286a6e7f4fEF52E9c5CE6963C75ab712;

    // Bridge CREATE3 salt & expected address (from b712_b712.txt - lower b712)
    bytes32 constant SALT_BRIDGE = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a30069762A37C3bAaE98Bc1C9d95aec3885Fb712;
    address constant EXPECTED_BRIDGE = 0xb71269762A37C3bAaE98Bc1C9d95aec3885Fb712;

    // Pool addresses (deterministic via CREATE3)
    address public poolZero;
    address public poolStable;

    // BTR, Treasury, Bridge addresses (deterministic via CREATE3)
    address public btrToken;
    address public treasury;
    address public bridge;

    // Pool CREATE3 salts & expected addresses (from b712_b712.txt - lower b712)
    bytes32 constant SALT_POOL_ZERO = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a30030d6f06d1a2b1002c664a2;
    address constant EXPECTED_POOL_ZERO = 0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712;

    bytes32 constant SALT_POOL_STABLE = 0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bd8547f48cdb0302ad4c3e;
    address constant EXPECTED_POOL_STABLE = 0xb712dCA09c4327daC7789EA34574783dC554b712;

    // ─────────────────────────────────────────────────────────────────────────
    // MAIN RUN
    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        // Load env vars
        deployer = vm.envAddress("DEPLOYER");
        createX = ICreateX(vm.envAddress("CREATEX"));
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        bool useCreate3 = vm.envOr("USE_CREATE3", true);

        console2.log("Starting BTR Pool deployment...");
        console2.log("Deployment mode:", useCreate3 ? "Deterministic (CREATE3)" : "Non-deterministic (CREATE)");
        console2.log("Deployer:", deployer);
        console2.log("CreateX:", address(createX));
        console2.log();

        vm.startBroadcast(deployerPk);

        // 1. Setup & Deploy Mock Tokens (CREATE3)
        initTokenDefs();
        deployMocks();

        // 2. Deploy Modules (normal CREATE, not deterministic)
        deployModules();

        // 3. Deploy BTR Token (CREATE3)
        btrToken = deployUserContract("BTR Token", SALT_BTR, EXPECTED_BTR);
        console2.log("BTR Token Proxy: %s", btrToken);
        console2.log("  Treasury: %s", address(treasury));

        // 4. Deploy Treasury (CREATE3)
        treasury = deployUserContract("Treasury", SALT_TREASURY, EXPECTED_TREASURY);
        console2.log("Treasury Proxy: %s", treasury);
        console2.log("  Owner: %s", address(treasury));

        // 5. Deploy Bridge (CREATE3)
        bridge = deployUserContract("Bridge", SALT_BRIDGE, EXPECTED_BRIDGE);
        console2.log("Bridge Proxy: %s", bridge);
        console2.log("  Owner: %s", address(treasury));

    // ─────────────────────────────────────────────────────────────────
    // DEPLOYMENT FUNCTIONS (CREATE3 for user contracts)
    // ─────────────────────────────────────────────────────────────────

    function deployUserContract(
        string memory logName,
        bytes32 salt,
        address expectedAddr
    ) internal returns (address) {
        bytes32 processedSalt = LibCast.hashFast(bytes32(uint256(uint160(deployer))), salt);
        address predicted = createX.computeCreate3Address(processedSalt);

        if (useCreate3) {
            // Deploy with CREATE3
            bytes memory initCode = abi.encodePacked(type(PoolProxyV1).creationCode);
            address deployed = createX.deployCreate3(processedSalt, initCode);
            require(deployed == predicted, "CREATE3 computed address mismatch");
            require(deployed == expectedAddr, "CREATE3 expected address mismatch");
        } else {
            // Deploy with normal CREATE
            deployed = address(new PoolProxyV1());
        }

        console2.log("%s Proxy: %s", logName, deployed);
        return deployed;
    }

    function deployPool(
        string memory logName,
        bytes32 salt,
        address expectedAddr,
        address base,
        address wnative,
        bool isPoolZero
    ) internal returns (address) {
        address deployed = deployUserContract(logName, salt, expectedAddr);

        PoolProxyV1(payable(deployed)).initialize(deployer, base, wnative, IPoolV1.FeeParams({protoShare: 25, flashFeeBps: 5, _pad: feePad}));

        console2.log("%s configured with %s assets\n", logName, isPoolZero ? "Pool Zero" : "Pool Stable");
        return deployed;
    }

     // 6. Export Deployment JSON
        exportDeployment(poolZero, poolStable, btrToken, treasury, bridge);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DEPLOYMENT LOGIC
    // ─────────────────────────────────────────────────────────────────────────

    function deployMocks() internal {
        console2.log("=== Deploying Mock Tokens (CREATE3) ===");
        for (uint i = 0; i < tokens.length; i++) {
            uint256 supply = (tokens[i].isStable ? 100_000 : 100) * 1e18;

            // Deploy with CREATE3
            bytes32 processedSalt = LibCast.hashFast(bytes32(uint256(uint160(deployer))), tokens[i].salt);
            address predicted = createX.computeCreate3Address(processedSalt);

            bytes memory initCode = abi.encodePacked(
                type(MockERC20).creationCode, abi.encode(tokens[i].name, tokens[i].symbol, uint8(18))
            );

            address deployed = createX.deployCreate3(processedSalt, initCode);
            require(deployed == predicted, "CREATE3 address mismatch");

            tokens[i].addr = deployed;

            // Mint initial supply
            MockERC20(deployed).mint(TEST_ADDR, supply);

            console2.log("  %s: %s", tokens[i].symbol, deployed);
        }
        console2.log("  Test address funded: %s\n", TEST_ADDR);
    }

    function deployModules() internal {
        console2.log("=== Deploying Modules (CREATE) ===");
        modules.exchange = address(new ExchangeV1());
        modules.liquidity = address(new LiquidityV1());
        modules.admin = address(new AdminV1());
        modules.oracle = address(new InternalOracleV1());
        console2.log("ExchangeV1: %s", modules.exchange);
        console2.log("LiquidityV1: %s", modules.liquidity);
        console2.log("AdminV1: %s", modules.admin);
        console2.log("InternalOracleV1: %s\n", modules.oracle);
    }

    function deployPool(
        string memory logName,
        bytes32 salt,
        address expectedAddr,
        address base,
        address wnative,
        bool isPoolZero,
        bool useCreate3
    ) internal returns (address) {
        console2.log("=== Deploying %s ===", logName);

        address deployed;

        if (useCreate3) {
            // Deploy with CREATE3
            bytes32 processedSalt = LibCast.hashFast(bytes32(uint256(uint160(deployer))), salt);
            address predicted = createX.computeCreate3Address(processedSalt);

            bytes memory initCode = abi.encodePacked(type(PoolProxyV1).creationCode);
            deployed = createX.deployCreate3(processedSalt, initCode);

            require(deployed == predicted, "CREATE3 computed address mismatch");
            require(deployed == expectedAddr, "CREATE3 expected address mismatch");
        } else {
            // Deploy with normal CREATE
            deployed = address(new PoolProxyV1());
        }

        console2.log("%s Proxy: %s", logName, deployed);

        PoolProxyV1 pool = PoolProxyV1(payable(deployed));

        // Initialize pool
        uint8[29] memory feePad;
        pool.initialize(deployer, base, wnative, IPoolV1.FeeParams({protoShare: 25, flashFeeBps: 5, _pad: feePad}));

        registerModules(address(pool));

        // Batch Add Assets
        uint count = 0;
        for (uint i = 0; i < tokens.length; i++) {
            if (isPoolZero ? tokens[i].inPoolZero : tokens[i].inPoolStable) {
                _addAsset(address(pool), tokens[i]);
                count++;
            }
        }
        console2.log("%s configured with %s assets\n", logName, count);
        return deployed;
    }

    function _addAsset(address pool, TokenDef memory t) internal {
        uint8[13] memory oraclePad;
        uint8[18] memory riskPad;

        uint8 accDec = t.isStable ? 6 : 12;
        uint64 encodedPrice = LibMaths.encodeB64(t.price * 1e18, 18);

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
                coverageFloor: 5000,
                decaySlope: 31709791,
                depthAmplifier: 20000,
                flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
                _pad: riskPad
            }),
            t.isStable ? concentratedProfile() : balancedProfile(),
            t.isStable ? 5 : 100, // Slippage BPS
            18, // Decimals
            encodedPrice,
            10000,
            10000
        );
        console2.log("  Added: %s", t.symbol);
    }

    function registerModules(address pool) internal {
        address[] memory impls = new address[](4);
        impls[0] = modules.exchange;
        impls[1] = modules.liquidity;
        impls[2] = modules.admin;
        impls[3] = modules.oracle;

        bytes4[][] memory selectors = new bytes4[][](4);
        selectors[0] = getExchangeSelectors();
        selectors[1] = getLiquiditySelectors();
        selectors[2] = getAdminSelectors();
        selectors[3] = getOracleSelectors();

        PoolProxyV1(payable(pool)).addModules(impls, selectors);
    }

    function refreshFeeds(address pool, bool isPoolZero) internal {
        for (uint i = 0; i < tokens.length; i++) {
            if (isPoolZero ? tokens[i].inPoolZero : tokens[i].inPoolStable) {
                uint8 accDec = tokens[i].isStable ? 6 : 12;
                uint64 price = LibMaths.encodeB64(tokens[i].price * 1e18, 18);
                InternalOracleV1(pool).updateFeed(tokens[i].addr, price, accDec, 10000, 10000);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONFIG & HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    function initTokenDefs() internal {
        // Salts from salts/bbbb_bb.txt
        //              Name                        Sym        Price   Stable  Zero   Stable  Salt
        _pushTok(
            "Mock USD Coin",
            "mUSDC",
            1,
            true,
            true,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3007f7376a3eb2fff03398e1e
        );
        _pushTok(
            "Mock Tether USD",
            "mUSDT",
            1,
            true,
            true,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bc1f715b7ef8ff03b100a2
        );
        _pushTok(
            "Mock Wrapped Ether",
            "mWETH",
            3500,
            false,
            true,
            false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3003ef9f4b604c0fd03d65b4d
        );
        _pushTok(
            "Mock Wrapped Bitcoin",
            "mWBTC",
            95000,
            false,
            true,
            false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300557ce5d8a6dbfe038ec92b
        );
        _pushTok(
            "Mock Wrapped BNB",
            "mWBNB",
            650,
            false,
            true,
            false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3001720cb50c3cdfd03560672
        );
        _pushTok(
            "Mock Solana",
            "mSOL",
            200,
            false,
            true,
            false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bc8a0a155f83ff03facaba
        );
        _pushTok(
            "Mock Zcash",
            "mZEC",
            45,
            false,
            true,
            false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300fab2bc8b8f2dfd0330eccc
        );
        _pushTok(
            "Mock Paxos Gold",
            "mPAXG",
            2700,
            false,
            true,
            false,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300629fcc7678ddff038a4e2a
        );
        _pushTok(
            "Mock Dai Stablecoin",
            "mDAI",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300e4269b50f9dafc03541aa5
        );
        _pushTok(
            "Mock TrueUSD",
            "mTUSD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300876580efd47fff037051ca
        );
        _pushTok(
            "Mock First Digital USD",
            "mFDUSD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300d4e8e3af8766fe03565451
        );
        _pushTok(
            "Mock Decentralized USD",
            "mUSDD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3008f1a371f9d77ff03242859
        );
        _pushTok(
            "Mock Pax Dollar",
            "mUSDP",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a30056454b52d4a9fe0345facd
        );
        _pushTok(
            "Mock Curve USD",
            "mcrvUSD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300b45cdb609273ff03fade98
        );
        _pushTok(
            "Mock Lista USD",
            "mlisUSD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3007f7376a3eb2fff03398e1e // Reuse salt
        );
        _pushTok(
            "Mock Agora Dollar",
            "mAUSD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a300bc1f715b7ef8ff03b100a2 // Reuse salt
        );
        _pushTok(
            "Mock Frax USD",
            "mfrxUSD",
            1,
            true,
            false,
            true,
            0x0a37aec263cba0aabc09bac56a0f2074a22e69a3003ef9f4b604c0fd03d65b4d // Reuse salt
        );
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

    function exportDeployment(address pZero, address pStable, address btrToken, address treasury, address bridge) internal {
        // Nested JSON structure as expected by frontend
        string memory pools = "pools";
        vm.serializeAddress(pools, "poolZero", pZero);
        string memory poolsJson = vm.serializeAddress(pools, "poolStable", pStable);

        string memory deployment = "deployment";
        vm.serializeUint(deployment, "chainId", 31337);
        vm.serializeString(deployment, "pools", poolsJson);
        vm.serializeAddress(deployment, "btrToken", btrToken);
        vm.serializeAddress(deployment, "treasury", treasury);
        vm.serializeAddress(deployment, "bridge", bridge);
        string memory finalJson = vm.serializeUint(deployment, "timestamp", block.timestamp);

        string memory path = "./front/public/deployment.json";
        vm.writeJson(finalJson, path);
        console2.log("
Saved deployment to: %s", path);
        console2.log("  Pool Zero: %s", pZero);
        console2.log("  Pool Stable: %s", pStable);
        console2.log("  BTR Token: %s", btrToken);
        console2.log("  Treasury: %s", treasury);
        console2.log("  Bridge: %s
", bridge);
    }
        // Nested JSON structure as expected by frontend
        string memory pools = "pools";
        vm.serializeAddress(pools, "poolZero", pZero);
        string memory poolsJson = vm.serializeAddress(pools, "poolStable", pStable);

        string memory deployment = "deployment";
        vm.serializeUint(deployment, "chainId", 31337);
        vm.serializeString(deployment, "pools", poolsJson);
        string memory finalJson = vm.serializeUint(deployment, "timestamp", block.timestamp);

        string memory path = "./front/public/deployment.json";
        vm.writeJson(finalJson, path);
        console2.log("\nSaved deployment to: %s", path);
        console2.log("  Pool Zero: %s", pZero);
        console2.log("  Pool Stable: %s\n", pStable);
    }

    function exportMockTokens() internal {
        // Export mock token addresses for frontend use
        string memory tokens = "tokens";
        for (uint i = 0; i < tokens.length; i++) {
            vm.serializeAddress(tokens, tokens[i].symbol, tokens[i].addr);
        }
        string memory tokensJson = vm.serializeAddress(tokens, "last", address(0));

        string memory deployment = "deployment";
        vm.serializeString(deployment, "tokens", tokensJson);

        string memory path = "./front/public/mock-tokens.json";
        vm.writeJson(deployment, path);
        console2.log("\nSaved mock tokens to: %s", path);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SELECTORS & PROFILES
    // ─────────────────────────────────────────────────────────────────────────

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
        s = new bytes4[](12);
        s[0] = ICoreV1.swap.selector;
        s[1] = ICoreV1.getSwapQuote.selector;
        s[2] = ICoreV1.owner.selector;
        s[3] = ICoreV1.baseToken.selector;
        s[4] = ICoreV1.wnative.selector;
        s[5] = ICoreV1.getAsset.selector;
        s[6] = ICoreV1.getLPBalance.selector;
        s[7] = ICoreV1.getProtocolFees.selector;
        s[8] = ICoreV1.getCoverageRatio.selector;
        s[9] = ICoreV1.getMidPrice.selector;
        s[10] = IPoolV1.getFeedConfig.selector;
        s[11] = IPoolV1.getRiskConfig.selector;
    }

    function getLiquiditySelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = ICoreV1.deposit.selector;
        s[1] = ICoreV1.withdraw.selector;
        s[2] = ICoreV1.withdrawTo.selector;
        s[3] = ICoreV1.swapLiability.selector;
        s[4] = ICoreV1.donate.selector;
    }

    function getAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = IAdminV1.freezeAsset.selector;
        s[1] = IAdminV1.unfreezeAsset.selector;
        s[2] = bytes4(keccak256("addAsset(address,(address,address,bytes32,uint16,uint8,uint8[13]),(uint16,uint16,uint32,uint16,uint16,uint8[18]),(uint8[16],int8[17]),uint16,uint8,uint64,uint32,uint32)"));
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
}
