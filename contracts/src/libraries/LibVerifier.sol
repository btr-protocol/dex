// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDarkPool} from "../interfaces/IDarkPool.sol";
import {IDarkPoolStorage} from "../interfaces/IDarkPoolStorage.sol";
import {LibStorage as S} from "./LibStorage.sol";
import {DarkPoolErrors as Errors} from "../darkpool/DarkPoolErrors.sol";
import {Poseidon} from "./Poseidon.sol";

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
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();

        // 1. Validate array lengths match circuit expectations
        uint256 maxAssets = 4;
        if (extData.extIn.length > maxAssets || extData.extOut.length > maxAssets) {
            revert Errors.ArrayLengthMismatch();
        }

        // 2. Check root is known
        if (!S.isKnownRoot(proof.merkleRoot)) {
            revert Errors.RootNotFound();
        }

        // 3. Recompute and verify extDataHash using Poseidon (matching circuit)
        bytes32 computedHash = _computeExtDataHash(extData);
        if (computedHash != proof.extDataHash) {
            revert Errors.ExtDataHashMismatch();
        }

        // 4. Check ASP if required (must be done BEFORE verifier call for correct binding)
        if (S._requiresASP($)) {
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
        // Query ShieldedState for nullifier status
        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) revert Errors.ZeroAddress();

        for (uint256 i = 0; i < proof.nullifiers.length; i++) {
            bytes32 nullifier = proof.nullifiers[i];
            (bool callSuccess, bytes memory result) = shieldedStateAddr.staticcall(
                abi.encodeWithSignature("nullifierSpent(bytes32)", nullifier)
            );

            if (!callSuccess || abi.decode(result, (bool))) {
                revert Errors.NullifierAlreadySpent(nullifier);
            }
        }

        return true;
    }

    /// @notice Compute extDataHash using two-layer Poseidon2
    function _computeExtDataHash(IDarkPool.ExtData calldata extData) private pure returns (bytes32) {
        uint256 asset0 = extData.assets.length > 0 ? uint256(uint160(extData.assets[0])) : 0;
        uint256 asset1 = extData.assets.length > 1 ? uint256(uint160(extData.assets[1])) : 0;
        uint256 asset2 = extData.assets.length > 2 ? uint256(uint160(extData.assets[2])) : 0;
        uint256 asset3 = extData.assets.length > 3 ? uint256(uint160(extData.assets[3])) : 0;

        uint256 recv0 = extData.receivers.length > 0 ? uint256(uint160(extData.receivers[0])) : 0;
        uint256 recv1 = extData.receivers.length > 1 ? uint256(uint160(extData.receivers[1])) : 0;
        uint256 recv2 = extData.receivers.length > 2 ? uint256(uint160(extData.receivers[2])) : 0;
        uint256 recv3 = extData.receivers.length > 3 ? uint256(uint160(extData.receivers[3])) : 0;

        uint256 hAssetsReceivers = Poseidon.hash8(asset0, asset1, asset2, asset3, recv0, recv1, recv2, recv3);

        uint256 extIn0 = extData.extIn.length > 0 ? extData.extIn[0] : 0;
        uint256 extIn1 = extData.extIn.length > 1 ? extData.extIn[1] : 0;
        uint256 extIn2 = extData.extIn.length > 2 ? extData.extIn[2] : 0;
        uint256 extIn3 = extData.extIn.length > 3 ? extData.extIn[3] : 0;

        uint256 extOut0 = extData.extOut.length > 0 ? extData.extOut[0] : 0;
        uint256 extOut1 = extData.extOut.length > 1 ? extData.extOut[1] : 0;
        uint256 extOut2 = extData.extOut.length > 2 ? extData.extOut[2] : 0;
        uint256 extOut3 = extData.extOut.length > 3 ? extData.extOut[3] : 0;

        uint256 hAmounts = Poseidon.hash8(extIn0, extIn1, extIn2, extIn3, extOut0, extOut1, extOut2, extOut3);

        uint256 hash = Poseidon.hash4(uint256(extData.actionType), uint256(extData.aspRoot), hAssetsReceivers, hAmounts);
        return bytes32(hash);
    }

    /// @notice Call the Groth16 verifier contract
    /// @param proof Proof struct with public inputs
    /// @param aspRoot Not used anymore (kept for compatibility, aspRoot is now in extDataHash)
    /// @return True if proof is valid
    function _callVerifier(
        IDarkPool.Proof calldata proof,
        bytes32 aspRoot
    ) private view returns (bool) {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();

        // Pack public inputs (minimal set, matching circuit)
        // Order: [merkleRoot, nullifier[0], nullifier[1], ..., extDataHash]
        // Note: aspRoot is now folded into extDataHash for stronger binding
        uint256 publicInputCount = 1 + proof.nullifiers.length + 1; // root + nullifiers + extDataHash
        uint256[] memory publicInputs = new uint256[](publicInputCount);

        publicInputs[0] = uint256(proof.merkleRoot);

        for (uint256 i = 0; i < proof.nullifiers.length; i++) {
            publicInputs[1 + i] = uint256(proof.nullifiers[i]);
        }

        publicInputs[1 + proof.nullifiers.length] = uint256(proof.extDataHash);

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

    /// @notice Mark nullifiers as spent in global ShieldedState
    /// @param nullifiers Array of nullifiers to mark
    function markNullifiersSpent(bytes32[] calldata nullifiers) internal {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) revert Errors.ZeroAddress();

        // Call ShieldedState to mark all nullifiers as spent
        (bool success, ) = shieldedStateAddr.call(
            abi.encodeWithSignature("spendNullifiers(bytes32[])", nullifiers)
        );

        if (!success) revert Errors.NullifierSpendingFailed();
    }
}
