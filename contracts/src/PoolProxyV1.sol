// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolV1} from "./interfaces/IPoolV1.sol";
import {IErrors} from "./interfaces/IErrors.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";

/// @title PoolProxyV1
/// @notice Lightweight diamond-pattern proxy (EIP-2535 inspired) that routes calls to modules
/// @dev Pure dispatcher with ERC-7201 storage, no inheritance
contract PoolProxyV1 {
    error Unauthorized();
    /// @dev Immutable deployer address for initialization access control
    address private immutable DEPLOYER;

    /// @dev Set deployer in constructor to prevent front-running initialization
    constructor() {
        DEPLOYER = msg.sender;
    }

    // ========== STORAGE ACCESS ==========

    /// @dev ERC-7201 storage location for base module
    function _s() internal pure returns (IPoolV1.PoolStorage storage $) {
        bytes32 slot = C.CORE_STORAGE_LOC;
        assembly {
            $.slot := slot
        }
    }

    // ========== INITIALIZATION ==========

    function initialize(
        address _owner,
        address _baseToken,
        address _wnative,
        IPoolV1.FeeParams calldata _feeParams
    ) external {
        IPoolV1.PoolStorage storage $ = _s();
        if ($.initialized) revert IErrors.InvalidState();

        // C-01 FIX: Only deployer can initialize to prevent front-running
        // This allows factory contracts to deploy and set arbitrary owner atomically
        if (msg.sender != DEPLOYER) revert Unauthorized();

        $.owner = _owner;
        $.baseToken = _baseToken;
        $.wnative = _wnative;
        $.feeParams = _feeParams;
        $.flowCooldownSeconds = C.DEFAULT_FLOW_COOLDOWN; // JIT protection default: 15 seconds
        $.initialized = true;

        emit IPoolV1.PoolInitialized(_owner, _baseToken, _wnative);
    }

    // ========== DIAMOND-LITE FALLBACK ==========

    /// @notice Fallback function for delegatecall to modules
    /// @dev Routes all function selectors to registered modules
    fallback() external payable {
        IPoolV1.PoolStorage storage $ = _s();
        address impl = $.modules[msg.sig];

        if (impl == address(0)) revert IErrors.InvalidInput();

        assembly {
            // Copy calldata to memory
            calldatacopy(0, 0, calldatasize())

            // Delegatecall to module implementation and check return value
            switch delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            case 0 {
                // Delegatecall failed - copy revert data and bubble up
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            default {
                // Delegatecall succeeded - copy return data
                returndatacopy(0, 0, returndatasize())
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {}
}
