// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolV1} from "./interfaces/IPoolV1.sol";
import {IErrors} from "./interfaces/IErrors.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";
import {LibTimelock as TL} from "./libraries/LibTimelock.sol";

/// @title PoolProxyV1
/// @notice Lightweight diamond-pattern proxy (EIP-2535 inspired) that routes calls to modules
/// @dev Pure dispatcher with ERC-7201 storage, no inheritance
contract PoolProxyV1 {
    error Unauthorized();
    error ModuleNotFound();
    error TimelockNotReady();
    error ArrayLengthMismatch();
    error UntrustedModule(); // SECURITY FIX (CRITICAL-10): Module not in trusted registry

    /// @dev Immutable deployer address for initialization access control
    address private immutable DEPLOYER;

    /// @dev Module update timelocks: selector => packed[executeAt<<48 | grace]
    mapping(bytes4 selector => uint96) public moduleTimelocks;

    /// @dev Pending module implementations: selector => new address
    mapping(bytes4 selector => address) public pendingModules;

    /// @dev SECURITY FIX (CRITICAL-10): Trusted module bytecode hashes
    /// @notice Maps bytecode hash => trusted status to prevent malicious module injection
    mapping(bytes32 codeHash => bool trusted) public trustedModules;

    /// @dev SECURITY FIX (CRITICAL-10): Emitted when module trust status changes
    event ModuleTrustUpdated(address indexed implementation, bytes32 codeHash, bool trusted);

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

    // ========== MODULE TRUST MANAGEMENT (CRITICAL-10 FIX) ==========

    /// @notice Set trusted status for a module implementation
    /// @dev SECURITY FIX (CRITICAL-10): Modules must be pre-approved before they can be added
    /// @param impl Module implementation address
    /// @param trusted Whether the module should be trusted
    function setModuleTrust(address impl, bool trusted) external {
        if (msg.sender != DEPLOYER) revert Unauthorized();
        if (impl == address(0)) revert IErrors.InvalidInput();

        bytes32 codeHash = impl.codehash;
        if (codeHash == bytes32(0)) revert IErrors.InvalidInput(); // No code at address

        trustedModules[codeHash] = trusted;
        emit ModuleTrustUpdated(impl, codeHash, trusted);
    }

    /// @notice Batch set trusted status for multiple module implementations
    /// @param impls Array of module implementation addresses
    /// @param trusted Array of trust statuses
    function setModuleTrustBatch(address[] calldata impls, bool[] calldata trusted) external {
        if (msg.sender != DEPLOYER) revert Unauthorized();
        if (impls.length != trusted.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < impls.length; i++) {
            if (impls[i] == address(0)) revert IErrors.InvalidInput();
            bytes32 codeHash = impls[i].codehash;
            if (codeHash == bytes32(0)) revert IErrors.InvalidInput();

            trustedModules[codeHash] = trusted[i];
            emit ModuleTrustUpdated(impls[i], codeHash, trusted[i]);
        }
    }

    /// @notice Check if a module implementation is trusted
    /// @param impl Module implementation address to check
    /// @return Whether the module is trusted
    function isModuleTrusted(address impl) public view returns (bool) {
        if (impl == address(0)) return false;
        return trustedModules[impl.codehash];
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

    // ========== MODULE MANAGEMENT ==========

    /// @notice Add a single module with its function selectors
    /// @dev If selector already exists, replacement is timelocked. New selectors register immediately.
    /// @param impl Module implementation address
    /// @param selectors Array of function selectors to register
    function addModule(
        address impl,
        bytes4[] calldata selectors
    ) external {
        if (msg.sender != DEPLOYER) revert Unauthorized();
        _addModule(impl, selectors, true);
    }

    /// @notice Add multiple modules with their function selectors
    /// @dev Bulk version that loops through each module calling internal _addModule
    /// @param impls Array of module implementation addresses
    /// @param selectors Array of selector arrays, one per implementation
    function addModules(
        address[] calldata impls,
        bytes4[][] calldata selectors
    ) external {
        if (msg.sender != DEPLOYER) revert Unauthorized();
        if (impls.length != selectors.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < impls.length; i++) {
            _addModule(impls[i], selectors[i], true);
        }
    }

    /// @notice Internal function to add/update module selectors
    /// @dev SECURITY FIX (CRITICAL-10): Validates module is in trusted registry before adding
    /// @param impl Module implementation address
    /// @param selectors Array of function selectors to register
    /// @param timelockIfExisting If true, timelock replacement for existing selectors
    function _addModule(
        address impl,
        bytes4[] calldata selectors,
        bool timelockIfExisting
    ) internal {
        // SECURITY FIX (CRITICAL-10): Validate module is trusted before allowing registration
        // This prevents malicious modules from being added that could exploit storage collisions
        if (!isModuleTrusted(impl)) revert UntrustedModule();

        IPoolV1.PoolStorage storage $ = _s();

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            address existingImpl = $.modules[selector];

            if (existingImpl == address(0)) {
                // New selector - register immediately
                $.modules[selector] = impl;
            } else if (existingImpl == impl) {
                // Already pointing to same impl - skip
                continue;
            } else if (timelockIfExisting) {
                // Existing selector with different impl - initiate timelock
                moduleTimelocks[selector] = TL.pack(C.HIGH_TIMELOCK, C.GRACE_PERIOD);
                pendingModules[selector] = impl;
            } else {
                // Update immediately (no timelock)
                $.modules[selector] = impl;
            }
        }
    }

    /// @notice Execute timelocked module update
    /// @dev SECURITY FIX (CRITICAL-10): Re-validates trust at execution time
    /// @param selector Function selector to update
    function executeModuleUpdate(bytes4 selector) external {
        uint96 tl = moduleTimelocks[selector];
        address newImpl = pendingModules[selector];

        if (newImpl == address(0)) revert IErrors.InvalidState();

        // SECURITY FIX (CRITICAL-10): Re-validate trust at execution time
        // Module bytecode could have changed between queueing and execution (selfdestruct + create2)
        if (!isModuleTrusted(newImpl)) revert UntrustedModule();

        TL.validate(tl);

        _s().modules[selector] = newImpl;
        delete moduleTimelocks[selector];
        delete pendingModules[selector];
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
