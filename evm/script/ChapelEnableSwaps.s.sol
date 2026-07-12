// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {ChapelSeedAmounts} from "./ChapelSeedAmounts.sol";

/// @title ChapelEnableSwaps — surgical Chapel reseed: new AC+Admin+pools; keep oracle/tokens/faucet.
/// @notice Bakes `deploy/testnet-asset-params.json` (2026-07-12b): stable κ wall, γ=2×, refs, fees.
///         New AccessControl so Steward-lite `isGuardian` / `isRiskSteward` exist. ExternalOracle
///         stays on incumbent AC (same owner EOA) — pusher grants unchanged.
/// @dev Run:
///   forge script script/ChapelEnableSwaps.s.sol:ChapelEnableSwaps --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelEnableSwaps is Script {
    address constant OLD_AC = 0x626eb915d4a4136F7c00352A54378d3A322488da;
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

    uint16 constant GAMMA = 20_000; // 2× inventory skew (SSoT)
    uint16 constant VEGA = 10_000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(50_000 ether));

        vm.startBroadcast(pk);

        // Fresh AC (Steward-lite whitelists). Owner+treasury = deployer (matches live Chapel).
        AccessControl ac = new AccessControl(deployer, deployer);

        Admin admin = new Admin(address(ac));
        Flash flash = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flash));
        Pool poolImpl = new Pool(address(ac), address(admin), address(flash), address(poolAux));
        PoolFactory factory = new PoolFactory(address(poolImpl), deployer, address(ac));

        address stable = _createPool(admin, factory, _stableList(), seedUsdc, true);
        address vol = _createPool(admin, factory, _volatileList(), seedUsdc, false);

        vm.stopBroadcast();

        console2.log("=== ChapelEnableSwaps ===");
        console2.log("ac(new)", address(ac));
        console2.log("ac(old/oracle)", OLD_AC);
        console2.log("admin", address(admin));
        console2.log("factory", address(factory));
        console2.log("stablePool", stable);
        console2.log("volatilePool", vol);
        console2.log("oracle(kept)", ORACLE);
        console2.log("faucet(kept)", FAUCET);

        _persist(address(ac), address(admin), address(factory), stable, vol);
    }

    function _stableList() internal pure returns (address[] memory list) {
        // SSoT also lists USDG — no Chapel mock token yet; 5 live stables only.
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

        IPool.RiskConfig memory rcBase = _riskStableBase();
        IPool.RiskConfig memory rcSpoke = stable ? _riskStableSpoke() : _riskVolatile();
        IPool.LiquidityProfile memory pf = stable ? _stableProfile() : _volatileProfile();

        for (uint256 i = 0; i < tokens.length; i++) {
            address tok = tokens[i];
            (uint16 minFee, uint16 refBand, uint32 minDisp, uint32 maxDisp) = _assetParams(tok, stable);
            IPool.OracleConfig memory oc = _oracleCfg(tok, tokens[0], refBand);
            // Base numeraire forbids κ wall (PoolAdminWrite); spokes use stable κ=100.
            IPool.RiskConfig memory rc = (tok == tokens[0]) ? rcBase : rcSpoke;
            admin.addAsset(poolAddr, tok, oc, rc, pf, minFee, 18, minDisp, maxDisp, GAMMA, VEGA);
            // initAsset defaults maxFeeBps=BPS; clamp to SSoT. κ-walled spokes require haircut=0.
            uint16 maxFee = stable ? 2_000 : 10_000;
            uint16 haircut = (rc.kappaCovBps > 0) ? 0 : 10_000;
            admin.setAssetParams(poolAddr, tok, 0, minFee, maxFee, GAMMA, VEGA, haircut, 0, 0);
            admin.setRiskFences(poolAddr, tok, _fences(tok, stable));
        }

        admin.setBaseTokenOracle(poolAddr, ORACLE, USDC_FEED);
        admin.sealBootstrap(poolAddr);
        _seedPool(Pool(payable(poolAddr)), tokens, seedUsdc);
    }

    /// @dev Base USDC: κ must be 0 (numeraire never walled). Shared decay/coverage floors.
    function _riskStableBase() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20_000;
        r.depthAmplifier = 10_000;
        r.kappaCovBps = 0;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    /// @dev Stable spokes: coverage wall ON, no depth subsidy.
    function _riskStableSpoke() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20_000;
        r.depthAmplifier = 0;
        r.kappaCovBps = 100;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _riskVolatile() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20_000;
        r.depthAmplifier = 10_000;
        r.kappaCovBps = 0;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _volatileProfile() internal pure returns (IPool.LiquidityProfile memory p) {
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

    /// @dev sharedLiquidityProfile — milder center bump [50,100,50].
    function _stableProfile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50;
        p.weights[1] = 100;
        p.weights[2] = 50;
        p.knots[0] = -50;
        p.knots[1] = -12;
        p.knots[2] = 12;
        p.knots[3] = 50;
    }

    function _fences(address tok, bool stable) internal pure returns (IAdmin.RiskFences memory f) {
        f.maxDeltaBps = 2_500;
        f.haircutHardMax = 10_000;
        f.gammaHardMin = 5_000;
        f.gammaHardMax = 40_000;
        f.vegaHardMin = 5_000;
        if (stable || tok == USDC || tok == USDT) {
            f.minFeeHardMin = 50; // SSoT floor 0.5 bp; FDUSD listed at 100
            f.minFeeHardMax = 2_000;
            f.maxFeeHardMax = 10_000;
            f.vegaHardMax = 20_000;
        } else {
            f.minFeeHardMin = 100;
            f.minFeeHardMax = 20_000;
            f.maxFeeHardMax = 50_000;
            f.vegaHardMax = 30_000;
        }
    }

    /// @dev Per-asset from testnet-asset-params.json stable-core / volatile-core.
    function _assetParams(address tok, bool stable)
        internal
        pure
        returns (uint16 minFee, uint16 refBand, uint32 minDisp, uint32 maxDisp)
    {
        if (stable) {
            // Defaults then per-asset overrides (SSoT 2026-07-12b).
            minFee = 50;
            minDisp = 500;
            maxDisp = 5000;
            refBand = 100;
            if (tok == USDC) {
                minFee = 50;
                minDisp = 200;
                maxDisp = 2000;
                refBand = 0;
            } else if (tok == USDT) {
                minDisp = 600;
                maxDisp = 6000;
            } else if (tok == USD1) {
                minDisp = 500;
                maxDisp = 5000;
            } else if (tok == USDE) {
                minFee = 75;
                minDisp = 800;
                maxDisp = 5000;
            } else if (tok == FDUSD) {
                minFee = 100;
                minDisp = 1000;
                maxDisp = 8000;
            }
            return (minFee, refBand, minDisp, maxDisp);
        }
        minFee = 1000;
        minDisp = 50_000;
        maxDisp = 500_000;
        refBand = tok == USDT ? 100 : 0;
    }

    function _oracleCfg(address asset, address base, uint16 refBandBps)
        internal
        pure
        returns (IPool.OracleConfig memory o)
    {
        o.primary = ORACLE;
        o.feedId = asset == USDC ? USDC_FEED : keccak256(abi.encodePacked(asset, base));
        // Non-base assets with refBand pin USDC as depeg ref (stable legs + volatile USDT).
        if (asset != USDC && refBandBps != 0) {
            o.refFeedId = USDC_FEED;
            o.refBandBps = refBandBps;
        } else {
            o.refFeedId = bytes32(0);
            o.refBandBps = 0;
        }
        o.mode = 0;
    }

    function _seedAmount(address tok, uint256 seedUsdc) internal view returns (uint256) {
        return ChapelSeedAmounts.seedAmount(tok, seedUsdc);
    }

    function _seedPool(Pool pool, address[] memory tokens, uint256 seedUsdc) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address tok = tokens[i];
            uint256 amt = _seedAmount(tok, seedUsdc);
            uint256 bal = IERC20(tok).balanceOf(msg.sender);
            if (bal < amt) TestnetERC20(tok).mint(msg.sender, amt - bal);
            IERC20(tok).approve(address(pool), type(uint256).max);
            pool.deposit(tok, amt);
        }
    }

    function _persist(address ac, address admin, address factory, address stable, address vol) internal {
        string memory k = "chapel";
        vm.serializeUint(k, "chainId", uint256(97));
        vm.serializeAddress(k, "ac", ac);
        vm.serializeAddress(k, "acOracle", OLD_AC);
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
