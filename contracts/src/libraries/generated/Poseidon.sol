// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoseidonT2} from "./PoseidonT2.sol";
import {PoseidonT3} from "./PoseidonT3.sol";
import {PoseidonT4} from "./PoseidonT4.sol";
import {PoseidonT5} from "./PoseidonT5.sol";
import {PoseidonT6} from "./PoseidonT6.sol";

/**
 * @title Poseidon
 * @notice Main library for Poseidon hash operations
 * @dev Wraps poseidon-solidity implementations (complete T2-T6 stack)
 * @dev DarkPool currently uses: T3 (merkle tree) and T5 (nullifier)
 * @dev Additional variants provided for future extensibility
 * @author Generated from poseidon-solidity package
 */
library Poseidon {
    /**
     * @notice Hash 1 input
     * @dev Uses PoseidonT2 (t=2 means 1 input + 1 capacity element)
     * @param input Input value
     * @return Hash output
     */
    function hash1(uint256 input) internal pure returns (uint256) {
        uint256[1] memory inputs = [input];
        return PoseidonT2.hash(inputs);
    }

    /**
     * @notice Hash 2 inputs (binary merkle tree)
     * @dev Uses PoseidonT3 (t=3 means 2 inputs + 1 capacity element)
     * @param left Left input
     * @param right Right input
     * @return Hash output
     */
    function hash2(uint256 left, uint256 right) internal pure returns (uint256) {
        uint256[2] memory inputs = [left, right];
        return PoseidonT3.hash(inputs);
    }

    /**
     * @notice Hash 3 inputs
     * @dev Uses PoseidonT4 (t=4 means 3 inputs + 1 capacity element)
     * @param a First input
     * @param b Second input
     * @param c Third input
     * @return Hash output
     */
    function hash3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256[3] memory inputs = [a, b, c];
        return PoseidonT4.hash(inputs);
    }

    /**
     * @notice Hash 4 inputs (nullifier computation)
     * @dev Uses PoseidonT5 (t=5 means 4 inputs + 1 capacity element)
     * @dev Used for: Poseidon(chainId, darkPool, nullifierSecret, ownerKey)
     * @param a First input
     * @param b Second input
     * @param c Third input
     * @param d Fourth input
     * @return Hash output
     */
    function hash4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256) {
        uint256[4] memory inputs = [a, b, c, d];
        return PoseidonT5.hash(inputs);
    }

    /**
     * @notice Hash 5 inputs
     * @dev Uses PoseidonT6 (t=6 means 5 inputs + 1 capacity element)
     * @param a First input
     * @param b Second input
     * @param c Third input
     * @param d Fourth input
     * @param e Fifth input
     * @return Hash output
     */
    function hash5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256) {
        uint256[5] memory inputs = [a, b, c, d, e];
        return PoseidonT6.hash(inputs);
    }

    /**
     * @notice Hash 8 inputs (commitment) - using nested approach
     * @dev Commitment = Poseidon(chainId, darkPool, assetId, noteType, value, ownerKey, blinding, salt)
     * @dev Implementation: hash2(hash4(a,b,c,d), hash4(e,f,g,h))
     * @dev This nested approach uses only T3 and T5 variants
     * @param a First input (chainId)
     * @param b Second input (darkPool)
     * @param c Third input (assetId)
     * @param d Fourth input (noteType)
     * @param e Fifth input (value)
     * @param f Sixth input (ownerKey)
     * @param g Seventh input (blinding)
     * @param h Eighth input (salt)
     * @return Hash output
     */
    function hash8(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h
    ) internal pure returns (uint256) {
        // Split into two groups of 4, hash each, then hash results
        uint256 leftHash = hash4(a, b, c, d);
        uint256 rightHash = hash4(e, f, g, h);
        return hash2(leftHash, rightHash);
    }

    /**
     * @notice Hash 9 inputs (extDataHash) - using nested approach
     * @dev ExtDataHash = Poseidon(extIn[0..3], extOut[0..3], aspRoot)
     * @dev Implementation: hash3(hash4(extIn), hash4(extOut), aspRoot)
     * @param extIn0 ExtIn amount for asset 0
     * @param extIn1 ExtIn amount for asset 1
     * @param extIn2 ExtIn amount for asset 2
     * @param extIn3 ExtIn amount for asset 3
     * @param extOut0 ExtOut amount for asset 0
     * @param extOut1 ExtOut amount for asset 1
     * @param extOut2 ExtOut amount for asset 2
     * @param extOut3 ExtOut amount for asset 3
     * @param aspRoot Association set root
     * @return Hash output
     */
    function hash9(
        uint256 extIn0,
        uint256 extIn1,
        uint256 extIn2,
        uint256 extIn3,
        uint256 extOut0,
        uint256 extOut1,
        uint256 extOut2,
        uint256 extOut3,
        uint256 aspRoot
    ) internal pure returns (uint256) {
        // Hash extIn amounts
        uint256 extInHash = hash4(extIn0, extIn1, extIn2, extIn3);
        // Hash extOut amounts
        uint256 extOutHash = hash4(extOut0, extOut1, extOut2, extOut3);
        // Combine with aspRoot
        return hash3(extInHash, extOutHash, aspRoot);
    }
}
