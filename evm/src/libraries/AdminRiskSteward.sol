// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "../interfaces/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {AdminTimelock as ATL} from "./AdminTimelock.sol";

/// @title AdminRiskSteward — Steward-lite fences for setAssetParamsBounded (EIP-170 relief).
/// @notice Hard min/max + single relative `maxDeltaBps` on risk-increasing changes.
///         Tighten (more defensive) is exempt from the relative clamp. No per-param matrix,
///         no EIP-712 injector, no param-write circuit breaker.
library AdminRiskSteward {
    function setFences(
        mapping(address => mapping(address => IAdmin.RiskFences)) storage fences,
        address pool,
        address token,
        IAdmin.RiskFences calldata f
    ) external {
        if (pool == address(0) || token == address(0)) revert Err.ZeroAddr();
        if (f.maxDeltaBps == 0 || f.maxDeltaBps > 10_000) revert Err.BadConfig();
        if (f.minFeeHardMin == 0 || f.minFeeHardMin > f.minFeeHardMax) revert Err.BadConfig();
        if (f.maxFeeHardMax < f.minFeeHardMax) revert Err.BadConfig();
        if (f.gammaHardMin > f.gammaHardMax) revert Err.BadConfig();
        if (f.vegaHardMin > f.vegaHardMax) revert Err.BadConfig();
        fences[pool][token] = f;
        emit IAdmin.RiskFencesSet(pool, token, f.maxDeltaBps);
    }

    /// @dev Validate then forward to the same untimelocked Pool write path as owner setAssetParams.
    function setAssetParamsBounded(
        mapping(address => mapping(address => IAdmin.RiskFences)) storage fences,
        address pool,
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 haircutSuppressor,
        uint64 reservationPrice,
        uint64 reservationPriceMax
    ) external {
        IAdmin.RiskFences memory f = fences[pool][token];
        if (f.maxDeltaBps == 0) revert Err.NotConfigured(Err.Resource.ASSET, token);

        IPool.Asset memory cur = IPool(pool).getAsset(token);
        _enforceHard(f, minFeeBps, maxFeeBps, gamma, vega, haircutSuppressor);

        bool tighten = minFeeBps >= cur.minFeeBps
            && maxFeeBps <= cur.maxFeeBps
            && gamma >= cur.gamma
            && vega >= cur.vega
            && haircutSuppressor <= cur.haircutSuppressor
            && !_widensReservation(cur.reservationPrice, cur.reservationPriceMax, reservationPrice, reservationPriceMax);

        if (!tighten) {
            _relOk(cur.minFeeBps, minFeeBps, f.maxDeltaBps);
            _relOk(cur.maxFeeBps, maxFeeBps, f.maxDeltaBps);
            _relOk(cur.gamma, gamma, f.maxDeltaBps);
            _relOk(cur.vega, vega, f.maxDeltaBps);
            _relOk(cur.haircutSuppressor, haircutSuppressor, f.maxDeltaBps);
        }

        ATL.setAssetParams(
            pool,
            token,
            minLiquidity,
            minFeeBps,
            maxFeeBps,
            gamma,
            vega,
            haircutSuppressor,
            reservationPrice,
            reservationPriceMax
        );
        emit IAdmin.AssetParamsBoundedSet(pool, token, minFeeBps, gamma, tighten);
    }

    function _enforceHard(
        IAdmin.RiskFences memory f,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 haircutSuppressor
    ) private pure {
        if (minFeeBps < f.minFeeHardMin || minFeeBps > f.minFeeHardMax) {
            revert Err.ThresholdViolation(minFeeBps, f.minFeeHardMax);
        }
        if (maxFeeBps > f.maxFeeHardMax) revert Err.ThresholdViolation(maxFeeBps, f.maxFeeHardMax);
        if (gamma < f.gammaHardMin || gamma > f.gammaHardMax) {
            revert Err.ThresholdViolation(gamma, f.gammaHardMax);
        }
        if (vega < f.vegaHardMin || vega > f.vegaHardMax) {
            revert Err.ThresholdViolation(vega, f.vegaHardMax);
        }
        if (haircutSuppressor > f.haircutHardMax) {
            revert Err.ThresholdViolation(haircutSuppressor, f.haircutHardMax);
        }
    }

    /// @dev Wider depeg band = risk-up (more room before halt). 0 stays "disabled".
    function _widensReservation(uint64 oldLo, uint64 oldHi, uint64 newLo, uint64 newHi)
        private
        pure
        returns (bool)
    {
        if (oldLo == 0 && oldHi == 0) return false;
        if (newLo == 0 && newHi == 0) return false;
        if (oldLo != 0 && newLo != 0 && newLo < oldLo) return true;
        if (oldHi != 0 && newHi != 0 && newHi > oldHi) return true;
        return false;
    }

    function _relOk(uint256 oldV, uint256 newV, uint16 maxDeltaBps) private pure {
        if (newV == oldV) return;
        if (oldV == 0) revert Err.BadConfig();
        uint256 diff = newV > oldV ? newV - oldV : oldV - newV;
        if (diff * 10_000 > oldV * uint256(maxDeltaBps)) {
            revert Err.ThresholdViolation(diff, (oldV * maxDeltaBps) / 10_000);
        }
    }
}
