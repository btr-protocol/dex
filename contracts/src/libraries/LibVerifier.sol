// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDarkPool} from "../interfaces/IDarkPool.sol";
import {LibDarkPoolStorage as LibStorage} from "./LibDarkPoolStorage.sol";
import {DarkPoolErrors as Errors} from "../darkpool/DarkPoolErrors.sol";
import {Poseidon} from "./generated/Poseidon.sol";

/// @title LibVerifier
/// @notice Groth16 proof verification helpers
library LibVerifier {
    // ========== VERIFICATION ==========

    /// @notice Verify a Groth16 proof
    /// @param proof Proof struct with public inputs
    /// @param extData External data to verify hash
    /// @return True if proof is valid
    function verifyProof(
        IDarkPool.Proof calldata proof,
        IDarkPool.ExtData calldata extData
    ) internal view returns (bool) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();

        // 1. Validate array lengths match circuit expectations
        uint256 maxAssets = 4;
        if (extData.extIn.length > maxAssets || extData.extOut.length > maxAssets) {
            revert Errors.ArrayLengthMismatch();
        }

        // 2. Check root is known
        if (!LibStorage.isKnownRoot(proof.merkleRoot)) {
            revert Errors.RootNotFound();
        }

        // 3. Recompute and verify extDataHash using Poseidon (matching circuit)
        bytes32 computedHash = _computeExtDataHash(extData);
        if (computedHash != proof.extDataHash) {
            revert Errors.ExtDataHashMismatch();
        }

        // 4. Check ASP if required (must be done BEFORE verifier call for correct binding)
        if ($.requireASP) {
            if (extData.aspRoot == bytes32(0)) {
                revert Errors.ASPRootZero();
            }
            // Check if ASP root is approved and not expired
            uint256 expiry = $.aspRootExpiry[extData.aspRoot];
            if (expiry == 0 || expiry < block.timestamp) {
                revert Errors.ASPNotApproved(extData.aspRoot);
            }
        }

        // 5. Call Groth16 verifier FIRST (before state changes)
        bool success = _callVerifier(proof, extData.aspRoot);
        if (!success) {
            revert Errors.InvalidProof();
        }

        // 6. Check nullifiers not spent (AFTER proof verification to prevent info leak)
        for (uint256 i = 0; i < proof.nullifiers.length; i++) {
            if ($.nullifierSpent[proof.nullifiers[i]]) {
                revert Errors.NullifierAlreadySpent(proof.nullifiers[i]);
            }
        }

        return true;
    }

    /// @notice Compute extDataHash using Poseidon to match circuit computation
    /// @param extData External data
    /// @return hash Poseidon hash of extData
    /// @dev Circuit computes: Poseidon(extIn[0..3], extOut[0..3], aspRoot)
    /// @dev Arrays must be padded to 4 elements with zeros
    function _computeExtDataHash(IDarkPool.ExtData calldata extData) private pure returns (bytes32) {
        // Pad extIn to 4 elements
        uint256 extIn0 = extData.extIn.length > 0 ? extData.extIn[0] : 0;
        uint256 extIn1 = extData.extIn.length > 1 ? extData.extIn[1] : 0;
        uint256 extIn2 = extData.extIn.length > 2 ? extData.extIn[2] : 0;
        uint256 extIn3 = extData.extIn.length > 3 ? extData.extIn[3] : 0;

        // Pad extOut to 4 elements
        uint256 extOut0 = extData.extOut.length > 0 ? extData.extOut[0] : 0;
        uint256 extOut1 = extData.extOut.length > 1 ? extData.extOut[1] : 0;
        uint256 extOut2 = extData.extOut.length > 2 ? extData.extOut[2] : 0;
        uint256 extOut3 = extData.extOut.length > 3 ? extData.extOut[3] : 0;

        // Compute Poseidon hash
        uint256 hash = Poseidon.hash9(
            extIn0, extIn1, extIn2, extIn3,
            extOut0, extOut1, extOut2, extOut3,
            uint256(extData.aspRoot)
        );

        return bytes32(hash);
    }

    /// @notice Call the Groth16 verifier contract
    /// @param proof Proof struct
    /// @param aspRoot Association set root (or 0)
    /// @return True if proof is valid
    function _callVerifier(
        IDarkPool.Proof calldata proof,
        bytes32 aspRoot
    ) private view returns (bool) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();

        // Pack public inputs
        // Order: [merkleRoot, nullifier[0], nullifier[1], ..., extDataHash, aspRoot]
        uint256 publicInputCount = 2 + proof.nullifiers.length + 1; // root + nullifiers + extDataHash + aspRoot
        uint256[] memory publicInputs = new uint256[](publicInputCount);

        publicInputs[0] = uint256(proof.merkleRoot);

        for (uint256 i = 0; i < proof.nullifiers.length; i++) {
            publicInputs[1 + i] = uint256(proof.nullifiers[i]);
        }

        publicInputs[1 + proof.nullifiers.length] = uint256(proof.extDataHash);
        publicInputs[2 + proof.nullifiers.length] = uint256(aspRoot);

        // Call verifier
        // The verifier contract implements: function verify(uint256[8] proof, uint256[] publicInputs) returns (bool)
        (bool success, bytes memory result) = $.verifier.staticcall(
            abi.encodeWithSignature(
                "verifyProof(uint256[8],uint256[])",
                proof.groth16Proof,
                publicInputs
            )
        );

        if (!success) return false;

        return abi.decode(result, (bool));
    }

    /// @notice Mark nullifiers as spent
    /// @param nullifiers Array of nullifiers to mark
    function markNullifiersSpent(bytes32[] calldata nullifiers) internal {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();

        for (uint256 i = 0; i < nullifiers.length; i++) {
            $.nullifierSpent[nullifiers[i]] = true;
        }
    }
}
