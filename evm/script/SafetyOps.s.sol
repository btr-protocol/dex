// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {Admin} from "../src/Admin.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";

/// @title SafetyOps — emergency pause/freeze operator script (Safety Control Center, CLI edition).
/// @notice One broadcast applies a risk-op across the whole official fleet, or across every pool that
///         lists one asset, via `Admin.batchRiskOp`. Works from an EOA OR a multisig broadcaster — the
///         loop runs inside `Admin`, so `msg.sender` stays the AC owner (no Safe MultiSend / Multicall3;
///         Multicall3 would fail `onlyAdmin`). Bad legs (uninit pool / unlisted asset) are skipped by
///         `batchRiskOp`, not reverted.
///
/// Env: `ADMIN` (Admin singleton), `FACTORY` (PoolFactory). Broadcaster key MUST be the AC owner.
/// Examples:
///   forge script script/SafetyOps.s.sol:SafetyOps --sig "pauseAll()"            --rpc-url $RPC --broadcast
///   forge script script/SafetyOps.s.sol:SafetyOps --sig "unpauseAll()"          --rpc-url $RPC --broadcast
///   forge script script/SafetyOps.s.sol:SafetyOps --sig "freezeAll()"           --rpc-url $RPC --broadcast
///   forge script script/SafetyOps.s.sol:SafetyOps --sig "pauseAsset(address)" 0xTOKEN --rpc-url $RPC --broadcast
///   forge script script/SafetyOps.s.sol:SafetyOps --sig "preview()"             --rpc-url $RPC   # dry-run, no broadcast
///
/// ⚠ NOTE: reaches only pools whose clone was deployed from an impl carrying PROTOCOL_PAUSED_BIT
/// (pause ops) — freeze ops work on all live clones. See project_dex_pause_admin_design memory.
/// // ponytail: single batch call; for a very large fleet paginate under the block gas limit
/// (add pauseRange(start,end)) — officialPools is append-only today.
contract SafetyOps is Script {
    Admin internal admin = Admin(vm.envAddress("ADMIN"));
    PoolFactory internal factory = PoolFactory(payable(vm.envAddress("FACTORY")));

    function pauseAll() external { _fleet(IAdmin.BatchOp.Pause); }
    function unpauseAll() external { _fleet(IAdmin.BatchOp.Unpause); }
    function freezeAll() external { _fleet(IAdmin.BatchOp.Freeze); }
    function unfreezeAll() external { _fleet(IAdmin.BatchOp.Unfreeze); }

    function pauseAsset(address token) external { _asset(token, IAdmin.BatchOp.Pause); }
    function unpauseAsset(address token) external { _asset(token, IAdmin.BatchOp.Unpause); }
    function freezeAsset(address token) external { _asset(token, IAdmin.BatchOp.Freeze); }
    function unfreezeAsset(address token) external { _asset(token, IAdmin.BatchOp.Unfreeze); }

    /// Dry-run: log the fleet the op WOULD touch, without broadcasting. Run before an emergency op.
    function preview() external view {
        (address[] memory pools, address[] memory tokens) = _fleetLegs();
        console2.log("official pools:", factory.getOfficialPoolsCount());
        console2.log("total (pool,token) legs:", pools.length);
        for (uint256 i; i < pools.length; ++i) {
            console2.log("  pool", pools[i]);
            console2.log("    token", tokens[i]);
        }
    }

    // ── internals ──

    function _fleet(IAdmin.BatchOp op) internal {
        (address[] memory pools, address[] memory tokens) = _fleetLegs();
        console2.log("batchRiskOp op=", uint8(op), "legs=", pools.length);
        vm.startBroadcast();
        admin.batchRiskOp(pools, tokens, op);
        vm.stopBroadcast();
    }

    function _asset(address token, IAdmin.BatchOp op) internal {
        address[] memory pools = factory.getPoolsForToken(token);
        address[] memory tokens = new address[](pools.length);
        for (uint256 i; i < pools.length; ++i) tokens[i] = token;
        console2.log("asset op=", uint8(op), "pools=", pools.length);
        vm.startBroadcast();
        admin.batchRiskOp(pools, tokens, op);
        vm.stopBroadcast();
    }

    /// Flatten officialPools × getPoolTokens(pool) into parallel (pool,token) arrays.
    function _fleetLegs() internal view returns (address[] memory pools, address[] memory tokens) {
        uint256 nPools = factory.getOfficialPoolsCount();
        uint256 total;
        for (uint256 i; i < nPools; ++i) {
            total += factory.getPoolTokens(factory.officialPools(i)).length;
        }
        pools = new address[](total);
        tokens = new address[](total);
        uint256 k;
        for (uint256 i; i < nPools; ++i) {
            address p = factory.officialPools(i);
            address[] memory tks = factory.getPoolTokens(p);
            for (uint256 j; j < tks.length; ++j) {
                pools[k] = p;
                tokens[k] = tks[j];
                ++k;
            }
        }
    }
}
