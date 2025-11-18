// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {IDarkPoolStorage} from "../interfaces/IDarkPoolStorage.sol";
import {LibPricing as P} from "./LibPricing.sol";
import {LibMaths as M} from "./LibMaths.sol";

/// @title LibStorage
/// @notice Centralized EIP-7201 namespaced storage for the entire protocol
/// @dev Consolidates BAMM, DarkPool, and Oracle storage layouts
library LibStorage {

    // ========================================
    // FEED ID COMPUTATION
    // ========================================

    /// @notice Compute feed ID from base and quote assets
    /// @dev Feed ID = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    /// @param baseAsset Asset being priced
    /// @param quoteAsset Pricing currency (e.g., pool's baseToken)
    /// @return feedId keccak256 hash of packed addresses
    function computeOracleId(address baseAsset, address quoteAsset) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseAsset, quoteAsset));
    }

    // ========================================
    // RISK CONFIG FLAGS HELPERS
    // ========================================

    /// @notice RiskConfig flags bit masks (stored in RiskConfig.flags)
    uint16 internal constant RISK_FLAG_FROZEN = 0x01;                  // bit0
    uint16 internal constant RISK_FLAG_SWAP_ENABLED = 0x02;            // bit1
    uint16 internal constant RISK_FLAG_LIABILITY_SWAP_ENABLED = 0x04;  // bit2
    uint16 internal constant RISK_FLAG_DECAY_ENABLED = 0x08;           // bit3
    uint16 internal constant RISK_FLAG_FLASH_ENABLED = 0x10;           // bit4
    uint16 internal constant RISK_FLAG_FEE_ON_TRANSFER = 0x20;         // bit5

    /// @notice Check if asset is frozen
    function _isFrozen(IBAMM.RiskConfig storage risk) internal view returns (bool) {
        return (risk.flags & RISK_FLAG_FROZEN) != 0;
    }

    /// @notice Check if swaps are enabled
    function _swapEnabled(IBAMM.RiskConfig storage risk) internal view returns (bool) {
        return (risk.flags & RISK_FLAG_SWAP_ENABLED) != 0;
    }

    /// @notice Check if liability swaps are enabled
    function _liabilitySwapEnabled(IBAMM.RiskConfig storage risk) internal view returns (bool) {
        return (risk.flags & RISK_FLAG_LIABILITY_SWAP_ENABLED) != 0;
    }

    /// @notice Check if decay is enabled
    function _decayEnabled(IBAMM.RiskConfig storage risk) internal view returns (bool) {
        return (risk.flags & RISK_FLAG_DECAY_ENABLED) != 0;
    }

    /// @notice Check if flash loans are enabled
    function _flashEnabled(IBAMM.RiskConfig storage risk) internal view returns (bool) {
        return (risk.flags & RISK_FLAG_FLASH_ENABLED) != 0;
    }

    /// @notice Check if asset has fee-on-transfer
    function _hasFeeOnTransfer(IBAMM.RiskConfig storage risk) internal view returns (bool) {
        return (risk.flags & RISK_FLAG_FEE_ON_TRANSFER) != 0;
    }

    // ========================================
    // DARKPOOL FLAGS HELPERS
    // ========================================

    /// @notice DarkPool flags bit masks
    uint8 internal constant DARKPOOL_FLAG_PAUSED = 0x01;      // bit0
    uint8 internal constant DARKPOOL_FLAG_REQUIRE_ASP = 0x02; // bit1

    /// @notice Check if DarkPool is paused
    function _isDarkPoolPaused(IDarkPoolStorage.DarkPoolStorage storage $) internal view returns (bool) {
        return ($.flags & DARKPOOL_FLAG_PAUSED) != 0;
    }

    /// @notice Check if DarkPool requires ASP
    function _requiresASP(IDarkPoolStorage.DarkPoolStorage storage $) internal view returns (bool) {
        return ($.flags & DARKPOOL_FLAG_REQUIRE_ASP) != 0;
    }

    /// @notice Set DarkPool paused flag
    function _setDarkPoolPaused(IDarkPoolStorage.DarkPoolStorage storage $, bool paused) internal {
        $.flags = paused ? $.flags | DARKPOOL_FLAG_PAUSED : $.flags & ~DARKPOOL_FLAG_PAUSED;
    }

    /// @notice Set DarkPool require ASP flag
    function _setRequireASP(IDarkPoolStorage.DarkPoolStorage storage $, bool requireASP) internal {
        $.flags = requireASP ? $.flags | DARKPOOL_FLAG_REQUIRE_ASP : $.flags & ~DARKPOOL_FLAG_REQUIRE_ASP;
    }

    // ========================================
    // BAMM STORAGE
    // ========================================

    /// @notice EIP-7201 storage slot for BAMM
    /// @dev keccak256(abi.encode(uint256(keccak256("bamm.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant BAMM_STORAGE_SLOT =
        0x8757882912c4910e2fa81a635c8b91b57e7ace2779ba7ca50d0cf6d4b7658b00;

    /// @notice Get BAMM storage pointer using EIP-7201
    function bamm() internal pure returns (IBAMM.BAMMStorage storage $) {
        assembly { $.slot := BAMM_STORAGE_SLOT }
    }

    // ========================================
    // DARKPOOL STORAGE
    // ========================================

    // DarkPool constants (duplicated from IDarkPoolStorage for access)
    uint8 internal constant TREE_HEIGHT = 32;
    uint32 internal constant ROOT_HISTORY_SIZE = 100;
    uint256 internal constant PRECISION = 1e18;
    uint8 internal constant NOTE_TYPE_TOKEN = 0;
    uint8 internal constant NOTE_TYPE_LP = 1;
    uint8 internal constant ACTION_TRANSFER = 0;
    uint8 internal constant ACTION_SWAP = 1;
    uint8 internal constant ACTION_LP_DEPOSIT = 2;
    uint8 internal constant ACTION_LP_WITHDRAW = 3;

    /// @dev keccak256(abi.encode(uint256(keccak256("darkpool.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DARKPOOL_STORAGE_SLOT =
        0xd520fb88501ea3fd6f848e11ec42e1ae44feb0f5d56e27f3b5b3569dc75a5d00;

    /// @notice Get DarkPool storage pointer using EIP-7201
    function darkPool() internal pure returns (IDarkPoolStorage.DarkPoolStorage storage $) {
        assembly { $.slot := DARKPOOL_STORAGE_SLOT }
    }

    // ========================================
    // DARKPOOL HELPER FUNCTIONS
    // ========================================

    /// @notice Check if a root is in the history and not expired
    /// @param root Root to check
    /// @return True if root is in history and still valid
    /// @dev O(1) lookup using ShieldedState.rootInHistory mapping
    function isKnownRoot(bytes32 root) internal view returns (bool) {
        IDarkPoolStorage.DarkPoolStorage storage $ = darkPool();

        // Get ShieldedState contract
        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) return false;

        // Call ShieldedState to check root
        (bool success, bytes memory result) = shieldedStateAddr.staticcall(
            abi.encodeWithSignature("isKnownRoot(bytes32)", root)
        );

        if (!success) return false;
        return abi.decode(result, (bool));
    }

    /// @notice Add a root to the history via ShieldedState
    /// @param root Root to add
    /// @dev Delegates to ShieldedState.addRoot()
    function addRoot(bytes32 root) internal {
        IDarkPoolStorage.DarkPoolStorage storage $ = darkPool();

        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) revert ZeroAddress();

        // Call ShieldedState to add root (must be called by owner)
        // This will revert if caller is not owner of ShieldedState
        (bool success, ) = shieldedStateAddr.call(
            abi.encodeWithSignature("addRoot(bytes32)", root)
        );

        if (!success) revert AddRootFailed();
    }


    // ========================================
    // RESERVED STORAGE SLOTS (FUTURE USE)
    // ========================================

    /// @notice Reserved EIP-7201 storage slot for Oracle (future use)
    /// @dev keccak256(abi.encode(uint256(keccak256("oracle.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Currently oracle data stored in BAMMStorage.oracleEntries
    bytes32 internal constant ORACLE_STORAGE_SLOT =
        0xbe7d32a8927afa9d36aa1d622b13e4698467d622ffee9b72c594522d41542300;

    /// @notice Reserved EIP-7201 storage slot for Hooks (future use)
    /// @dev keccak256(abi.encode(uint256(keccak256("hook.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Currently hook addresses stored in Asset.hooks field
    bytes32 internal constant HOOK_STORAGE_SLOT =
        0x39ad489ed614fb1cd2c7d913838f5a7d7a73df8b6bd3a3202be6a193febd1000;

    // ========================================
    // ERRORS
    // ========================================

    error ZeroAddress();
    error AddRootFailed();
}
