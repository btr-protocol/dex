// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

library CdpConstants {
  uint16 internal constant STABLE_CORE_CANONICAL_LTV_BPS = 8500;
  uint16 internal constant STABLE_CORE_CANONICAL_LT_BPS = 9000;
  uint16 internal constant STABLE_CORE_CANONICAL_BONUS_BPS = 300;

  uint16 internal constant DEFAULT_HL_BPS = 200;
  uint16 internal constant DEFAULT_HO_BPS = 100;

  uint16 internal constant CLOSE_FACTOR_PARTIAL_BPS = 5000;
  uint256 internal constant HF_FULL_LIQ_THRESHOLD_WAD = 0.95e18;

  uint16 internal constant BACKSTOP_BONUS_SHARE_BPS = 2000;
  uint256 internal constant DUST_DEBT = 1e15;
  uint8 internal constant DEBT_DECIMALS = 18;

  uint16 internal constant TIER_S_BPS = 500;
  uint16 internal constant TIER_M_BPS = 200;
}
