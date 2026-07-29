//! Cross-language parity gate: every constant `sim` shares with the deployed contracts is re-read
//! from the Solidity source and compared against `aimm_sim::amm::consts`.
//!
//! DIRECTION OF TRUTH: Solidity is normative. `dex/evm` is what is deployed; this crate mirrors it.
//! A failure here means the sim drifted (or a Solidity constant changed and the sim was not
//! updated) — fix the Rust side, never the assertion.
//!
//! Deliberately source-text driven rather than vector driven: `tests/quartic_parity.rs` already
//! covers numeric agreement against a committed fit snapshot, but a snapshot cannot notice that
//! `STALE_Z` moved from 100 to 120. Reading the `.sol` files is what makes a constant edit on
//! either side break the build.

use aimm_sim::amm::consts as c;
use std::fs;
use std::path::PathBuf;

fn sol(rel: &str) -> String {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(rel);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
}

/// Extract `<name> = <expr>;` from a Solidity constant declaration, returning the raw expression
/// with underscores and whitespace stripped.
fn decl(src: &str, name: &str) -> String {
    let needle = format!("constant {name} = ");
    let at = src.find(&needle).unwrap_or_else(|| {
        panic!("`constant {name} =` not found — declaration renamed or removed")
    });
    let rest = &src[at + needle.len()..];
    let end = rest.find(';').expect("unterminated constant declaration");
    rest[..end].replace(['_', ' '], "")
}

/// Evaluate the small arithmetic dialect the mirrored constants are written in: integer literals,
/// `1eN`, `SC.X` references, and `*` / `/` chains. Anything richer must be mirrored by hand.
fn eval(expr: &str) -> f64 {
    let mut acc: Option<f64> = None;
    let mut op = '*';
    for tok in expr.split_inclusive(['*', '/']) {
        let next_op = tok.chars().last().filter(|ch| *ch == '*' || *ch == '/');
        let raw = tok.trim_end_matches(['*', '/']);
        let cleaned = raw
            .trim_start_matches("int256(")
            .trim_start_matches("uint256(")
            .trim_end_matches(')');
        let v = match cleaned {
            "SC.WAD" => c::WAD,
            "SC.BPS" => c::BPS,
            "SC.PBPS" => c::PBPS,
            _ => cleaned
                .parse::<f64>()
                .unwrap_or_else(|_| panic!("unsupported constant expression term `{raw}`")),
        };
        acc = Some(match (acc, op) {
            (None, _) => v,
            (Some(a), '/') => a / v,
            (Some(a), _) => a * v,
        });
        if let Some(o) = next_op {
            op = o;
        }
    }
    acc.expect("empty constant expression")
}

fn assert_const(src: &str, name: &str, rust: f64) {
    let expr = decl(src, name);
    let solidity = eval(&expr);
    assert_eq!(
        solidity, rust,
        "{name}: Solidity says {expr} = {solidity}, sim has {rust} — update sim/src/amm/consts.rs"
    );
}

#[test]
fn shared_precision_constants_match() {
    let src = sol("../../shared/evm/src/Constants.sol");
    assert_const(&src, "WAD", c::WAD);
    assert_const(&src, "BPS", c::BPS);
    assert_const(&src, "PBPS", c::PBPS);
}

#[test]
fn pricing_constants_match() {
    let src = sol("../evm/src/libraries/Pricing.sol");
    assert_const(&src, "STALE_Z", c::STALE_Z);
    assert_const(&src, "STALE_GRACE_CAP_S", c::STALE_GRACE_CAP_S as f64);
    assert_const(&src, "MAX_IMPACT", c::MAX_IMPACT * c::WAD);
    assert_const(&src, "MIN_ADJ", c::MIN_ADJ * c::WAD);
    assert_const(&src, "MIN_EXEC_PRICE_BPS", c::MIN_EXEC_PRICE_BPS);
    // `-int256(SC.PBPS) * 90 / 100`: the leading unary minus is outside this dialect.
    let expr = decl(&src, "SPLINE_MIN_OFFSET_PBPS");
    let magnitude = eval(expr.trim_start_matches('-'));
    assert!(
        expr.starts_with('-'),
        "SPLINE_MIN_OFFSET_PBPS lost its sign"
    );
    assert_eq!(-magnitude, c::SPLINE_MIN_OFFSET_PBPS);
}

#[test]
fn nuquartic_constants_match() {
    let src = sol("../evm/src/libraries/NUQuartic.sol");
    assert_const(&src, "MAX_SEGS", c::MAX_SEGS as f64);
    assert_const(&src, "FLAG_REQUIRES_WALL", f64::from(c::FLAG_REQUIRES_WALL));
    // Packed-lane bounds are written as type limits, not literals; mirror them structurally.
    let q = eval(&decl(&src, "Q"));
    assert_eq!(
        q, 1e9,
        "NUQuartic.Q changed — consts.rs divides it out by hand"
    );
    assert_eq!(c::SEG_COEFF_LIMIT_PBPS, ((u64::MAX / 2) as f64) / q);
    assert_eq!(c::PREFIX_LIMIT_PBPS, (i128::MAX as f64) / q);
    assert!(
        src.contains("int256(uint256(type(uint64).max) / 2)")
            && src.contains("S > type(int128).max"),
        "NUQuartic._buildSeg overflow guards changed shape — re-derive the sim bounds"
    );
}

/// The staleness grace is a formula, not a constant, and it is the one that bricked a reference
/// oracle: pin the shape read out of `Pricing._cacheEndpoint` as well as the cap.
#[test]
fn keeper_grace_formula_matches() {
    let src = sol("../evm/src/libraries/Pricing.sol");
    let compact: String = src.chars().filter(|ch| !ch.is_whitespace()).collect();
    assert!(
        compact.contains("uint256grace=uint256(feed.ttl)/2;")
            && compact.contains("if(grace>STALE_GRACE_CAP_S)grace=STALE_GRACE_CAP_S;"),
        "Pricing._cacheEndpoint grace formula changed — mirror it in Aimm::push_grace"
    );
}
