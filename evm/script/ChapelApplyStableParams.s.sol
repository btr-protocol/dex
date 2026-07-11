// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";

import {Admin} from "../src/Admin.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";

/// @title ChapelApplyStableParams — push stable-core risk params onto the live Chapel stable pool.
/// @notice Immediate: `setAssetParams` (fees/gamma/vega). Timelocked (Chapel LOW=5m / BASE=15m):
///         `requestUpdateProfile` (knots/weights + dispersion) + `requestUpdateOracle` (refBand).
///         Risk coverage/flags already correct from surgical listing (flags=6).
/// @dev Run (gas 0.1 gwei):
///   # 1) fees now + queue profile/oracle
///   forge script script/ChapelApplyStableParams.s.sol:ChapelApplyStableParams --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
///   # 2) after ≥5m: execute profiles
///   forge script ... --sig executeProfiles --rpc-url chapel --broadcast --with-gas-price 100000000
///   # 3) after ≥15m: execute oracles
///   forge script ... --sig executeOracles --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelApplyStableParams is Script {
    address constant ADMIN = 0x71ad34866B2bB0E99478297DA735E9b94922B7Fb;
    address constant STABLE = 0xC954A27E69ae7C9d10a136c4f7F3910b38F09324;
    address constant ORACLE = 0xD91712c9F4037D0010041691Df191AB45994F2bF;
    bytes32 constant USDC_FEED = 0xdacab87341ef44905f4cfdb16cbfbd61ad65accd449f2df15ae6fb26f53ba17d;

    address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
    address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;
    address constant USD1 = 0xC28bE4D407096E771F932c202F13D866B4d6BA07;
    address constant USDE = 0xebF751546832ec77a039083E9FDd8158B21c0172;
    address constant FDUSD = 0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        Admin admin = Admin(ADMIN);
        address[5] memory toks = [USDC, USDT, USD1, USDE, FDUSD];

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < toks.length; i++) {
            address tok = toks[i];
            (uint16 minFee, uint32 minDisp, uint32 maxDisp, uint16 refBand) = _params(tok);
            // Preserve live haircutSuppressor=10000 / zero reservation band / zero minLiquidity.
            admin.setAssetParams(STABLE, tok, 0, minFee, 2000, 10_000, 10_000, 10_000, 0, 0);
            admin.requestUpdateProfile(STABLE, tok, _profile(), minDisp, maxDisp);
            admin.requestOracleUpdate(STABLE, tok, _oracle(tok, refBand));
            console2.log("queued", tok, minFee, refBand);
        }
        vm.stopBroadcast();
        console2.log("setAssetParams done; profile ETA ~5m; oracle ETA ~15m");
    }

    function executeProfiles() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        Admin admin = Admin(ADMIN);
        address[5] memory toks = [USDC, USDT, USD1, USDE, FDUSD];
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < toks.length; i++) {
            admin.executeUpdateProfile(STABLE, toks[i]);
            console2.log("profile ok", toks[i]);
        }
        vm.stopBroadcast();
    }

    function executeOracles() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        Admin admin = Admin(ADMIN);
        address[5] memory toks = [USDC, USDT, USD1, USDE, FDUSD];
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < toks.length; i++) {
            admin.executeOracleUpdate(STABLE, toks[i]);
            console2.log("oracle ok", toks[i]);
        }
        vm.stopBroadcast();
    }

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        // sharedLiquidityProfile: knots [-50,-12,12,50] · weights [25,150,25]
        p.weights[0] = 25;
        p.weights[1] = 150;
        p.weights[2] = 25;
        p.knots[0] = -50;
        p.knots[1] = -12;
        p.knots[2] = 12;
        p.knots[3] = 50;
    }

    function _params(address tok)
        internal
        pure
        returns (uint16 minFee, uint32 minDisp, uint32 maxDisp, uint16 refBand)
    {
        if (tok == USDC) return (10, 100, 2000, 50);
        if (tok == USDT) return (10, 600, 6000, 100);
        if (tok == USD1) return (10, 500, 5000, 150);
        if (tok == USDE) return (15, 500, 5000, 200);
        if (tok == FDUSD) return (15, 500, 5000, 200);
        revert("unknown");
    }

    function _oracle(address tok, uint16 refBand) internal pure returns (IPool.OracleConfig memory o) {
        o.primary = ORACLE;
        o.feedId = tok == USDC ? USDC_FEED : keccak256(abi.encodePacked(tok, USDC));
        // Only USDT pins a USDC refFeed (testnet-asset-params / user table). Others: refBand stored, no ref.
        if (tok == USDT) {
            o.refFeedId = USDC_FEED;
            o.refBandBps = refBand;
        } else {
            o.refFeedId = bytes32(0);
            o.refBandBps = refBand; // kept for ops visibility; inactive without refFeedId
        }
        o.mode = 0; // EXTERNAL
    }
}
