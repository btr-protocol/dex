// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";
import {IDarkPoolFactory} from "../interfaces/IDarkPoolFactory.sol";

/// @title BAMMFactory
/// @notice Factory for deploying BAMM pools using Beacon Proxy pattern
contract BAMMFactory {

    // ========== STATE VARIABLES ==========

    UpgradeableBeacon public immutable beacon;
    address public admin;
    address public pendingAdmin;
    uint256 public pendingAdminTimestamp;

    // DarkPool integration
    IDarkPoolFactory public darkPoolFactory;
    address public defaultVerifier;
    mapping(address => address) public darkPoolForBAMM;

    address[] public pools;
    mapping(address => PoolInfo) public poolInfo;

    uint256 constant ADMIN_TRANSFER_DELAY = 4 days;
    uint256 constant ADMIN_ACCEPT_WINDOW = 3 days;

    /// @notice Pool information struct (optimized for storage packing: 3 slots instead of 6)
    /// @dev Packing: [baseToken+poolAdmin(40)] + [keeper+exists+hasDarkPool(22)] + [deployedAt(32)] = 3 slots
    struct PoolInfo {
        address baseToken;     // 20 bytes
        address poolAdmin;     // 20 bytes (slot 1: 40 bytes total)
        address keeper;        // 20 bytes
        bool exists;          // 1 byte
        bool hasDarkPool;     // 1 byte (slot 2: 22 bytes total)
        uint256 deployedAt;    // 32 bytes (slot 3: 32 bytes total)
    }

    // ========== EVENTS ==========

    event PoolDeployed(address indexed pool, address indexed baseToken, address indexed admin, address keeper);
    event DarkPoolEnabled(address indexed bammPool, address indexed darkPool);
    event DarkPoolFactorySet(address indexed darkPoolFactory);
    event DefaultVerifierSet(address indexed verifier);
    event BeaconUpgraded(address indexed newImplementation);
    event AdminTransferInitiated(address indexed newAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // ========== MODIFIERS ==========

    modifier onlyAdmin() {
        if (msg.sender != admin) revert E.Unauthorized();
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor(address _implementation) {
        if (_implementation == address(0)) revert E.ZeroAddress();

        admin = msg.sender;
        beacon = new UpgradeableBeacon(address(this), _implementation);

        emit Events.OwnershipTransferred(address(0), msg.sender);
    }

    // ========== POOL DEPLOYMENT ==========

    function deployPool(
        address _baseToken,
        address _baseMainOracle,
        address _baseFallbackOracle,
        uint128 _baseMinLiquidity,
        address _poolAdmin,
        address _keeper,
        address _treasury,
        uint16 _baseFee,
        uint16 _maxFee,
        uint16 _withdrawalFee,
        uint16 _maxTWAPChange,
        uint16 _protocolFeeBps,
        bool _enableDarkPool
    ) external returns (address pool) {
        if (_baseToken == address(0) || _poolAdmin == address(0) || _keeper == address(0)) {
            revert E.ZeroAddress();
        }

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,uint128,address,address,address,uint16,uint16,uint16,uint16,uint16)",
            _baseToken,
            _baseMainOracle,
            _baseFallbackOracle,
            _baseMinLiquidity,
            _poolAdmin,
            _keeper,
            _treasury,
            _baseFee,
            _maxFee,
            _withdrawalFee,
            _maxTWAPChange,
            _protocolFeeBps
        );

        pool = LibClone.deployERC1967BeaconProxy(address(beacon), initData);

        poolInfo[pool] = PoolInfo({
            baseToken: _baseToken,
            poolAdmin: _poolAdmin,
            keeper: _keeper,
            deployedAt: block.timestamp,
            exists: true,
            hasDarkPool: false
        });

        pools.push(pool);

        emit PoolDeployed(pool, _baseToken, _poolAdmin, _keeper);

        // Optionally deploy DarkPool
        if (_enableDarkPool) {
            _enableDarkPoolForBAMM(pool, _poolAdmin);
        }
    }

    /// @notice Enable DarkPool for an existing BAMM pool
    /// @param _bammPool BAMM pool address
    /// @param _darkPoolAdmin Admin for the DarkPool (typically same as pool admin)
    function enableDarkPool(address _bammPool, address _darkPoolAdmin) external {
        PoolInfo storage info = poolInfo[_bammPool];

        // Only pool admin or factory admin can enable
        if (msg.sender != info.poolAdmin && msg.sender != admin) {
            revert E.Unauthorized();
        }

        if (!info.exists) revert E.InvalidParameter();
        if (info.hasDarkPool) revert E.InvalidParameter(); // Already enabled

        _enableDarkPoolForBAMM(_bammPool, _darkPoolAdmin);
    }

    /// @notice Internal function to deploy DarkPool proxy
    /// @param _bammPool BAMM pool address
    /// @param _darkPoolAdmin Admin for the DarkPool
    function _enableDarkPoolForBAMM(address _bammPool, address _darkPoolAdmin) internal {
        if (address(darkPoolFactory) == address(0)) revert E.NotInitialized();
        if (defaultVerifier == address(0)) revert E.NotInitialized();

        // Deploy DarkPool via DarkPoolFactory
        address darkPool = darkPoolFactory.createDarkPool(
            _bammPool,
            defaultVerifier,
            _darkPoolAdmin
        );

        // Track relationship
        darkPoolForBAMM[_bammPool] = darkPool;
        poolInfo[_bammPool].hasDarkPool = true;

        emit DarkPoolEnabled(_bammPool, darkPool);
    }

    // ========== UPGRADE FUNCTIONS ==========

    function upgradeBeacon(address _newImplementation) external onlyAdmin {
        if (_newImplementation == address(0)) revert E.ZeroAddress();

        beacon.upgradeTo(_newImplementation);
        emit BeaconUpgraded(_newImplementation);
    }

    // ========== DARKPOOL CONFIGURATION ==========

    /// @notice Set the DarkPoolFactory address
    /// @param _darkPoolFactory DarkPoolFactory address
    function setDarkPoolFactory(address _darkPoolFactory) external onlyAdmin {
        if (_darkPoolFactory == address(0)) revert E.ZeroAddress();
        darkPoolFactory = IDarkPoolFactory(_darkPoolFactory);
        emit DarkPoolFactorySet(_darkPoolFactory);
    }

    /// @notice Set the default Groth16 verifier for new DarkPools
    /// @param _verifier Verifier contract address
    function setDefaultVerifier(address _verifier) external onlyAdmin {
        if (_verifier == address(0)) revert E.ZeroAddress();
        defaultVerifier = _verifier;
        emit DefaultVerifierSet(_verifier);
    }

    // ========== ADMIN TRANSFER ==========

    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert E.ZeroAddress();
        if (_newAdmin == admin) revert E.InvalidParameter();

        pendingAdmin = _newAdmin;
        pendingAdminTimestamp = block.timestamp;

        emit AdminTransferInitiated(_newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert E.Unauthorized();
        if (pendingAdmin == address(0)) revert E.NotInitialized();
        if (block.timestamp < pendingAdminTimestamp + ADMIN_TRANSFER_DELAY) revert E.Locked();
        if (block.timestamp > pendingAdminTimestamp + ADMIN_TRANSFER_DELAY + ADMIN_ACCEPT_WINDOW) {
            revert E.Expired();
        }

        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        pendingAdminTimestamp = 0;

        emit AdminTransferCompleted(oldAdmin, admin);
        emit Events.OwnershipTransferred(oldAdmin, admin);
    }

    function cancelAdminTransfer() external onlyAdmin {
        pendingAdmin = address(0);
        pendingAdminTimestamp = 0;
    }

    // ========== VIEW FUNCTIONS ==========

    function implementation() external view returns (address) {
        return beacon.implementation();
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function getAllPools() external view returns (address[] memory) {
        return pools;
    }

    function isPool(address _pool) external view returns (bool) {
        return poolInfo[_pool].exists;
    }

    function getDarkPool(address _bammPool) external view returns (address) {
        return darkPoolForBAMM[_bammPool];
    }
}
