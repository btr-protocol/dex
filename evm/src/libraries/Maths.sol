// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {B64} from "@btr-shared/libs/B64.sol";

/// @title Maths -B64 (52/5/7) float ops + helpers.
/// @dev Constants WAD/PBPS @ Constants. B64 layout: mantissa(52)|decimals(5)|exp+bias(7).
///      Core encode/decode/arithmetic delegated to shared B64 library.
library Maths {
  function encodeB64(uint256 x, uint8 decimals) internal pure returns (uint64 packed) {
    return B64.encodeB64(x, decimals);
  }

  function decodeB64(uint64 packed, uint8 tarb64Decimals) internal pure returns (uint256 x) {
    return B64.decodeB64(packed, tarb64Decimals);
  }

  function b64To1e18(uint64 packed) internal pure returns (uint256) {
    return B64.decodeB64(packed, 18);
  }
}
