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

  function b64Decimals(uint64 packed) internal pure returns (uint8 decimals) {
    return B64.b64Decimals(packed);
  }

  function add64(uint64 a, uint64 b) internal pure returns (uint64 c) {
    return B64.add64(a, b);
  }

  function gt64(uint64 a, uint64 b) internal pure returns (bool result) {
    return B64.gt64(a, b);
  }

  /// @notice |b - a| / a in 1e6 (1_000_000 = 1%). 10% on zero/invalid input.
  function diff1e6(uint64 a64, uint64 b64) internal pure returns (uint32) {
    if (a64 == 0 || b64 == 0) return 10_000_000;
    unchecked {
      (uint256 a, uint256 b) = (b64To1e18(a64), b64To1e18(b64));
      if (a == 0) return 10_000_000;
      uint256 diff = a > b ? a - b : b - a;
      uint256 vol = (diff * 1_000_000) / a;
      return vol > type(uint32).max ? type(uint32).max : uint32(vol);
    }
  }
}
