// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";
import {BeaconFactory} from "../utils/BeaconFactory.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";
import {IDarkPoolFactory} from "../interfaces/IDarkPoolFactory.sol";

/// @title BAMMFactory
/// @notice Factory for deploying BAMM pools using Beacon Proxy pattern
/// @dev Each deployment creates a new beacon proxy pointing to shared implementation
///      Factory ownership can be transferred (e.g., EOA → multisig) via Solady's Ownable
contract BAMMFactory is BeaconFactory {

    // ========== STATE VARIABLES ==========

    // DarkPool integration
    IDarkPoolFactory public darkPoolFactory;
    address public defaultVerifier;
    mapping(address => address) public darkPoolForBAMM;

    address[] public pools;
    mapping(address => PoolInfo) public poolInfo;

    /// @notice Pool information struct (optimized for storage packing: 3 slots instead of 6)
    /// @dev Packing: [baseToken+poolOwner(40)] + [guardian+exists+hasDarkPool(22)] + [deployedAt(32)] = 3 slots
    struct PoolInfo {
        address baseToken;     // 20 bytes
        address poolOwner;     // 20 bytes (slot 1: 40 bytes total)
        address guardian;      // 20 bytes
        bool exists;          // 1 byte
        bool hasDarkPool;     // 1 byte (slot 2: 22 bytes total)
        uint256 deployedAt;    // 32 bytes (slot 3: 32 bytes total)
    }

    // ========== EVENTS ==========

    event PoolDeployed(address indexed pool, address indexed baseToken, address indexed owner, address guardian);
    event DarkPoolEnabled(address indexed bammPool, address indexed darkPool);
    event DarkPoolFactorySet(address indexed darkPoolFactory);
    event DefaultVerifierSet(address indexed verifier);

    // ========== CONSTRUCTOR ==========

    /// @notice Deploy factory with BAMM implementation
    /// @param implementation BAMM implementation address
    /// @param initialOwner Factory owner (can upgrade beacon and deploy pools)
    constructor(address implementation, address initialOwner)
        BeaconFactory(implementation, initialOwner)
    {}

    // ========== POOL DEPLOYMENT ==========

    function deployPool(
        address _baseToken,
        address _poolOwner,
        address _pricingFacet,
        address _adminFacet,
        address _oracleFacet,
        bytes4[] calldata _adminSelectors,
        bytes4[] calldata _oracleSelectors
    ) external returns (address pool) {
        if (_baseToken == address(0) || _poolOwner == address(0)) {
            revert E.ZeroAddress();
        }
        if (_pricingFacet == address(0) || _adminFacet == address(0) || _oracleFacet == address(0)) {
            revert E.ZeroAddress();
        }

        // Encode initialization call with new diamond-style signature
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,bytes4[],bytes4[])",
            _baseToken,
            _pricingFacet,
            _adminFacet,
            _oracleFacet,
            _poolOwner,
            _adminSelectors,
            _oracleSelectors
        );

        pool = LibClone.deployERC1967BeaconProxy(address(_beacon), initData);

        poolInfo[pool] = PoolInfo({
            baseToken: _baseToken,
            poolOwner: _poolOwner,
            guardian: _poolOwner,  // Default: pool owner is also guardian
            deployedAt: block.timestamp,
            exists: true,
            hasDarkPool: false
        });

        pools.push(pool);

        emit PoolDeployed(pool, _baseToken, _poolOwner, _poolOwner);
    }

    /// @notice Enable DarkPool for an existing BAMM pool
    /// @param _bammPool BAMM pool address
    /// @param _darkPoolOwner Owner for the DarkPool (typically same as pool owner)
    function enableDarkPool(address _bammPool, address _darkPoolOwner) external {
        PoolInfo storage info = poolInfo[_bammPool];

        // Only pool owner or factory owner can enable
        if (msg.sender != info.poolOwner && msg.sender != owner()) {
            revert E.Unauthorized();
        }

        if (!info.exists) revert E.InvalidParameter();
        if (info.hasDarkPool) revert E.InvalidParameter(); // Already enabled

        _enableDarkPoolForBAMM(_bammPool, _darkPoolOwner);
    }

    /// @notice Internal function to deploy DarkPool proxy
    /// @param _bammPool BAMM pool address
    /// @param _darkPoolOwner Owner for the DarkPool
    function _enableDarkPoolForBAMM(address _bammPool, address _darkPoolOwner) internal {
        if (address(darkPoolFactory) == address(0)) revert E.NotInitialized();
        if (defaultVerifier == address(0)) revert E.NotInitialized();

        // Deploy DarkPool via DarkPoolFactory
        address darkPool = darkPoolFactory.createDarkPool(
            _bammPool,
            defaultVerifier,
            _darkPoolOwner
        );

        // Track relationship
        darkPoolForBAMM[_bammPool] = darkPool;
        poolInfo[_bammPool].hasDarkPool = true;

        emit DarkPoolEnabled(_bammPool, darkPool);
    }

    // ========== DARKPOOL CONFIGURATION ==========

    /// @notice Set the DarkPoolFactory address
    /// @param _darkPoolFactory DarkPoolFactory address
    function setDarkPoolFactory(address _darkPoolFactory) external onlyOwner {
        if (_darkPoolFactory == address(0)) revert E.ZeroAddress();
        darkPoolFactory = IDarkPoolFactory(_darkPoolFactory);
        emit DarkPoolFactorySet(_darkPoolFactory);
    }

    /// @notice Set the default Groth16 verifier for new DarkPools
    /// @param _verifier Verifier contract address
    function setDefaultVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) revert E.ZeroAddress();
        defaultVerifier = _verifier;
        emit DefaultVerifierSet(_verifier);
    }

    // ========== VIEW FUNCTIONS ==========

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
