// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolProxyFactoryV1} from "./interfaces/IPoolProxyFactoryV1.sol";
import {IPoolV1} from "./interfaces/IPoolV1.sol";
import {IErrors} from "./interfaces/IErrors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title PoolProxyFactoryV1
/// @notice Non-upgradeable factory for deploying pool proxies with token registry
/// @dev Deployed deterministically via CREATE3, owns registry of all pools
contract PoolProxyFactoryV1 is IPoolProxyFactoryV1, Ownable {
    using SafeTransferLib for address;

    // ========== CONSTANTS ==========

    /// @notice Minimum delay between reference implementation upgrades
    uint256 public constant UPGRADE_TIMELOCK = 7 days;

    /// @notice Special marker for ETH (zero address in token registries)
    address internal constant ETH = address(0);

    /// @notice Minimal proxy bytecode (EIP-1167)
    /// @dev 3d602d80600a3d3981f3 = creation code setup
    ///      363d3d373d3d3d363d73 = delegatecall to implementation
    ///      [address] = implementation address (20 bytes)
    ///      5af43d82803e903d91602b57fd5bf3 = return code
    bytes internal constant MINIMAL_PROXY_CODE =
        hex"3d602d80600a3d3981f3363d3d373d3d3d363d73";

    // ========== STATE ==========

    /// @notice Reference implementation for pool proxies
    address public override referencePool;

    /// @notice Timelocked pending reference implementation
    address public pendingReferencePool;
    uint256 public upgradeTimelock;

    /// @notice Protocol deployer (their pools are auto-whitelisted)
    address public override protocolDeployer;

    // ========== POOL REGISTRY ==========

    /// @notice All deployed pools (including user-deployed)
    address[] public override allPools;
    mapping(address => bool) public override isPool;

    /// @notice Official protocol pools (whitelisted for routing)
    address[] public override officialPools;
    mapping(address pool => bool) private _isOfficialPool;

    /// @notice Check if pool is official (override for custom getter)
    function isOfficialPool(address pool) external view override returns (bool) {
        return _isOfficialPool[pool];
    }

    // ========== TOKEN REGISTRY ==========

    /// @notice Mapping of token → pools that support it
    mapping(address token => address[]) public override tokenToPools;

    /// @notice Mapping of pool → tokens it supports
    mapping(address pool => address[]) public override poolToTokens;

    /// @notice Bidirectional presence checks for array management
    mapping(address token => mapping(address pool => bool)) public override tokenInPool;
    mapping(address pool => mapping(address token => bool)) private _poolHasToken;

    /// @notice Pool base tokens (for routing optimization)
    mapping(address pool => address) public override poolBaseTokens;

    // ========== CONSTRUCTOR ==========

    constructor(address _referencePool, address _protocolDeployer) {
        if (_referencePool == address(0)) revert IErrors.ZeroValue();
        if (_protocolDeployer == address(0)) revert IErrors.ZeroValue();

        referencePool = _referencePool;
        protocolDeployer = _protocolDeployer;

        _initializeOwner(msg.sender);
    }

    // ========== POOL DEPLOYMENT ==========

    /// @notice Deploy a new pool proxy with initial token configuration
    /// @param baseToken Pool's base token (price anchor)
    /// @param tokens Initial tokens to support
    /// @param initdata Initialization calldata for pool
    /// @return pool The deployed proxy address
    function createPool(
        address baseToken,
        address[] calldata tokens,
        bytes calldata initdata
    ) external returns (address pool) {
        if (baseToken == address(0)) revert IErrors.ZeroValue();
        if (tokens.length == 0) revert IErrors.InvalidInput();

        // Construct minimal proxy bytecode
        bytes memory bytecode = bytes.concat(
            MINIMAL_PROXY_CODE,
            abi.encodePacked(referencePool),
            hex"5af43d82803e903d91602b57fd5bf3"
        );

        // Create2 deterministic address based on sender, baseToken, tokens
        bytes32 salt = keccak256(
            abi.encodePacked(
                msg.sender,
                baseToken,
                keccak256(abi.encode(tokens)),
                block.chainid
            )
        );

        assembly {
            pool := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        if (pool == address(0)) revert IErrors.DeploymentFailed();

        // Initialize the pool
        (bool success, ) = pool.call(initdata);
        if (!success) revert IErrors.OperationFailed();

        // Register pool
        _registerPool(pool, msg.sender, baseToken, tokens);
    }

    // ========== REGISTRY MANAGEMENT ==========

    /// @notice Register tokens for a pool (called by pool itself during asset addition)
    /// @dev Only callable by the pool to ensure sync with actual pool state
    function registerTokens(address[] calldata tokens) external {
        if (!isPool[msg.sender]) revert Ownable.Unauthorized();

        _addTokens(msg.sender, tokens);

        emit TokensRegistered(msg.sender, tokens);
    }

    /// @notice Internal registration logic
    function _registerPool(
        address pool,
        address creator,
        address baseToken,
        address[] memory tokens
    ) internal {
        isPool[pool] = true;
        allPools.push(pool);
        poolBaseTokens[pool] = baseToken;

        bool official = (creator == protocolDeployer);
        if (official) {
            _isOfficialPool[pool] = true;
            officialPools.push(pool);
        }

        _addTokens(pool, tokens);

        emit PoolCreated(pool, creator, baseToken, official);
    }

    /// @notice Add tokens to registry
    function _addTokens(address pool, address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) revert IErrors.ZeroValue();

            // Skip if already registered
            if (_poolHasToken[pool][token]) continue;

            // token → pools mapping
            tokenToPools[token].push(pool);
            tokenInPool[token][pool] = true;

            // pool → tokens mapping
            poolToTokens[pool].push(token);
            _poolHasToken[pool][token] = true;
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get all tokens supported by a pool
    function getPoolTokens(address pool)
        external
        view
        override
        returns (address[] memory)
    {
        return poolToTokens[pool];
    }

    /// @notice Get all pools that support a specific token
    function getPoolsForToken(address token)
        external
        view
        override
        returns (address[] memory pools)
    {
        return tokenToPools[token];
    }

    /// @notice Get pools that support both tokens (direct swap candidates)
    function getCommonPools(address tokenA, address tokenB)
        public
        view
        override
        returns (address[] memory pools)
    {
        address[] memory poolsA = tokenToPools[tokenA];
        address[] memory poolsB = tokenToPools[tokenB];

        // Early exit for empty arrays
        if (poolsA.length == 0 || poolsB.length == 0) {
            return new address[](0);
        }

        // Use smaller array for iteration
        if (poolsA.length > poolsB.length) {
            (poolsA, poolsB) = (poolsB, poolsA);
        }

        // Count matches first for efficient allocation
        uint256 count = 0;
        for (uint256 i = 0; i < poolsA.length; i++) {
            if (tokenInPool[tokenB][poolsA[i]]) {
                count++;
            }
        }

        // Allocate and fill result
        pools = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < poolsA.length; i++) {
            if (tokenInPool[tokenB][poolsA[i]]) {
                pools[index++] = poolsA[i];
            }
        }
    }

    /// @notice Get official pools count
    function getOfficialPoolsCount() external view override returns (uint256) {
        return officialPools.length;
    }

    /// @notice Get all pools count
    function getAllPoolsCount() external view override returns (uint256) {
        return allPools.length;
    }

    /// @notice Check if a route exists between two tokens
    function checkRoute(address tokenA, address tokenB)
        external
        view
        override
        returns (bool hasDirectRoute, address[] memory commonPools)
    {
        commonPools = getCommonPools(tokenA, tokenB);
        hasDirectRoute = commonPools.length > 0;
    }

    // ========== ADMIN ==========

    /// @notice Request reference implementation upgrade (timelocked)
    function requestReferenceUpgrade(address newImplementation)
        external
        onlyOwner
    {
        if (newImplementation == address(0)) revert IErrors.ZeroValue();
        if (pendingReferencePool != address(0)) revert IErrors.PendingTimelock(uint48(block.timestamp));

        pendingReferencePool = newImplementation;
        upgradeTimelock = block.timestamp + UPGRADE_TIMELOCK;

        emit ReferencePoolUpgradeRequested(
            referencePool,
            newImplementation,
            upgradeTimelock
        );
    }

    /// @notice Execute pending reference upgrade
    function executeReferenceUpgrade() external onlyOwner {
        if (block.timestamp < upgradeTimelock) revert IErrors.PendingTimelock(uint48(upgradeTimelock));
        if (pendingReferencePool == address(0)) revert IErrors.InvalidState();

        address oldImplementation = referencePool;
        referencePool = pendingReferencePool;

        delete pendingReferencePool;
        delete upgradeTimelock;

        emit ReferencePoolUpgraded(oldImplementation, referencePool);
    }

    /// @notice Cancel pending reference upgrade
    function cancelReferenceUpgrade() external onlyOwner {
        if (pendingReferencePool == address(0)) revert IErrors.InvalidState();

        delete pendingReferencePool;
        delete upgradeTimelock;
    }

    /// @notice Update protocol deployer
    function setProtocolDeployer(address newDeployer) external onlyOwner {
        if (newDeployer == address(0)) revert IErrors.ZeroValue();

        address oldDeployer = protocolDeployer;
        protocolDeployer = newDeployer;

        emit ProtocolDeployerUpdated(oldDeployer, newDeployer);
    }

    // ========== RESIDUALS ==========

    /// @notice Allow factory to receive ETH for pool deployments
    receive() external payable {}
}
