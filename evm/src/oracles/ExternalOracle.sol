// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {Maths as M} from "../libraries/Maths.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

/// @title ExternalOracle
/// @notice Push-based external oracle. Keeper pushes mark + Parkinson σ sample + mark CI; chain
///         maintains the rate-clamped σ-EMA. Quote = `lastPriceB64`; pricing σ = `sigmaEma`.
/// @dev Pusher is any `grantOracle` address — testnet EOA, mainnet Gnosis Safe (2-of-3). No threshold
///      logic on-chain; multisig is `msg.sender` after `execTransaction`.
contract ExternalOracle is IOracle, EIP712 {
    address public immutable AC;
    uint32 public constant MAX_VOLATILITY = C.MAX_SIGMA_PBPS;
    uint16 public constant MAX_DEV_THRESHOLD = 65_000;
    /// @dev Clock-skew allowance (s) for the signed-path future-dated bound. A signed blob whose sourceTs
    ///      leads wall-clock by more than this is rejected — an unbounded far-future sourceTs would clear
    ///      the monotonic guard and then permanently freeze the feed (no honest near-now push could ever
    ///      exceed it again; no reset path). Ostium "future-dated report" vector.
    uint32 public constant SOURCE_TS_FUTURE_SKEW_S = 300;

    /// @dev EIP-712 typehash for a signed batch. The signature commits to `keccak256(blob)` — the exact
    ///      packed calldata (24 B/feed, idx-based). See ORACLE_SIGNED_PUSH_SPEC.md.
    bytes32 private constant BATCH_TYPEHASH = keccak256("BatchQuote(bytes32 blobHash)");
    uint256 private constant RECORD_BYTES = 24;

    mapping(address => bool) public oracles;
    mapping(bytes32 => FeedData) private feeds;
    bytes32[] public feedIds;
    /// @notice NXR attester keys. A signed quote is authorized iff `ecrecover(digest) ∈ signers` — the
    ///         relayer (`msg.sender`) is unpermissioned. Decouples price-authority from push-liveness.
    mapping(address => bool) public signers;

    /// @notice Absolute freshness bound for the signed path (seconds). A signed blob is rejected if its
    ///         `sourceTs` lags wall-clock by more than this — monotonicity alone lets a withheld older
    ///         blob land and read perfectly fresh downstream (updatedAt = block.timestamp). 0 = disabled
    ///         (bring-up default); set generously above real relay + clock skew once live.
    uint32 public maxRelayLagSecs;

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
    event Pushed(
        bytes32 indexed feedId,
        uint64 price,
        uint32 sigmaSample,
        uint32 sigmaEma,
        uint16 confidence,
        address indexed pusher
    );
    event BatchPushed(uint256 count, address indexed pusher);
    event OracleGranted(address indexed oracle);
    event OracleRevoked(address indexed oracle);
    event SignerGranted(address indexed signer);
    event SignerRevoked(address indexed signer);
    event MaxRelayLagSet(uint32 secs);

    modifier onlyOracle() {
        if (!oracles[msg.sender]) revert Err.NotAuth();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != AccessControl(AC).owner()) revert Err.NotAuth();
        _;
    }

    constructor(address ac_, address oracle_) {
        if (ac_ == address(0) || oracle_ == address(0)) revert Err.ZeroValue();
        AC = ac_;
        oracles[oracle_] = true;
        emit OracleGranted(oracle_);
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
        if (maxDeviation == 0 || maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();
        if (tauSigma == 0) tauSigma = tau;

        bytes32 feedId = keccak256(abi.encodePacked(base, quote));
        if (feeds[feedId].updatedAt != 0) revert Err.FeedAlreadyExists(feedId);

        feeds[feedId] = FeedData({
            lastPriceB64: price,
            sigmaEma: sigmaSample,
            updatedAt: uint32(block.timestamp),
            ttl: ttl,
            confidence: confidence,
            tau: tau,
            tauSigma: tauSigma,
            maxDeviation: maxDeviation,
            sourceTs: 0 // legacy-added feed; set only by the signed path
        });
        feedIds.push(feedId);
        emit FeedAdded(feedId, base, quote, price, sigmaSample, confidence, tau, tauSigma, maxDeviation);
    }

    function updateFeed(bytes32 feedId, uint16 maxDeviation, uint16 ttl) external onlyAdmin {
        if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
        if (maxDeviation == 0 || maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();
        feeds[feedId].ttl = ttl;
        feeds[feedId].maxDeviation = maxDeviation; // now packed in the feed slot (was a cold mapping)
        emit FeedUpdated(feedId, maxDeviation, ttl);
    }

    function grantOracle(address oracle) external onlyAdmin {
        if (oracle == address(0)) revert Err.ZeroValue();
        oracles[oracle] = true;
        emit OracleGranted(oracle);
    }

    function revokeOracle(address oracle) external onlyAdmin {
        oracles[oracle] = false;
        emit OracleRevoked(oracle);
    }

    function grantSigner(address signer) external onlyAdmin {
        if (signer == address(0)) revert Err.ZeroValue();
        signers[signer] = true;
        emit SignerGranted(signer);
    }

    function revokeSigner(address signer) external onlyAdmin {
        signers[signer] = false;
        emit SignerRevoked(signer);
    }

    /// @notice Set the signed-path absolute freshness bound (seconds); 0 disables. See `maxRelayLagSecs`.
    function setMaxRelayLag(uint32 secs) external onlyAdmin {
        maxRelayLagSecs = secs;
        emit MaxRelayLagSet(secs);
    }

    /// @dev solady EIP712 domain. Fixed name/version; solady binds chainId + address(this), fork-safe.
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("BTR ExternalOracle", "1");
    }

    function pushFeed(bytes32 feedId, uint64 newPriceB64, uint32 sigmaSample, uint16 newConfidence)
        external onlyOracle
    {
        // OBS-01: `Pushed` is emitted inside `_pushInternal` now, so batchPush legs are observable too.
        _pushInternal(feedId, newPriceB64, sigmaSample, newConfidence);
    }

    function batchPush(
        bytes32[] calldata _feedIds,
        uint64[] calldata prices,
        uint32[] calldata sigmas,
        uint16[] calldata confidences
    ) external onlyOracle {
        uint256 length = _feedIds.length;
        if (
            length == 0 ||
            prices.length != length ||
            sigmas.length != length ||
            confidences.length != length
        ) revert Err.InvalidInput();

        for (uint256 i; i < length;) {
            bytes32 id;
            uint256 p;
            uint256 s;
            uint256 c;
            assembly ("memory-safe") {
                let w := shl(5, i)
                id := calldataload(add(_feedIds.offset, w))
                p := calldataload(add(prices.offset, w))
                s := calldataload(add(sigmas.offset, w))
                c := calldataload(add(confidences.offset, w))
            }
            _pushInternal(id, uint64(p), uint32(s), uint16(c));
            unchecked { ++i; }
        }
        emit BatchPushed(length, msg.sender);
    }

    /// @notice Relay an NXR-signed batch of quotes. Auth = `ecrecover(digest) ∈ signers`; the relayer
    ///         (`msg.sender`) needs no permission. One ECDSA sig over the whole `blob`. Single push =
    ///         a 24-byte blob (n=1). Packed record layout + digest: see ORACLE_SIGNED_PUSH_SPEC.md.
    /// @param blob Packed records, 24 B each: idx(u16)|price(u64)|sigma(u32)|conf(u16)|sourceTs(u64).
    /// @param sig  65-byte (or EIP-2098 64-byte) ECDSA signature over the EIP-712 digest.
    function batchPushSigned(bytes calldata blob, bytes calldata sig) external {
        uint256 len = blob.length;
        if (len == 0 || len % RECORD_BYTES != 0) revert Err.InvalidInput();

        // Verify BEFORE any state change (checks-effects). blobHash commits to the exact idx-based bytes;
        // safe because feedIds is append-only (idx never remaps).
        // SECURITY: replay defense is the per-feed monotonic sourceTs (_pushSignedInternal), NEVER signature
        // uniqueness — recoverCalldata does not reject a malleable s. Never key any state on the sig bytes.
        bytes32 digest = _hashTypedData(keccak256(abi.encode(BATCH_TYPEHASH, keccak256(blob))));
        address signer = ECDSA.recoverCalldata(digest, sig);
        if (!signers[signer]) revert Err.NotAuth();

        // Absolute freshness floor (ms), read ONCE (no per-feed SLOAD). 0 = disabled. A signed blob
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
            unchecked { ++i; }
        }
    }

    function _validate(uint64 price, uint32 sigmaSample) internal pure returns (uint256 mark1e18) {
        if ((mark1e18 = M.b64To1e18(price)) == 0) revert Err.ZeroValue();
        if (sigmaSample > MAX_VOLATILITY) revert Err.ThresholdViolation(sigmaSample, MAX_VOLATILITY);
    }

    /// @dev Per-push mark-move clamp (D1/H-2), shared by legacy + signed paths. Band grows linearly with
    ///      staleness: maxDeviation·(1 + dt/ttl), hard-capped at MAX_DEV_THRESHOLD. Fail-closed on out-of-band
    ///      and on maxDev==0. Signature (signed path) authorizes AUTHENTICITY, not MAGNITUDE — this backstops
    ///      a compromised NXR key exactly as it backstops a compromised keeper EOA on the legacy path.
    function _checkDeviation(uint256 prevMark1e18, uint256 mark1e18, uint256 dt, uint16 ttl, uint16 maxDev)
        internal pure
    {
        uint256 diff = mark1e18 > prevMark1e18 ? mark1e18 - prevMark1e18 : prevMark1e18 - mark1e18;
        uint256 devBps = (diff * SC.BPS) / prevMark1e18;
        uint256 allowed = uint256(maxDev);
        allowed += (allowed * dt) / ttl;
        if (allowed > MAX_DEV_THRESHOLD) allowed = MAX_DEV_THRESHOLD;
        if (devBps > allowed) revert Err.ThresholdViolation(devBps, allowed);
    }

    /// @dev One feed-slot SLOAD + one SSTORE. maxDeviation for the push clamp now lives IN the slot
    ///      (no separate cold mapping — ORA-02). Slot layout (low→high bits):
    ///      lastPriceB64[0:64) | sigmaEma[64:96) | updatedAt[96:128) | ttl[128:144)
    ///      | confidence[144:160) | tau[160:176) | tauSigma[176:192) | maxDeviation[192:208)
    ///      | sourceTs[208:256) (uint48 ms, signed-path monotonic guard; 0 on legacy-only feeds).
    function _pushInternal(bytes32 feedId, uint64 newPriceB64, uint32 sigmaSample, uint16 newConfidence)
        internal
    {
        FeedData storage feed = feeds[feedId];
        uint256 slot;
        uint256 word;
        assembly ("memory-safe") {
            slot := feed.slot
            word := sload(slot)
        }
        uint32 prevAt = uint32((word >> 96) & 0xFFFFFFFF);
        if (prevAt == 0) revert Err.FeedNotFound(feedId);

        uint64 prevMarkB64 = uint64(word);
        uint256 prevMark1e18 = M.b64To1e18(prevMarkB64);
        uint256 mark1e18 = _validate(newPriceB64, sigmaSample);

        uint256 dt;
        unchecked { dt = block.timestamp - prevAt; }
        // One mark update per feed per block. The per-push clamp below bounds a move against the
        // PREVIOUS push's mark; within a single block dt==0 so the band never grows, and N pushes
        // (looped pushFeed, or a feedId repeated inside one batchPush) would each pass the band yet
        // compound geometrically to an unbounded one-tx move — exactly the drain P4/H-2 claim to
        // prevent. Rejecting a same-block re-push bounds the per-BLOCK move to a single band step and
        // makes a duplicate feedId in a batch fail-closed. Honest keepers push once per feed per tick
        // (≥ poll interval ≫ 1 block), so this never bites them.
        if (dt == 0) revert Err.CooldownActive(1);

        uint16 ttl = uint16((word >> 128) & 0xFFFF);
        // Per-feed push clamp (D1). The pool QUOTES off the raw mark (lastPriceB64), not the rate-clamped
        // EMA, so an unbounded push = mark-to-arbitrary + self-swap-drain. The allowed band grows LINEARLY
        // with staleness — maxDeviation·(1 + dt/ttl), hard-capped at MAX_DEV_THRESHOLD — so a legitimate
        // post-downtime re-sync (larger move accumulated while quiet) passes, but a compromised key can no
        // longer buy an UNBOUNDED jump by inducing staleness (H-2): the band is time-proportional and
        // monitorable, never infinite. In normal operation the keeper heartbeats < ttl so dt ≈ 0 and the
        // band ≈ maxDeviation. maxDeviation is mandatory-nonzero (addFeed/updateFeed); a 0 would fail
        // CLOSED here (band 0 rejects any move) — the safe direction. Fail-closed: REJECT out-of-band.
        _checkDeviation(prevMark1e18, mark1e18, dt, ttl, uint16((word >> 192) & 0xFFFF));

        uint16 tau = uint16((word >> 160) & 0xFFFF);
        uint16 tauSigma = uint16((word >> 176) & 0xFFFF);
        uint32 prevSigmaEma = uint32((word >> 64) & 0xFFFFFFFF);
        uint16 maxDev = uint16((word >> 192) & 0xFFFF);

        uint32 sigmaEma = Oracle.updateSigmaEma(prevSigmaEma, sigmaSample, prevMark1e18, mark1e18, dt, tauSigma);

        uint256 newWord = uint256(newPriceB64) | (uint256(sigmaEma) << 64)
            | (uint256(uint32(block.timestamp)) << 96) | (uint256(ttl) << 128) | (uint256(newConfidence) << 144)
            | (uint256(tau) << 160) | (uint256(tauSigma) << 176) | (uint256(maxDev) << 192)
            | (word & (uint256(0xFFFFFFFFFFFF) << 208)); // preserve sourceTs[208:256) (untouched by legacy path)
        assembly ("memory-safe") { sstore(slot, newWord) }
        // OBS-01: per-feed event on EVERY push (single or batch leg) — indexers/keeper-drift monitors get
        // a full per-feed mark history, not just an opaque BatchPushed(count).
        emit Pushed(feedId, newPriceB64, sigmaSample, sigmaEma, newConfidence, msg.sender);
    }

    /// @dev Signed-path writer. Differs from `_pushInternal`: (1) monotonic `sourceTs` replay guard + a
    ///      future-dated bound, (2) stores the NXR-signed σ DIRECTLY (no on-chain updateSigmaEma — the
    ///      smoothing moves to source, -800 gas) but FLOORED at |Δmark|/mark (compromised-signer backstop),
    ///      (3) no event (observability = getFeed() state polling). Same slot, same one-per-block +
    ///      deviation-band + validate guards. Auth already checked by the caller.
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
        // land and stamp updatedAt=now, reading fresh downstream. minSourceTsMs==0 → disabled.
        if (minSourceTsMs != 0 && sourceTs < minSourceTsMs) revert Err.FeedStale();

        uint256 prevMark1e18 = M.b64To1e18(uint64(word));
        uint256 mark1e18 = _validate(newPriceB64, sigma);

        uint256 dt;
        unchecked { dt = block.timestamp - prevAt; }
        if (dt == 0) revert Err.CooldownActive(1); // one mark/feed/block; duplicate idx in a batch fails closed

        uint16 ttl = uint16((word >> 128) & 0xFFFF);
        _checkDeviation(prevMark1e18, mark1e18, dt, ttl, uint16((word >> 192) & 0xFFFF));

        // σ floor (economic circuit-breaker vs a compromised signer). The signature authorizes the
        // AUTHENTICITY of the mark, NOT the volatility — a signer signing σ=0 would collapse the pricing
        // spread to the minFee floor and make a mark-then-self-swap round trip spread-free. Floor the
        // stored σ at the realized |Δmark|/mark so any mark move (even within the deviation band) forces a
        // proportional spread → the round trip is spread-NEGATIVE. Mirrors the legacy path's mark-move
        // floor in Oracle.updateSigmaEma, minus the EMA (signed path keeps its direct-σ, no-smoothing
        // design). markMovePbps caps at MAX_SIGMA_PBPS == MAX_VOLATILITY and sigma is already _validate'd
        // ≤ MAX_VOLATILITY, so sigmaStored stays within the validated σ invariant (no extra cap needed).
        uint32 moveFloor = Oracle.markMovePbps(prevMark1e18, mark1e18);
        uint32 sigmaStored = sigma > moveFloor ? sigma : moveFloor;

        // Preserve config fields (ttl/conf-slot/tau/tauSigma/maxDev) from the slot; overwrite mark, σ (direct),
        // updatedAt, confidence, sourceTs. sigmaEma[64:96) := floored signed σ (no EMA on the signed path).
        uint256 newWord = uint256(newPriceB64)
            | (uint256(sigmaStored) << 64)
            | (uint256(uint32(block.timestamp)) << 96)
            | (word & (uint256(0xFFFF) << 128)) // ttl
            | (uint256(conf) << 144)
            // GAS-22: tau|tauSigma|maxDeviation are contiguous [160:208) → preserve in one 48-bit mask.
            | (word & (uint256(0xFFFFFFFFFFFF) << 160))
            | (uint256(uint48(sourceTs)) << 208);
        assembly ("memory-safe") { sstore(slot, newWord) }
    }

    function getFeed(bytes32 feedId) external view override returns (FeedData memory data) {
        data = feeds[feedId];
        if (data.updatedAt == 0) revert Err.FeedNotFound(feedId);
    }

    function isFeedFresh(bytes32 feedId, uint32 maxAge) external view override returns (bool) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) return false;
        unchecked { return block.timestamp - f.updatedAt <= maxAge; }
    }

    function isFeedFresh(bytes32 feedId) external view override returns (bool) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) return false;
        unchecked { return block.timestamp - f.updatedAt <= f.ttl; }
    }

    function getFeedIds() external view returns (bytes32[] memory) { return feedIds; }
    function getFeedCount() external view returns (uint256) { return feedIds.length; }
    function hasFeed(bytes32 feedId) external view returns (bool) { return feeds[feedId].updatedAt != 0; }
}
