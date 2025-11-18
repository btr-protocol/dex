// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDarkPool} from "../interfaces/IDarkPool.sol";
import {IDarkPoolStorage} from "../interfaces/IDarkPoolStorage.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBAMM} from "../interfaces/IBAMM.sol";

import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibMerkleTree} from "../libraries/LibMerkleTree.sol";
import {LibVerifier} from "../libraries/LibVerifier.sol";
import {LibBAMM} from "../libraries/LibBAMM.sol";
import {LibNativeToken} from "../libraries/LibNativeToken.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {DarkPoolErrors as Errors} from "./DarkPoolErrors.sol";

/// @title DarkPool
/// @notice Privacy-preserving trading and LP for BAMM pools
/// @dev Beacon proxy implementation - each BAMM pool has its own DarkPool proxy
contract DarkPool is IDarkPool, Initializable, ReentrancyGuard, Ownable {
    using SafeTransferLib for address;

    // ========== MODIFIERS ==========

    modifier notPaused() {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        if (S._isDarkPoolPaused($)) revert Errors.Paused();
        _;
    }

    // ========== INITIALIZATION ==========

    /// @inheritdoc IDarkPool
    function initialize(
        address _bammPool,
        address _verifier,
        address _owner,
        address _shieldedState
    ) external override initializer {
        if (_bammPool == address(0)) revert Errors.ZeroAddress();
        if (_verifier == address(0)) revert Errors.ZeroAddress();
        if (_owner == address(0)) revert Errors.ZeroAddress();
        if (_shieldedState == address(0)) revert Errors.ZeroAddress();

        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();

        $.bammPool = _bammPool;
        $.verifier = _verifier;
        $.shieldedState = _shieldedState;
        S._setDarkPoolPaused($, false);
        S._setRequireASP($, false);

        // Initialize ownership
        _initializeOwner(_owner);
    }

    // ========== DEPOSIT FUNCTIONS ==========

    /// @inheritdoc IDarkPool
    function depositToken(
        address token,
        uint256 amount,
        bytes32 commitment,
        bytes calldata recipientHint
    ) external payable override nonReentrant notPaused {
        LibUtils.requireNonZero(token);
        if (amount == 0) revert Errors.ZeroAmount();
        if (commitment == bytes32(0)) revert Errors.InvalidParameter();

        // Get WETH address from BAMM pool (stored in BAMMStorage)
        address weth = S.bamm().weth;

        // Transfer token to DarkPool (handles native ETH wrapping)
        LibNativeToken.pullToken(token, msg.sender, address(this), amount, weth);

        // Insert commitment into merkle tree
        uint32 leafIndex = LibMerkleTree.insertLeaf(commitment);

        // Emit events
        emit Deposit(token, amount, commitment);
        emit NewCommitment(commitment, leafIndex, recipientHint);
        emit NewRoot(currentRoot(), leafIndex);
    }

    /// @inheritdoc IDarkPool
    function depositAndMintLP(
        address token,
        uint256 amount,
        bytes32 commitment,
        bytes calldata recipientHint,
        uint256 minLpTokens
    ) external payable nonReentrant notPaused {
        LibUtils.requireNonZero(token);
        if (amount == 0) revert Errors.ZeroAmount();
        if (commitment == bytes32(0)) revert Errors.InvalidParameter();

        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        address bamm = $.bammPool;
        address weth = S.bamm().weth;

        // Transfer token to DarkPool (handles native ETH wrapping)
        LibNativeToken.pullToken(token, msg.sender, address(this), amount, weth);

        // Read liquidityIndex before deposit
        IBAMM.LPState memory lpStateBefore = IBAMM(bamm).getLPState(token);

        // Approve and deposit to BAMM (using safe approve for USDT compatibility)
        LibBAMM._safeApprovePublic(token, bamm, amount);
        uint256 lpTokens = IBAMM(bamm).deposit{value: LibNativeToken.isNative(token) ? amount : 0}(token, amount, minLpTokens);

        // Insert commitment into merkle tree
        // Note: Commitment must encode scaledShares (computed off-chain: LibBAMM.computeScaledShares)
        uint32 leafIndex = LibMerkleTree.insertLeaf(commitment);

        // Emit events (consolidated at contract level for ABI discoverability)
        emit Deposit(token, amount, commitment);
        emit NewCommitment(commitment, leafIndex, recipientHint);
        emit NewRoot(currentRoot(), leafIndex);
        emit LPDeposited(token, amount, lpTokens, lpStateBefore.liquidityIndex);
    }

    // ========== PRIVATE TRANSACT ==========

    /// @inheritdoc IDarkPool
    function transact(
        Proof calldata proof,
        ExtData calldata extData,
        bytes32[] calldata recipientHints
    ) external override nonReentrant notPaused returns (bool) {
        // 0. Validate inputs BEFORE any state changes or external calls
        _validateTransactionInputs(proof, extData);

        // 1. Verify proof (includes nullifier checks AFTER proof verification)
        LibVerifier.verifyProof(proof, extData);

        // 2. Mark nullifiers as spent
        LibVerifier.markNullifiersSpent(proof.nullifiers);

        // Emit nullifier events (cache length for gas efficiency)
        uint256 nullifierLen = proof.nullifiers.length;
        for (uint256 i = 0; i < nullifierLen; ) {
            emit NewNullifier(proof.nullifiers[i]);
            unchecked { i++; }
        }

        // 3. Execute external actions (including token intake for extIn)
        LibBAMM.executeActions(extData, msg.sender);

        // 4. Insert output commitments (cache length for gas efficiency)
        uint256 outLen = proof.outCommitments.length;
        for (uint256 i = 0; i < outLen; ) {
            uint32 leafIndex = LibMerkleTree.insertLeaf(proof.outCommitments[i]);

            // Get recipient hint (use zero bytes32 if not provided)
            bytes32 hint = i < recipientHints.length ? recipientHints[i] : bytes32(0);

            emit NewCommitment(proof.outCommitments[i], leafIndex, abi.encodePacked(hint));

            unchecked { i++; }
        }

        // 5. Emit transaction event
        emit Transact(proof.nullifiers, proof.outCommitments, proof.extDataHash);
        // Emit NewRoot with the current leaf index from the tree insertion
        emit NewRoot(currentRoot(), 0); // The actual leaf index is tracked internally in ShieldedState

        return true;
    }

    /// @notice Validate transaction inputs before processing
    /// @param proof Proof struct
    /// @param extData External data
    function _validateTransactionInputs(
        Proof calldata proof,
        ExtData calldata extData
    ) private pure {
        // Validate nullifiers length (circuit expects exactly 2)
        if (proof.nullifiers.length != 2) {
            revert Errors.InvalidParameter();
        }

        // Validate output commitments length (circuit supports max 2)
        if (proof.outCommitments.length > 2) {
            revert Errors.InvalidParameter();
        }

        // Validate extData array lengths match assets
        if (extData.extIn.length != extData.assets.length) {
            revert Errors.ArrayLengthMismatch();
        }
        if (extData.extOut.length != extData.assets.length) {
            revert Errors.ArrayLengthMismatch();
        }

        // Validate maximum assets (circuit constraint)
        if (extData.assets.length > 4) {
            revert Errors.ArrayLengthMismatch();
        }

        // Action-specific validation
        if (extData.actionType == S.ACTION_TRANSFER) {
            // Transfer can have multiple receivers (one per asset)
            if (extData.receivers.length > extData.assets.length) {
                revert Errors.ArrayLengthMismatch();
            }
        } else if (extData.actionType == S.ACTION_SWAP) {
            // Swap requires exactly 2 assets (tokenIn, tokenOut)
            if (extData.assets.length != 2) {
                revert Errors.InvalidParameter();
            }
            // Swap can have 0 or 1 receiver
            if (extData.receivers.length > 1) {
                revert Errors.ArrayLengthMismatch();
            }
        } else if (extData.actionType == S.ACTION_LP_DEPOSIT || extData.actionType == S.ACTION_LP_WITHDRAW) {
            // LP operations require exactly 1 asset
            if (extData.assets.length != 1) {
                revert Errors.InvalidParameter();
            }
            // LP operations can have 0 or 1 receiver
            if (extData.receivers.length > 1) {
                revert Errors.ArrayLengthMismatch();
            }
        }
    }

    // ========== OWNER FUNCTIONS ==========

    /// @inheritdoc IDarkPool
    function setPaused(bool _paused) external override onlyOwner {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        S._setDarkPoolPaused($, _paused);
        emit Paused(_paused);
    }

    /// @inheritdoc IDarkPool
    function setRequireASP(bool _requireASP) external override onlyOwner {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        S._setRequireASP($, _requireASP);
        emit RequireASPSet(_requireASP);
    }

    /// @inheritdoc IDarkPool
    function setASPRootApproved(bytes32 aspRoot, bool approved) external override onlyOwner {
        if (aspRoot == bytes32(0)) revert Errors.ZeroAddress();

        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();

        if (approved) {
            // Approve for 30 days by default
            $.aspRootExpiry[aspRoot] = block.timestamp + 30 days;
        } else {
            // Revoke by setting expiry to 0
            $.aspRootExpiry[aspRoot] = 0;
        }

        emit ASPRootApproved(aspRoot, approved);
    }

    /// @notice Set ASP root with custom expiration time
    /// @param aspRoot ASP root to approve
    /// @param expiryTimestamp Timestamp when approval expires
    function setASPRootWithExpiry(bytes32 aspRoot, uint256 expiryTimestamp) external onlyOwner {
        if (aspRoot == bytes32(0)) revert Errors.ZeroAddress();
        if (expiryTimestamp <= block.timestamp) revert Errors.InvalidParameter();

        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        $.aspRootExpiry[aspRoot] = expiryTimestamp;

        emit ASPRootApproved(aspRoot, true);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @inheritdoc IDarkPool
    function currentRoot() public view override returns (bytes32) {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) return bytes32(0);

        // Query current root from ShieldedState
        (bool success, bytes memory result) = shieldedStateAddr.staticcall(
            abi.encodeWithSignature("currentRoot()")
        );

        if (!success) return bytes32(0);
        return abi.decode(result, (bytes32));
    }

    /// @inheritdoc IDarkPool
    function isSpent(bytes32 nullifier) external view override returns (bool) {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) return false;

        // Query nullifier status from ShieldedState
        (bool success, bytes memory result) = shieldedStateAddr.staticcall(
            abi.encodeWithSignature("nullifierSpent(bytes32)", nullifier)
        );

        if (!success) return false;
        return abi.decode(result, (bool));
    }

    /// @inheritdoc IDarkPool
    function isKnownRoot(bytes32 root) external view override returns (bool) {
        return S.isKnownRoot(root);
    }

    /// @inheritdoc IDarkPool
    function getBammPool() external view override returns (address) {
        return S.darkPool().bammPool;
    }

    /// @inheritdoc IDarkPool
    function getVerifier() external view override returns (address) {
        return S.darkPool().verifier;
    }

    /// @inheritdoc IDarkPool
    function getOwner() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc IDarkPool
    function isPaused() external view override returns (bool) {
        return S._isDarkPoolPaused(S.darkPool());
    }

    /// @inheritdoc IDarkPool
    function isASPRequired() external view override returns (bool) {
        return S._requiresASP(S.darkPool());
    }

    /// @inheritdoc IDarkPool
    function isASPRootApproved(bytes32 aspRoot) external view override returns (bool) {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        uint256 expiry = $.aspRootExpiry[aspRoot];
        return expiry > 0 && expiry >= block.timestamp;
    }

    // ========== EVENTS (inherited from IDarkPool) ==========

    // ========== ERC1155 RECEIVER ==========

    /// @notice Handle ERC1155 token receipt (for LP tokens from BAMM)
    /// @dev Only accepts tokens from the associated BAMM pool to prevent griefing
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
        // Only accept LP tokens from our BAMM pool
        if (msg.sender != S.darkPool().bammPool) {
            revert Errors.Unauthorized();
        }
        return this.onERC1155Received.selector;
    }

    /// @notice Handle batch ERC1155 token receipt
    /// @dev Only accepts tokens from the associated BAMM pool to prevent griefing
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view returns (bytes4) {
        // Only accept LP tokens from our BAMM pool
        if (msg.sender != S.darkPool().bammPool) {
            revert Errors.Unauthorized();
        }
        return this.onERC1155BatchReceived.selector;
    }
}
