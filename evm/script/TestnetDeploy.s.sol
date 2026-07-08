// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Deploy} from "./Deploy.s.sol";
import {Admin} from "../src/Admin.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ExternalOracle} from "../src/oracles/ExternalOracle.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {TestnetFaucet} from "../src/testnet/TestnetFaucet.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title TestnetDeploy — chapel (chainId 97) full demo stack.
/// @notice Extends singleton deploy with mock ERC20s, Faucet, ExternalOracle, two pools,
///         feeds (params aligned with deploy/testnet-asset-params.json), and seed liquidity.
/// @dev Env: DEPLOYER_PK (required). Optional: ORACLE_PUSHER, WNATIVE (default 0xCAFE stub),
///         SEED_USDC (default 2_000_000e18 per pool side), DEPLOY_OUT.
/// @dev Run: forge script script/TestnetDeploy.s.sol:TestnetDeploy --sig deployTestnet --rpc-url chapel --broadcast
contract TestnetDeploy is Deploy {
    uint16 internal constant TAU = 1800;
    uint16 internal constant STABLE_TTL = 7200;
    uint16 internal constant VOLATILE_TTL = 600;
    uint32 internal constant SIGMA_SEED = 10_000; // 1% PBPS
    uint16 internal constant CONF_SEED = 25; // bps interim

    struct Tokens {
        TestnetERC20 usdc;
        TestnetERC20 usdt;
        TestnetERC20 usd1;
        TestnetERC20 usde;
        TestnetERC20 fdusd;
        TestnetERC20 btcb;
        TestnetERC20 eth;
        TestnetERC20 wbnb;
        TestnetERC20 cake;
        TestnetERC20 xaut;
    }

    struct TestnetAddrs {
        Deploy.Addrs core;
        ExternalOracle oracle;
        TestnetFaucet faucet;
        Tokens tok;
        bytes32 usdcFeedId;
        address stablePool;
        address volatilePool;
    }

    function deployTestnet() external returns (TestnetAddrs memory out) {
        out.core = _broadcastDeploy();
        address deployer = out.core.deployer;
        address oraclePusher = vm.envOr("ORACLE_PUSHER", deployer);
        address wnative = vm.envOr("WNATIVE", address(0xCAFE));
        uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(2_000_000 ether));

        vm.startBroadcast(deployer);

        out.tok = _deployTokens();
        out.faucet = new TestnetFaucet();
        out.oracle = new ExternalOracle(out.core.ac, deployer);
        if (oraclePusher != deployer) {
            out.oracle.grantOracle(oraclePusher);
        }

        out.usdcFeedId = _seedFeeds(out.oracle, out.tok);

        out.stablePool = _createPool(out, wnative, _stableList(out.tok), seedUsdc, true);
        out.volatilePool = _createPool(out, wnative, _volatileList(out.tok), seedUsdc, false);

        _fundFaucet(out);

        vm.stopBroadcast();

        _logTestnet(out);
        _persistTestnet(out);
    }

    function _deployTokens() internal returns (Tokens memory t) {
        t.usdc = new TestnetERC20("USD Coin", "USDC", 18);
        t.usdt = new TestnetERC20("Tether USD", "USDT", 18);
        t.usd1 = new TestnetERC20("World Liberty USD", "USD1", 18);
        t.usde = new TestnetERC20("Ethena USDe", "USDE", 18);
        t.fdusd = new TestnetERC20("First Digital USD", "FDUSD", 18);
        t.btcb = new TestnetERC20("Bitcoin BEP20", "BTCB", 18);
        t.eth = new TestnetERC20("Ethereum Peg", "ETH", 18);
        t.wbnb = new TestnetERC20("Wrapped BNB", "WBNB", 18);
        t.cake = new TestnetERC20("PancakeSwap", "CAKE", 18);
        t.xaut = new TestnetERC20("Tether Gold", "XAUT", 18);
    }

    function _seedFeeds(ExternalOracle oracle, Tokens memory t) internal returns (bytes32 usdcFeed) {
        address usdc = address(t.usdc);
        usdcFeed = keccak256(abi.encodePacked(usdc, usdc));
        oracle.addFeed(usdc, usdc, M.encodeB64(1e18, 18), SIGMA_SEED, CONF_SEED, TAU, TAU, 0, STABLE_TTL);

        _addPairFeed(oracle, address(t.usdt), usdc, M.encodeB64(1e18, 18), STABLE_TTL);
        _addPairFeed(oracle, address(t.usd1), usdc, M.encodeB64(1e18, 18), STABLE_TTL);
        _addPairFeed(oracle, address(t.usde), usdc, M.encodeB64(1e18, 18), STABLE_TTL);
        _addPairFeed(oracle, address(t.fdusd), usdc, M.encodeB64(1e18, 18), STABLE_TTL);

        _addPairFeed(oracle, address(t.btcb), usdc, M.encodeB64(62_000e18, 18), VOLATILE_TTL);
        _addPairFeed(oracle, address(t.eth), usdc, M.encodeB64(3_100e18, 18), VOLATILE_TTL);
        _addPairFeed(oracle, address(t.wbnb), usdc, M.encodeB64(610e18, 18), VOLATILE_TTL);
        _addPairFeed(oracle, address(t.cake), usdc, M.encodeB64(2.4e18, 18), VOLATILE_TTL);
        _addPairFeed(oracle, address(t.xaut), usdc, M.encodeB64(2_380e18, 18), VOLATILE_TTL);
    }

    function _addPairFeed(
        ExternalOracle oracle,
        address asset,
        address usdc,
        uint64 priceB64,
        uint16 ttl
    ) internal {
        oracle.addFeed(asset, usdc, priceB64, SIGMA_SEED, CONF_SEED, TAU, TAU, 0, ttl);
    }

    function _stableList(Tokens memory t) internal pure returns (address[] memory list) {
        list = new address[](5);
        list[0] = address(t.usdc);
        list[1] = address(t.usdt);
        list[2] = address(t.usd1);
        list[3] = address(t.usde);
        list[4] = address(t.fdusd);
    }

    function _volatileList(Tokens memory t) internal pure returns (address[] memory list) {
        list = new address[](7);
        list[0] = address(t.usdc);
        list[1] = address(t.usdt);
        list[2] = address(t.btcb);
        list[3] = address(t.eth);
        list[4] = address(t.wbnb);
        list[5] = address(t.cake);
        list[6] = address(t.xaut);
    }

    function _createPool(
        TestnetAddrs memory ctx,
        address wnative,
        address[] memory tokens,
        uint256 seedUsdc,
        bool stable
    ) internal returns (address poolAddr) {
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 20, flashFeeBps: 100, _pad: pad});
        bytes memory initdata =
            abi.encodeWithSelector(Pool.initialize.selector, tokens[0], wnative, fp);
        poolAddr = PoolFactory(payable(ctx.core.poolFactory)).createPool(tokens[0], tokens, initdata);
        Pool pool = Pool(payable(poolAddr));
        Admin admin = Admin(ctx.core.admin);
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();

        for (uint256 i = 0; i < tokens.length; i++) {
            address tok = tokens[i];
            (uint16 minFee, uint16 refBand) = _assetParams(tok, ctx.tok, stable);
            IPool.OracleConfig memory oc = _oracleCfg(address(ctx.oracle), tok, tokens[0], ctx.usdcFeedId, refBand);
            admin.addAsset(poolAddr, tok, oc, rc, pf, minFee, 18, 1000, 100_000, 10_000, 10_000);
        }

        _seedPool(pool, ctx.tok, tokens, seedUsdc);
    }

    function _assetParams(address tok, Tokens memory t, bool stable)
        internal
        pure
        returns (uint16 minFee, uint16 refBand)
    {
        minFee = 1;
        refBand = 0;
        if (tok == address(t.usdt)) refBand = 100;
        else if (stable && tok != address(t.usdc)) refBand = 150;
        else if (!stable && tok == address(t.xaut)) refBand = 200;
    }

    function _oracleCfg(
        address oracle,
        address asset,
        address base,
        bytes32 usdcFeedId,
        uint16 refBandBps
    ) internal pure returns (IPool.OracleConfig memory o) {
        o.primary = oracle;
        o.feedId = keccak256(abi.encodePacked(asset, base));
        o.refFeedId = refBandBps > 0 ? usdcFeedId : bytes32(0);
        o.refBandBps = refBandBps;
        o.mode = 0;
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20_000;
        r.depthAmplifier = 10_000;
    }

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50;
        p.weights[1] = 50;
        p.weights[2] = 50;
        p.weights[3] = 50;
        p.knots[0] = -50;
        p.knots[1] = -25;
        p.knots[2] = 0;
        p.knots[3] = 25;
        p.knots[4] = 50;
    }

    function _seedPool(Pool pool, Tokens memory t, address[] memory tokens, uint256 seedUsdc) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address tok = tokens[i];
            uint256 amt = _seedAmount(tok, t, seedUsdc);
            TestnetERC20(tok).mint(address(this), amt);
            IERC20(tok).approve(address(pool), type(uint256).max);
            pool.deposit(tok, amt);
        }
    }

    function _seedAmount(address tok, Tokens memory t, uint256 seedUsdc) internal pure returns (uint256) {
        if (tok == address(t.usdc) || tok == address(t.usdt) || tok == address(t.usd1) || tok == address(t.usde)
            || tok == address(t.fdusd)) {
            return seedUsdc;
        }
        if (tok == address(t.btcb)) return seedUsdc * 1e18 / 62_000e18;
        if (tok == address(t.eth)) return seedUsdc * 1e18 / 3_100e18;
        if (tok == address(t.wbnb)) return seedUsdc * 1e18 / 610e18;
        if (tok == address(t.cake)) return seedUsdc * 1e18 / 2.4e18;
        if (tok == address(t.xaut)) return seedUsdc * 1e18 / 2_380e18;
        return seedUsdc;
    }

    function _fundFaucet(TestnetAddrs memory ctx) internal {
        address[] memory all = _allTokens(ctx.tok);
        for (uint256 i = 0; i < all.length; i++) {
            TestnetERC20(all[i]).mint(address(this), 1_000_000 ether);
            IERC20(all[i]).approve(address(ctx.faucet), type(uint256).max);
            ctx.faucet.fund(all[i], 500_000 ether);
        }
    }

    function _allTokens(Tokens memory t) internal pure returns (address[] memory list) {
        list = new address[](10);
        list[0] = address(t.usdc);
        list[1] = address(t.usdt);
        list[2] = address(t.usd1);
        list[3] = address(t.usde);
        list[4] = address(t.fdusd);
        list[5] = address(t.btcb);
        list[6] = address(t.eth);
        list[7] = address(t.wbnb);
        list[8] = address(t.cake);
        list[9] = address(t.xaut);
    }

    function _logTestnet(TestnetAddrs memory a) internal view {
        console2.log("=== BTR chapel testnet ===");
        console2.log("ExternalOracle:", address(a.oracle));
        console2.log("Faucet:", address(a.faucet));
        console2.log("Stable pool:", a.stablePool);
        console2.log("Volatile pool:", a.volatilePool);
        console2.log("USDC feedId:");
        console2.logBytes32(a.usdcFeedId);
    }

    function _persistTestnet(TestnetAddrs memory a) internal {
        string memory k = "chapel";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "oracle", address(a.oracle));
        vm.serializeAddress(k, "faucet", address(a.faucet));
        vm.serializeAddress(k, "stablePool", a.stablePool);
        vm.serializeAddress(k, "volatilePool", a.volatilePool);
        vm.serializeBytes32(k, "usdcFeedId", a.usdcFeedId);
        vm.serializeAddress(k, "routerProxy", a.core.routerProxy);
        vm.serializeAddress(k, "poolFactory", a.core.poolFactory);
        vm.serializeAddress(k, "admin", a.core.admin);
        vm.serializeAddress(k, "ac", a.core.ac);
        vm.serializeAddress(k, "usdc", address(a.tok.usdc));
        vm.serializeAddress(k, "usdt", address(a.tok.usdt));
        vm.serializeAddress(k, "usd1", address(a.tok.usd1));
        vm.serializeAddress(k, "usde", address(a.tok.usde));
        vm.serializeAddress(k, "fdusd", address(a.tok.fdusd));
        vm.serializeAddress(k, "btcb", address(a.tok.btcb));
        vm.serializeAddress(k, "eth", address(a.tok.eth));
        vm.serializeAddress(k, "wbnb", address(a.tok.wbnb));
        vm.serializeAddress(k, "cake", address(a.tok.cake));
        string memory json = vm.serializeAddress(k, "xaut", address(a.tok.xaut));

        string memory outPath = vm.envOr(
            "DEPLOY_OUT",
            string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
        );
        try vm.writeJson(json, outPath) {} catch {
            console2.log("(skip) writeJson not permitted");
        }
    }
}
