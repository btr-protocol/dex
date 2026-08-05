// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "../interfaces/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title AdminTimelock
/// @notice Encode/decode helpers for Admin timelock payloads (isolates stack depth).
library AdminTimelock {
  struct AddAssetPayload {
    address token;
    IPool.OracleConfig oracleCfg;
    IPool.RiskConfig riskCfg;
    uint16 presetId;
    uint16 minFeePbps;
    uint8 decimals;
    uint32 minDispersion;
    uint32 maxDispersion;
    uint16 gamma;
    uint16 vega;
  }

  struct AssetParamsPayload {
    address token;
    uint128 minLiquidity;
    uint16 minFeePbps;
    uint16 maxFeePbps;
    uint16 gamma;
    uint16 vega;
    uint16 haircutSuppressor;
    uint64 reservationPrice;
    uint64 reservationPriceMax;
  }

  /// @dev Two-blob encode keeps `abi.decode` off the via_ir stack-too-deep edge as IPool structs grow.
  function encodeAddAsset(AddAssetPayload memory p) internal pure returns (bytes memory) {
    bytes memory head = abi.encode(p.token, p.oracleCfg, p.riskCfg, p.presetId);
    bytes memory tail =
      abi.encode(p.minFeePbps, p.decimals, p.minDispersion, p.maxDispersion, p.gamma, p.vega);
    return abi.encode(head, tail);
  }

  function decodeAddAsset(bytes memory raw) internal pure returns (AddAssetPayload memory p) {
    bytes memory head;
    bytes memory tail;
    (head, tail) = abi.decode(raw, (bytes, bytes));
    (p.token, p.oracleCfg, p.riskCfg, p.presetId) =
      abi.decode(head, (address, IPool.OracleConfig, IPool.RiskConfig, uint16));
    (p.minFeePbps, p.decimals, p.minDispersion, p.maxDispersion, p.gamma, p.vega) =
      abi.decode(tail, (uint16, uint8, uint32, uint32, uint16, uint16));
  }

  /// @dev External entry gets a fresh stack frame (avoids stack-too-deep on the pool call).
  function applyAddAsset(address pool, address token, bytes memory raw)
    external
    returns (uint8 decimals)
  {
    AddAssetPayload memory p = decodeAddAsset(raw);
    if (p.token != token) revert Err.InvalidInput();
    IPool(pool)
      .adminInitAsset(
        p.token,
        p.oracleCfg,
        p.riskCfg,
        p.presetId,
        p.minFeePbps,
        p.decimals,
        p.minDispersion,
        p.maxDispersion,
        p.gamma,
        p.vega
      );
    return p.decimals;
  }

  /// @dev Bootstrap listing (untimelocked). Fail-closed if `bootstrapSealed[pool]`.
  function addAssetBootstrap(
    mapping(address => bool) storage bootstrapSealed,
    address pool,
    address token,
    IPool.OracleConfig calldata oracleCfg,
    IPool.RiskConfig calldata riskCfg,
    uint16 presetId,
    uint16 minFeePbps,
    uint8 decimals,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) external {
    if (bootstrapSealed[pool]) revert Err.InvalidState();
    IPool(pool)
      .adminInitAsset(
        token,
        oracleCfg,
        riskCfg,
        presetId,
        minFeePbps,
        decimals,
        minDispersion,
        maxDispersion,
        gamma,
        vega
      );
    emit IAdmin.AssetAdded(pool, token, decimals, 0);
  }

  function encodeAssetParams(
    address token,
    uint128 minLiquidity,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) internal pure returns (bytes memory) {
    return abi.encode(
      token,
      minLiquidity,
      minFeePbps,
      maxFeePbps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );
  }

  function decodeAssetParams(bytes memory raw) internal pure returns (AssetParamsPayload memory p) {
    (p.token, p.minLiquidity, p.minFeePbps, p.maxFeePbps, p.gamma, p.vega, p.haircutSuppressor, p.reservationPrice, p.reservationPriceMax) =
      abi.decode(
        raw,
        (address, uint128, uint16, uint16, uint16, uint16, uint16, uint64, uint64)
      );
  }

  function setAssetParams(
    address pool,
    address token,
    uint128 minLiquidity,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) external {
    _writeAssetParams(
      pool,
      token,
      minLiquidity,
      minFeePbps,
      maxFeePbps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );
  }

  function applyAssetParams(address pool, address token, bytes memory raw) external {
    AssetParamsPayload memory p = decodeAssetParams(raw);
    if (p.token != token) revert Err.InvalidInput();
    _writeAssetParams(
      pool,
      token,
      p.minLiquidity,
      p.minFeePbps,
      p.maxFeePbps,
      p.gamma,
      p.vega,
      p.haircutSuppressor,
      p.reservationPrice,
      p.reservationPriceMax
    );
  }

  /// @dev GOV-ECO-01: defensive tighten exempts owner `setAssetParams` from LOW_TIMELOCK once bootstrap
  ///      is sealed. Mirrors AdminRiskSteward paramTighten + _narrowsReservation (no relative clamp).
  function isDefensiveTighten(
    IPool.Asset memory cur,
    uint128 minLiquidity,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) external pure returns (bool) {
    if (minLiquidity < cur.minLiquidity) return false;
    if (minFeePbps < cur.minFeePbps) return false;
    if (maxFeePbps < cur.maxFeePbps) return false;
    if (gamma < cur.gamma) return false;
    if (vega < cur.vega) return false;
    if (haircutSuppressor > cur.haircutSuppressor) return false;
    return _narrowsReservation(
      cur.reservationPrice, cur.reservationPriceMax, reservationPrice, reservationPriceMax
    );
  }

  function _writeAssetParams(
    address pool,
    address token,
    uint128 minLiquidity,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) internal {
    IPool(pool)
      .adminSetAssetParams(
        token,
        minLiquidity,
        minFeePbps,
        maxFeePbps,
        gamma,
        vega,
        haircutSuppressor,
        reservationPrice,
        reservationPriceMax
      );
    emit IAdmin.AssetParamsUpdated(pool, token, minLiquidity, reservationPrice);
  }

  /// @dev Narrower depeg band = defensive. Disabling an active band is risk-up.
  function _narrowsReservation(uint64 oldLo, uint64 oldHi, uint64 newLo, uint64 newHi)
    private
    pure
    returns (bool)
  {
    if (oldLo == 0 && oldHi == 0) return newLo == 0 && newHi == 0;
    if (newLo == 0 && newHi == 0) return false;
    if (oldLo != 0 && newLo == 0) return false;
    if (oldHi != 0 && newHi == 0) return false;
    if (oldLo != 0 && newLo != 0 && newLo < oldLo) return false;
    if (oldHi != 0 && newHi != 0 && newHi > oldHi) return false;
    return true;
  }
}
