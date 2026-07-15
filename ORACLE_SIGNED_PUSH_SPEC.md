# Oracle signed-push spec (SoT)

Status: **reference implementation, pre-security-review.** Money path. Do NOT deploy to live before `/security-review` + human sign-off + NXR integration test.

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
- `signer = ECDSA.recoverCalldata(digest, sig)` (solady). NOTE: `recoverCalldata` does NOT reject a malleable `s`/`v` (~4 valid encodings per logical sig). Safe here because replay defense is the on-chain monotonic `sourceTs`, NEVER signature uniqueness. Do not add any state keyed on signature bytes.
- One signature over the whole batch. Relay `msg.sender` is unpermissioned.

## Known tradeoffs (audit cohorts A+B, 0 CRIT / 0 HIGH)
- **Permissionless-relay grief (F-2, LOW/MED)**: any address may relay. An attacker buffering older-but-still-valid signed blobs can race to land one first in a block; the honest fresher blob then reverts on the one-per-block guard that block. Bounded to ~1-block staleness, self-limiting (monotonic sourceTs; a given blob lands at most once), backstopped by the deviation band + `updatedAt` staleness premium. Inherent to the decoupled relay design. If observed on mainnet, add an optional allowlisted-relayer mode.
- **Compromised-signer ceiling (F-3, info)**: `_checkDeviation` lets the band grow with staleness up to `MAX_DEV_THRESHOLD` (650%). Keep keeper heartbeat << ttl so the band stays ≈ maxDeviation; monitor `updatedAt` gaps.
- **Legacy/signed σ-mix (LOW)**: a feed pushed via both paths mixes EMA (legacy) and direct (signed) σ semantics. Do not mix per feed; cut over atomically.
- **year-2106 uint32 `updatedAt` wrap (LOW, pre-existing)**: shared with the legacy path.

## On-chain checks per feed (fail-closed, all revert)
1. `feedIds[idx]` bounds check (OOB reverts). `prevAt != 0` (feed exists).
2. **Monotonic**: `sourceTs > prevSourceTs`, and `sourceTs < 2^48`. Replay of a landed batch fails (all sourceTs == stored).
3. **One per block**: `dt = block.timestamp - prevAt != 0` (else `CooldownActive`). Bounds per-block move to one band step; makes duplicate idx in a batch fail-closed.
4. **Deviation band**: `devBps <= maxDeviation*(1 + dt/ttl)` capped `MAX_DEV_THRESHOLD` (65_000). Unchanged from legacy; backstops a compromised NXR key (signature authorizes authenticity, NOT magnitude).
5. `b64To1e18(price) != 0`, `sigma <= MAX_VOLATILITY`.
Store σ directly (no `updateSigmaEma`). No event emitted (observability = `getFeed()` state polling, per `collector/snapshot.ts`).

## Signer registry
`mapping(address => bool) signers` + `grantSigner`/`revokeSigner` (onlyAdmin), mirrors `oracles`. Seed NXR key post-deploy. <= 6 signers; any one valid signer authorizes (OR semantics). Multi-sig-of-N (require k distinct signers) is a future option, not built.

## Migration
- Legacy `pushFeed`/`batchPush` (onlyOracle, σ-EMA, `Pushed` event) kept during cutover. Deprecate once keeper relays signed quotes. Do NOT mix legacy + signed on the same feed (σ semantics differ: EMA vs direct).
- Off-chain order (deferred, blocked on NXR dirty tree + integration): NXR signer service (sign DEX subset @200ms, stream via WS `kind:"signed"`) -> keeper subscribes stream, holds freshest, relays on local θ/heartbeat trigger -> zero round-trip, next-block. Move keeper off 12s REST poll.

## Gas targets (to be MEASURED by ExternalOracleSigned.t.sol gas report)
| | legacy batchPush(10)/feed | signed batchPushSigned(10)/feed |
|---|---|---|
| event | Pushed ~2524 | none |
| σ | updateSigmaEma ~800 | 0 (direct store) |
| calldata | 128 B ABI | 24 B packed |
| auth | onlyOracle SLOAD (once) | ecrecover 3000 (once) |
| target | ~12,900 | ~8,960 (-31%) |
vs Scribe poke bar=1 measured 60,700 (`docs/Benchmarks.md`).
