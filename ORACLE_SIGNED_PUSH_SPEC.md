# Oracle signed-push spec (SoT)

Status: **reference implementation.** Money path. Do not deploy to mainnet before independent review, human sign-off, and NXR integration test.

Single source of truth for the byte-exact contract between: NXR signer (Rust, deferred), keeper relay (Rust), `ExternalOracle.sol` verifier (this repo), TS SDK (front/back). All four MUST agree byte-for-byte or signatures fail closed.

## Why
- Move price authority to **NXR-signed quotes** (ECDSA/EIP-712). Keepers become stateless relays; any relay lands the freshest signed quote. Decouples price-authority (NXR key) from liveness (N relays).
- **Gas**: drop dead `Pushed` event (-2524/feed), store NXR-signed σ directly (drop on-chain σ-EMA, -800/feed), packed calldata 24 B/feed vs ABI 128 B/feed. Target -31% vs legacy `batchPush`, and ~half Scribe `poke` (measured 60,700 @ bar=1).
- ECDSA + EIP-712, <= 6 signers. NO Schnorr (Scribe's aggregation is O(N) on-chain via per-signer pubkey SLOADs ~5,100/signer > independent ECDSA ~4,040/signer, and needs an off-chain nonce round). Scheme kept swappable (opaque `bytes sig`) if a large fixed signer set ever justifies Schnorr.

## Storage (1 slot/feed, unchanged layout + sourceTs in free bits)
```
lastPriceB64[0:64) | sigmaEma[64:96) | updatedAt[96:128) | ttl[128:144)
| confidence[144:160) | tau[160:176) | tauSigma[176:192) | maxDeviation[192:208)
| sourceTs[208:256)   <-- NEW: uint48 ms since epoch, monotonic replay/dedup guard
```
`updatedAt` = on-chain block.timestamp (staleness/σ√τ premium + deviation band). `sourceTs` = NXR signed timestamp (ms). They serve different roles; both stored.

## Packed calldata record (24 B/feed, big-endian, top-aligned in the loaded word)
```
byte  0- 1  idx        uint16   index into feedIds[] (append-only, stable). resolves to bytes32 feedId
byte  2- 9  priceB64   uint64   B64 mark
byte 10-13  sigma      uint32   NXR-signed σ (PBPS). stored DIRECTLY as sigmaEma (no on-chain EMA)
byte 14-15  confidence uint16   mark CI (bps)
byte 16-23  sourceTs   uint64   ms since epoch. MUST be < 2^48 (fits slot). strictly monotonic per feed
```
`blob` = concat of N records. `blob.length % 24 == 0`, N >= 1. Single push = 24-byte blob.

## Signature (EIP-712)
- Domain: name `"BTR ExternalOracle"`, version `"1"`, chainId, verifyingContract = oracle address (solady `EIP712`, fork-safe).
- `BATCH_TYPEHASH = keccak256("BatchQuote(bytes32 blobHash)")`.
- `blobHash = keccak256(blob)` — the exact packed calldata bytes (idx-based). Safe because feedIds is append-only (idx never remaps); a feed added between sign and land leaves lower indices unchanged.
- `structHash = keccak256(abi.encode(BATCH_TYPEHASH, blobHash))`.
- `digest = _hashTypedDataV4(structHash)`.
- `sigs` = k CONCATENATED 65-byte ECDSA signatures (`r||s||v`, fixed stride, no EIP-2098) over the SAME digest. `sigs.length % 65 == 0`, `k = sigs.length / 65 >= signerThreshold`.
- Each sig recovers via `ECDSA.recoverCalldata(digest, sigs[i*65:(i+1)*65])`; every recovered address must be a granted signer AND strictly greater than the previous one. Strictly-increasing recovered addresses = the distinctness check: rejects duplicates and unsorted input, so relays MUST sort sigs by recovered signer address ascending.
- NOTE: `recoverCalldata` does NOT reject a malleable `s`/`v` (~4 valid encodings per logical sig). Safe here because replay defense is the on-chain monotonic `sourceTs`, NEVER signature uniqueness. Do not add any state keyed on signature bytes.
- k signatures over the whole batch, all verified before any state write. Relay `msg.sender` is unpermissioned.

## Known tradeoffs
- **Permissionless-relay grief (F-2, LOW/MED)**: any address may relay. An attacker buffering older-but-still-valid signed blobs can race to land one first in a block; the honest fresher blob then reverts on the one-per-block guard that block. Bounded to ~1-block staleness, self-limiting (monotonic sourceTs; a given blob lands at most once), backstopped by the deviation band + `updatedAt` staleness premium. Inherent to the decoupled relay design. If observed on mainnet, add an optional allowlisted-relayer mode.
- **Compromised-signer ceiling (F-3, info)**: `_checkDeviation` lets the band grow with staleness up to `MAX_DEV_THRESHOLD` (650%). Keep keeper heartbeat << ttl so the band stays ≈ maxDeviation; monitor `updatedAt` gaps.
- **Legacy/signed σ-mix (LOW)**: a feed pushed via both paths mixes EMA (legacy) and direct (signed) σ semantics. Do not mix per feed; cut over atomically.
- **year-2106 uint32 `updatedAt` wrap (LOW, pre-existing)**: shared with the legacy path.

## On-chain checks per feed (fail-closed, all revert)
1. `feedIds[idx]` bounds check (OOB reverts). `prevAt != 0` (feed exists).
2. **Monotonic**: `sourceTs > prevSourceTs`, and `sourceTs < 2^48`. Replay of a landed batch fails (all sourceTs == stored).
3. **One per block**: `dt = block.timestamp - prevAt != 0` (else `CooldownActive`). Bounds per-block move to one band step; makes duplicate idx in a batch fail-closed.
4. **Deviation band (VOLATILITY-ADAPTIVE, SOURCE-time-driven per-push sanity cap)**: `devBps <= maxDeviation + Z·σ·√(dtSource/1800)` capped `MAX_DEV_THRESHOLD` (65_000), where `dtSource = (sourceTs - prevSourceTs)/1000` s of ATTESTED source time, `σ` is the STORED prior sigmaEma (PBPS — never the incoming push's own σ, which would let a signer widen its own band), `Z = 6`, and `1800` = NXR's 30-min Parkinson σ window. On-chain integer form: `allowed = maxDev + Z·σ_pbps·sqrt(dtSource·1e6/1800)/1e5`. The band scales with the ticker's OWN volatility and with √(elapsed source time) (Brownian): a high-vol ticker earns a wider per-push allowance, a stable a tighter one, for the same elapsed time. `maxDeviation` degrades to a microstructure/discretization FLOOR (deploy: 50 bps stables, 100 bps volatiles). Chain-agnostic: identical allowance on a 400ms and a 12s chain; a fast chain gets no extra cumulative walk. First signed push (`prevSourceTs == 0`) ⇒ `dtSource = 0` ⇒ band = the maxDeviation floor exactly (σ√dt term vanishes), no bootstrap widening. Per-push SANITY cap only; the CUMULATIVE bound on a compromised push quorum is the independent `refPrimary` band (below).
5. `b64To1e18(price) != 0`, `sigma <= MAX_SIGMA_PBPS`.
Store σ directly (no `updateSigmaEma`). No event emitted (observability = `getFeed()` state polling, per `collector/snapshot.ts`).

## Signer registry (k-of-n)
`mapping(address => bool) signers` + packed `uint8 signerThreshold`/`uint8 signerCount`. Construction atomically installs 3–`MAX_SIGNERS` (16) unique non-zero signers and requires `2 <= signerThreshold <= signerCount`; there is no single-signer deployment state. The cap is 16 rather than 6 because the contract is NOT upgradeable: raising it later costs an oracle redeploy + a timelocked `Admin.requestOracleUpdate/executeOracleUpdate` per pool asset + re-`addFeed`/re-seed of every feed, and at 6 a deployed oracle cannot express 5-of-8 at all (a 2-of-3 primary plus 3 distinct reference keys already fills 6 exactly). Growing an existing set is SEQUENTIAL — only one grant may be pending — so 3 → 8 signers is 5 consecutive `SIGNER_GOV_TIMELOCK` waits; install the full target set in the constructor on a fresh deploy instead. At most one signer addition can be pending: `requestSignerGrant` → 2-day timelock (shortened on testnet) → `executeSignerGrant`, with a 7-day execution grace; guardian or owner can cancel. This prevents a compromised owner from queue-farming many candidates. `revokeSigner` remains instant for guardian/owner. Threshold increases are immediate owner-only hardening; decreases use the same single-pending request/execute/cancel delay and can never go below two. Execution revalidates the live signer cap/count. Revoking below the threshold deliberately HALTS pushing (fail-safe compromise response); feeds go stale and the pool fail-closes.

## Feed config governance (tighten instant, loosen timelocked)
`addFeed` is owner-only. `updateFeed` is TIGHTEN-ONLY: it accepts `maxDeviation`/`ttl` less than or equal to the live values and reverts on any widening. Loosening either axis goes `requestFeedWiden` -> `SIGNER_GOV_TIMELOCK` (`BASE_TIMELOCK`, 15 min via `govDelay` on testnets) -> `executeFeedWiden`, and `cancelFeedWiden` is open to guardian OR owner. The pending record snapshots the config as of the request; if the live config changes during the delay (a guardian `narrowMaxDeviation`, an owner `updateFeed`) the payload is stale and `executeFeedWiden` reverts, so a tighten is never silently reverted by an older widen. Rationale: widening the per-push band is a single-transaction drain enabler and widening `ttl` lets a stale mark keep quoting, so the loosening direction is the one that needs the delay and the veto. Tightening stays instant because a fail-safe that waits is not a fail-safe. Operational consequence: a stranded feed (seeded off market, first push outside the bare `maxDeviation` floor) can no longer be rescued by an instant band widen. Seed at market, within 5 minutes of broadcast.

## Independent reference feed (the cumulative bound)
`OracleConfig.refPrimary` (per asset, in the pool) points the depeg ref band at a SEPARATE oracle instance. `PoolIO.priceBandGuard` reads `refPrimary` (fallback to `primary` only for legacy stored state) and fail-closes via `Oracle.gate`. Validation: `refBandBps != 0` requires `refFeedId != 0`, a reachable `refPrimary`, and `refPrimary != primary`. Address inequality is only the enforceable structural floor; deployment must additionally ensure independent signer/admin/data failure domains, since two instances sharing keys can still be walked together. Result: a compromised primary push quorum cannot walk the mark past `refBandBps` of an operationally independent reference without halting swaps; push-rate-independent, magnitude-based.

## Migration
- There is no signature-less legacy push entrypoint. Existing feeds begin with `sourceTs == 0`; their
  first signed update is constrained by the configured flat `maxDeviation`, then all later updates
  additionally require a strictly increasing authenticated source timestamp.
- NXR quorum (BUILT, nx-rates `core/src/server/signed.rs`): each replica holds its own `NXR_SIGNER_KEY`; `/v1/quote/signed` self-signs + fans the blob to `peers` (`POST /v1/quote/cosign`, internal-only); a peer countersigns ONLY after re-validating every record vs its OWN live view (price tolerance bps, sourceTs skew, σ/CI understatement guards); sigs deduped by recovered attester; `< quorum` fails the quote closed (503). Response = `{blob, sigs[]}`; keeper sorts by recovered address + concatenates (`sort_and_concat_sigs`).
- Still deferred: WS `kind:"signed"` stream (keeper on 12s REST poll today; poll works for testnet, stream = latency optimization).

## Gas targets (to be MEASURED by ExternalOracleSigned.t.sol gas report)
| | legacy batchPush(10)/feed | signed batchPushSigned(10)/feed |
|---|---|---|
| event | Pushed ~2524 | none |
| σ | updateSigmaEma ~800 | 0 (direct store) |
| calldata | 128 B ABI | 24 B packed |
| auth | onlyOracle SLOAD (once) | k x ecrecover ~3000+ (k = signerThreshold) |
| target | ~12,900 | ~8,960 (-31%) |
vs Scribe poke bar=1 measured 60,700 (`docs/Benchmarks.md`).
