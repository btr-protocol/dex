// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {PoolAdminWrite} from "./libraries/PoolAdminWrite.sol";
import {PoolEdge} from "./libraries/PoolEdge.sol";

/// @title PoolAux -cold-path dispatcher for Pool (Wave-3a EIP-170 reduction)
/// @notice Singleton deployed once per protocol; Pool's fallback DELEGATECALLs to this.
///         Holds all rarely-called external entry points (admin setters,
///         flash send/account, oracle updateFeed/poke) so Pool itself need not allocate
///         selector dispatch entries for them.
/// @dev    Auth + reentrancy checks live HERE (executed under Pool's storage context via
///         delegatecall). Immutables (AC/admin/flash) are inlined into bytecode,
///         so they remain correct under delegatecall (immutables read from code, not
///         storage). The Pool clone's $ at slot 0 is shared transparently.
contract PoolAux is ReentrancyGuardTransient {
    /// @dev Layout MUST mirror Pool: $ at slot 0 so delegatecalls hit the right slots.
    IPool.PoolStorage internal $;

    address public immutable AC;
    address public immutable admin;
    address public immutable flash;

    constructor(address ac_, address admin_, address flash_) {
        if (ac_ == address(0) || admin_ == address(0) || flash_ == address(0)) {
            revert Err.ZeroAddr();
        }
        AC = ac_;
        admin = admin_;
        flash = flash_;
    }

    function _owner() internal view returns (address) {
        return AccessControl(AC).owner();
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Err.NotOwner();
        _;
    }

    modifier onlyFlash() {
        if (msg.sender != flash) revert Err.NotOwner();
        _;
    }

    modifier whenInitialized() {
        if (!$.initialized) revert Err.InvalidState();
        _;
    }

    // ── ADMIN setters ──

    function adminFreezeAsset(address token) external onlyAdmin {
        PoolAdminWrite.freezeAsset($, token);
    }

    function adminUnfreezeAsset(address token) external onlyAdmin {
        PoolAdminWrite.unfreezeAsset($, token);
    }

    function adminPauseAsset(address token) external onlyAdmin {
        PoolAdminWrite.pauseAsset($, token);
    }

    function adminUnpauseAsset(address token) external onlyAdmin {
        PoolAdminWrite.unpauseAsset($, token);
    }

    function adminInitAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega
    ) external onlyAdmin {
        PoolAdminWrite.initAsset(
            $, address(this), token, oracleCfg, riskCfg, profile,
            minFeeBps, decimals, minDispersion, maxDispersion, gamma, vega
        );
    }

    function adminCollectProtocolFees(address token, address recipient)
        external nonReentrant onlyAdmin returns (uint256)
    {
        return PoolEdge.collectProtocolFees($, token, recipient);
    }

    function adminSetFlowCooldown(uint16 cooldownSeconds) external onlyAdmin {
        PoolAdminWrite.setFlowCooldown($, cooldownSeconds);
    }

    function adminSetAnchor(address token, address anchor) external onlyAdmin {
        PoolAdminWrite.setAnchor($, token, anchor);
    }

    function adminSetAssetParams(
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 haircutSuppressor,
        uint64 reservationPrice,
        uint64 reservationPriceMax
    ) external onlyAdmin {
        PoolAdminWrite.setAssetParams($, token, minLiquidity, minFeeBps, maxFeeBps, gamma, vega, haircutSuppressor, reservationPrice, reservationPriceMax);
    }

    function adminSetRiskConfig(address token, IPool.RiskConfig calldata cfg) external onlyAdmin {
        PoolAdminWrite.setRiskConfig($, token, cfg);
    }

    function adminSetOracleConfig(address token, IPool.OracleConfig calldata cfg) external onlyAdmin {
        PoolAdminWrite.setOracleConfig($, address(this), token, cfg);
    }

    function adminSetFeeParams(IPool.FeeParams calldata params) external onlyAdmin {
        PoolAdminWrite.setFeeParams($, params);
    }

    function adminSetBridge(address newBridge) external onlyAdmin {
        PoolAdminWrite.setBridge($, newBridge);
    }

    function adminSetTreasury(address newTreasury) external onlyAdmin {
        PoolAdminWrite.setTreasury($, newTreasury);
    }

    function adminSetBaseToken(address newBase) external onlyAdmin {
        PoolAdminWrite.setBaseToken($, newBase);
    }

    /// @notice R44-2 (T3-HIGH2): set/unset base-token oracle for depeg detection.
    function adminSetBaseTokenOracle(address oracle, bytes32 feedId) external onlyAdmin {
        PoolAdminWrite.setBaseTokenOracle($, oracle, feedId);
    }

    // ── FLASH ──

    function flashSend(address token, uint256 amount, address to) external onlyFlash whenInitialized nonReentrant {
        PoolEdge.flashSend($, token, amount, to);
    }

    function flashAccount(address token, uint256 fee, uint256 protoFee) external onlyFlash {
        PoolEdge.flashAccount($, token, fee, protoFee);
    }
}
