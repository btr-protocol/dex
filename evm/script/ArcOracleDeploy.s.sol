// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {DeployBase} from "@btr-shared-script/Deploy.base.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {ExternalOracle} from "../src/oracles/ExternalOracle.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {console2} from "forge-std/Script.sol";

/// @title ArcOracleDeploy — Arc Testnet (5042002) ORACLE STACK ONLY.
/// @notice AccessControl + ExternalOracle + 14 market assets (8 peg stables + 6 FX; no volatile
///         crypto) + a USD unit token + 15 feeds (idx 0..13 market + idx 14 USDC/USD reference) +
///         admin mark seed. Real Arc ERC-20 USDC at the chain-native address (6 decimals); every
///         other leg is a TestnetERC20(18). No WETH / wnative mock.
///         Pools/AMM are a SEPARATE later deploy that MUST reuse the persisted AC + token
///         addresses (deployments/5042002.deploy.json = SoT; feed_id = keccak(asset, USDC)
///         binds to these token addresses forever).
/// @dev BASE USDC CONFIG (owner decision 2026-07-23, wired at the later pool deploy):
///      - Base market mark = 1.0 CONSTANT. The pool never prices the base off a pushed mark:
///        Pricing._readBasePriceOrHalt discards the read price for quoting (numeraire ≡ 1.0);
///        idx 0 USDC/USDC stays an identity feed SEEDED at 1e18 and is NEVER pushed (absent
///        from the NXR signed manifest + keeper feeds; exempt from the freshness market-audit;
///        kept on-chain only to preserve the pinned append-only idx numbering).
///      - Base DEPEG GUARD = the SIGNED USDC/USD reference (idx 14, feed_USDC-USD =
///        keccak(USDC, USD)). Pool base OracleConfig: mode = EXTERNAL, primary = this
///        ExternalOracle, feedId = feed_USDC-USD. _readBasePriceOrHalt gates it (stale/dead/
///        uncertain fail-closed) and halts swaps when |USDC/USD − 1e18| > C.BASE_DEPEG_HALT_BPS
///        (500 bp). INTERNAL mode for the base is forbidden (PoolAdmin.validateOracleMode).
///      - refFeedId/refBandBps/refPrimary stay 0 FOR THE BASE: the refPrimary band is the
///        spoke-side breaker (validateOracleConfig requires refPrimary != primary); the base's
///        canonical feed IS its breaker (base is exempt from requireExternalSpokeBound).
///      - Reservation band BASE-per-asset: Asset.reservationPrice/reservationPriceMax (B64,
///        BASE units always; DEN-02). For usdQuoted spokes, priceBandGuard converts the USD
///        primary mark to BASE before comparing. On the base itself the band is typically
///        0.99/1.01 vs the signed USDC/USD depeg feed (base mark ≡ 1 for quoting).
/// @dev Env: DEPLOYER_PK. Seeds from deployments/5042002.seed-marks.json (required; written by
///      sdk/scripts/fetch-seed-marks.ts). Peg stables clamp [0.98e18, 1.02e18]; FX legs require
///      nonzero encodeable marks (EURC plausibility [0.8e18, 1.4e18]; JPYC/KRW1 are <<1e18).
///      GUARDIAN is REQUIRED (second key, != deployer, granted AC guardian in-broadcast). Optional:
///      TREASURY, DEPLOY_OUT, REDEPLOY (override re-run guard), ORACLE_SEED_USDCUSD_1E18.
///      Signer set = canonical NXR 2-of-3 attester set (env-overridable ORACLE_SIGNER_{0,1,2},
///      defaults = canonical pins). Public addresses only; the private keys exist solely as raw
///      k8s Secrets in cluster etcd (sealing owner-gated — SIGNING_TIER_RUNBOOK.md §3), and the
///      EIP-712 domain binds chainId + oracle address so Chapel signatures cannot replay here.
/// @dev RUNBOOK (money-path, ORDER MATTERS):
///      0. PRE-DEPLOY (ttl-safety): `forge script ... --sig "predictOracle()" --rpc-url arc`
///         prints the precomputed oracle address (deployer CREATE nonce+1). Fill the NXR
///         signed_quotes ConfigMap AND keepers/oracle.arc.toml `oracle` with it BEFORE the
///         signing tier boots — signers then never restart post-deploy (a restart re-runs the
///         ~4h sigma warm-up and races the seed band/ttl). The deployer MUST NOT send any other
///         tx between prediction and deploy; deployOracle() hard-asserts deployed == predicted.
///      1. Fund deployer with Arc testnet gas.
///      2. Pull ALL seeds from live NXR quotes <= 5 min pre-broadcast into
///         deployments/5042002.seed-marks.json. First signed push has dt=0 ⇒ band = bare maxDev
///         floor (50bp peg stable / 75bp FX) around the SEED — a stale/off seed strands its feed.
///         `updateFeed` is TIGHTEN-ONLY; widening routes through requestFeedWiden → timelock →
///         executeFeedWiden, guardian-vetoable.
///      3. forge script script/ArcOracleDeploy.s.sol:ArcOracleDeploy \
///           --sig "deployOracle()" --rpc-url arc --broadcast --slow --verify
///      4. Fill keepers/oracle.arc.toml feed_ids from deployments/5042002.deploy.json
///         (keepers/scripts/fill-oracle-config.py) and start the keeper IMMEDIATELY in the same
///         session (--once, then keeper loop) so first pushes land while seeds are fresh.
///      5. Guardian is appointed IN-BROADCAST (step 3) and the script hard-reverts without it.
///      6. HANDOVER: guardian Safe → setGuardian → treasury bootstrap → ownership handover →
///         drop bootstrap EOA guardian → armQuorumPolicy from admin Safe.
contract ArcOracleDeploy is DeployBase {
  uint16 internal constant STABLE_TTL = 7200;
  uint16 internal constant FX_TTL = 3600;
  // σ seed MUST be non-zero (addFeed enforces it). Band = maxDev + Z·σ·√(dt/…); σ only rises on
  // a successful push. Seeds below under-state the observed live per-class medians so the band is
  // not inflated; the first real push overwrites.
  uint32 internal constant SIGMA_SEED_STABLE = 300;
  uint32 internal constant SIGMA_SEED_FX = 800;
  uint16 internal constant CONF_SEED = 25; // bps interim
  uint16 internal constant STABLE_MAXDEV = 50; // 0.5% floor (peg stables)
  uint16 internal constant FX_MAXDEV = 75; // 0.75% floor (fiat FX vs USDC)
  uint8 internal constant SIGNER_THRESHOLD = 2;
  uint256 internal constant N = 14; // idx 0..7 peg stables, 8..13 FX
  uint256 internal constant N_STABLE = 8;

  // Arc Testnet native USDC (6 decimals, no deposit/withdraw). NOT minted by this script.
  address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;

  // Canonical regenerated NXR attester set (2-of-3), the DEFAULT for env ORACLE_SIGNER_{0,1,2}.
  // Must match keepers/oracle.arc.toml pin exactly.
  address internal constant SIGNER_0 = 0x9E34F1120B9a6fD93AAF81e6eF2df187A6CE45cF;
  address internal constant SIGNER_1 = 0x80F7f57Bd9DF46FA448586bC2Cc5e4ddF765973E;
  address internal constant SIGNER_2 = 0x672C2dc3CA298eDca4793C700b9C658482966B2c;

  /// @dev Resolved signer set: env-overridable with canonical defaults; zero/dup fail closed.
  function _signers() internal view returns (address[] memory s) {
    s = new address[](3);
    s[0] = vm.envOr("ORACLE_SIGNER_0", SIGNER_0);
    s[1] = vm.envOr("ORACLE_SIGNER_1", SIGNER_1);
    s[2] = vm.envOr("ORACLE_SIGNER_2", SIGNER_2);
    require(
      s[0] != address(0) && s[1] != address(0) && s[2] != address(0) && s[0] != s[1]
        && s[0] != s[2] && s[1] != s[2],
      "invalid signer set (zero or duplicate)"
    );
  }

  /// @notice Pre-deploy oracle address precomputation (ttl-safety): the signing tier + keeper
  ///         configs are filled with THIS address BEFORE deploy so signer pods boot exactly once.
  function predictOracle() external view returns (address predicted) {
    address deployer = vm.addr(vm.envUint("DEPLOYER_PK"));
    uint64 nonce = vm.getNonce(deployer);
    predicted = vm.computeCreateAddress(deployer, nonce + 1);
    console2.log("deployer:      ", deployer);
    console2.log("current nonce: ", nonce);
    console2.log("predicted ExternalOracle:", predicted);
  }

  /// @dev addFeed order = append-only feedIds[] idx 0..14 — the idx NXR-signed records carry.
  ///      idx 0..7 peg stables (USDC identity + USDT..RLUSD), idx 8..13 FX, idx 14 USDC/USD ref.
  function _syms() internal pure returns (string[N] memory s) {
    s = [
      string("USDC"), // idx 0: base identity USDC/USDC — seeded 1e18, NEVER pushed
      "USDT",
      "USDE",
      "USDS",
      "USD1",
      "USDG",
      "PYUSD",
      "RLUSD", // idx 7: last peg stable
      "EURC", // idx 8: first FX
      "QCAD",
      "AUDF",
      "BRLA",
      "JPYC",
      "KRW1" // idx 13: last FX
    ];
  }

  function _isFx(uint256 i) internal pure returns (bool) {
    return i >= N_STABLE;
  }

  function _isStable(uint256 i) internal pure returns (bool) {
    return i < N_STABLE;
  }

  /// @dev Seeds from deployments/<chain>.seed-marks.json (ceremony NXR snapshot). Absent file or
  ///      absent mark ⇒ revert.
  function _loadSeeds(string[N] memory syms) internal view returns (uint256[N] memory m) {
    string memory marks = vm.readFile(
      string.concat("deployments/", vm.toString(block.chainid), ".seed-marks.json")
    );
    for (uint256 i; i < N; ++i) {
      m[i] = vm.parseJsonUint(marks, string.concat(".marks.", syms[i], ".mark1e18"));
      require(m[i] != 0 && M.encodeB64(m[i], 18) != 0, "invalid oracle seed mark");
      if (_isStable(i)) {
        require(m[i] >= 0.98e18 && m[i] <= 1.02e18, "stable seed out of band");
      } else {
        // EURC ~1.08 (EUR/USD); coarse scale guard. Other FX (JPYC/KRW1 <<1e18) need only nonzero.
        if (keccak256(bytes(syms[i])) == keccak256("EURC")) {
          require(m[i] >= 0.8e18 && m[i] <= 1.4e18, "EURC seed implausible");
        }
      }
    }
    require(m[0] == 1e18, "USDC/USDC seed must equal 1e18");
  }

  function deployOracle() external returns (address ac, address oracle) {
    require(block.chainid == 5042002, "Arc Testnet only");
    string memory outPath = _outPath();
    require(
      !_oracleLive(outPath) || vm.envOr("REDEPLOY", false),
      "already deployed: 5042002.deploy.json carries a live oracle (REDEPLOY=true to override)"
    );
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
    address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
    string[N] memory syms = _syms();
    uint256[N] memory seeds = _loadSeeds(syms);

    vm.startBroadcast(pk);
    ac = address(_deployAC(deployer, _resolveTreasury(deployer)));
    address[] memory signers = _signers();
    ExternalOracle o = new ExternalOracle(ac, 30, signers, SIGNER_THRESHOLD);
    oracle = address(o);
    require(
      oracle == predicted,
      "oracle != precomputed: signing-tier/keeper config prefill (predictOracle) is INVALID"
    );

    address[N] memory toks;
    toks[0] = ARC_USDC;
    for (uint256 i = 1; i < N; ++i) {
      toks[i] = address(new TestnetERC20(syms[i], syms[i], 18));
    }
    for (uint256 i; i < N; ++i) {
      bool fx = _isFx(i);
      o.addFeed(
        toks[i],
        toks[0],
        M.encodeB64(seeds[i], 18),
        fx ? SIGMA_SEED_FX : SIGMA_SEED_STABLE,
        CONF_SEED,
        fx ? FX_MAXDEV : STABLE_MAXDEV,
        fx ? FX_TTL : STABLE_TTL
      );
    }
    // idx 14: SIGNED USDC/USD REFERENCE — base depeg-guard feed, NOT a market mark.
    address usd = address(new TestnetERC20("USD", "USD", 18));
    uint256 usdRefSeed = vm.envOr("ORACLE_SEED_USDCUSD_1E18", uint256(1e18));
    require(
      usdRefSeed >= 0.98e18 && usdRefSeed <= 1.02e18, "USDC/USD reference seed out of band"
    );
    o.addFeed(
      toks[0],
      usd,
      M.encodeB64(usdRefSeed, 18),
      SIGMA_SEED_STABLE,
      CONF_SEED,
      STABLE_MAXDEV,
      STABLE_TTL
    );
    address guardian = vm.envAddress("GUARDIAN");
    require(guardian != address(0), "GUARDIAN unset: fail-safe would not exist");
    require(guardian != deployer, "GUARDIAN == deployer: not an independent fail-safe");
    AccessControl(ac).setGuardian(guardian, true);
    require(AccessControl(ac).guardianCount() >= 1, "guardian not registered");
    vm.stopBroadcast();

    _persist(ac, oracle, deployer, guardian, syms, toks, usd, outPath);
  }

  function _oracleLive(string memory outPath) internal view returns (bool) {
    if (!vm.exists(outPath)) return false;
    string memory j = vm.readFile(outPath);
    if (!vm.keyExists(j, ".oracle")) return false;
    return vm.parseJsonAddress(j, ".oracle").code.length > 0;
  }

  function _outPath() internal view returns (string memory) {
    return vm.envOr(
      "DEPLOY_OUT", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
  }

  function _persist(
    address ac,
    address oracle,
    address deployer,
    address guardian,
    string[N] memory syms,
    address[N] memory toks,
    address usd,
    string memory outPath
  ) internal {
    console2.log("=== BTR Arc oracle stack ===");
    console2.log("AccessControl: ", ac);
    console2.log("ExternalOracle:", oracle);
    console2.log("guardian:      ", guardian);

    string memory k = "arc";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "deployer", deployer);
    vm.serializeAddress(k, "ac", ac);
    vm.serializeAddress(k, "oracle", oracle);
    vm.serializeAddress(k, "guardian", guardian);
    vm.serializeAddress(k, "owner", AccessControl(ac).owner());
    string memory json;
    for (uint256 i; i < N; ++i) {
      vm.serializeAddress(k, syms[i], toks[i]);
      json = vm.serializeBytes32(
        k, string.concat("feed_", syms[i]), keccak256(abi.encodePacked(toks[i], toks[0]))
      );
    }
    // idx 14 USDC/USD reference: key matches keeper feed name "USDC-USD"
    vm.serializeAddress(k, "USD", usd);
    json = vm.serializeBytes32(k, "feed_USDC-USD", keccak256(abi.encodePacked(toks[0], usd)));

    try vm.writeJson(json, outPath) {}
    catch {
      console2.log("(skip) writeJson not permitted; JSON below:");
      console2.log(json);
    }
  }
}
