// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {Admin} from "../src/Admin.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IPool} from "../src/interfaces/IPool.sol";

/// @title SeedRiskFences — one-shot owner seed of `Admin.riskFences` for the whole Sepolia fleet.
/// @notice DEPLOY GAP CLOSER. `setRiskFences` had never been called on Sepolia: every
///         `riskFences(pool,token)` returned the zero struct, so `maxDeltaBps == 0` made
///         `setAssetParamsBounded` fail closed (`AdminRiskSteward.sol:49`) and the risk keeper
///         rejected 76/76 decisions since deploy (`keepers/src/risk/fences.rs:68`).
///
/// Fences BRACKET the values measured live on 2026-07-29, they do not encode a wish:
///   gamma  = 20000 on all 32 legs -> [5000, 40000]
///   vega   = 10000 on all 32 legs -> [5000, 40000]
///   maxFee = 2000 (stable) / 10000 (volatile) / 5000 (fx) -> ceiling 20000
///   minFee = 50..496 stable-class, 400..2003 volatile-class -> two classes, see `_fences`
///   haircutSuppressor = 0 on the kappa-walled legs, 10000 elsewhere -> per-leg ceiling
///   reservationPrice / reservationPriceMax = 0 on every leg (band off) -> 0/0 fences, which
///   `setAssetParamsBounded` accepts precisely because the band is not live.
///
/// `maxDeltaBps = 2500` mirrors the +-25% asserted at `keepers/src/guards.rs:464`.
///
/// ⚠ `minFeeHardMin` floors the OWNER path too (`Admin.sol:252`), so it is deliberately set BELOW
/// each leg's live minFee: the five fx legs sit at 400 pbps against a 2*theta requirement of 1000,
/// and a fence at 1000 would re-brick the keeper on exactly the legs that must climb. The 2*theta
/// invariant is enforced by the keeper's H-2 startup gate + `risk/fences.rs` coupling gates, not here.
///
/// Env: `ADMIN` (Admin singleton). Broadcaster MUST be the AccessControl owner.
///   forge script script/SeedRiskFences.s.sol:SeedRiskFences --sig "preview()"  --rpc-url $RPC
///   forge script script/SeedRiskFences.s.sol:SeedRiskFences --sig "calldatas()" --rpc-url $RPC
///   forge script script/SeedRiskFences.s.sol:SeedRiskFences --sig "seed()" --rpc-url $RPC --broadcast
contract SeedRiskFences is Script {
  Admin internal admin = Admin(vm.envAddress("ADMIN"));

  uint16 internal constant MAX_DELTA_BPS = 2500;
  uint16 internal constant MAX_FEE_HARD_MAX = 20_000;
  uint16 internal constant GAMMA_MIN = 5_000;
  uint16 internal constant GAMMA_MAX = 40_000;
  uint16 internal constant VEGA_MIN = 5_000;
  uint16 internal constant VEGA_MAX = 40_000;
  // Stable class: live minFee 50..496. Volatile class: live minFee 400..2003.
  uint16 internal constant STABLE_MIN_FEE_LO = 25;
  uint16 internal constant STABLE_MIN_FEE_HI = 1_000;
  uint16 internal constant VOL_MIN_FEE_LO = 200;
  uint16 internal constant VOL_MIN_FEE_HI = 6_000;

  address internal constant STABLE_POOL = 0xA9207BE6f1D33828b98508C6c77f51cdeC4951eE;
  address internal constant VOLATILE_POOL = 0x1f997b7dCcE0A956e431A24D58622e32656C8537;
  address internal constant FX_POOL = 0x18c7376A4F9B3C3fb8A0A33fAf3c55aD225CB229;

  struct Leg {
    address pool;
    address token;
    string sym;
    /// Live minFee <= 1000 pbps. Selects the minFee fence window.
    bool stableClass;
    /// kappa-walled (live `haircutSuppressor == 0`). A walled leg MUST keep haircut 0
    /// (AIMM_PROOFS coverage-safety), so its ceiling is 0, not 10000.
    bool walled;
  }

  function _fences(Leg memory l) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = l.stableClass ? STABLE_MIN_FEE_LO : VOL_MIN_FEE_LO;
    f.minFeeHardMax = l.stableClass ? STABLE_MIN_FEE_HI : VOL_MIN_FEE_HI;
    f.maxFeeHardMax = MAX_FEE_HARD_MAX;
    f.gammaHardMin = GAMMA_MIN;
    f.gammaHardMax = GAMMA_MAX;
    f.vegaHardMin = VEGA_MIN;
    f.vegaHardMax = VEGA_MAX;
    f.haircutHardMax = l.walled ? 0 : 10_000;
    f.maxDeltaBps = MAX_DELTA_BPS;
    // Reservation band is off (0/0) on every live leg; `setAssetParamsBounded` only demands the
    // absolute fence when the matching band side is non-zero (AdminRiskSteward.sol:54).
    f.reservationHardLoMin = 0;
    f.reservationHardHiMax = 0;
  }

  function _legs() internal pure returns (Leg[] memory l) {
    l = new Leg[](32);
    uint256 i;
    // ── stable-core ──
    l[i++] = Leg(STABLE_POOL, 0x5AFaFEC0495e362976E1cA87D1Ce044AC49A39E9, "USDC", true, false);
    l[i++] = Leg(STABLE_POOL, 0xa7Dc0A8815acCbDfc22619b6F65b2dE710Eb2A7B, "USDT", true, true);
    l[i++] = Leg(STABLE_POOL, 0xfe1Dc89FfE61CcDe653Fc05Bc5D6108417E5AF8e, "USDE", true, true);
    l[i++] = Leg(STABLE_POOL, 0x878e27566Ab9E32534e306C26388dFcE82D0AB46, "USDS", true, true);
    l[i++] = Leg(STABLE_POOL, 0x66dbe40c8dc03f2C9e7A187F253e8889A03640c8, "DAI", true, true);
    l[i++] = Leg(STABLE_POOL, 0x0326748d09eD77D8C15fbf04d6277aE4CAF033f3, "USD1", true, true);
    l[i++] = Leg(STABLE_POOL, 0xeE12a7072779a4ab85f2DD2a1E163DbF164291f9, "USDG", true, true);
    l[i++] = Leg(STABLE_POOL, 0x626eb915d4a4136F7c00352A54378d3A322488da, "PYUSD", true, true);
    l[i++] = Leg(STABLE_POOL, 0x35c625c07ed4a9123ab863f6e8722c9210c808A3, "RLUSD", true, true);
    l[i++] = Leg(STABLE_POOL, 0xee7D69C52c2F183A0389374E82ca841c5a463573, "USDF", true, true);
    l[i++] = Leg(STABLE_POOL, 0x89A9cD1dd6DE3ab7152EF9c7C5496c2946334D0D, "U", true, true);
    l[i++] = Leg(STABLE_POOL, 0xF36eEe851bf3e76E464609a717bAE4a239A8cC7b, "GHO", true, true);
    l[i++] = Leg(STABLE_POOL, 0xbAA18E707E7b7fE9d1c0e4CeA61603035cb30C55, "TUSD", true, true);
    l[i++] = Leg(STABLE_POOL, 0x49C710167A4b486F20f9437485D865D653806310, "USDTB", true, true);
    l[i++] = Leg(STABLE_POOL, 0x432A3248e91d8B6fd41A487dE8886E0B44Fb7a6D, "FDUSD", true, true);
    l[i++] = Leg(STABLE_POOL, 0x96f953bAC2FF3829B4a526cacd858A5a22327E03, "AUSD", true, true);
    // ── volatile-core ──
    l[i++] = Leg(VOLATILE_POOL, 0x5AFaFEC0495e362976E1cA87D1Ce044AC49A39E9, "USDC", true, false);
    l[i++] = Leg(VOLATILE_POOL, 0xa7Dc0A8815acCbDfc22619b6F65b2dE710Eb2A7B, "USDT", true, true);
    l[i++] = Leg(VOLATILE_POOL, 0x6db2Ca217808f8d534d1e932396310aD612c0832, "WETH", false, false);
    l[i++] = Leg(VOLATILE_POOL, 0x66F3F73f8224Ed79c532a0C220003aC41A695Abb, "WBTC", false, false);
    l[i++] = Leg(VOLATILE_POOL, 0xf9190B9Ef055fdBbb70135C87fBf1A919932236f, "cbBTC", false, false);
    l[i++] = Leg(VOLATILE_POOL, 0x7A11aFd4953DC9E696C92a9ee7FA960f29D9e59e, "BNB", false, false);
    l[i++] = Leg(VOLATILE_POOL, 0x636647b9cd4a8A4fDD46F1576adb8A5FdFe01a34, "XAUT", false, false);
    l[i++] = Leg(VOLATILE_POOL, 0xFF4dCC8C224fD40a850B452afad4CE018AA368A8, "PAXG", false, false);
    l[i++] = Leg(VOLATILE_POOL, 0x05705Ac3915A094b345629B02D5aa8d52Bb99DDB, "EURC", false, false);
    // ── fx-core ──
    l[i++] = Leg(FX_POOL, 0x5AFaFEC0495e362976E1cA87D1Ce044AC49A39E9, "USDC", true, false);
    l[i++] = Leg(FX_POOL, 0x05705Ac3915A094b345629B02D5aa8d52Bb99DDB, "EURC", false, false);
    l[i++] = Leg(FX_POOL, 0x7730C2C1b3945cE1380093d8C0E4Dfb6146CDC57, "QCAD", false, false);
    l[i++] = Leg(FX_POOL, 0x34F6d53672c857A9a40E6c3199ad39EEb23f2668, "AUDF", false, false);
    l[i++] = Leg(FX_POOL, 0x749cb251a922c56e4aE71B9a1E7E5CBa9a15615a, "BRLA", false, false);
    l[i++] = Leg(FX_POOL, 0x366C7D67291b7aE37c5E137eb1BfDF0052C06707, "JPYC", false, false);
    l[i++] = Leg(FX_POOL, 0xD5eE24Fb35b847F6b8bdFe71b2F9E051f289d08a, "KRW1", false, false);
    require(i == l.length, "leg count");
  }

  /// @notice Read-only. Asserts every fence BRACKETS the leg's live on-chain params, so a seed can
  ///         never install a fence that instantly bricks `setAssetParamsBounded` on that leg.
  function preview() external view {
    Leg[] memory legs = _legs();
    for (uint256 i; i < legs.length; ++i) {
      Leg memory l = legs[i];
      IAdmin.RiskFences memory f = _fences(l);
      IPool.Asset memory a = IPool(l.pool).getAsset(l.token);
      require(a.decimals != 0, string.concat(l.sym, ": not listed in pool"));
      require(
        a.minFeePbps >= f.minFeeHardMin && a.minFeePbps <= f.minFeeHardMax,
        string.concat(l.sym, ": live minFee outside fence")
      );
      require(a.maxFeePbps <= f.maxFeeHardMax, string.concat(l.sym, ": live maxFee above ceiling"));
      require(
        a.gamma >= f.gammaHardMin && a.gamma <= f.gammaHardMax,
        string.concat(l.sym, ": live gamma outside fence")
      );
      require(
        a.vega >= f.vegaHardMin && a.vega <= f.vegaHardMax,
        string.concat(l.sym, ": live vega outside fence")
      );
      require(
        a.haircutSuppressor <= f.haircutHardMax,
        string.concat(l.sym, ": live haircut above ceiling, walled flag wrong?")
      );
      require(
        a.reservationPrice == 0 && a.reservationPriceMax == 0,
        string.concat(l.sym, ": reservation band is LIVE, 0/0 fences would fail closed")
      );
      console2.log(l.sym, l.pool, a.minFeePbps, a.haircutSuppressor);
    }
    console2.log("preview OK, legs:", legs.length);
  }

  /// @notice Emit the exact `setRiskFences` calldata per leg for an owner/multisig to send offline.
  function calldatas() external view {
    Leg[] memory legs = _legs();
    for (uint256 i; i < legs.length; ++i) {
      console2.log(legs[i].sym, address(admin));
      console2.logBytes(
        abi.encodeCall(Admin.setRiskFences, (legs[i].pool, legs[i].token, _fences(legs[i])))
      );
    }
  }

  /// @notice Owner-only broadcast. 32 txs; `Admin.setRiskFences` is `_onlyAdmin`.
  function seed() external {
    Leg[] memory legs = _legs();
    vm.startBroadcast();
    for (uint256 i; i < legs.length; ++i) {
      admin.setRiskFences(legs[i].pool, legs[i].token, _fences(legs[i]));
    }
    vm.stopBroadcast();
  }
}
