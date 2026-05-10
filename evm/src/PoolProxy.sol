// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";

/// @title PoolProxy
/// @notice Diamond-pattern proxy (EIP-2535 inspired) routing calls to modules.
contract PoolProxy {
    error ModuleNotFound();
    error TimelockNotReady();
    error ArrayLengthMismatch();
    error UntrustedModule();

    address private immutable DEPLOYER;

    mapping(bytes4 selector => uint96) public moduleTimelocks;
    mapping(bytes4 selector => address) public pendingModules;
    mapping(bytes32 codeHash => bool trusted) public trustedModules;

    event ModuleTrustUpdated(address indexed implementation, bytes32 codeHash, bool trusted);

    constructor() {
        DEPLOYER = msg.sender;
    }

    function _s() internal pure returns (IPool.PoolStorage storage $) {
        bytes32 slot = C.CORE_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    // ─── module trust ───

    /// @notice Mark module impls as trusted (or untrusted) by codehash. DEPLOYER-only.
    /// @dev Phase 42D #10 DISCARD (by-design): codehash trust persists across DEPLOYER turnover.
    ///      DEPLOYER is set once at construction; if compromised or rotated, prior-trusted codehashes
    ///      remain trusted. There is no `revokeModuleTrust` by codehash — revocation must be done
    ///      by the new DEPLOYER calling this with `trusted=false` for the codehashes to revoke.
    ///      Trust model: DEPLOYER is a one-shot deployment role, NOT a runtime governance principal.
    ///      For runtime-governable module updates, rely on the `addModules` + `executeModuleUpdate`
    ///      timelock flow which re-validates trust at exec time.
    function setModuleTrustBatch(address[] calldata impls, bool[] calldata trusted) external {
        if (msg.sender != DEPLOYER) revert Ownable.Unauthorized();
        if (impls.length != trusted.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < impls.length; i++) {
            address impl = impls[i];
            if (impl == address(0)) revert Err.InvalidInput();
            bytes32 codeHash = impl.codehash;
            if (codeHash == bytes32(0)) revert Err.InvalidInput();
            trustedModules[codeHash] = trusted[i];
            emit ModuleTrustUpdated(impl, codeHash, trusted[i]);
        }
    }

    function isModuleTrusted(address impl) public view returns (bool) {
        return impl == address(0) ? false : trustedModules[impl.codehash];
    }

    // ─── init ───

    /// @dev F-A2-R10-1 (LOW) NOT FIXED (intentional): unguarded `initialize`. Production flow has
    ///      `PoolProxyFactory.createPool` deploy + initialize atomically in a single tx →
    ///      front-run window = 0. One-shot guard via `$.initialized` blocks repeat. Mirrors the
    ///      same disposition as Bridge / Treasury / Router.
    function initialize(
        address _owner,
        address _baseToken,
        address _wnative,
        IPool.FeeParams calldata _feeParams
    ) external {
        IPool.PoolStorage storage $ = _s();
        if ($.initialized) revert Err.InvalidState();
        // F-A3-R12-2 (R13 fix): protoShare ∈ [0,100] (Pricing.splitFee invariant).
        if (_feeParams.protoShare > 100) revert Err.InvalidInput();
        $.owner = _owner;
        $.baseToken = _baseToken;
        $.wnative = _wnative;
        $.feeParams = _feeParams;
        $.flowCooldownSeconds = C.DEFAULT_FLOW_COOLDOWN;
        $.initialized = true;
        emit IPool.PoolInitialized(_owner, _baseToken, _wnative);
    }

    // ─── module mgmt ───

    /// @notice Add modules with selectors. Existing selectors are timelocked; new register instantly.
    /// @dev F-A2-R14-1 (R14 INFO, DISCARDED): selectors that collide with PoolProxy's own concrete
    ///      functions (e.g. `initialize`, `addModules`, `executeModuleUpdate`, ...) can be written
    ///      to `$.modules[sel]` here, but Solidity's built-in dispatch resolves concrete functions
    ///      BEFORE entering `fallback`, so the registered impl is dead-storage. No security impact;
    ///      DEPLOYER-only entrypoint and worst case is a self-grief silent no-op. Adding an explicit
    ///      blacklist would couple this module to PoolProxy's selector set and complicate future
    ///      upgrades — accepted constraint.
    function addModules(address[] calldata impls, bytes4[][] calldata selectors) external {
        if (msg.sender != DEPLOYER) revert Ownable.Unauthorized();
        if (impls.length != selectors.length) revert ArrayLengthMismatch();
        IPool.PoolStorage storage $ = _s();
        for (uint256 i = 0; i < impls.length; i++) {
            address impl = impls[i];
            if (!isModuleTrusted(impl)) revert UntrustedModule();
            bytes4[] calldata sels = selectors[i];
            for (uint256 j = 0; j < sels.length; j++) {
                bytes4 sel = sels[j];
                address existing = $.modules[sel];
                if (existing == address(0)) {
                    $.modules[sel] = impl;
                } else if (existing != impl) {
                    moduleTimelocks[sel] = TL.pack(SC.HIGH_TIMELOCK, SC.GRACE_PERIOD);
                    pendingModules[sel] = impl;
                }
            }
        }
    }

    /// @notice Execute timelocked module update. Re-validates trust at exec time.
    function executeModuleUpdate(bytes4 selector) external {
        if (msg.sender != DEPLOYER) revert Ownable.Unauthorized();
        uint96 tl = moduleTimelocks[selector];
        address newImpl = pendingModules[selector];
        if (newImpl == address(0)) revert Err.InvalidState();
        if (!isModuleTrusted(newImpl)) revert UntrustedModule();
        TL.validate(tl);
        _s().modules[selector] = newImpl;
        delete moduleTimelocks[selector];
        delete pendingModules[selector];
    }

    // ─── diamond fallback ───

    fallback() external payable {
        address impl = _s().modules[msg.sig];
        if (impl == address(0)) revert Err.InvalidInput();
        assembly {
            calldatacopy(0, 0, calldatasize())
            switch delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            case 0 {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            default {
                returndatacopy(0, 0, returndatasize())
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {}
}
