// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {DeployBase} from "@btr-shared-script/Deploy.base.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {ExternalOracle} from "../src/oracles/ExternalOracle.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {TestnetWETH9} from "../src/testnet/TestnetWETH9.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {console2} from "forge-std/Script.sol";

/// @title SepoliaOracleDeploy — Sepolia (11155111) ORACLE STACK ONLY.
/// @notice AccessControl + ExternalOracle + 24 mock assets (+ a USD unit token) + 25 feeds
///         (idx 0..23 market + idx 24 USDC/USD reference) + admin mark seed.
///         Pools/AMM are a SEPARATE later deploy that MUST reuse the persisted AC + token
///         addresses (deployments/11155111.deploy.json = SoT; feed_id = keccak(asset, USDC)
///         binds to these token addresses forever).
/// @dev BASE USDC CONFIG (owner decision 2026-07-23, wired at the later pool deploy):
///      - Base market mark = 1.0 CONSTANT. The pool never prices the base off a pushed mark:
///        Pricing._readBasePriceOrHalt discards the read price for quoting (numeraire ≡ 1.0);
///        idx 0 USDC/USDC stays an identity feed SEEDED at 1e18 and is NEVER pushed (absent
///        from the NXR signed manifest + keeper feeds; exempt from the freshness market-audit;
///        kept on-chain only to preserve the pinned append-only idx numbering).
///      - Base DEPEG GUARD = the SIGNED USDC/USD reference (idx 24, feed_USDC-USD =
///        keccak(USDC, USD)). Pool base OracleConfig: mode = EXTERNAL, primary = this
///        ExternalOracle, feedId = feed_USDC-USD. _readBasePriceOrHalt gates it (stale/dead/
///        uncertain fail-closed) and halts swaps when |USDC/USD − 1e18| > C.BASE_DEPEG_HALT_BPS
///        (500 bp). INTERNAL mode for the base is forbidden (PoolAdmin.validateOracleMode).
///      - refFeedId/refBandBps/refPrimary stay 0 FOR THE BASE: the refPrimary band is the
///        spoke-side breaker (validateOracleConfig requires refPrimary != primary); the base's
///        canonical feed IS its breaker (base is exempt from requireExternalSpokeBound).
///      - Reservation band in USD: Asset.reservationPrice/reservationPriceMax (B64, USD units,
///        e.g. 0.99/1.01) arm PoolIO.priceBandGuard against the SAME signed USDC/USD feed —
///        the reservation/minimum price is denominated in USD via this reference.
///      - Generalization (REF_ORACLE gap): where Chainlink lacks a pair (BNB/XAUT/PAXG), an
///        NXR-signed reference feed on a SECOND ExternalOracle instance (distinct address +
///        ideally distinct signer set) fills the spoke refPrimary/refFeedId role.
/// @dev Env: DEPLOYER_PK + ORACLE_SEED_{ETH,BTC,BNB,XAUT,PAXG,syrupUSDC}_1E18 (required; WBTC+cbBTC
///      both seed from BTC, WETH from ETH; syrupUSDC is an ACCRUING wrapper, never a 1.0 peg).
///      Peg stables default 1e18, overridable via ORACLE_SEED_<SYMBOL>_1E18 within
///      [0.98e18, 1.02e18] (admits real off-peg prints, rejects fat-fingers); volatiles are
///      bounds-checked per asset (scale-error guard only). GUARDIAN is REQUIRED (second key,
///      != deployer, granted AC guardian in-broadcast). Optional: TREASURY, DEPLOY_OUT,
///      REDEPLOY (override re-run guard).
///      Signer set = canonical NXR 2-of-3 attester set (env-overridable ORACLE_SIGNER_{0,1,2},
///      defaults = canonical pins). Public addresses only; the private keys exist solely as raw
///      k8s Secrets in cluster etcd (sealing owner-gated — SIGNING_TIER_RUNBOOK.md §3), and the
///      EIP-712 domain binds chainId + oracle address so Chapel signatures cannot replay here —
///      no fresh key ceremony warranted for Sepolia (mainnet ALWAYS gets one).
/// @dev RUNBOOK (money-path, ORDER MATTERS):
///      0. PRE-DEPLOY (ttl-safety): `forge script ... --sig "predictOracle()" --rpc-url sepolia`
///         prints the precomputed oracle address (deployer CREATE nonce+1). Fill the NXR
///         signed_quotes ConfigMap AND keepers/oracle.sepolia.toml `oracle` with it BEFORE the
///         signing tier boots — signers then never restart post-deploy (a restart re-runs the
///         ~4h sigma warm-up and races the seed band/ttl). The deployer MUST NOT send any other
///         tx between prediction and deploy; deployOracle() hard-asserts deployed == predicted.
///      1. Fund deployer >= 0.3 ETH (est. 0.065 @ ~2 gwei; Sepolia base fee spikes 20-100 gwei).
///      2. Pull ALL seeds from live NXR quotes <= 5 min pre-broadcast (volatiles + syrupUSDC
///         required; env-seed any stable trading > ~25bp off peg — verify U redemption value).
///         First signed push has dt=0 ⇒ band = bare maxDev floor (50bp stable / 100bp volatile)
///         around the SEED — a stale/off seed strands its feed. ⚠ RECOVERY CHANGED: `updateFeed`
///         is now TIGHTEN-ONLY; widening the band/ttl routes through
///         requestFeedWiden → BASE_TIMELOCK (15 min on Sepolia via govDelay) → executeFeedWiden,
///         guardian-vetoable. There is still no removeFeed. This is precisely why this ceremony
///         seeds AT MARKET (step 2, <= 5 min): the old instant-widen hole was the operational
///         crutch for a bad seed, and it is gone.
///      3. forge script script/SepoliaOracleDeploy.s.sol:SepoliaOracleDeploy \
///           --sig "deployOracle()" --rpc-url sepolia --broadcast --slow --verify
///         (--slow: ~50 sequential txs on a public RPC — avoids nonce gaps/batch drops).
///      4. Fill keepers/oracle.sepolia.toml feed_ids from deployments/11155111.deploy.json
///         (keepers/scripts/fill-oracle-config.py) and start the keeper IMMEDIATELY in the same
///         session (--once, then keeper loop) so first pushes land while seeds are fresh. NEVER park
///         the stack seeded-but-unpushed (>1% drift strands volatile feeds).
///      5. Guardian is appointed IN-BROADCAST (step 3) and the script now hard-reverts without it.
///         Verify: `cast call <ac> "guardianCount()(uint8)"` >= 1 and
///         `cast call <ac> "isGuardian(address)(bool)" <guardianSafe>` == true.
///      6. HANDOVER, in this order (ordering is load-bearing — see AccessControl.armQuorumPolicy,
///         which enforces it on-chain and reverts if guardians are absent):
///           a. Deploy the guardian Safe (1-of-n; 2-of-n only per guardianQuorumMax) and the admin
///              Safe (ceil(2n/3): 2-of-3, 3-of-4, 4-of-5 ...).
///           b. setGuardian(guardianSafe, true) — guardians BEFORE armed, always.
///           c. bootstrapTreasuryOwner(adminSafe) (one-shot, instant) or queue+execute if already
///              bootstrapped.
///           d. adminSafe.requestOwnershipHandover(); deployer.completeOwnershipHandover(adminSafe).
///           e. setGuardian(deployerHotKey, false) — drop any bootstrap EOA guardian.
///           f. armQuorumPolicy() from the admin Safe. Post-arm, every principal must satisfy the
///              formula; EOA principals are refused. THIS is "the system is armed".
///         `quorumStatus()` is the monitoring read (a Safe self-lowering its threshold post-arm is
///         sovereign and undetectable to any gate — alert on it).
contract SepoliaOracleDeploy is DeployBase {
  uint16 internal constant STABLE_TTL = 7200;
  uint16 internal constant VOLATILE_TTL = 600;
  // σ seed MUST be non-zero (addFeed enforces it). The old σ=0 "deliberately inert" seed reasoned
  // only about the FIRST push; it is a DEADLOCK when that push is late. Band = maxDev + Z·σ·√(dt/…)
  // and σ only rises on a successful push, so a σ=0 feed keeps the bare maxDev floor until it takes
  // one — and once the market has drifted past that floor, no push can ever land (needs a push for
  // σ, needs σ for the push). Recovery is the timelocked requestFeedWiden. Seeds below are BELOW
  // the observed live per-class medians (stables 93-429, FX 296-2729, volatile 893-4114 PBPS/30min)
  // so they under-state the prior rather than inflating the band; the first real push overwrites.
  uint32 internal constant SIGMA_SEED_STABLE = 300;
  uint32 internal constant SIGMA_SEED_VOLATILE = 2_000;
  uint16 internal constant CONF_SEED = 25; // bps interim
  // maxDeviation = microstructure FLOOR of the volatility-adaptive per-push band
  // (allowed = floor + min(6·σ·√(dtSource/1800), 9·floor)); θ policy: 0.25bp stable / 5bp volatile.
  uint16 internal constant STABLE_MAXDEV = 50; // 0.5% floor (σ≈0 for pegged units)
  uint16 internal constant VOLATILE_MAXDEV = 100; // 1% floor (σ scales this up per ticker)
  uint8 internal constant SIGNER_THRESHOLD = 2;
  uint256 internal constant N = 24;
  uint256 internal constant N_STABLE = 17; // idx 0..16 stable, 17..23 volatile

  // Canonical regenerated NXR attester set (2-of-3), the DEFAULT for env ORACLE_SIGNER_{0,1,2}
  // (config-driven promotion: a different chain's set is env, not new Solidity). Public
  // addresses; keys = raw k8s Secrets nxr-signer-key-{0,1,2} in cluster etcd (sealing
  // owner-gated). Must match keepers/oracle.sepolia.toml pin exactly.
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
  ///         configs are filled with THIS address BEFORE deploy so signer pods boot exactly once
  ///         (no post-deploy restart, no sigma warm-up race against the seed band/ttl).
  ///         Deterministic CREATE: _deployAC consumes deployer nonce N, ExternalOracle is N+1.
  ///         Invalidated by ANY other deployer tx before deployOracle() (which hard-asserts).
  function predictOracle() external view returns (address predicted) {
    address deployer = vm.addr(vm.envUint("DEPLOYER_PK"));
    uint64 nonce = vm.getNonce(deployer);
    predicted = vm.computeCreateAddress(deployer, nonce + 1);
    console2.log("deployer:      ", deployer);
    console2.log("current nonce: ", nonce);
    console2.log("predicted ExternalOracle:", predicted);
  }

  /// @dev addFeed order = append-only feedIds[] idx 0..23 — the idx NXR-signed records carry.
  ///      USD0 dropped (no live feed). WBTC/cbBTC route the BTC mark, WETH the ETH mark (NXR-side).
  ///      Downstream feed lookup is by name / keccak(asset,USDC), never numeric idx, so appending
  ///      EURC does not disturb any earlier feed; the USDC/USD reference (added after the loop)
  ///      shifts to keeper idx 24.
  function _syms() internal pure returns (string[N] memory s) {
    s = [
      string("USDC"), // idx 0: base identity USDC/USDC — seeded 1e18, NEVER pushed (see header)
      "USDT",
      "USDE",
      "USDS",
      "DAI",
      "USD1",
      "USDG",
      "PYUSD",
      "RLUSD",
      "syrupUSDC",
      "USDF",
      "U",
      "GHO",
      "TUSD",
      "USDTB",
      "FDUSD",
      "AUSD", // idx 16: last stable
      "WETH", // idx 17: first volatile
      "WBTC",
      "cbBTC",
      "BNB",
      "XAUT",
      "PAXG",
      "EURC" // idx 23: euro-stable, VOLATILE class (FX); pool-roster asset (owner 2026-07-21)
    ];
  }

  function _isWeth(string memory sym) internal pure returns (bool) {
    return keccak256(bytes(sym)) == keccak256("WETH");
  }

  /// @dev idx of syrupUSDC in _syms(): the one non-peg "stable" (accruing Maple wrapper ~1.1x).
  uint256 internal constant SYRUP_IDX = 9;

  /// @dev Seeds come from the ceremony's ONE NXR snapshot (deployments/<chain>.seed-marks.json,
  ///      written by sdk/scripts/fetch-seed-marks.ts), which SepoliaPoolDeploy also sizes its legs
  ///      from. A second source — 24 hand-set ORACLE_SEED_* env vars — is a second thing that can
  ///      disagree with the pool seeding, and `envOr(..., 1e18)` on a peg stable silently seeded a
  ///      wrong mark whenever an export was forgotten. Absent file or absent mark ⇒ revert.
  function _loadSeeds(string[N] memory syms) internal view returns (uint256[N] memory m) {
    string memory marks = vm.readFile(
      string.concat("deployments/", vm.toString(block.chainid), ".seed-marks.json")
    );
    // Volatile plausibility bounds (1e18 units): coarse SCALE-error guards (1e15-vs-1e18
    // fat-finger), not market views. A >20% off seed is near-unrecoverable (updateFeed caps
    // maxDeviation at 2000 = 20%/push walk) — runbook: seeds from live NXR <= 5 min pre-broadcast.
    // EURC ~1.08 (EUR/USD); the [0.9,1.3] window admits the FX band, rejects a scale fat-finger.
    uint256[7] memory volLo =
      [uint256(500e18), 20_000e18, 20_000e18, 100e18, 1_500e18, 1_500e18, 0.9e18];
    uint256[7] memory volHi =
      [uint256(20_000e18), 500_000e18, 500_000e18, 5_000e18, 10_000e18, 10_000e18, 1.3e18];
    for (uint256 i; i < N; ++i) {
      bool stable = i < N_STABLE;
      // syrupUSDC accrues — its true mark sits well above 1.0, so it takes the REQUIRED-env +
      // wide-bound path; the peg clamp below would reject its true mark and strand the feed.
      bool pegStable = stable && i != SYRUP_IDX;
      m[i] = vm.parseJsonUint(marks, string.concat(".marks.", syms[i], ".mark1e18"));
      require(m[i] != 0 && M.encodeB64(m[i], 18) != 0, "invalid oracle seed mark");
      // First signed push has dt=0 ⇒ band = bare maxDev floor around the SEED (50bp stable /
      // 100bp volatile); a seed off the live mark strands the bootstrap push behind the band.
      // Peg clamp [0.98e18, 1.02e18]: admits documented off-peg prints (TUSD/FDUSD/USDF have
      // traded 30-100bp off) while rejecting magnitude fat-fingers; any stable > ~25bp off peg
      // MUST be env-seeded from live NXR (runbook step 2).
      if (pegStable) {
        require(m[i] >= 0.98e18 && m[i] <= 1.02e18, "stable seed out of band");
      } else if (stable) {
        require(m[i] >= 1e18 && m[i] <= 1.5e18, "syrupUSDC seed out of band");
      } else {
        uint256 v = i - N_STABLE;
        require(m[i] >= volLo[v] && m[i] <= volHi[v], "volatile seed implausible");
      }
    }
    // USDC/USDC is an identity feed by construction (see TestnetDeploy USDC seed rationale).
    require(m[0] == 1e18, "USDC/USDC seed must equal 1e18");
  }

  function deployOracle() external returns (address ac, address oracle) {
    require(block.chainid == 11155111, "Sepolia only");
    // Re-run guard: a second broadcast would mint a duplicate stack AND silently overwrite the
    // SoT json (feed_id binds keccak(asset,USDC) to these token addresses forever; a keeper
    // pointed at a stale json = wrong oracle / OOB idx). REDEPLOY=true overrides deliberately.
    string memory outPath = _outPath();
    // CODE, not file existence: forge runs the script AGAIN to broadcast, so a bare `vm.exists`
    // trips on the artifact the simulation pass just wrote and aborts a genuine first deploy.
    require(
      !_oracleLive(outPath) || vm.envOr("REDEPLOY", false),
      "already deployed: 11155111.deploy.json carries a live oracle (REDEPLOY=true to override)"
    );
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
    // ttl-safety invariant: the address the signing tier was pre-filled with (predictOracle)
    // MUST be the address actually minted — asserted post-CREATE below. Computed from the
    // SAME nonce source so any interleaved deployer tx fails the deploy, not the bring-up.
    address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
    string[N] memory syms = _syms();
    uint256[N] memory seeds = _loadSeeds(syms);

    vm.startBroadcast(pk);
    ac = address(_deployAC(deployer, _resolveTreasury(deployer)));
    address[] memory signers = _signers();
    // lag 30s couples with Pricing.STALE_GRACE_CAP_S = 30 (L-1): a longer oracle lag would leave
    // a window where the pool's staleness premium is capped below the actual mark age.
    // Note (F-3): 30s ≈ 2.5 Sepolia blocks — congested inclusion beyond that reverts the relay
    // stale-on-arrival (fail-closed; keeper re-fetches a fresh blob). Monitor revert rate.
    ExternalOracle o = new ExternalOracle(ac, 30, signers, SIGNER_THRESHOLD);
    oracle = address(o);
    require(
      oracle == predicted,
      "oracle != precomputed: signing-tier/keeper config prefill (predictOracle) is INVALID"
    );

    address[N] memory toks;
    for (uint256 i; i < N; ++i) {
      // WETH is the pool's wnative, so its mock MUST answer deposit()/withdraw() or native ETH
      // cannot be wrapped at all (PoolIO.pull/push call them). Every other leg stays a plain mock.
      toks[i] = _isWeth(syms[i])
        ? address(new TestnetWETH9(syms[i], syms[i], 18))
        : address(new TestnetERC20(syms[i], syms[i], 18));
    }
    for (uint256 i; i < N; ++i) {
      bool stable = i < N_STABLE;
      o.addFeed(
        toks[i],
        toks[0],
        M.encodeB64(seeds[i], 18),
        stable ? SIGMA_SEED_STABLE : SIGMA_SEED_VOLATILE,
        CONF_SEED,
        stable ? STABLE_MAXDEV : VOLATILE_MAXDEV,
        stable ? STABLE_TTL : VOLATILE_TTL
      );
    }
    // idx 24: SIGNED USDC/USD REFERENCE — the base depeg-guard feed, NOT a market mark (header).
    // feed_id = keccak(USDC, USD); the USD unit token exists only to mint that id (never a pool
    // asset). NXR signs it from pyth Lazer USDC/USD (~1s cadence, freshness tier 1500 ms) and it
    // rides the same signed batch (keeper idx 24). Seed env-overridable like every peg stable.
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
    // F-2: independent fast-freeze from day one, MANDATORY. Previously `envOr(..., address(0))`
    // with a silent skip — which is exactly how the live Sepolia AccessControls ended up with ZERO
    // guardians (no GuardianSet event in full history), collapsing every fail-safe lever in the
    // fleet (pauseFeed / freezeAsset / cancel* / UpgradeGate.pause) onto the single deployer EOA
    // that is simultaneously the entire attack surface. An un-appointed guardian is not a
    // deferred nicety; it is the fail-safe being absent. Hard-required, and it must be a DIFFERENT
    // key from the deployer or it protects against nothing.
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
    console2.log("=== BTR Sepolia oracle stack ===");
    console2.log("AccessControl: ", ac);
    console2.log("ExternalOracle:", oracle);
    console2.log("guardian:      ", guardian);

    string memory k = "sepolia";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "deployer", deployer);
    vm.serializeAddress(k, "ac", ac);
    vm.serializeAddress(k, "oracle", oracle);
    // Recorded so the artifact answers "who can halt this?" without an archive-node log scan. The
    // absence of this key in the current 11155111.deploy.json is exactly how zero-guardians went
    // unnoticed. `owner` is recorded separately from `deployer` because they diverge at handover.
    vm.serializeAddress(k, "guardian", guardian);
    vm.serializeAddress(k, "owner", AccessControl(ac).owner());
    string memory json;
    for (uint256 i; i < N; ++i) {
      vm.serializeAddress(k, syms[i], toks[i]);
      json = vm.serializeBytes32(
        k, string.concat("feed_", syms[i]), keccak256(abi.encodePacked(toks[i], toks[0]))
      );
    }
    // idx 23 USDC/USD reference: key matches the keeper feed name "USDC-USD"
    // (fill-oracle-config.py derives feed_<name> when no -USDC suffix strips).
    vm.serializeAddress(k, "USD", usd);
    json = vm.serializeBytes32(k, "feed_USDC-USD", keccak256(abi.encodePacked(toks[0], usd)));

    try vm.writeJson(json, outPath) {}
    catch {
      console2.log("(skip) writeJson not permitted; JSON below:");
      console2.log(json);
    }
  }
}
