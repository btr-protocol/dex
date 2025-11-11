// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDarkPool
/// @notice Interface for DarkPool privacy layer
interface IDarkPool {
    // ========== STRUCTS ==========

    /// @notice Groth16 proof with public inputs
    struct Proof {
        uint256[8] groth16Proof;     // Groth16 proof data (a, b, c points)
        bytes32 merkleRoot;          // Root to prove inclusion against
        bytes32[] nullifiers;        // Nullifiers for input notes
        bytes32 extDataHash;         // Hash binding external actions
        bytes32[] outCommitments;    // Output note commitments
    }

    /// @notice External action parameters
    struct ExtData {
        uint8 actionType;            // TRANSFER | SWAP | LP_DEPOSIT | LP_WITHDRAW
        address[] assets;            // Tokens involved
        uint256[] extIn;             // External inputs per asset
        uint256[] extOut;            // External outputs per asset
        address[] receivers;         // External payout addresses
        bytes32 memoHash;            // Optional metadata hash
        bytes32 aspRoot;             // Association set root (if requireASP enabled)
    }

    // ========== EVENTS ==========

    event Deposit(address indexed asset, uint256 amount, bytes32 indexed commitment);
    event Transact(bytes32[] nullifiers, bytes32[] outCommitments, bytes32 extDataHash);
    event NewCommitment(bytes32 indexed commitment, uint32 leafIndex, bytes recipientHint);
    event NewNullifier(bytes32 indexed nullifier);
    event NewRoot(bytes32 indexed root, uint32 leafIndex);
    event Paused(bool paused);
    event RequireASPSet(bool requireASP);
    event ASPRootApproved(bytes32 indexed aspRoot, bool approved);

    // ========== INITIALIZATION ==========

    /// @notice Initialize the DarkPool proxy
    /// @param _bammPool The BAMM pool this DarkPool serves
    /// @param _verifier Groth16 verifier contract
    /// @param _admin Admin address for emergency controls
    function initialize(address _bammPool, address _verifier, address _admin) external;

    // ========== DEPOSIT FUNCTIONS ==========

    /// @notice Deposit token and create shielded note
    /// @param token Token to deposit
    /// @param amount Amount to deposit
    /// @param commitment Commitment to shield
    /// @param recipientHint Encrypted hint for recipient discovery
    function depositToken(
        address token,
        uint256 amount,
        bytes32 commitment,
        bytes calldata recipientHint
    ) external;

    /// @notice Deposit token to BAMM and create shielded LP note
    /// @param token Underlying token
    /// @param amount Token amount to deposit
    /// @param commitment Commitment to shield LP note
    /// @param recipientHint Encrypted hint for recipient discovery
    function depositAndMintLP(
        address token,
        uint256 amount,
        bytes32 commitment,
        bytes calldata recipientHint
    ) external;

    // ========== PRIVATE TRANSACT ==========

    /// @notice Execute private transaction with ZK proof
    /// @param proof ZK proof with public inputs
    /// @param extData External action parameters
    /// @param recipientHints Encrypted hints for output notes
    /// @return success True if transaction succeeded
    function transact(
        Proof calldata proof,
        ExtData calldata extData,
        bytes calldata recipientHints
    ) external returns (bool success);

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Pause/unpause the contract
    /// @param _paused New pause state
    function setPaused(bool _paused) external;

    /// @notice Enable/disable association set requirement
    /// @param _requireASP New ASP requirement state
    function setRequireASP(bool _requireASP) external;

    /// @notice Approve/revoke an association set root
    /// @param aspRoot ASP root to approve/revoke
    /// @param approved True to approve, false to revoke
    function setASPRootApproved(bytes32 aspRoot, bool approved) external;

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get the current merkle root
    /// @return root Current merkle root
    function currentRoot() external view returns (bytes32 root);

    /// @notice Check if a nullifier has been spent
    /// @param nullifier Nullifier to check
    /// @return spent True if nullifier is spent
    function isSpent(bytes32 nullifier) external view returns (bool spent);

    /// @notice Check if a root is in the history
    /// @param root Root to check
    /// @return known True if root is known
    function isKnownRoot(bytes32 root) external view returns (bool known);

    /// @notice Get the BAMM pool this DarkPool serves
    /// @return bamm BAMM pool address
    function getBammPool() external view returns (address bamm);

    /// @notice Get the verifier contract
    /// @return verifier Verifier address
    function getVerifier() external view returns (address verifier);

    /// @notice Get the admin address
    /// @return admin Admin address
    function getAdmin() external view returns (address admin);

    /// @notice Check if the contract is paused
    /// @return paused True if paused
    function isPaused() external view returns (bool paused);

    /// @notice Check if ASP is required
    /// @return required True if ASP is required
    function isASPRequired() external view returns (bool required);

    /// @notice Check if an ASP root is approved
    /// @param aspRoot ASP root to check
    /// @return approved True if approved
    function isASPRootApproved(bytes32 aspRoot) external view returns (bool approved);
}
