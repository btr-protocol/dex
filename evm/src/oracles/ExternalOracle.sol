// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {Maths as M} from "../libraries/Maths.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title ExternalOracle
/// @notice Push-based external oracle. NXR attests mark + σ + mark CI, signs the batch; any relayer lands
///         it via `batchPushSigned`. Quote = `lastPriceB64`; pricing σ = `sigmaEma`.
/// @dev Price authority = k-of-n distinct granted signers over one EIP-712 digest, decoupled from
///      the relayer (`msg.sender`, unpermissioned). Signer additions and threshold decreases are
///      timelocked; emergency revocation and threshold increases remain immediate. No
///      signature-less/`msg.sender`-trusting push path exists.
contract ExternalOracle is IOracle, EIP712 {
  address public immutable AC;
  uint32 public constant MAX_VOLATILITY = C.MAX_SIGMA_PBPS;
  uint16 public constant MAX_DEV_THRESHOLD = 65_000;
  uint8 public constant MAX_SIGNERS = 6;
  /// @dev Per-push deviation band = maxDeviation floor + DEV_SIGMA_Z·σ·√(dtSource/SIGMA_INTERVAL_S).
  ///      The band is VOLATILITY-ADAPTIVE: a legitimate move over dtSource seconds for a ticker with
  ///      per-interval volatility σ is ~ Z·σ·√(dtSource/interval) (Brownian). maxDeviation degrades to
  ///      a microstructure/discretization FLOOR; σ (the STORED prior σ, never the incoming push's own —
  ///      that would let a signer inflate its own band) is the adaptive term. SIGMA_INTERVAL_S matches
  ///      NXR's 30-min Parkinson σ window. Z=6 ⇒ a 6σ sanity cap (per-push authenticity backstop; the
  ///      CUMULATIVE bound on a compromised quorum is the independent refPrimary band, not this).
  uint256 private constant DEV_SIGMA_Z = 6;
  uint256 private constant SIGMA_INTERVAL_S = 1800;
  uint48 public constant SIGNER_GOV_TIMELOCK = SC.BASE_TIMELOCK;
  uint48 public constant SIGNER_GOV_GRACE = SC.GRACE_PERIOD;
  /// @dev Clock-skew allowance (s) for the signed-path future-dated bound. A signed blob whose sourceTs
  ///      leads wall-clock by more than this is rejected — an unbounded far-future sourceTs would clear
  ///      the monotonic guard and then permanently freeze the feed (no honest near-now push could ever
  ///      exceed it again; no reset path). Ostium "future-dated report" vector.
  /// @dev NXR's off-chain quorum target is <50 ms. Five seconds leaves two orders of magnitude for
  ///      NTP drift, scheduler/network jitter, and block-timestamp granularity without granting a
  ///      compromised quorum a multi-minute nonce lead over honest signers.
  uint32 public constant SOURCE_TS_FUTURE_SKEW_S = 5;

  /// @dev EIP-712 typehash for a signed batch. The signature commits to `keccak256(blob)` — the exact
  ///      packed calldata (24 B/feed, idx-based). See ORACLE_SIGNED_PUSH_SPEC.md.
  bytes32 private constant BATCH_TYPEHASH = keccak256("BatchQuote(bytes32 blobHash)");
  uint256 private constant RECORD_BYTES = 24;
  /// @dev FeedData.flags bit0 = paused (guardian fast-freeze). Repurposed from vestigial `tau`. No new slot.
  uint16 private constant FLAG_PAUSED = 1;

  mapping(bytes32 => FeedData) private feeds;
  bytes32[] public feedIds;
  /// @notice NXR attester keys. A signed quote is authorized iff `signerThreshold` DISTINCT granted
  ///         signers signed the batch digest — the relayer (`msg.sender`) is unpermissioned.
  ///         Decouples price-authority from push-liveness.
  mapping(address => bool) public signers;
  /// @notice k-of-n signature threshold for `batchPushSigned` (Ostium single-key hardening).
  ///         Initialized atomically to at least 2-of-3. Revoking signers BELOW the threshold is
  ///         deliberately allowed — it halts pushing, the fail-safe compromise response.
  uint8 public signerThreshold;
  /// @notice Live granted-signer count (executeSignerGrant/revokeSigner bookkeeping).
  /// @dev uint8 is sufficient under MAX_SIGNERS and packs with signerThreshold in the same slot.
  uint8 public signerCount;
  /// @dev Pending threshold decrease and its grace-bearing timelock pack into the signer config slot.
  uint8 public pendingSignerThreshold;
  uint96 public pendingSignerThresholdOp;
  /// @dev One pending signer grant at a time. Address + uint96 op exactly fill one slot and prevent a
  ///      compromised owner from queue-farming many candidates that guardians must veto individually.
  address public pendingSigner;
  uint96 public pendingSignerGrantOp;

  /// @notice Immutable absolute freshness bound for the signed path (seconds).
  uint32 public immutable maxRelayLagSecs;

  event FeedAdded(
    bytes32 indexed feedId,
    address indexed base,
    address indexed quote,
    uint64 price,
    uint32 sigmaSample,
    uint16 confidence,
    uint16 tau,
    uint16 tauSigma,
    uint16 maxDeviation
  );
  event FeedUpdated(bytes32 indexed feedId, uint16 maxDeviation, uint16 ttl);
  event SignerGranted(address indexed signer);
  event SignerGrantRequested(address indexed signer, uint48 eta);
  event SignerGrantCancelled(address indexed signer);
  event SignerRevoked(address indexed signer);
  event SignerThresholdSet(uint8 threshold);
  event SignerThresholdDecreaseRequested(uint8 threshold, uint48 eta);
  event SignerThresholdDecreaseCancelled(uint8 threshold);
  event FeedPaused(bytes32 indexed feedId);
  event FeedUnpaused(bytes32 indexed feedId);
  event MaxDeviationNarrowed(bytes32 indexed feedId, uint16 newMaxDeviation);

  modifier onlyAdmin() {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotAuth();
    _;
  }

  /// @dev Guardian gate: owner OR AC.isGuardian. Guardian may only HALT/TIGHTEN/CANCEL — every reverse
  ///      (requestSignerGrant, unpauseFeed, widen via updateFeed) stays owner-only. Guardian is owner-set +
  ///      instant-revocable (AC.isGuardian), the rogue-guardian bound. Mirrors Admin._onlyGuardianOrAdmin.
  function _onlyGuardianOrAdmin() internal view {
    AccessControl ac_ = AccessControl(AC);
    if (msg.sender != ac_.owner() && !ac_.isGuardian(msg.sender)) revert Err.NotAuth();
  }

  constructor(
    address ac_,
    uint32 maxRelayLagSecs_,
    address[] memory initialSigners_,
    uint8 signerThreshold_
  ) {
    if (ac_ == address(0)) revert Err.ZeroValue();
    if (ac_.code.length == 0) revert Err.NotCode();
    // Upper bound < uint16 max: feeds require ttl > maxRelayLagSecs and ttl is uint16, so a larger
    // lag would make every addFeed revert (no addable feed) — the uint16 ceiling (65534s) IS the
    // structural cap. Immutable — loosening under duress is a deliberate non-goal; remediation for
    // structural relay lag = redeploy + timelocked oracle re-pin.
    if (maxRelayLagSecs_ == 0 || maxRelayLagSecs_ >= type(uint16).max) revert Err.InvalidInput();
    uint256 count = initialSigners_.length;
    if (count < 3 || count > MAX_SIGNERS || signerThreshold_ < 2 || signerThreshold_ > count) {
      revert Err.InvalidInput();
    }
    AC = ac_;
    maxRelayLagSecs = maxRelayLagSecs_;
    for (uint256 i; i < count;) {
      address signer = initialSigners_[i];
      if (signer == address(0)) revert Err.ZeroValue();
      if (signers[signer]) revert Err.InvalidInput();
      signers[signer] = true;
      emit SignerGranted(signer);
      unchecked {
        ++i;
      }
    }
    signerCount = uint8(count);
    signerThreshold = signerThreshold_;
    emit SignerThresholdSet(signerThreshold_);
  }

  function addFeed(
    address base,
    address quote,
    uint64 price,
    uint32 sigmaSample,
    uint16 confidence,
    uint16 tau,
    uint16 tauSigma,
    uint16 maxDeviation,
    uint16 ttl
  ) external onlyAdmin {
    if (base == address(0) || quote == address(0)) revert Err.ZeroValue();
    _validate(price, sigmaSample);
    // maxDeviation is MANDATORY non-zero: the pool quotes off the raw pushed mark, so an unbounded
    // push is a single-tx drain — every feed must declare a per-push bound (H-1).
    // ttl > maxRelayLagSecs: gate() ages from sourceTs, so a blob legally landing at the lag bound
    // with ttl <= lag is stale on arrival — every read reverts until the next push (liveness cliff).
    if (maxDeviation == 0 || maxDeviation > MAX_DEV_THRESHOLD || ttl <= maxRelayLagSecs) {
      revert Err.InvalidInput();
    }
    if (tauSigma == 0) tauSigma = tau;

    bytes32 feedId = keccak256(abi.encodePacked(base, quote));
    if (feeds[feedId].updatedAt != 0) revert Err.FeedAlreadyExists(feedId);

    feeds[feedId] = FeedData({
      lastPriceB64: price,
      sigmaEma: sigmaSample,
      updatedAt: uint32(block.timestamp),
      ttl: ttl,
      confidence: confidence,
      flags: 0, // new feed starts unpaused; guardian pause sets bit0 later
      tauSigma: tauSigma,
      maxDeviation: maxDeviation,
      sourceTs: 0 // legacy-added feed; set only by the signed path
    });
    feedIds.push(feedId);
    emit FeedAdded(feedId, base, quote, price, sigmaSample, confidence, tau, tauSigma, maxDeviation);
  }

  function updateFeed(bytes32 feedId, uint16 maxDeviation, uint16 ttl) external onlyAdmin {
    if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
    // Same ttl > lag coupling as addFeed (stale-on-landing guard).
    if (maxDeviation == 0 || maxDeviation > MAX_DEV_THRESHOLD || ttl <= maxRelayLagSecs) {
      revert Err.InvalidInput();
    }
    feeds[feedId].ttl = ttl;
    feeds[feedId].maxDeviation = maxDeviation; // now packed in the feed slot (was a cold mapping)
    emit FeedUpdated(feedId, maxDeviation, ttl);
  }

  /// @notice Queue a signer addition. Adding price authority is a loosening and therefore cannot
  ///         take effect in the same transaction (or block) as a compromised-owner request.
  function requestSignerGrant(address signer) external onlyAdmin {
    if (signer == address(0)) revert Err.ZeroValue();
    if (signers[signer] || signerCount >= MAX_SIGNERS) revert Err.InvalidInput();
    if (pendingSignerGrantOp != 0) revert Err.PendingTimelock(uint48(block.timestamp));
    uint48 delay = SC.govDelay(SIGNER_GOV_TIMELOCK);
    pendingSigner = signer;
    pendingSignerGrantOp = TL.pack(delay, SIGNER_GOV_GRACE);
    emit SignerGrantRequested(signer, uint48(block.timestamp) + delay);
  }

  /// @notice Execute a matured signer addition during its bounded grace window. Revalidates both
  ///         membership and the hard signer cap because emergency revocations/other grants may have
  ///         changed the live set while this request waited.
  function executeSignerGrant() external onlyAdmin {
    uint96 op = pendingSignerGrantOp;
    if (op == 0) revert Err.InvalidState();
    TL.validate(op);
    address signer = pendingSigner;
    if (signer == address(0) || signers[signer] || signerCount >= MAX_SIGNERS) {
      revert Err.InvalidInput();
    }
    delete pendingSigner;
    delete pendingSignerGrantOp;
    signers[signer] = true;
    ++signerCount;
    emit SignerGranted(signer);
  }

  /// @notice Guardian or owner may veto a pending authority addition, including an expired request.
  function cancelSignerGrant() external {
    _onlyGuardianOrAdmin();
    if (pendingSignerGrantOp == 0) revert Err.InvalidState();
    address signer = pendingSigner;
    delete pendingSigner;
    delete pendingSignerGrantOp;
    emit SignerGrantCancelled(signer);
  }

  /// @notice Guardian OR owner may revoke a signer (fast removal of a leaked NXR key). Asymmetric with
  ///         requestSignerGrant (owner-only): worst rogue-guardian case = revoke all signers → feeds go stale →
  ///         pool fail-closes = a safe halt, never a loosening. Revoking BELOW signerThreshold is
  ///         deliberately unblocked: dropping under k halts pushing (fail-safe), never loosens.
  function revokeSigner(address signer) external {
    _onlyGuardianOrAdmin();
    if (signers[signer]) {
      signers[signer] = false;
      --signerCount;
      emit SignerRevoked(signer);
    }
  }

  /// @notice Immediately RAISE the k-of-n threshold (hardening). Decreases must use the timelocked
  ///         request/execute path below. Bounded to the live signer set so governance cannot directly
  ///         configure an unreachable threshold; emergency revocation may still deliberately halt.
  function setSignerThreshold(uint8 t) external onlyAdmin {
    if (t <= signerThreshold || t > signerCount) revert Err.InvalidInput();
    signerThreshold = t;
    emit SignerThresholdSet(t);
  }

  /// @notice Queue a quorum decrease. Only one decrease may be pending; it expires after the grace
  ///         window and must then be explicitly cancelled before another request can be queued.
  function requestSignerThresholdDecrease(uint8 t) external onlyAdmin {
    if (t < 2 || t >= signerThreshold || t > signerCount) revert Err.InvalidInput();
    if (pendingSignerThresholdOp != 0) revert Err.PendingTimelock(uint48(block.timestamp));
    uint48 delay = SC.govDelay(SIGNER_GOV_TIMELOCK);
    pendingSignerThreshold = t;
    pendingSignerThresholdOp = TL.pack(delay, SIGNER_GOV_GRACE);
    emit SignerThresholdDecreaseRequested(t, uint48(block.timestamp) + delay);
  }

  /// @notice Execute a matured quorum decrease. The target must still be a strict decrease and
  ///         reachable by the live signer set at execution time.
  function executeSignerThresholdDecrease() external onlyAdmin {
    uint96 op = pendingSignerThresholdOp;
    if (op == 0) revert Err.InvalidState();
    TL.validate(op);
    uint8 t = pendingSignerThreshold;
    if (t < 2 || t >= signerThreshold || t > signerCount) revert Err.InvalidInput();
    delete pendingSignerThreshold;
    delete pendingSignerThresholdOp;
    signerThreshold = t;
    emit SignerThresholdSet(t);
  }

  /// @notice Guardian or owner may veto a pending quorum decrease, including an expired request.
  function cancelSignerThresholdDecrease() external {
    _onlyGuardianOrAdmin();
    if (pendingSignerThresholdOp == 0) revert Err.InvalidState();
    uint8 cancelled = pendingSignerThreshold;
    delete pendingSignerThreshold;
    delete pendingSignerThresholdOp;
    emit SignerThresholdDecreaseCancelled(cancelled);
  }

  /// @notice Guardian OR owner may pause a feed (fast-freeze). Fail-closed: a paused feed reverts in
  ///         Oracle.gate() and reads not-fresh in isFeedFresh, regardless of freshness. Mark/σ preserved —
  ///         unpause (owner-only) restores exactly. Sets FeedData.flags bit0 in-slot (no new storage).
  function pauseFeed(bytes32 feedId) external {
    _onlyGuardianOrAdmin();
    if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
    feeds[feedId].flags |= FLAG_PAUSED;
    emit FeedPaused(feedId);
  }

  /// @notice Unpause a feed. Owner-only: un-halting is the reverse power, never a guardian's.
  function unpauseFeed(bytes32 feedId) external onlyAdmin {
    if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
    feeds[feedId].flags &= ~FLAG_PAUSED;
    emit FeedUnpaused(feedId);
  }

  /// @notice Guardian OR owner may TIGHTEN the per-push deviation band (never widen). Guardrails: strictly
  ///         narrower than current, non-zero (a zero band = unbounded push = single-tx drain), and within
  ///         MAX_DEV_THRESHOLD. Touches only maxDeviation; ttl and all other fields untouched. Widening back
  ///         is owner-only via updateFeed (deliberately unguarded here).
  function narrowMaxDeviation(bytes32 feedId, uint16 newMaxDeviation) external {
    _onlyGuardianOrAdmin();
    uint16 cur = feeds[feedId].maxDeviation;
    if (cur == 0) revert Err.FeedNotFound(feedId); // maxDeviation is mandatory non-zero on every live feed
    if (newMaxDeviation == 0 || newMaxDeviation >= cur || newMaxDeviation > MAX_DEV_THRESHOLD) {
      revert Err.InvalidInput();
    }
    feeds[feedId].maxDeviation = newMaxDeviation;
    emit MaxDeviationNarrowed(feedId, newMaxDeviation);
  }

  /// @dev solady EIP712 domain. Fixed name/version; solady binds chainId + address(this), fork-safe.
  function _domainNameAndVersion()
    internal
    pure
    override
    returns (string memory name, string memory version)
  {
    return ("BTR ExternalOracle", "1");
  }

  /// @notice Relay an NXR-signed batch of quotes. Auth = k-of-n: `sigs` = concatenated 65-byte ECDSA
  ///         signatures over the SAME EIP-712 digest (whole `blob`), k >= signerThreshold, each
  ///         recovering to a DISTINCT granted signer. Distinctness is enforced by strictly-increasing
  ///         recovered address — rejects duplicates AND unsorted input (the standard cheap multisig
  ///         check). The relayer (`msg.sender`) needs no permission. Single push = a 24-byte blob
  ///         (n=1). Packed record layout + digest: see ORACLE_SIGNED_PUSH_SPEC.md.
  /// @param blob Packed records, 24 B each: idx(u16)|price(u64)|sigma(u32)|conf(u16)|sourceTs(u64).
  /// @param sigs k concatenated 65-byte ECDSA signatures, sorted by recovered signer address.
  function batchPushSigned(bytes calldata blob, bytes calldata sigs) external {
    uint256 len = blob.length;
    if (len == 0 || len % RECORD_BYTES != 0) revert Err.InvalidInput();
    // Fixed 65-byte stride (no EIP-2098): the count IS the quorum claim, so it must be unambiguous.
    uint256 k = sigs.length / 65;
    if (sigs.length % 65 != 0 || k < signerThreshold) revert Err.InvalidInput();

    // Verify ALL sigs BEFORE any state change (checks-effects). blobHash commits to the exact
    // idx-based bytes; safe because feedIds is append-only (idx never remaps).
    // SECURITY: replay defense is the per-feed monotonic sourceTs (_pushSignedInternal), NEVER signature
    // uniqueness — recoverCalldata does not reject a malleable s. Never key any state on the sig bytes.
    bytes32 digest = _hashTypedData(keccak256(abi.encode(BATCH_TYPEHASH, keccak256(blob))));
    address prev;
    for (uint256 i; i < k;) {
      uint256 off;
      unchecked {
        off = i * 65;
      }
      address rec = ECDSA.recoverCalldata(digest, sigs[off:off + 65]);
      // Strictly-increasing recovered address ⇒ k DISTINCT signers (dups/unsorted fail closed).
      if (rec <= prev || !signers[rec]) revert Err.NotAuth();
      prev = rec;
      unchecked {
        ++i;
      }
    }

    // Absolute freshness floor (ms), read ONCE (no per-feed SLOAD). A signed blob
    // whose sourceTs predates (now - maxRelayLag) is rejected fail-closed — see `maxRelayLagSecs`.
    uint256 minSourceTsMs;
    uint32 lag = maxRelayLagSecs;
    if (lag != 0 && block.timestamp > lag) minSourceTsMs = (block.timestamp - lag) * 1000;
    // Future-dated bound (ms), read ONCE. Rejects a compromised-signer far-future sourceTs that would
    // clear the monotonic guard and then permanently freeze the feed. See SOURCE_TS_FUTURE_SKEW_S.
    uint256 maxSourceTsMs = (block.timestamp + SOURCE_TS_FUTURE_SKEW_S) * 1000;

    uint256 n = len / RECORD_BYTES;
    uint256 base;
    assembly ("memory-safe") { base := blob.offset }
    for (uint256 i; i < n;) {
      uint16 idx;
      uint64 price;
      uint32 sigma;
      uint16 conf;
      uint64 sourceTs;
      assembly ("memory-safe") {
        // 24-byte record occupies the top 24 bytes of the loaded word (bits 64..256). The extra
        // 8 low bits read past the last record are masked off and never used.
        let w := calldataload(add(base, mul(i, RECORD_BYTES)))
        idx := shr(240, w)
        price := and(shr(176, w), 0xFFFFFFFFFFFFFFFF)
        sigma := and(shr(144, w), 0xFFFFFFFF)
        conf := and(shr(128, w), 0xFFFF)
        sourceTs := and(shr(64, w), 0xFFFFFFFFFFFFFFFF)
      }
      _pushSignedInternal(feedIds[idx], price, sigma, conf, sourceTs, minSourceTsMs, maxSourceTsMs); // OOB idx reverts
      unchecked {
        ++i;
      }
    }
  }

  function _validate(uint64 price, uint32 sigmaSample) internal pure returns (uint256 mark1e18) {
    if ((mark1e18 = M.b64To1e18(price)) == 0) revert Err.ZeroValue();
    if (sigmaSample > MAX_VOLATILITY) revert Err.ThresholdViolation(sigmaSample, MAX_VOLATILITY);
  }

  /// @dev Per-push mark-move SANITY cap (D1/H-2), SOURCE-TIME-driven: `dt` = attested sourceTs delta
  ///      (s), NOT wall-clock landing delta. Band grows linearly with source staleness:
  ///      maxDeviation·(1 + dt/ttl), hard-capped at MAX_DEV_THRESHOLD. Source-time makes the bound
  ///      identical %/wall-second on a 400ms chain and a 12s chain — a fast chain gets no extra
  ///      cumulative walk from more blocks. Fail-closed on out-of-band and on maxDev==0. The signature
  ///      authorizes AUTHENTICITY, not MAGNITUDE — this clamp backstops a compromised push quorum
  ///      per push; the CUMULATIVE bound is the independent refPrimary band (PoolIO.priceBandGuard),
  ///      not this.
  /// @dev Volatility-adaptive per-push band. `allowed = maxDev + Z·σ·√(dt/interval)`, where σ is the
  ///      STORED prior volatility (PBPS). σ_bps = σ_pbps/100; √(dt/interval) = √(dt·1e6/interval)/1000
  ///      (integer). So the σ term in bps = Z·σ_pbps·√(dt·1e6/interval)/1e5. dt=0 (first push) ⇒ band =
  ///      maxDev floor. Capped at MAX_DEV_THRESHOLD. prevSigma is trusted (already on-chain, floored
  ///      each push at |Δmark|/mark) — a signer cannot widen THIS push's band with THIS push's σ.
  function _checkDeviation(
    uint256 prevMark1e18,
    uint256 mark1e18,
    uint256 dt,
    uint16 maxDev,
    uint32 prevSigmaPbps
  ) internal pure {
    uint256 diff = mark1e18 > prevMark1e18 ? mark1e18 - prevMark1e18 : prevMark1e18 - mark1e18;
    uint256 devBps = (diff * SC.BPS) / prevMark1e18;
    uint256 allowed = uint256(maxDev)
      + (DEV_SIGMA_Z * uint256(prevSigmaPbps) * FixedPointMathLib.sqrt(dt * 1e6 / SIGMA_INTERVAL_S))
      / 1e5;
    if (allowed > MAX_DEV_THRESHOLD) allowed = MAX_DEV_THRESHOLD;
    if (devBps > allowed) revert Err.ThresholdViolation(devBps, allowed);
  }

  /// @dev Sole feed writer. One feed-slot SLOAD + one SSTORE. maxDeviation for the push clamp lives IN
  ///      the slot (no separate cold mapping — ORA-02). Slot layout (low→high bits):
  ///      lastPriceB64[0:64) | sigmaEma[64:96) | updatedAt[96:128) | ttl[128:144)
  ///      | confidence[144:160) | flags[160:176) (bit0=paused) | tauSigma[176:192) | maxDeviation[192:208)
  ///      | sourceTs[208:256) (uint48 ms, monotonic replay guard; 0 until first signed push).
  ///      Guards: (1) monotonic `sourceTs` replay guard + a future-dated bound, (2) stores the NXR-signed
  ///      σ DIRECTLY (no on-chain EMA — smoothing moves to source) FLOORED at |Δmark|/mark
  ///      (compromised-signer backstop), (3) no event (observability = getFeed() state polling). Same
  ///      one-per-block + deviation-band + validate guards. Auth already checked by the caller.
  function _pushSignedInternal(
    bytes32 feedId,
    uint64 newPriceB64,
    uint32 sigma,
    uint16 conf,
    uint64 sourceTs,
    uint256 minSourceTsMs,
    uint256 maxSourceTsMs
  ) internal {
    FeedData storage feed = feeds[feedId];
    uint256 slot;
    uint256 word;
    assembly ("memory-safe") {
      slot := feed.slot
      word := sload(slot)
    }
    uint32 prevAt = uint32((word >> 96) & 0xFFFFFFFF);
    if (prevAt == 0) revert Err.FeedNotFound(feedId);

    // Monotonic source timestamp: strictly advance, and fit the 48-bit slot field. A replayed batch
    // (same sourceTs) or a stale/reordered relay fails closed here — the timestamp IS the nonce.
    uint256 prevSourceTs = (word >> 208) & 0xFFFFFFFFFFFF;
    if (sourceTs <= prevSourceTs || sourceTs >= (1 << 48)) revert Err.InvalidInput();
    // Future-dated reject: a far-future sourceTs clears the monotonic guard once, then poisons it —
    // every honest near-now push fails the strictly-advancing check forever (feed-freeze DoS).
    if (sourceTs > maxSourceTsMs) revert Err.InvalidInput();
    // Absolute freshness bound (fail-closed): a withheld older-but-monotonic blob would otherwise
    // land and stamp updatedAt=now, reading fresh downstream. During chain genesis only,
    // minSourceTsMs may be zero because block.timestamp has not exceeded the immutable lag.
    if (minSourceTsMs != 0 && sourceTs < minSourceTsMs) revert Err.FeedStale();

    uint256 prevMark1e18 = M.b64To1e18(uint64(word));
    uint256 mark1e18 = _validate(newPriceB64, sigma);

    uint256 dt;
    unchecked {
      dt = block.timestamp - prevAt;
    }
    if (dt == 0) revert Err.CooldownActive(1); // one mark/feed/block; duplicate idx in a batch fails closed

    // Deviation band is VOLATILITY-ADAPTIVE and scales with ATTESTED source-time delta (chain-agnostic,
    // not block time) — floor + Z·σ·√(dtSource/interval), see _checkDeviation. sourceTs > prevSourceTs
    // already enforced (monotonic guard) so unchecked is safe. The first signed push has no
    // authenticated prior source-time interval: dt=0 ⇒ the band is exactly the maxDeviation floor (σ√dt
    // term vanishes), never an epoch-sized wide-cap exemption.
    uint256 dtSourceSecs;
    if (prevSourceTs != 0) {
      unchecked {
        dtSourceSecs = (sourceTs - prevSourceTs) / 1000;
      }
    }
    _checkDeviation(
      prevMark1e18,
      mark1e18,
      dtSourceSecs,
      uint16((word >> 192) & 0xFFFF), // maxDeviation floor
      uint32((word >> 64) & 0xFFFFFFFF) // stored σ (PBPS) drives the adaptive band
    );

    // σ floor (economic circuit-breaker vs a compromised signer). The signature authorizes the
    // AUTHENTICITY of the mark, NOT the volatility — a signer signing σ=0 would collapse the pricing
    // spread to the minFee floor and make a mark-then-self-swap round trip spread-free. Floor the
    // stored σ at the realized |Δmark|/mark so any mark move (even within the deviation band) forces a
    // proportional spread → the round trip is spread-NEGATIVE. Direct-σ, no on-chain smoothing.
    // markMovePbps caps at MAX_SIGMA_PBPS == MAX_VOLATILITY and sigma is already _validate'd
    // ≤ MAX_VOLATILITY, so sigmaStored stays within the validated σ invariant (no extra cap needed).
    uint32 moveFloor = Oracle.markMovePbps(prevMark1e18, mark1e18);
    uint32 sigmaStored = sigma > moveFloor ? sigma : moveFloor;

    // Preserve config fields (ttl/conf-slot/tau/tauSigma/maxDev) from the slot; overwrite mark, σ (direct),
    // updatedAt, confidence, sourceTs. sigmaEma[64:96) := floored signed σ (no EMA on the signed path).
    uint256 newWord = uint256(newPriceB64) | (uint256(sigmaStored) << 64)
      | (uint256(uint32(block.timestamp)) << 96) | (word & (uint256(0xFFFF) << 128)) // ttl
      | (uint256(conf) << 144)
      // GAS-22: flags|tauSigma|maxDeviation are contiguous [160:208) → preserve in one 48-bit mask
      // (so a guardian-set paused bit survives every signed push; only owner unpause clears it).
      | (word & (uint256(0xFFFFFFFFFFFF) << 160)) | (uint256(uint48(sourceTs)) << 208);
    assembly ("memory-safe") { sstore(slot, newWord) }
  }

  function getFeed(bytes32 feedId) external view override returns (FeedData memory data) {
    data = feeds[feedId];
    if (data.updatedAt == 0) revert Err.FeedNotFound(feedId);
  }

  /// @dev Same clock as `Oracle.observedAt` (storage-local; avoids memory copy).
  function _obsAt(FeedData storage f) private view returns (uint32) {
    if (f.sourceTs != 0) {
      uint256 srcSec = uint256(f.sourceTs) / 1000;
      if (srcSec > f.updatedAt) srcSec = f.updatedAt;
      return uint32(srcSec);
    }
    return f.updatedAt;
  }

  function isFeedFresh(bytes32 feedId, uint32 maxAge) external view override returns (bool) {
    FeedData storage f = feeds[feedId];
    if (f.updatedAt == 0 || f.flags & FLAG_PAUSED != 0) return false;
    unchecked {
      return block.timestamp - _obsAt(f) <= maxAge;
    }
  }

  function isFeedFresh(bytes32 feedId) external view override returns (bool) {
    FeedData storage f = feeds[feedId];
    if (f.updatedAt == 0 || f.flags & FLAG_PAUSED != 0) return false;
    unchecked {
      return block.timestamp - _obsAt(f) <= f.ttl;
    }
  }

  function getFeedIds() external view returns (bytes32[] memory) {
    return feedIds;
  }

  function getFeedCount() external view returns (uint256) {
    return feedIds.length;
  }

  function hasFeed(bytes32 feedId) external view returns (bool) {
    return feeds[feedId].updatedAt != 0;
  }
}
