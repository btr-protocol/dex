// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// NB: Currently unused since dependency of unreleased darkpools.
// Uncomment and restore poseidon2-evm dependency if needed for zk-proof hashing.
//
// import {Poseidon2Lib} from "poseidon2-evm/Poseidon2Lib.sol";
// import {Field} from "poseidon2-evm/Field.sol";
//
// /// @title Poseidon
// /// @notice Minimal Poseidon2 wrapper for hash operations
// /// @dev YUL-optimized implementation from zemse/poseidon2-evm
// library LibPoseidon {
//     using Field for Field.Type;
//
//     function hash2(uint256 x, uint256 y) internal pure returns (uint256) {
//         return Poseidon2Lib.hash_2(Field.Type.wrap(x), Field.Type.wrap(y)).toUint256();
//     }
//
//     function hash4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256) {
//         Field.Type[] memory input = new Field.Type[](4);
//         input[0] = Field.Type.wrap(a);
//         input[1] = Field.Type.wrap(b);
//         input[2] = Field.Type.wrap(c);
//         input[3] = Field.Type.wrap(d);
//         return Poseidon2Lib.hash(input, 4, false).toUint256();
//     }
//
//     function hash8(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g, uint256 h) internal pure returns (uint256) {
//         Field.Type[] memory input = new Field.Type[](8);
//         input[0] = Field.Type.wrap(a);
//         input[1] = Field.Type.wrap(b);
//         input[2] = Field.Type.wrap(c);
//         input[3] = Field.Type.wrap(d);
//         input[4] = Field.Type.wrap(e);
//         input[5] = Field.Type.wrap(f);
//         input[6] = Field.Type.wrap(g);
//         input[7] = Field.Type.wrap(h);
//         return Poseidon2Lib.hash(input, 8, false).toUint256();
//     }
// }
