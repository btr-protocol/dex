// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPoolFactory} from "./interfaces/IPoolFactory.sol";
import {IPool} from "./interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @title PoolFactory
/// @notice Phase 42H.B.3d -non-upgradeable factory deploying EIP-1167 minimal-proxy clones
///         of the Pool impl. PoolProxy is gone; each clone IS a Pool with its own storage.
contract PoolFactory is IPoolFactory {
    using SafeTransferLib for address;

    uint256 public constant UPGRADE_TIMELOCK = 7 days;
    address internal constant ETH = address(0);

    address public override referencePool;
    address public pendingReferencePool;
    /// @notice Earliest block timestamp at which the pending impl swap may be executed.
    /// @dev Phase 42H.D · G3 -kept as raw `uint256` (≠ shared/Timelock.sol packed `uint96`)
    ///      because:
    ///        1. PoolFactory has a SINGLE in-flight pending upgrade (no per-op keying), so
    ///           the packed (eta|grace) optimisation buys no slot reuse -`pendingReferencePool`
    ///           lives in its own slot anyway.
    ///        2. The grace window concept (auto-expiry) is undesirable here: if governance
    ///           misses the execution window, the upgrade should NOT silently void -admins
    ///           MUST explicitly cancel via `cancelReferenceUpgrade`. Equivalent semantics =
    ///           grace = ∞, which the packed lib does not encode (uint48 grace).
    ///        3. `uint256` is ABI-stable for downstream front-ends already reading this slot.
    uint256 public upgradeTimelock;
    address public override protocolDeployer;

    /// @notice Shared singleton AccessControl -single source of truth for pool ownership.
    /// @dev Phase 42H.B.1 -wired once at factory construction, exposed for consumers
    ///      (front-ends, keepers, integrators) to verify which AC governs all pools spun
    ///      by this factory. Module impls hold their own immutable AC; this is informational.
    address public immutable AC;

    address[] public override allPools;
    mapping(address => bool) public override isPool;
    address[] public override officialPools;
    mapping(address pool => bool) private _isOfficialPool;

    function isOfficialPool(address pool) external view override returns (bool) {
        return _isOfficialPool[pool];
    }

    mapping(address token => address[]) public override tokenToPools;
    mapping(address pool => address[]) public override poolToTokens;
    mapping(address token => mapping(address pool => bool)) public override tokenInPool;
    mapping(address pool => address) public override poolBaseTokens;

    constructor(address referencePool_, address protocolDeployer_, address ac_) {
        if (referencePool_ == address(0) || protocolDeployer_ == address(0) || ac_ == address(0)) revert Err.ZeroValue();
        referencePool = referencePool_;
        protocolDeployer = protocolDeployer_;
        AC = ac_;
    }

    /// @notice AC-singleton ownership gate. Mirrors Distributor.sol:40 pattern.
    modifier onlyOwner() {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        _;
    }

    // ─── deploy ───

    function createPool(
        address baseToken,
        address[] calldata tokens,
        bytes calldata initdata
    ) external returns (address pool) {
        if (baseToken == address(0)) revert Err.ZeroValue();
        if (tokens.length == 0) revert Err.InvalidInput();

        bytes32 salt = keccak256(abi.encodePacked(msg.sender, baseToken, keccak256(abi.encode(tokens)), block.chainid));
        pool = LibClone.cloneDeterministic(referencePool, salt);
        if (pool == address(0)) revert Err.DeploymentFailed();

        (bool success, ) = pool.call(initdata);
        if (!success) revert Err.OperationFailed();

        _registerPool(pool, msg.sender, baseToken, tokens);
    }

    // ─── registry ───

    function registerTokens(address[] calldata tokens) external {
        if (!isPool[msg.sender]) revert Ownable.Unauthorized();
        _addTokens(msg.sender, tokens);
        emit TokensRegistered(msg.sender, tokens);
    }

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

    function _addTokens(address pool, address[] memory tokens) internal {
        uint256 n = tokens.length;
        for (uint256 i; i < n;) {
            address token = tokens[i];
            if (token == address(0)) revert Err.ZeroValue();
            if (!tokenInPool[token][pool]) {
                tokenToPools[token].push(pool);
                tokenInPool[token][pool] = true;
                poolToTokens[pool].push(token);
            }
            unchecked { ++i; }
        }
    }

    // ─── views ───

    function getPoolTokens(address pool) external view override returns (address[] memory) {
        return poolToTokens[pool];
    }

    function getPoolsForToken(address token) external view override returns (address[] memory) {
        return tokenToPools[token];
    }

    function getCommonPools(address tokenA, address tokenB)
        public
        view
        override
        returns (address[] memory pools)
    {
        address[] memory poolsA = tokenToPools[tokenA];
        address[] memory poolsB = tokenToPools[tokenB];
        if (poolsA.length == 0 || poolsB.length == 0) return new address[](0);
        if (poolsA.length > poolsB.length) (poolsA, poolsB) = (poolsB, poolsA);

        uint256 nA = poolsA.length;
        uint256 count;
        for (uint256 i; i < nA;) {
            if (tokenInPool[tokenB][poolsA[i]]) ++count;
            unchecked { ++i; }
        }
        pools = new address[](count);
        uint256 idx;
        for (uint256 i; i < nA;) {
            if (tokenInPool[tokenB][poolsA[i]]) { pools[idx] = poolsA[i]; unchecked { ++idx; } }
            unchecked { ++i; }
        }
    }

    function getOfficialPoolsCount() external view override returns (uint256) {
        return officialPools.length;
    }

    function getAllPoolsCount() external view override returns (uint256) {
        return allPools.length;
    }

    function checkRoute(address tokenA, address tokenB)
        external
        view
        override
        returns (bool hasDirectRoute, address[] memory commonPools)
    {
        commonPools = getCommonPools(tokenA, tokenB);
        hasDirectRoute = commonPools.length > 0;
    }

    // ─── admin ───

    function requestReferenceUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert Err.ZeroValue();
        if (pendingReferencePool != address(0)) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingReferencePool = newImplementation;
        upgradeTimelock = block.timestamp + UPGRADE_TIMELOCK;
        emit ReferencePoolUpgradeRequested(referencePool, newImplementation, upgradeTimelock);
    }

    function executeReferenceUpgrade() external onlyOwner {
        if (block.timestamp < upgradeTimelock) revert Err.PendingTimelock(uint48(upgradeTimelock));
        if (pendingReferencePool == address(0)) revert Err.InvalidState();
        address oldImpl = referencePool;
        referencePool = pendingReferencePool;
        delete pendingReferencePool;
        delete upgradeTimelock;
        emit ReferencePoolUpgraded(oldImpl, referencePool);
    }

    function cancelReferenceUpgrade() external onlyOwner {
        if (pendingReferencePool == address(0)) revert Err.InvalidState();
        delete pendingReferencePool;
        delete upgradeTimelock;
    }

    function setProtocolDeployer(address newDeployer) external onlyOwner {
        if (newDeployer == address(0)) revert Err.ZeroValue();
        address old = protocolDeployer;
        protocolDeployer = newDeployer;
        emit ProtocolDeployerUpdated(old, newDeployer);
    }

    receive() external payable {}
}
