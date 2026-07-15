// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPoolFactory} from "./interfaces/IPoolFactory.sol";
import {IPool} from "./interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";

/// @title PoolFactory
/// @notice Non-upgradeable factory deploying deterministic ERC1967 beacon proxies of the Pool
///         impl (Solady `UpgradeableBeacon` fleet). Each proxy IS a Pool with its own storage;
///         all proxies read impl from one beacon, so `executeReferenceUpgrade` swaps the impl
///         for the ENTIRE live fleet atomically (was: re-point future clones only).
contract PoolFactory is IPoolFactory {
    using SafeTransferLib for address;

    uint256 public constant UPGRADE_TIMELOCK = 7 days;
    address internal constant ETH = address(0);

    /// @notice REG-01: hard caps on the permissionless append-only discovery arrays. `createPool` (any
    ///         caller) and `registerTokens` (any isPool) can otherwise inflate `poolToTokens` /
    ///         `tokenToPools` without bound until `getCommonPools`/`checkRoute` run out of gas
    ///         (route-view DoS) and per-token emergency sweeps bloat. Sized far above any real star pool.
    uint256 public constant MAX_POOL_TOKENS = 32;
    uint256 public constant MAX_TOKEN_POOLS = 128;

    /// @notice GAS-19: the live impl is the single source of truth in `beacon.implementation()`; a mirror
    ///         storage slot only risked drift. `referencePool()` is now a view over the beacon (below).
    address public pendingReferencePool;
    /// @notice Earliest block timestamp at which the pending impl swap may be executed. It expires
    ///         `SC.GRACE_PERIOD` after that (LOW-11), so a matured-but-forgotten upgrade cannot linger
    ///         executable forever — governance must re-`request` past the grace window.
    /// @dev Phase 42H.D · G3 -kept as raw `uint256` (≠ shared/Timelock.sol packed `uint96`) because
    ///      PoolFactory has a SINGLE in-flight pending upgrade (no per-op keying), so the packed
    ///      (eta|grace) optimisation buys no slot reuse, and `uint256` is ABI-stable for front-ends.
    uint256 public upgradeTimelock;
    address public override protocolDeployer;

    /// @notice Shared singleton AccessControl -single source of truth for pool ownership.
    /// @dev Phase 42H.B.1 -wired once at factory construction, exposed for consumers
    ///      (front-ends, keepers, integrators) to verify which AC governs all pools spun
    ///      by this factory. Module impls hold their own immutable AC; this is informational.
    address public immutable AC;

    /// @notice Solady UpgradeableBeacon owning the shared Pool impl for the whole proxy fleet.
    /// @dev Factory is the beacon owner, so the timelocked `executeReferenceUpgrade` drives
    ///      `beacon.upgradeTo(newImpl)` = atomic upgrade of every live pool. `referencePool`
    ///      storage mirrors `beacon.implementation()` (kept for the IPoolFactory ABI + events).
    address public immutable override beacon;

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

    /// @notice REG-01: official-only discovery index. `getCommonPools`/`checkRoute` route off THIS
    ///         (unpolluted by permissionless clones), while `tokenToPools` remains the full registry.
    mapping(address token => address[]) public officialTokenToPools;
    mapping(address token => mapping(address pool => bool)) private _officialTokenInPool;

    function getOfficialPoolsForToken(address token) external view returns (address[] memory) {
        return officialTokenToPools[token];
    }

    constructor(address referencePool_, address protocolDeployer_, address ac_) {
        if (referencePool_ == address(0) || protocolDeployer_ == address(0) || ac_ == address(0)) revert Err.ZeroValue();
        protocolDeployer = protocolDeployer_;
        AC = ac_;
        // Factory owns the beacon → timelocked fleet upgrades funnel through it.
        beacon = address(new UpgradeableBeacon(address(this), referencePool_));
    }

    /// @notice AC-singleton ownership gate. Mirrors Distributor.sol:40 pattern.
    modifier onlyAdmin() {
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
        // GAS-14: LibClone reverts on deploy failure (never returns address(0)) → no null check.
        pool = LibClone.deployDeterministicERC1967BeaconProxy(beacon, salt);

        (bool success, ) = pool.call(initdata);
        if (!success) revert Err.OperationFailed();

        // REG-03: the clone is registered as tradeable, so verify `initdata` actually ran `initialize`
        // with the SAME base — arbitrary initdata could low-level-succeed on a different selector, arming
        // an un/mis-initialized pool in the index. `baseToken()` is 0 (or mismatched) unless initialized.
        if (IPool(pool).baseToken() != baseToken) revert Err.OperationFailed();

        _registerPool(pool, msg.sender, baseToken, tokens);
    }

    // ─── registry ───

    function registerTokens(address[] calldata tokens) external override {
        if (!isPool[msg.sender]) revert Ownable.Unauthorized();
        _addTokens(msg.sender, tokens, _isOfficialPool[msg.sender]);
        emit TokensRegistered(msg.sender, tokens);
    }

    /// @notice REG-02: keep the factory's cached base in sync when a pool migrates its base numeraire.
    ///         isPool-gated (only the pool itself, from `PoolAdminWrite.setBaseToken`).
    function setPoolBaseToken(address newBase) external override {
        if (!isPool[msg.sender]) revert Ownable.Unauthorized();
        if (newBase == address(0)) revert Err.ZeroValue();
        poolBaseTokens[msg.sender] = newBase;
        emit PoolBaseTokenUpdated(msg.sender, newBase);
    }

    /// @notice REG-01: owner-only de-pollution — evict a pool (typically a permissionless/griefing clone)
    ///         from every discovery index so it stops bloating route views + emergency sweeps.
    function deregisterPool(address pool) external override onlyAdmin {
        if (!isPool[pool]) revert Err.InvalidState();
        address[] memory toks = poolToTokens[pool];
        for (uint256 i; i < toks.length;) {
            address t = toks[i];
            _removeFromArray(tokenToPools[t], pool);
            delete tokenInPool[t][pool];
            if (_officialTokenInPool[t][pool]) {
                _removeFromArray(officialTokenToPools[t], pool);
                delete _officialTokenInPool[t][pool];
            }
            unchecked { ++i; }
        }
        delete poolToTokens[pool];
        delete poolBaseTokens[pool];
        delete isPool[pool];
        if (_isOfficialPool[pool]) {
            delete _isOfficialPool[pool];
            _removeFromArray(officialPools, pool);
        }
        _removeFromArray(allPools, pool);
        emit PoolDeregistered(pool);
    }

    function _removeFromArray(address[] storage arr, address val) private {
        uint256 n = arr.length;
        for (uint256 i; i < n;) {
            if (arr[i] == val) {
                arr[i] = arr[n - 1];
                arr.pop();
                return;
            }
            unchecked { ++i; }
        }
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
        _addTokens(pool, tokens, official);
        emit PoolCreated(pool, creator, baseToken, official);
    }

    function _addTokens(address pool, address[] memory tokens, bool official) internal {
        uint256 n = tokens.length;
        // REG-01: bound the per-pool token set (append-only, permissionless).
        if (poolToTokens[pool].length + n > MAX_POOL_TOKENS) revert Err.ExcessiveAmount(n, MAX_POOL_TOKENS);
        for (uint256 i; i < n;) {
            address token = tokens[i];
            if (token == address(0)) revert Err.ZeroValue();
            if (!tokenInPool[token][pool]) {
                // REG-01: bound the per-token pool list so a griefer cannot make a token's route views DoS.
                if (tokenToPools[token].length >= MAX_TOKEN_POOLS) {
                    revert Err.ExcessiveAmount(tokenToPools[token].length, MAX_TOKEN_POOLS);
                }
                tokenToPools[token].push(pool);
                tokenInPool[token][pool] = true;
                poolToTokens[pool].push(token);
            }
            // Official-only discovery index (unpolluted by permissionless clones).
            if (official && !_officialTokenInPool[token][pool]) {
                _officialTokenInPool[token][pool] = true;
                officialTokenToPools[token].push(pool);
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
        // REG-01: route off the OFFICIAL index only — permissionless clones cannot pollute discovery
        // nor grow this loop unbounded (the full registry stays queryable via getPoolsForToken).
        address[] memory poolsA = officialTokenToPools[tokenA];
        address[] memory poolsB = officialTokenToPools[tokenB];
        if (poolsA.length == 0 || poolsB.length == 0) return new address[](0);
        if (poolsA.length > poolsB.length) (poolsA, poolsB) = (poolsB, poolsA);

        uint256 nA = poolsA.length;
        uint256 count;
        for (uint256 i; i < nA;) {
            if (_officialTokenInPool[tokenB][poolsA[i]]) ++count;
            unchecked { ++i; }
        }
        pools = new address[](count);
        uint256 idx;
        for (uint256 i; i < nA;) {
            if (_officialTokenInPool[tokenB][poolsA[i]]) { pools[idx] = poolsA[i]; unchecked { ++idx; } }
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

    /// @notice GAS-19: current live impl for the whole fleet, read straight from the beacon (no mirror slot).
    function referencePool() external view override returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    function requestReferenceUpgrade(address newImplementation) external onlyAdmin {
        if (newImplementation == address(0)) revert Err.ZeroValue();
        // REG-04: a non-contract impl would brick every future clone (delegatecalls to empty code).
        if (newImplementation.code.length == 0) revert Err.NotCode();
        // Impl-compat: the beacon swap re-points the ENTIRE live fleet, so the new impl's baked-in
        // immutables MUST match the live wiring or every pool breaks atomically. AC/admin/flash are
        // structural (assert equality); poolAux MAY change across upgrades (assert only codeful — its
        // $-layout parity with Pool remains a deploy/CI invariant, `forge inspect storage-layout` diff,
        // NOT on-chain-checkable).
        address live = UpgradeableBeacon(beacon).implementation();
        if (
            IPool(newImplementation).AC() != AC ||
            IPool(newImplementation).admin() != IPool(live).admin() ||
            IPool(newImplementation).flash() != IPool(live).flash() ||
            IPool(newImplementation).poolAux().code.length == 0
        ) revert Err.BadConfig();
        if (pendingReferencePool != address(0)) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingReferencePool = newImplementation;
        upgradeTimelock = block.timestamp + UPGRADE_TIMELOCK;
        emit ReferencePoolUpgradeRequested(live, newImplementation, upgradeTimelock);
    }

    function executeReferenceUpgrade() external onlyAdmin {
        if (block.timestamp < upgradeTimelock) revert Err.PendingTimelock(uint48(upgradeTimelock));
        // LOW-11: a matured pending upgrade expires SC.GRACE_PERIOD after its eta so a forgotten,
        // stale-vetted impl cannot be executed months later — must be re-requested past the window.
        if (block.timestamp > upgradeTimelock + SC.GRACE_PERIOD) revert Err.Expired();
        if (pendingReferencePool == address(0)) revert Err.InvalidState();
        address oldImpl = UpgradeableBeacon(beacon).implementation();
        address newImpl = pendingReferencePool;
        delete pendingReferencePool;
        delete upgradeTimelock;
        // Atomic fleet upgrade: every live beacon proxy now points at the new impl.
        UpgradeableBeacon(beacon).upgradeTo(newImpl);
        emit ReferencePoolUpgraded(oldImpl, newImpl);
    }

    function cancelReferenceUpgrade() external onlyAdmin {
        address cancelled = pendingReferencePool;
        if (cancelled == address(0)) revert Err.InvalidState();
        delete pendingReferencePool;
        delete upgradeTimelock;
        emit ReferencePoolUpgradeCancelled(msg.sender, cancelled);
    }

    /// @notice MED: guardian escape hatch — a fleet-wide code swap is otherwise gated only by the
    ///         owner (request) and cancellable only by that same owner. A guardian (AC.isGuardian) may
    ///         veto a pending upgrade during the timelock, matching guardians' freeze/pause-only remit.
    /// @dev Residual (accepted MED): a fully-compromised owner can `setGuardian(false)` to strip
    ///      guardians instantly, then re-request — the guard raises the bar, it is not absolute. Owner
    ///      is a multisig; this backstops a single mis-clicked/coerced request, not a full owner takeover.
    function guardianCancelUpgrade() external {
        if (!AccessControl(AC).isGuardian(msg.sender)) revert Err.NotAuth();
        address cancelled = pendingReferencePool;
        if (cancelled == address(0)) revert Err.InvalidState();
        delete pendingReferencePool;
        delete upgradeTimelock;
        emit ReferencePoolUpgradeCancelled(msg.sender, cancelled);
    }

    function setProtocolDeployer(address newDeployer) external onlyAdmin {
        if (newDeployer == address(0)) revert Err.ZeroValue();
        address old = protocolDeployer;
        protocolDeployer = newDeployer;
        emit ProtocolDeployerUpdated(old, newDeployer);
    }

    receive() external payable {}
}
