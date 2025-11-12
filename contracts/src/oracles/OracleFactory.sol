// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";
import {BeaconFactory} from "../utils/BeaconFactory.sol";

/// @title OracleFactory
/// @notice Factory for deploying oracle contracts using Beacon Proxy pattern
/// @dev Each deployment creates a new beacon proxy pointing to shared oracle implementation
///      Factory ownership can be transferred (e.g., EOA → multisig) via Solady's Ownable
///      Supports any oracle implementation that follows the initialize pattern
contract OracleFactory is BeaconFactory {

    // ========== STORAGE ==========

    /// @notice List of deployed oracle proxies
    address[] public oracles;

    /// @notice Mapping from oracle address to deployment info
    mapping(address => OracleInfo) public oracleInfo;

    /// @notice Oracle deployment metadata
    struct OracleInfo {
        address deployer;      // Address that deployed this oracle
        uint256 deployedAt;    // Block timestamp of deployment
        bool exists;           // Whether this oracle was deployed by this factory
    }

    // ========== EVENTS ==========

    /// @notice Emitted when a new oracle is deployed
    /// @param oracle Address of the deployed oracle proxy
    /// @param deployer Address that deployed the oracle
    event OracleDeployed(address indexed oracle, address indexed deployer);

    // ========== CONSTRUCTOR ==========

    /// @notice Deploy factory with oracle implementation
    /// @param implementation Oracle implementation address (must support initialize pattern)
    /// @param initialOwner Factory owner (can upgrade beacon and deploy oracles)
    constructor(address implementation, address initialOwner)
        BeaconFactory(implementation, initialOwner)
    {}

    // ========== DEPLOYMENT FUNCTIONS ==========

    /// @notice Deploy a new oracle proxy with initialization data
    /// @param initData Initialization data to pass to oracle's initialize function
    /// @return oracle Address of the deployed oracle proxy
    function deployOracle(bytes calldata initData) external returns (address oracle) {
        // Deploy beacon proxy with initialization
        oracle = LibClone.deployERC1967BeaconProxy(address(_beacon), initData);

        // Record deployment info
        oracleInfo[oracle] = OracleInfo({
            deployer: msg.sender,
            deployedAt: block.timestamp,
            exists: true
        });

        oracles.push(oracle);

        emit OracleDeployed(oracle, msg.sender);

        return oracle;
    }

    /// @notice Deploy oracle with manual initialization (two-step)
    /// @dev Use this if you need to initialize the oracle after deployment
    /// @return oracle Address of the deployed oracle proxy (uninitialized)
    function deployOracleUninitialized() external returns (address oracle) {
        // Deploy beacon proxy without initialization
        oracle = LibClone.deployERC1967BeaconProxy(address(_beacon));

        // Record deployment info
        oracleInfo[oracle] = OracleInfo({
            deployer: msg.sender,
            deployedAt: block.timestamp,
            exists: true
        });

        oracles.push(oracle);

        emit OracleDeployed(oracle, msg.sender);

        return oracle;
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get total number of deployed oracles
    /// @return count Number of oracles deployed by this factory
    function oracleCount() external view returns (uint256) {
        return oracles.length;
    }

    /// @notice Get all deployed oracle addresses
    /// @return Array of oracle addresses
    function getAllOracles() external view returns (address[] memory) {
        return oracles;
    }

    /// @notice Check if an address is an oracle deployed by this factory
    /// @param oracle Address to check
    /// @return True if deployed by this factory
    function isOracle(address oracle) external view returns (bool) {
        return oracleInfo[oracle].exists;
    }
}
