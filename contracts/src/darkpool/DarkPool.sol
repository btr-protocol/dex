// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDarkPool} from "../interfaces/IDarkPool.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBAMM} from "../interfaces/IBAMM.sol";

import {LibStorage} from "../libraries/LibStorage.sol";
import {LibMerkleTree} from "../libraries/LibMerkleTree.sol";
import {LibVerifier} from "../libraries/LibVerifier.sol";
import {LibBAMM} from "../libraries/LibBAMM.sol";
import {DarkPoolErrors as Errors} from "./DarkPoolErrors.sol";

/// @title DarkPool
/// @notice Privacy-preserving trading and LP for BAMM pools
/// @dev Beacon proxy implementation - each BAMM pool has its own DarkPool proxy
contract DarkPool is IDarkPool, Initializable, ReentrancyGuard, Ownable {
    using SafeTransferLib for address;

    // ========== MODIFIERS ==========

    modifier notPaused() {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();
        if ($.paused) revert Errors.Paused();
        _;
    }

    // ========== INITIALIZATION ==========

    /// @inheritdoc IDarkPool
    function initialize(
        address _bammPool,
        address _verifier,
        address _owner
    ) external override initializer {
        if (_bammPool == address(0)) revert Errors.ZeroAddress();
        if (_verifier == address(0)) revert Errors.ZeroAddress();
        if (_owner == address(0)) revert Errors.ZeroAddress();

        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();

        $.bammPool = _bammPool;
        $.verifier = _verifier;
        $.treeHeight = LibStorage.TREE_HEIGHT;
        $.rootHistorySize = LibStorage.ROOT_HISTORY_SIZE;
        $.paused = false;
        $.requireASP = false;

        // Initialize ownership
        _initializeOwner(_owner);

        // Initialize merkle tree with first zero root
        bytes32 initialRoot = LibMerkleTree.getZeroValue(LibStorage.TREE_HEIGHT);
        LibStorage.addRoot(initialRoot);
    }

    // ========== DEPOSIT FUNCTIONS ==========

    /// @inheritdoc IDarkPool
    function depositToken(
        address token,
        uint256 amount,
        bytes32 commitment,
        bytes calldata recipientHint
    ) external override nonReentrant notPaused {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (commitment == bytes32(0)) revert Errors.InvalidParameter();

        // Transfer token to DarkPool
        token.safeTransferFrom(msg.sender, address(this), amount);

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
        bytes calldata recipientHint
    ) external override nonReentrant notPaused {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (commitment == bytes32(0)) revert Errors.InvalidParameter();

        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();
        address bamm = $.bammPool;

        // Transfer token to DarkPool
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Read liquidityIndex before deposit
        IBAMM.LPState memory lpStateBefore = IBAMM(bamm).lpStates(token);

        // Approve and deposit to BAMM
        token.safeApprove(bamm, amount);
        uint256 lpTokens = IBAMM(bamm).deposit(token, amount, 0);

        // Compute scaled shares
        uint256 scaledShares = LibBAMM.computeScaledShares(token, lpTokens);

        // Insert commitment into merkle tree
        // Note: Commitment must encode scaledShares (computed off-chain)
        uint32 leafIndex = LibMerkleTree.insertLeaf(commitment);

        // Emit events
        emit Deposit(token, amount, commitment);
        emit NewCommitment(commitment, leafIndex, recipientHint);
        emit NewRoot(currentRoot(), leafIndex);
        emit LibBAMM.LPDeposited(token, amount, lpTokens, lpStateBefore.liquidityIndex);
    }

    // ========== PRIVATE TRANSACT ==========

    /// @inheritdoc IDarkPool
    function transact(
        Proof calldata proof,
        ExtData calldata extData,
        bytes calldata recipientHints
    ) external override nonReentrant notPaused returns (bool) {
        // 0. Validate inputs BEFORE any state changes or external calls
        _validateTransactionInputs(proof, extData);

        // 1. Verify proof (includes nullifier checks AFTER proof verification)
        LibVerifier.verifyProof(proof, extData);

        // 2. Mark nullifiers as spent
        LibVerifier.markNullifiersSpent(proof.nullifiers);

        // Emit nullifier events
        for (uint256 i = 0; i < proof.nullifiers.length; i++) {
            emit NewNullifier(proof.nullifiers[i]);
        }

        // 3. Execute external actions (including token intake for extIn)
        LibBAMM.executeActions(extData, msg.sender);

        // 4. Insert output commitments
        for (uint256 i = 0; i < proof.outCommitments.length; i++) {
            uint32 leafIndex = LibMerkleTree.insertLeaf(proof.outCommitments[i]);

            // Extract recipient hint for this output
            bytes memory hint;
            if (recipientHints.length >= (i + 1) * 32) {
                hint = recipientHints[i * 32:(i + 1) * 32];
            }

            emit NewCommitment(proof.outCommitments[i], leafIndex, hint);
        }

        // 5. Emit transaction event
        emit Transact(proof.nullifiers, proof.outCommitments, proof.extDataHash);
        emit NewRoot(currentRoot(), LibStorage.getDarkPoolStorage().nextLeafIndex - 1);

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
        if (extData.actionType == LibStorage.ACTION_TRANSFER) {
            // Transfer can have multiple receivers (one per asset)
            if (extData.receivers.length > extData.assets.length) {
                revert Errors.ArrayLengthMismatch();
            }
        } else if (extData.actionType == LibStorage.ACTION_SWAP) {
            // Swap requires exactly 2 assets (tokenIn, tokenOut)
            if (extData.assets.length != 2) {
                revert Errors.InvalidParameter();
            }
            // Swap can have 0 or 1 receiver
            if (extData.receivers.length > 1) {
                revert Errors.ArrayLengthMismatch();
            }
        } else if (extData.actionType == LibStorage.ACTION_LP_DEPOSIT || extData.actionType == LibStorage.ACTION_LP_WITHDRAW) {
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
        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();
        $.paused = _paused;
        emit Paused(_paused);
    }

    /// @inheritdoc IDarkPool
    function setRequireASP(bool _requireASP) external override onlyOwner {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();
        $.requireASP = _requireASP;
        emit RequireASPSet(_requireASP);
    }

    /// @inheritdoc IDarkPool
    function setASPRootApproved(bytes32 aspRoot, bool approved) external override onlyOwner {
        if (aspRoot == bytes32(0)) revert Errors.ZeroAddress();

        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();

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

        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();
        $.aspRootExpiry[aspRoot] = expiryTimestamp;

        emit ASPRootApproved(aspRoot, true);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @inheritdoc IDarkPool
    function currentRoot() public view override returns (bytes32) {
        return LibStorage.getDarkPoolStorage().currentRoot;
    }

    /// @inheritdoc IDarkPool
    function isSpent(bytes32 nullifier) external view override returns (bool) {
        return LibStorage.getDarkPoolStorage().nullifierSpent[nullifier];
    }

    /// @inheritdoc IDarkPool
    function isKnownRoot(bytes32 root) external view override returns (bool) {
        return LibStorage.isKnownRoot(root);
    }

    /// @inheritdoc IDarkPool
    function getBammPool() external view override returns (address) {
        return LibStorage.getDarkPoolStorage().bammPool;
    }

    /// @inheritdoc IDarkPool
    function getVerifier() external view override returns (address) {
        return LibStorage.getDarkPoolStorage().verifier;
    }

    /// @inheritdoc IDarkPool
    function getOwner() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc IDarkPool
    function isPaused() external view override returns (bool) {
        return LibStorage.getDarkPoolStorage().paused;
    }

    /// @inheritdoc IDarkPool
    function isASPRequired() external view override returns (bool) {
        return LibStorage.getDarkPoolStorage().requireASP;
    }

    /// @inheritdoc IDarkPool
    function isASPRootApproved(bytes32 aspRoot) external view override returns (bool) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getDarkPoolStorage();
        uint256 expiry = $.aspRootExpiry[aspRoot];
        return expiry > 0 && expiry >= block.timestamp;
    }

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
        if (msg.sender != LibStorage.getDarkPoolStorage().bammPool) {
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
        if (msg.sender != LibStorage.getDarkPoolStorage().bammPool) {
            revert Errors.Unauthorized();
        }
        return this.onERC1155BatchReceived.selector;
    }
}
