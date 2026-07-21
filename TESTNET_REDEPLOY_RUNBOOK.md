# BTR DEX Testnet Redeploy Runbook (BSC Chapel, chainId 97)

Ready-to-execute, ordered, copy-pasteable. Pricing engine changed Hermite -> clamped quartic I-spline with a PRESETS model (9 regimes x wall tiers; each asset points at a preset via `Asset.presetId`). This redeploy reuses the SAME risk/param values as the last testnet deploy where they still apply, remapped onto presets.

Canonical last full reseed = `dex/evm/script/ChapelEnableSwaps.s.sol` (bakes `deploy/testnet-asset-params.json`, tag 2026-07-12b). This runbook supersedes the placeholder linear-ramp curves in that script with fitted presets from `dex/research/stable-core/out/spline_shared_grid.json`.

Sources of truth:
- Params: `dex/evm/deploy/testnet-asset-params.json` (SSoT for risk/fee/refBand).
- Presets: `dex/research/stable-core/out/spline_shared_grid.json` + docs `1. AIMM/1.1. Pricing/1.1.2. Liquidity Shaping.md` sec 4.1.
- On-chain oracle: `dex/evm/src/oracles/ExternalOracle.sol` + `dex/ORACLE_SIGNED_PUSH_SPEC.md`.
- Keeper: `keepers/oracle.chapel.toml` + `keepers/src/oracle/**`.

Convention: PBPS unit = 1e-6 (dispersion, minFee, curve weights). bps = 1e-4 (refBand, maxDeviation, fences). Curve weight integer `wQ` = value_in_pbps * Q, Q = 1e9.

---

## 0. Roles and the ONE new owner decision

Three disjoint key domains. Never mix, never print private keys:
- Deployer/admin EOA (`DEPLOYER_PK`): owns new AccessControl, runs bootstrap. NOT a price authority.
- NXR attester signers (`ORACLE_SIGNER_0/1/2`, private keys live NXR-side only as `NXR_SIGNER_KEY` per replica): the 2-of-3 price quorum. Only public addresses ever appear here.
- Keeper relay (`KEEPER_PRIVATE_KEY`, dedicated gas payer `0xc4B4635B76ed49A7239291F6fbB33455D059a5B9`): unpermissioned `msg.sender`, pays gas only, no price authority.

OWNER DECISION (only genuinely new choice): the per-asset regime -> preset assignment (section 6). The table below is the recommended default remap; confirm before deploy. Two soft points to confirm: USD1 (plateau W1 now vs hyper W0.5 after peg-confidence) and CAKE (platy vs lepto).

---

## 1. Prereqs and environment (NAMES only, never values)

Toolchain: `foundry` (forge/cast), `bun`, Rust toolchain for keeper, `kubectl` ctx `k0s-nxrates`, in-cluster BuildKit (never build images on Mac).

RPC: `chapel` alias -> `https://data-seed-prebsc-2-s1.bnbchain.org:8545`. chainId 97.

Env for the deploy script (`ChapelEnableSwaps.run` requires these; script asserts non-zero / independence):
- `DEPLOYER_PK` (deployer EOA; never echo)
- `REF_ORACLE` (independent reference oracle addr, MUST != primary ORACLE)
- `XAUT_REF_ORACLE` (independent XAUT/USDC ref oracle, MUST != primary)
- `XAUT_REF_FEED_ID` (MUST == keccak256(abi.encodePacked(XAUT, USDC)); script reverts otherwise)
- `SEED_USDC` (optional, default 50_000e18; stable-leg seed fallback)

Env if the oracle is deployed FRESH (default path KEEPS the incumbent oracle, see section 3):
- `ORACLE_SIGNER_0`, `ORACLE_SIGNER_1`, `ORACLE_SIGNER_2` (3 NXR attester public addrs; threshold 2)
- `REF_ORACLE_SIGNER_0/1/2`, `XAUT_REF_ORACLE_SIGNER_0/1/2` (each ref oracle its own 3 signers, distinct owners)
- `ORACLE_SEED_*_1E18` seed marks (USDC/USDC MUST == 1e18)

Keeper env (cluster secret `keepers/.env.chapel`, gitignored, NEVER print):
- `KEEPER_PRIVATE_KEY` (relay gas only), `KEEPER_EXECUTE=1` (live gate), `NXR_API_KEY`, `NXR_API_URL`, `ORACLE_RPC_URL`, `HEARTBEAT_FILE`.

Verify prereqs:
```sh
cast chain-id --rpc-url chapel                 # -> 97
cast balance $DEPLOYER_ADDR --rpc-url chapel   # gas present
cast balance 0xc4B4635B76ed49A7239291F6fbB33455D059a5B9 --rpc-url chapel  # relay gas present
test -f dex/research/stable-core/out/spline_shared_grid.json && echo presets-present
```

---

## 2. Values that MUST match the last deploy (carry-over, do not change)

Fixed addresses (KEPT across redeploy):
| item | address |
|---|---|
| ExternalOracle (kept) | `0xD91712c9F4037D0010041691Df191AB45994F2bF` |
| Oracle's AccessControl (OLD_AC) | `0x626eb915d4a4136F7c00352A54378d3A322488da` |
| Faucet (kept) | `0x6a901982CE6cD2561F677217e012A33b8a88EF27` |
| Dedicated relay pusher | `0xc4B4635B76ed49A7239291F6fbB33455D059a5B9` |
| WNATIVE sentinel | `0x000000000000000000000000000000000000CAFE` |
| USDC_FEED id | `0xdacab87341ef44905f4cfdb16cbfbd61ad65accd449f2df15ae6fb26f53ba17d` |

Mock tokens (KEPT, `ChapelSeedAmounts.sol` / `ChapelEnableSwaps` constants):
USDC `0x6dF80a290E0585dad752c25f2808E83b5624290d` (base, both pools), USDT `0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64`, USD1 `0xC28bE4D407096E771F932c202F13D866B4d6BA07`, USDE `0xebF751546832ec77a039083E9FDd8158B21c0172`, FDUSD `0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc`, BTCB `0xd719319e853670ac938e426fbdB70CFdb34c11Fa`, ETH `0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189`, WBNB `0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D`, CAKE `0xa7E62dd82789346bEb48a80227B5d926c6403400`, XAUT `0xd384aC4696FA230c9049F6534Fc35aC3af586073`.

Pool composition (unchanged; USDG in SSoT stable list is SKIPPED, no Chapel mock -> 5 stables only):
- Stable pool base USDC: [USDC, USDT, USD1, USDE, FDUSD]
- Volatile pool base USDC: [USDC, USDT, BTCB, ETH, WBNB, CAKE, XAUT]

Global constants (unchanged):
- GAMMA = 20000 (2x inventory skew), VEGA = 10000 (1x)
- FeeParams: protoShare = 20, flashFeePbps = 100
- decimals = 18
- maxFee: stable 2000, volatile 10000
- haircutSuppressor: 0 iff kappaCovBps > 0 (coverage-walled), else 10000

RiskConfig triplet (unchanged; all decayStartRatioBps=5000, coverageMin=5000, coverageMax=20000, flags = SWAP_ENABLED | LIABILITY_SWAP_ENABLED):
| template | applies to | kappaCovBps | depthAmplifier |
|---|---|---|---|
| base | USDC numeraire (both pools) | 0 (never walled) | 10000 |
| stableSpoke | non-USDC stables | 100 (wall ON) | 0 (no subsidy) |
| volatile | volatile spokes | 0 | 10000 |

Per-asset carry-over (minFee PBPS, minDisp, maxDisp, refBand bps) match `ChapelEnableSwaps._assetParams`:

STABLE pool:
| asset | minFee | minDisp | maxDisp | refBand | risk template | kappa | haircut |
|---|---|---|---|---|---|---|---|
| USDC (base) | 50 | 200 | 2000 | 0 | base | 0 | 10000 |
| USDT | 50 | 600 | 6000 | 100 | spoke | 100 | 0 |
| USD1 | 50 | 500 | 5000 | 100 | spoke | 100 | 0 |
| USDE | 75 | 800 | 5000 | 100 | spoke | 100 | 0 |
| FDUSD | 100 | 1000 | 8000 | 100 | spoke | 100 | 0 |

VOLATILE pool (all minFee 1000, minDisp 50000, maxDisp 500000, kappa 0, haircut 10000):
| asset | refBand | ref feed / oracle |
|---|---|---|
| USDC (base) | 0 | none |
| USDT | 100 | USDC_FEED / REF_ORACLE |
| BTCB | 0 | none |
| ETH | 0 | none |
| WBNB | 0 | none |
| CAKE | 0 | none |
| XAUT | 200 | XAUT_REF_FEED_ID / XAUT_REF_ORACLE (independent XAUT/USDC mark, NOT USDC_FEED) |

Ref wiring rule (`_oracleCfg`): non-USDC asset with refBand != 0 gets refPrimary = REF_ORACLE (XAUT: XAUT_REF_ORACLE), refFeedId = USDC_FEED (XAUT: XAUT_REF_FEED_ID). USDC self-ref suppressed (refBand 0). XAUT MUST use the independent XAUT/USDC mark; comparing tokenized gold to the unit USDC feed halts permanently.

Risk fences (`_fences`, unchanged; all: maxDeltaBps=2500, haircutHardMax=10000, gammaHardMin=5000, gammaHardMax=40000, vegaHardMin=5000):
| band | applies to | minFeeHardMin | minFeeHardMax | maxFeeHardMax | vegaHardMax |
|---|---|---|---|---|---|
| tight | all stable + vol USDC/USDT | 50 | 2000 | 10000 | 20000 |
| wide | vol BTCB/ETH/WBNB/CAKE/XAUT | 100 | 20000 | 50000 | 30000 |

Note: the live-patch scripts (`ChapelApplyStableParams`, `ChapelSetRiskFences`) loosened stable minFeeHardMin -> 25. This reseed uses 50 per `_fences`. Keep 50 unless owner re-confirms 25.

Keeper push cadence (unchanged, `oracle.chapel.toml`):
- Stables (idx 0-4): theta_bps 0.25, heartbeat_s 1800, ttl 3600 (=2x hb).
- Volatiles (idx 5-9): theta_bps 5.0, heartbeat_s 300, ttl 600.
- poll_interval_ms 5, mark_max_age_ms 500.

Feed maxDeviation floors (on-chain, addFeed): stable 50 bps, volatile 100 bps. Feed ttl: stable 7200, volatile 600 (both > maxRelayLagSecs 120).

---

## 3. NEW since last deploy (migration callouts, read before executing)

1. `setCurve` is a NEW governance action (`IAdmin.setCurve(pool, presetId, interior[], wQ[], dispRef, flags)`). Installs a preset into the per-pool curve table `PoolStorage.curves[presetId]`. Pre-seal only; post-seal -> timelocked `requestSetCurve`/`executeSetCurve`.
2. `addAsset` profile arg is now `presetId` (uint16), NOT inline knots/weights. Asset -> curve via `Asset.presetId`. `presetId = 0` = no-shape sentinel.
3. Multiple presets per pool: last deploy installed ONE preset per pool (stable=2, vol=1) with a LINEAR PLACEHOLDER ramp. This redeploy installs one fitted preset per distinct (regime, wall, dispRef) used in the pool, then each asset references the correct id.
4. Fitted weights replace the placeholder. `_curve()` placeholder (`wQ[i]=(i-4)*step`, step 12.5e9/125e9, interior [2000,4000,6000,8000]) is NOT the fitted quartic. Fitted arrays come from `spline_shared_grid.json` (section 6 extraction recipe).
5. `FLAG_REQUIRES_WALL = 1` (`NUQuartic.sol:27`): the `hyper` preset carries it. `PoolAdmin.validatePresetAssign` reverts if a `hyper`-flagged preset is assigned to an asset with `kappaCovBps == 0`. Only coverage-walled spokes (stable spokes, kappa=100) may take `hyper`. Base USDC and all volatile legs (kappa=0) are barred from `hyper`.
6. `requestUpdateProfile` signature is now `(pool, token, presetId, minDispersion, maxDispersion)`. Repoints preset + sets dispersion band; no per-asset knot arrays.
7. `testnet-asset-params.json` `sharedLiquidityProfile` still carries the OLD Hermite shape `weights=[50,100,50] knots=[-50,-12,12,50]`. It is SUPERSEDED by the preset table and must not be used. Update the JSON schema to preset-per-asset (open item, section 15).

---

## 4. Contract deploy sequence

Fresh singletons; oracle + faucet + tokens KEPT. Single broadcast (`ChapelEnableSwaps.run`, order per `ChapelEnableSwaps.s.sol:67-73`):
1. `AccessControl(deployer, deployer)` (new AC, owner+treasury=deployer; enables Steward-lite `isGuardian`/`isRiskSteward`).
2. `Admin(ac)`
3. `Flash()`
4. `PoolAux(ac, admin, flash)`
5. `Pool(ac, admin, flash, poolAux)` (clone impl)
6. `PoolFactory(poolImpl, deployer, ac)`

Then per pool (section 5-9) inside the same broadcast, stable first then volatile.

STOP - do NOT broadcast the script as-shipped. `ChapelEnableSwaps` currently: (a) builds a LINEAR-ramp placeholder curve in `_curve` (`wQ[i]=(i-4)*step`, lines 190-206), (b) installs ONE preset per pool (`presetId = stable?2:1`, line 135) with `flags=0` (line 137), (c) assigns that single presetId to EVERY asset (line 146). Running it deploys WRONG pricing with NO revert. The script MUST first be patched per section 6: multi-`setCurve` for presets {10,11,12} stable / {20,21,22,23} vol, `flags=1` ONLY on hyper preset 11, and per-asset `presetId` selection in the `addAsset` loop. Complete the section 4a pre-broadcast checks first.

Command (only AFTER the section 6 preset patch AND the section 4a pre-broadcast checks pass):
```sh
cd dex/evm
forge script script/ChapelEnableSwaps.s.sol:ChapelEnableSwaps --sig run \
  --rpc-url chapel --broadcast --with-gas-price 100000000
```
Runtime pool addresses are logged (`stablePool`, `volatilePool`) and persisted via `_persist`. Record them; the keeper and post-seal patches need them.

ORACLE: default path KEEPS `0xD917...F2bF` on OLD_AC (its `addFeed` entries and pusher grants already exist). Only if the oracle is redeployed fresh, run section 5 first.

### 4a. Pre-broadcast checks (STOP on any revert; these gate the whole broadcast)

The section 14 checks are POST-deploy. These four must pass BEFORE the broadcast, because a failure here reverts the entire single-broadcast reseed (or deploys wrong pricing). Run against the KEPT oracle `0xD917...F2bF` and the ref oracles named in env:
```sh
# 1. Incumbent oracle exposes k-of-n hardening (else the kept-oracle path is INVALID).
cast call $ORACLE "signerThreshold()(uint8)" --rpc-url chapel   # MUST be 2
cast call $ORACLE "signerCount()(uint8)"     --rpc-url chapel   # MUST be 3
#    A revert on either selector => 0xD917 predates the Ostium k-of-n / batchPushSigned hardening.
#    It CANNOT accept 2-of-3 signed pushes. The fresh-oracle path (section 5) is then MANDATORY, not optional.

# 2. Ref-oracle feeds exist (addAsset -> PoolAdmin.validateOracleConfig calls getFeed(refFeedId) on the ref
#    oracle, PoolAdmin.sol:110). A missing ref feed reverts the FIRST refBand!=0 asset (USDT) and unwinds the
#    ENTIRE broadcast. On the default "keep primary" path section 5 is SKIPPED, so fresh ref oracles would have
#    no feeds -> populate them first.
cast call $REF_ORACLE      "getFeed(bytes32)" $USDC_FEED --rpc-url chapel        # MUST NOT revert
cast call $XAUT_REF_ORACLE "getFeed(bytes32)" $XAUT_REF_FEED_ID --rpc-url chapel # MUST NOT revert

# 3. Primary feeds exist + fresh: getMark on all 10 primary feeds (getFeed exists AND within ttl).
#    validateOracleConfig also getFeed(cfg.feedId) on the primary for EVERY asset (PoolAdmin.sol:102).
for f in $USDC_FEED $USDT_FEED $USD1_FEED $USDE_FEED $FDUSD_FEED $BTCB_FEED $ETH_FEED $WBNB_FEED $CAKE_FEED $XAUT_FEED; do
  cast call $ORACLE "getMark(bytes32)(uint256,uint256)" $f --rpc-url chapel      # MUST NOT revert (stale => revert)
done
```
Any revert -> STOP. Fix the feeds (populate ref/primary, refresh stale marks) or take the fresh-oracle path (section 5). Only then broadcast section 4.

---

## 5. Oracle (only if deploying a FRESH ExternalOracle; else skip)

Constructor (`ExternalOracle.sol:113`, installs the signer set ATOMICALLY, no single-signer state):
```
new ExternalOracle(ac, maxRelayLagSecs = 120, [ORACLE_SIGNER_0, ORACLE_SIGNER_1, ORACLE_SIGNER_2], signerThreshold = 2)
```
Constructor invariants (revert otherwise): 3 <= count <= 6, unique non-zero signers, 2 <= threshold <= count, 0 < maxRelayLagSecs < 65535. Deploy REF_ORACLE and XAUT_REF_ORACLE the same way, each with its own 3 signers and a distinct AC owner.

`addFeed(base, quote, price, sigmaSample, confidence, maxDeviation, ttl)` per ticker, feedId = keccak256(abi.encodePacked(base, quote)):
- Stables (idx 0-4): maxDeviation = 50 bps, ttl = 7200. USDC/USDC price MUST = 1e18.
- Volatiles (idx 5-9): maxDeviation = 100 bps, ttl = 600.
- maxDeviation MANDATORY non-zero and <= 65000; ttl MUST > maxRelayLagSecs (120). Seed confidence 25. Seed sigma: volatiles 10000 is fine; for STABLES seed a smaller sigma (a few-bp peg-realistic value, not 10000). The stored seed sigma feeds the Layer-2 band `allowed ~= 50 + 6*sigma*sqrt(dtSource/1800)`; at 10000 PBPS a full 1800s stable heartbeat gap admits ~650 bps on the first post-gap push. Not a hard blocker (cold start is floor-tight at dt=0, real sigma lands after push 1, Layer-4 refBand 100 halts cumulative drift), but a smaller stable seed tightens early pushes.

Feed idx order (must match `oracle.chapel.toml`): 0 USDC-USDC, 1 USDT-USDC, 2 USD1-USDC, 3 USDE-USDC, 4 FDUSD-USDC, 5 BTCB, 6 ETH, 7 WBNB, 8 CAKE, 9 XAUT. feedIds pinned in the toml.

---

## 6. Per-pool preset install (setCurve, bootstrap, NEW STEP)

setCurve MUST run after `createPool` and BEFORE the first `addAsset` referencing that presetId, and before `sealBootstrap`.

### 6a. Recommended regime -> preset map (confirm with owner)

STABLE pool:
| asset | regime | wall W (bp) | dispRef | presetId | FLAG_REQUIRES_WALL | notes |
|---|---|---|---|---|---|---|
| USDC (base) | plateau | 1 | 100 | 10 | no | base kappa=0 bars hyper; tightest legal un-walled peg |
| USDT | hyper | 0.5 | 50 | 11 | YES | Tier-1 stable, walled (kappa=100): needle-at-mark |
| USD1 | plateau | 1 | 100 | 10 | no | youngest peg; tighten -> hyper W0.5 post-confidence |
| USDE | plateau | 2 | 200 | 12 | no | 477 bp depeg tail, widest stable shape |
| FDUSD | plateau | 1 | 100 | 10 | no | soft-peg, mid flow |

VOLATILE pool (all kappa=0, so NO hyper allowed):
| asset | regime | wall W (bp) | dispRef | presetId | notes |
|---|---|---|---|---|---|
| USDC (base) | plateau | 1 | 100 | 20 | numeraire |
| USDT | plateau | 1 | 100 | 20 | stable leg, kappa=0 -> plateau not hyper |
| BTCB | lepto | 5 | 500 | 21 | crypto major, fat wing; minFee 10bp = 2*theta satisfies lepto gate |
| ETH | lepto | 5 | 500 | 21 | |
| WBNB | lepto | 5 | 500 | 21 | |
| CAKE | platy | 5 | 500 | 22 | mid-cap alt, low conviction (confirm platy vs lepto) |
| XAUT | meso | 2 | 200 | 23 | tokenized gold, calm; symmetric (mark carries no skew) |

Distinct presets to install: stable {10 plateau W1, 11 hyper W0.5 (walled), 12 plateau W2}; volatile {20 plateau W1, 21 lepto W5, 22 platy W5, 23 meso W2}. presetId space is per-pool. Assets sharing regime+wall+dispRef share one presetId (different minDisp/maxDisp per asset is fine; dispRef scales the curve, `_scaleY`).

CONFIRM the volatile dispRef change before sealing: the last-live deploy kept preset 1 at dispRef=1000 (`ChapelWidenVolatileDisp`) over disp band 50k/500k. This map installs regime-default dispRef (plateau 100, meso 200, lepto/platy 500) over the SAME band. Since quotes scale y by disp/dispRef (`_scaleY`), a lower dispRef at the same band is a ~2x steeper curve (lepto 1000 -> 500). Intended (regime table is SSoT), but verify against the sim BEFORE `sealBootstrap`; post-seal, curve/dispRef changes are timelocked-only (`requestSetCurve`/`requestUpdateProfile`, ~5m LOW).

Portable whitelist check (only these ship; assert before assigning):
- W0.5 available: hyper, plateau, lepto
- W1 available: hyper, flat, plateau, lepto
- W2 available: all 9
- W5 available: all 9 (+ pin_M variants, research only)

All recommended assignments are inside the whitelist.

### 6b. Extraction recipe (JSON -> setCurve args)

From `spline_shared_grid.json`, for wall `W<k>` and regime `<r>`:
- `interior[]` = `walls.W<k>.shared.interiorX` (already in domain units [0,10000]). Lengths: W0.5/W1/W5 = 9 interior knots; W2 = 13 interior knots.
- `wQ[]` = `[round(w_i * 1e9) for w_i in walls.W<k>.presets.<r>.w]`. The JSON `w` values are already in PBPS (W=0.5bp -> +/-50, W=5bp -> +/-500). Q = 1e9. Lengths: W0.5/W1/W5 = 14 control points; W2 = 18.
- `dispRef` = regime default (hyper 50, flat 100, plateau 100, meso 200, lepto 500, platy 500). Matches 6a.
- `flags` = 1 (FLAG_REQUIRES_WALL) for hyper, else 0.
- Assert `presets.<r>.portable == true` and `presets.<r>.ok == true` before use.

Generator (writes a broadcast-ready args file; run per preset):
The bare `portable`/`ok` asserts are not enough: `NUQuartic._validate` also reverts on a non-monotone `wQ` (`wQ[i] < wQ[i-1]`) and on a flat curve (`wQ[0] == wQ[n-1]`), and `PoolAdmin.validatePresetAssign` reverts unless `SC.PBPS(1e6) + wQ[0]_pbps * maxDisp / dispRef > 0` (the min-offset at max dispersion must not push the quote non-positive). Assert all three, using the LARGEST `maxDisp` assigned to each preset (most-negative offset = binding case):
```sh
python3 - <<'PY'
import json
d=json.load(open('dex/research/stable-core/out/spline_shared_grid.json'))
PBPS=1_000_000  # SC.PBPS
def emit(wall, regime, presetId, flags, dispRef, maxDisp):
    w=d['walls'][wall]; p=w['presets'][regime]
    assert p['portable'] and p['ok'], (wall,regime,p.get('why'))
    wv=p['w']
    # NUQuartic._validate: nondecreasing (monotone curve)
    assert all(wv[i] >= wv[i-1] for i in range(1,len(wv))), (wall,regime,'non-monotone wQ')
    # NUQuartic._validate: not flat (else no price discovery)
    assert wv[0] != wv[-1], (wall,regime,'flat wQ')
    # validatePresetAssign: min offset at max dispersion must keep quote > 0
    assert PBPS + wv[0]*maxDisp/dispRef > 0, (wall,regime,f'wQ[0]={wv[0]} bricks addAsset @maxDisp={maxDisp} dispRef={dispRef}')
    interior=w['shared']['interiorX']
    wQ=[round(x*1_000_000_000) for x in wv]
    print(f"# presetId {presetId}  {regime}@{wall}  ncp={len(wQ)} knots={len(interior)}  dispRef={dispRef}")
    print(f"interior={interior}")
    print(f"wQ={wQ}")
    print(f"flags={flags}\n")
# stable pool  (maxDisp = largest among assets on the preset: 10<-{USDC 2000,USD1 5000,FDUSD 8000}=8000; 11<-USDT 6000; 12<-USDE 5000)
emit('W1','plateau',10,0,100,8000); emit('W0_5','hyper',11,1,50,6000); emit('W2','plateau',12,0,200,5000)
# volatile pool (all assets on each preset use maxDisp 500000)
emit('W1','plateau',20,0,100,500000); emit('W5','lepto',21,0,500,500000); emit('W5','platy',22,0,500,500000); emit('W2','meso',23,0,200,500000)
PY
```
Substitute these arrays into the deploy path: either patch `ChapelEnableSwaps._curve` to a per-presetId lookup, or issue explicit `admin.setCurve` calls per presetId before the asset loop. Do NOT ship the linear placeholder.

setCurve call shape:
```
admin.setCurve(pool, presetId, interior, wQ, dispRef, flags)   // flags=1 only for hyper preset 11
```

---

## 7. Per-ticker addAsset + setAssetParams + risk

Per pool, after all presets for that pool are installed, loop tokens in composition order:

1. `admin.addAsset(pool, token, oracleCfg, riskCfg, presetId, minFeePbps, 18, minDispersion, maxDispersion, gamma=20000, vega=10000)`
   - `presetId` from 6a (NOT inline knots).
   - `oracleCfg` from `_oracleCfg` (refFeedId/refPrimary/refBandBps per section 2 ref rule).
   - `riskCfg` = base for USDC, stableSpoke for non-USDC stables, volatile for volatile spokes (section 2 triplet).
   - minFee/minDisp/maxDisp per section 2 carry-over table.
   - Wall gate: if presetId has FLAG_REQUIRES_WALL, riskCfg.kappaCovBps MUST be > 0 or the call reverts. (Only USDT preset 11.)

2. `admin.setAssetParams(pool, token, minLiquidity=0, minFeePbps, maxFeePbps, gamma=20000, vega=10000, haircutSuppressor, 0, 0)`
   - maxFeePbps: stable 2000, volatile 10000 (clamps initAsset default of BPS).
   - haircutSuppressor: 0 if kappaCovBps > 0 (walled spokes), else 10000. Coverage-walled assets MUST have haircut 0 (coverage-wall-bypass fix).

3. `admin.setRiskFences(pool, token, fences)` per section 2 fences table.

---

## 8. Risk fences

Applied inside the asset loop (step 7.3). One `setRiskFences` per token. Values per section 2 (tight vs wide band). These are the Steward-lite hard bounds a risk steward can never cross; maxDeltaBps=2500 caps any single steward risk-up move at +25%.

---

## 9. Seal bootstrap

After all assets added and parametrized in a pool:
```
admin.sealBootstrap(pool)
```
GOV-03: closes direct `addAsset`/`setCurve`/`setAssetParams`. Post-seal, all curve/profile/oracle changes go through timelocked twins (Chapel: LOW ~5m `requestSetCurve`/`requestUpdateProfile`, BASE ~15m `requestOracleUpdate`, HIGH ~30m treasury). Seal each pool.

Seal ordering safety: `executeSetCurve` MUST land before any `executeUpdateProfile` that repoints an asset to that preset.

---

## 10. Enable swaps

There is no separate enable call. Swaps are gated by RiskConfig `flags = SWAP_ENABLED_BIT | LIABILITY_SWAP_ENABLED_BIT`, baked at `addAsset` (section 2 triplet, all three templates carry both bits). Confirm no pause bit is set:
- Feed-level: `ExternalOracle` feeds start unpaused (flags 0); guardian `pauseFeed` sets bit0.
- Asset/pool-level: no PROTOCOL_PAUSED / asset-pause bit set at bootstrap.

Verify (section 14) that a quote returns before announcing live.

---

## 11. Seed liquidity

Per token, in `_seedPool`: mint mocks if short, `approve(pool, max)`, `pool.deposit(token, amount)`. Amounts from `deploy/chapel-seed-amounts.json` (generate via `keepers/bots/scripts/gen-chapel-seed-amounts.ts`, live-mark sized). Stable-leg fallback = `SEED_USDC` (default 50_000e18). Non-stable legs REVERT if the JSON is absent, so generate it first:
```sh
bun keepers/bots/scripts/gen-chapel-seed-amounts.ts   # writes deploy/chapel-seed-amounts.json
```
Seeding runs inside `_createPool` after `sealBootstrap`.

---

## 12. Wire and start the keeper (2-of-3 signed push + relative-deviation gate)

### 12a. Pin the signer quorum (BLOCKER: keeper is fail-closed until pinned)

`keepers/oracle.chapel.toml` currently has NO `signers` / `signer_threshold`. The daemon will not arm (`chapel_config_is_fail_closed_until_signers_are_pinned`). Add, at top level:
```toml
signers = ["<ORACLE_SIGNER_0>", "<ORACLE_SIGNER_1>", "<ORACLE_SIGNER_2>"]  # 3 NXR attester PUBLIC addrs
signer_threshold = 2
# optional multi-relay HA:
# keeper_set = ["<relay_addr_0>", "..."]
# relay_fallback_ms = <n>
# relay_jitter_ms = <n>
```
These MUST be the public addresses of the on-chain signer set. Startup reconciles against the chain and fails loud on any missing/extra signer. Private keys never appear here (NXR-side `NXR_SIGNER_KEY`, keeper-side `KEEPER_PRIVATE_KEY`).

### 12b. Signing + push model (reference)

- Quorum: 2-of-3 ECDSA over EIP-712 `BatchQuote(bytes32 blobHash)`, domain "BTR ExternalOracle" v"1". NX-Rates `/v1/quote/signed` self-signs and fans to peers `/v1/quote/cosign`; a peer countersigns only after re-validating each record against its own live view (px tolerance, sourceTs skew, sigma/CI guards). Below quorum -> 503 fail-closed.
- On-chain `batchPushSigned(blob, sigs)`: k concatenated 65B sigs, each recovered address strictly increasing (distinctness) and in the signer registry; k >= signerThreshold; all verified before any state write. Relayer `msg.sender` unpermissioned.
- Cadence: poll 5ms; push when cold-start OR |delta| > theta OR heartbeat elapsed OR CI spike. All-or-nothing blob, one push per block on-chain. Soft-leader `keeper_set[H(sourceTs) % n]` relays; standbys arm jittered fallback.
- Key handling: signer grant / threshold DECREASE are timelocked (~15m Chapel); revoke / threshold RAISE are instant. Revoking below threshold deliberately HALTS pushing (fail-safe).

### 12c. Build and deploy (in-cluster, never Mac)

```sh
# BuildKit Job in nxrates k0s -> internal registry (amd64), NEVER Mac/podman:
#   builds 10.100.56.218/btr-keeper:<sha>
./keepers/scripts/apply-chapel-oracle-k8s.sh <sha>
```
Set the new oracle/pool addresses if the oracle was redeployed. Ensure `KEEPER_EXECUTE=1` and secrets present in the cluster (`.env.chapel`).

---

## 13. Per-asset deviation thresholds (relative-deviation gate)

Four distinct layers. Layers 1-2 are on-chain accept bands (a push exceeding them REVERTS, last good mark survives). Layer 3 is the off-chain push trigger. Layer 4 is the cumulative depeg halt vs an independent reference.

Layer 1: feed-slot `maxDeviation` floor (on-chain, addFeed, mandatory > 0): stables 50 bps, volatiles 100 bps. maxDeviation is a per-FEED property, not per-pool-asset: the volatile pool's USDC and USDT legs reference the SHARED stable feeds (`USDC_FEED`, `keccak(USDT,USDC)`) already added at 50, so their on-chain maxDeviation is 50 (tighter, safe). The 100-bps floor applies only to the volatile-unique feeds BTCB/ETH/WBNB/CAKE/XAUT.

Layer 2: volatility-adaptive per-push band (`_checkDeviation`, `ExternalOracle.sol:444`):
```
devBps  = |mark - prevMark| * 10000 / prevMark
allowed = maxDeviation + (DEV_SIGMA_Z * prevSigmaPbps * sqrt(dtSource * 1e6 / SIGMA_INTERVAL_S)) / 1e5
allowed = min(allowed, MAX_DEV_THRESHOLD)   # 65000 bps (650%)
revert if devBps > allowed
```
DEV_SIGMA_Z = 6, SIGMA_INTERVAL_S = 1800 (30-min Parkinson window). sigma = STORED prior sigmaEma (never the incoming push's own sigma; prevents self-widening). dtSource = attested source-time delta in seconds (chain-agnostic). First push (prevSourceTs = 0) -> band = floor exactly. Plus: monotonic sourceTs (nonce, < 2^48), future-skew reject (sourceTs <= (now+5s)*1000), freshness floor (sourceTs >= (now - maxRelayLagSecs)*1000), one-per-block cooldown.

Layer 3: keeper theta trigger (off-chain, when to push, `oracle.chapel.toml`): stables 0.25 bps, volatiles 5 bps. Plus mark_max_age_ms 500 staleness and 5s future-skew mirror.

Layer 4: pool depeg refBand (cumulative bound vs independent refPrimary, halts swaps; `OracleConfig.refBandBps`):
| asset | refBand bps | reference |
|---|---|---|
| USDC (both pools) | 0 | self (none) |
| USDT (stable) | 100 | USDC ref |
| USD1 | 100 | USDC ref |
| USDE | 100 | USDC ref |
| FDUSD | 100 | USDC ref |
| XAUT | 200 | independent XAUT/USDC oracle |
| USDT (volatile) | 100 | USDC ref |
| BTCB/ETH/WBNB/CAKE | 0 | none |

Note: `RISK_PARAMS_TESTNET.md` proposes wider USD1 150 / USDe 200. LIVE SSoT (`testnet-asset-params.json` + scripts) uses flat 100. Carry the LIVE 100 unless owner reconciles the SSoT first.

Guardian may only tighten on-chain: `narrowMaxDeviation` (tighten-only), `pauseFeed`. Owner widens via `updateFeed`.

---

## 14. Post-deploy verification checklist

Run all before announcing live. Substitute recorded pool/token addresses.

Feeds fresh and readable:
```sh
# each feed within ttl (sourceTs recent); a stale read reverts
cast call $ORACLE "getMark(bytes32)(uint256,uint256)" $USDC_FEED --rpc-url chapel
# repeat per feedId (from oracle.chapel.toml); confirm non-revert + sane price
```

Deviation gate live:
```sh
# feed maxDeviation set (non-zero): stable 50, vol 100
cast call $ORACLE "feeds(bytes32)" $USDT_USDC_FEED --rpc-url chapel   # inspect maxDeviation slot
# negative test (dry-run, do NOT broadcast): a mark > allowed band must revert on batchPushSigned
```

Signer quorum armed:
```sh
cast call $ORACLE "signerThreshold()(uint8)" --rpc-url chapel   # -> 2
cast call $ORACLE "signerCount()(uint8)" --rpc-url chapel        # -> 3
# each ORACLE_SIGNER_i in signer registry; keeper startup log shows on-chain == pin-list
```

Swaps quote:
```sh
# expect a non-zero out for a small in on each pool
cast call $STABLE_POOL "quoteSwap(address,address,uint256)(uint256)" $USDC $USDT 1000000000000000000 --rpc-url chapel
cast call $VOL_POOL "quoteSwap(address,address,uint256)(uint256)" $USDC $BTCB 1000000000000000000 --rpc-url chapel
```

Wall-gated presets have kappa > 0:
```sh
# USDT stable (preset 11, FLAG_REQUIRES_WALL) MUST report kappaCovBps > 0
cast call $STABLE_POOL "riskConfig(address)" $USDT --rpc-url chapel   # kappaCovBps = 100
# base USDC + all volatile legs: kappaCovBps = 0 AND presetId NOT flagged
# addAsset already reverts on a hyper preset over a kappa=0 asset; confirm none slipped
```

Preset install sanity:
```sh
# each referenced presetId has a non-empty curve; presetId=0 assigned to no asset
cast call $STABLE_POOL "presetOf(address)(uint16)" $USDT --rpc-url chapel   # -> 11
cast call $VOL_POOL "presetOf(address)(uint16)" $BTCB --rpc-url chapel      # -> 21
```

Bootstrap sealed:
```sh
cast call $ADMIN "bootstrapSealed(address)(bool)" $STABLE_POOL --rpc-url chapel   # -> true
cast call $ADMIN "bootstrapSealed(address)(bool)" $VOL_POOL --rpc-url chapel      # -> true
```

Liquidity seeded: each token balance in its pool > 0. Keeper pushing: heartbeat file advancing, recent `batchPushSigned` txs from the relay address, no revert storm.

---

## 15. Open reconcile items (resolve before or at deploy)

1. `oracle.chapel.toml` signers/threshold EMPTY -> keeper fail-closed. Pin top-level `signers = [<3 public NXR attester addrs>]` + `signer_threshold = 2` before live (section 12a). BLOCKER.
2. Placeholder linear `wQ` in `ChapelEnableSwaps._curve` (lines 190-206) + single-preset install (`presetId = stable?2:1`, one id assigned to every asset, `flags = 0`) -> replace with per-`presetId` fitted lookup, multi-`setCurve` for {10,11,12} stable / {20,21,22,23} vol, `flags = 1` only on hyper preset 11, and per-asset `presetId` in the addAsset loop (section 6). BLOCKER for correct pricing; the section 4 baseline command as-shipped deploys wrong pricing with no revert.
3. `testnet-asset-params.json.sharedLiquidityProfile` still old Hermite `[50,100,50]` shape -> migrate schema to preset-per-asset; do not read the old field.
4. refBand script-vs-MD mismatch (scripts flat 100 vs `RISK_PARAMS_TESTNET.md` historical graded USD1 150 / USDe 200) -> hold LIVE flat 100 for all non-USDC stables + XAUT 200; ensure `testnet-asset-params.json` SSoT is actually flat-100, not the graded schedule. Runbook carries LIVE 100.
5. USD1 regime (plateau W1 now vs hyper W0.5 later) and CAKE (platy vs lepto) -> owner confirm.
6. `ChapelWireYield` MockVenus vUSDC/vUSDT NOT registered in the real Venus Unitroller `0x94d1...b77D`; `claimVenus` reverts until swapped for real Chapel markets. Yield wiring is optional and can follow the core reseed.
7. Incumbent-oracle k-of-n capability + ref-oracle feeds UNVERIFIED on the default keep-`0xD917` path. Run the section 4a pre-broadcast checks: `signerThreshold()==2` / `signerCount()==3` (revert => predates hardening => fresh-oracle path section 5 MANDATORY), `getFeed` non-revert on both ref oracles (else the first refBand!=0 asset (USDT) reverts the whole broadcast), `getMark` fresh on all 10 primary feeds. BLOCKER if unmet.
8. Stable `minFeeHardMin`: carry the reseed `_fences` value 50, NOT the live-patch 25 (section 2 note), unless a price war needs the 1-PBPS lever.
```
