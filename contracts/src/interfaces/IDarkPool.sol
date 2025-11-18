// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDarkPool
/// @notice Interface for DarkPool privacy layer
interface IDarkPool {
    // ========== STRUCTS ==========

    /// @notice Groth16 proof with public inputs
    /// @dev Circuit supports exactly 2 input notes → 2 nullifiers, 2 output notes
    struct Proof {
        uint256[8] groth16Proof;     // Groth16 proof data (a, b, c points)
        bytes32 merkleRoot;          // Root to prove inclusion against
        bytes32[] nullifiers;        // Nullifiers for input notes (dynamic array)
        bytes32 extDataHash;         // Hash binding external actions
        bytes32[] outCommitments;    // Output note commitments (dynamic array)
    }

    /// @notice External action parameters
    /// @dev extIn/extOut semantics depend on action type:
    ///      - TRANSFER: extIn = tokens entering privacy pool (pulled from sender)
    ///                  extOut = tokens exiting privacy pool (sent to receivers)
    ///      - SWAP: extOut[0] = amountIn (private → BAMM)
    ///              extIn[1] = minAmountOut (slippage protection)
    ///              If receiver not specified, swapped tokens remain in DarkPool for re-shielding
    ///      - LP_DEPOSIT: extOut[0] = token amount to deposit
    ///                    extIn[0] = minLpTokens (slippage protection)
    ///                    LP tokens are held by DarkPool; scaled shares encoded in output commitment
    ///      - LP_WITHDRAW: extIn[0] = scaledShares (from note)
    ///                     extOut[0] = minAmountOut (slippage protection)
    ///                     If receiver not specified, withdrawn tokens remain in DarkPool for re-shielding
    /// @dev Re-shielding: When receiver = address(0), tokens remain in DarkPool for subsequent
    ///      private transactions, maintaining privacy without exiting to public addresses
    struct ExtData {
        uint8 actionType;            // TRANSFER | SWAP | LP_DEPOSIT | LP_WITHDRAW
        address[] assets;            // Tokens involved
        uint256[] extIn;             // External inputs per asset (public→private or slippage params)
        uint256[] extOut;            // External outputs per asset (private→public or action amounts)
        address[] receivers;         // External payout addresses (address(0) = re-shield)
        bytes32 memoHash;            // Optional metadata hash
        bytes32 aspRoot;             // Association set root (if requireASP enabled)
    }

    // ========== EVENTS ==========

    // Privacy events
    event Deposit(address indexed asset, uint256 amount, bytes32 indexed commitment);
    event Transact(bytes32[] nullifiers, bytes32[] outCommitments, bytes32 extDataHash);
    event NewCommitment(bytes32 indexed commitment, uint32 leafIndex, bytes recipientHint);
    event NewNullifier(bytes32 indexed nullifier);
    event NewRoot(bytes32 indexed root, uint32 leafIndex);

    // Merkle tree events
    event LeafInserted(uint32 indexed leafIndex, bytes32 leaf, bytes32 newRoot);

    // LP events
    event LPDeposited(address indexed token, uint256 amountIn, uint256 lpTokensOut, uint128 liquidityIndex);
    event LPWithdrawn(address indexed token, uint256 lpTokensIn, uint256 amountOut, uint128 liquidityIndex);

    // Admin events
    event Paused(bool paused);
    event RequireASPSet(bool requireASP);
    event ASPRootApproved(bytes32 indexed aspRoot, bool approved);

    // ========== INITIALIZATION ==========

    /// @notice Initialize the DarkPool proxy
    /// @param _bammPool The BAMM pool this DarkPool serves
    /// @param _verifier Groth16 verifier contract
    /// @param _owner Owner address for emergency controls
    /// @param _shieldedState Global shielded state contract (shared Merkle tree and nullifier set)
    function initialize(address _bammPool, address _verifier, address _owner, address _shieldedState) external;

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
    ) external payable;

    /// @notice Deposit token to BAMM and create shielded LP note
    /// @param token Underlying token
    /// @param amount Token amount to deposit
    /// @param commitment Commitment to shield LP note
    /// @param recipientHint Encrypted hint for recipient discovery
    /// @param minLpTokens Minimum LP tokens to receive (slippage protection)
    function depositAndMintLP(
        address token,
        uint256 amount,
        bytes32 commitment,
        bytes calldata recipientHint,
        uint256 minLpTokens
    ) external payable;

    // ========== PRIVATE TRANSACT ==========

    /// @notice Execute private transaction with ZK proof
    /// @param proof ZK proof with public inputs
    /// @param extData External action parameters
    /// @param recipientHints Encrypted hints for output notes (one bytes32 per output commitment)
    /// @return success True if transaction succeeded
    function transact(
        Proof calldata proof,
        ExtData calldata extData,
        bytes32[] calldata recipientHints
    ) external returns (bool success);

    // ========== OWNER FUNCTIONS ==========

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

    /// @notice Get the owner address
    /// @return owner Owner address
    function getOwner() external view returns (address owner);

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
