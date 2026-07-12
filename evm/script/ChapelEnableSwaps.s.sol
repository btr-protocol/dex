// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";

/// @title ChapelEnableSwaps — surgical Chapel reseed: new Admin+pools, reuse tokens/oracle/faucet.
/// @notice Live Admin predates shared `govDelay` (1d LOW). Pool.admin is immutable ⇒ no in-place
///         risk-flag flip. Redeploy Admin/Flash/PoolAux/Pool/Factory, list assets with
///         SWAP|LIABILITY_SWAP already set, seed liquidity. Keeps AC + ExternalOracle + mocks + faucet.
/// @dev Run:
///   forge script script/ChapelEnableSwaps.s.sol:ChapelEnableSwaps --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelEnableSwaps is Script {
    // Existing Chapel stack (97.deploy.json) — tokens/oracle/faucet/AC preserved.
    address constant AC = 0x626eb915d4a4136F7c00352A54378d3A322488da;
    address constant ORACLE = 0xD91712c9F4037D0010041691Df191AB45994F2bF;
    address constant FAUCET = 0x6a901982CE6cD2561F677217e012A33b8a88EF27;
    address constant WNATIVE = address(0xCAFE);
    bytes32 constant USDC_FEED = 0xdacab87341ef44905f4cfdb16cbfbd61ad65accd449f2df15ae6fb26f53ba17d;

    address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
    address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;
    address constant USD1 = 0xC28bE4D407096E771F932c202F13D866B4d6BA07;
    address constant USDE = 0xebF751546832ec77a039083E9FDd8158B21c0172;
    address constant FDUSD = 0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc;
    address constant BTCB = 0xd719319e853670ac938e426fbdB70CFdb34c11Fa;
    address constant ETH = 0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189;
    address constant WBNB = 0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D;
    address constant CAKE = 0xa7E62dd82789346bEb48a80227B5d926c6403400;
    address constant XAUT = 0xd384aC4696FA230c9049F6534Fc35aC3af586073;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        // Lean seed for smoke (enough depth; deployer already holds large balances).
        uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(50_000 ether));

        vm.startBroadcast(pk);

        Admin admin = new Admin(AC);
        Flash flash = new Flash();
        PoolAux poolAux = new PoolAux(AC, address(admin), address(flash));
        Pool poolImpl = new Pool(AC, address(admin), address(flash), address(poolAux));
        PoolFactory factory = new PoolFactory(address(poolImpl), deployer, AC);

        address stable = _createPool(admin, factory, _stableList(), seedUsdc, true);
        address vol = _createPool(admin, factory, _volatileList(), seedUsdc, false);

        vm.stopBroadcast();

        console2.log("=== ChapelEnableSwaps ===");
        console2.log("admin", address(admin));
        console2.log("factory", address(factory));
        console2.log("stablePool", stable);
        console2.log("volatilePool", vol);
        console2.log("oracle(kept)", ORACLE);
        console2.log("faucet(kept)", FAUCET);
        console2.log("ac(kept)", AC);

        _persist(address(admin), address(factory), stable, vol);
    }

    function _stableList() internal pure returns (address[] memory list) {
        list = new address[](5);
        list[0] = USDC;
        list[1] = USDT;
        list[2] = USD1;
        list[3] = USDE;
        list[4] = FDUSD;
    }

    function _volatileList() internal pure returns (address[] memory list) {
        list = new address[](7);
        list[0] = USDC;
        list[1] = USDT;
        list[2] = BTCB;
        list[3] = ETH;
        list[4] = WBNB;
        list[5] = CAKE;
        list[6] = XAUT;
    }

    function _createPool(
        Admin admin,
        PoolFactory factory,
        address[] memory tokens,
        uint256 seedUsdc,
        bool stable
    ) internal returns (address poolAddr) {
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 20, flashFeeBps: 100, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, tokens[0], WNATIVE, fp);
        poolAddr = factory.createPool(tokens[0], tokens, initdata);

        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();

        for (uint256 i = 0; i < tokens.length; i++) {
            address tok = tokens[i];
            (uint16 minFee, uint16 refBand, uint32 minDisp, uint32 maxDisp) = _assetParams(tok, stable);
            IPool.OracleConfig memory oc = _oracleCfg(tok, tokens[0], refBand);
            IPool.LiquidityProfile memory pfTok = stable ? _stableProfile() : pf;
            admin.addAsset(poolAddr, tok, oc, rc, pfTok, minFee, 18, minDisp, maxDisp, 10_000, 10_000);
        }

        admin.setBaseTokenOracle(poolAddr, ORACLE, USDC_FEED);
        admin.sealBootstrap(poolAddr);

        _seedPool(Pool(payable(poolAddr)), tokens, seedUsdc);
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20_000;
        r.depthAmplifier = 10_000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        // Volatile default (flat-ish 5-knot). Stable uses `_stableProfile`.
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

    /// @dev testnet-asset-params.json sharedLiquidityProfile — 4-knot center bump.
    function _stableProfile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 25;
        p.weights[1] = 150;
        p.weights[2] = 25;
        p.knots[0] = -50;
        p.knots[1] = -12;
        p.knots[2] = 12;
        p.knots[3] = 50;
    }

    /// @dev Per-asset from testnet-asset-params.json stable-core / volatile-core.
    function _assetParams(address tok, bool stable)
        internal
        pure
        returns (uint16 minFee, uint16 refBand, uint32 minDisp, uint32 maxDisp)
    {
        if (stable) {
            minDisp = 500;
            maxDisp = 5000;
            minFee = 10;
            refBand = 0;
            if (tok == USDC) { minFee = 10; minDisp = 100; maxDisp = 2000; refBand = 50; }
            else if (tok == USDT) { minFee = 10; minDisp = 600; maxDisp = 6000; refBand = 100; }
            else if (tok == USD1) { minFee = 10; minDisp = 500; maxDisp = 5000; refBand = 150; }
            else if (tok == USDE) { minFee = 15; minDisp = 500; maxDisp = 5000; refBand = 200; }
            else if (tok == FDUSD) { minFee = 15; minDisp = 500; maxDisp = 5000; refBand = 200; }
            return (minFee, refBand, minDisp, maxDisp);
        }
        // volatile-core defaults (minDisp 50_000 → ±2.5% with knots ±50)
        minFee = 1000;
        minDisp = 50_000;
        maxDisp = 500_000;
        refBand = 0;
        if (tok == USDT) refBand = 100;
        // No refFeedId for XAUT (or other volatiles) → refBandBps must stay 0 (inactive guard).
    }

    function _oracleCfg(address asset, address base, uint16 refBandBps)
        internal
        pure
        returns (IPool.OracleConfig memory o)
    {
        o.primary = ORACLE;
        o.feedId = asset == USDC ? USDC_FEED : keccak256(abi.encodePacked(asset, base));
        // Only USDT pins USDC as depeg ref (testnet-asset-params). Others: refFeedId=0 and refBandBps=0.
        if (asset == USDT) {
            o.refFeedId = USDC_FEED;
            o.refBandBps = refBandBps;
        } else {
            o.refFeedId = bytes32(0);
            o.refBandBps = 0;
        }
        o.mode = 0;
    }

    function _seedAmount(address tok, uint256 seedUsdc) internal pure returns (uint256) {
        // 50k USD notionnel per token (mark-sized for volatiles). Marks ~2026-07-11 NXR.
        if (tok == USDC || tok == USDT || tok == USD1 || tok == USDE || tok == FDUSD) return seedUsdc;
        if (tok == BTCB) return seedUsdc * 1e18 / 64_250e18;
        if (tok == ETH) return seedUsdc * 1e18 / 1_802e18;
        if (tok == WBNB) return seedUsdc * 1e18 / 582e18;
        if (tok == CAKE) return seedUsdc * 1e18 / 1.43e18;
        if (tok == XAUT) return seedUsdc * 1e18 / 4_105e18;
        return seedUsdc;
    }

    function _seedPool(Pool pool, address[] memory tokens, uint256 seedUsdc) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address tok = tokens[i];
            uint256 amt = _seedAmount(tok, seedUsdc);
            // Top up via minter if balance short (deployer is TestnetERC20.minter).
            uint256 bal = IERC20(tok).balanceOf(msg.sender);
            if (bal < amt) {
                TestnetERC20(tok).mint(msg.sender, amt - bal);
            }
            IERC20(tok).approve(address(pool), type(uint256).max);
            pool.deposit(tok, amt);
        }
    }

    function _persist(address admin, address factory, address stable, address vol) internal {
        string memory k = "chapel";
        vm.serializeUint(k, "chainId", uint256(97));
        vm.serializeAddress(k, "ac", AC);
        vm.serializeAddress(k, "admin", admin);
        vm.serializeAddress(k, "poolFactory", factory);
        vm.serializeAddress(k, "oracle", ORACLE);
        vm.serializeAddress(k, "faucet", FAUCET);
        vm.serializeAddress(k, "stablePool", stable);
        vm.serializeAddress(k, "volatilePool", vol);
        vm.serializeBytes32(k, "usdcFeedId", USDC_FEED);
        vm.serializeAddress(k, "usdc", USDC);
        vm.serializeAddress(k, "usdt", USDT);
        vm.serializeAddress(k, "usd1", USD1);
        vm.serializeAddress(k, "usde", USDE);
        vm.serializeAddress(k, "fdusd", FDUSD);
        vm.serializeAddress(k, "btcb", BTCB);
        vm.serializeAddress(k, "eth", ETH);
        vm.serializeAddress(k, "wbnb", WBNB);
        vm.serializeAddress(k, "cake", CAKE);
        string memory json = vm.serializeAddress(k, "xaut", XAUT);
        try vm.writeJson(json, "deployments/97.deploy.json") {} catch {
            console2.log("(skip) writeJson");
            console2.log(json);
        }
    }
}
