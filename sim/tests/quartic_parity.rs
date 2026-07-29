//! Parity of the f64 quartic port vs the SAME fitted vectors NUQuartic.t.sol asserts against
//! (`evm/test/proto/quartic_vectors.json`): every shape family, eval at the published xs grid and
//! O(1) areas. The vectors are integer pbps·Q (Q=1e9) snapshots of the TS fitter; the f64 port
//! carries no fixed-point truncation, so the residual budget is the vectors' own 1-unit
//! quantization (~1e-9 pbps) plus ~1e-9 relative on the areas.

use aimm_sim::amm::nuquartic::{QuarticCurve, XSPAN};
use serde_json::Value;

const Q: f64 = 1e9; // on-chain pbps fixed point carried by the vector file

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../evm/test/proto/quartic_vectors.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("quartic_vectors.json"))
        .expect("parse vectors")
}

fn floats(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

fn curve_of(entry: &Value) -> QuarticCurve {
    let interior = floats(&entry["interior"]);
    let w: Vec<f64> = floats(&entry["wQ"]).iter().map(|y| y / Q).collect();
    QuarticCurve::new(&interior, &w, 500.0, 0) // dispRef ≙ NUQuartic.t.sol's 500 (irrelevant to raw parity)
}

#[test]
fn parity_all_shapes() {
    let vec = vectors();
    let mut worst_eval = 0.0f64; // pbps·Q units, same scale NUQuartic.t.sol reports
    let mut worst_area_abs = 0.0f64; // pbps·Q·x units
    let mut worst_area_rel = 0.0f64; // over non-degenerate integrals only
    for (name, entry) in vec.as_object().unwrap() {
        let c = curve_of(entry);
        let xs = floats(&entry["xs"]);
        let y_q = floats(&entry["yQ"]);
        for (x, yq) in xs.iter().zip(&y_q) {
            let d = (c.eval(*x) * Q - yq).abs();
            worst_eval = worst_eval.max(d);
            // vector quantization is 1 unit (1e-9 pbps); allow rel 1e-9 on top for f64 roundoff
            assert!(
                d <= 2.0 + yq.abs() * 1e-9,
                "eval parity {name} x={x}: |d|={d}"
            );
        }
        for a in entry["areas"].as_array().unwrap() {
            let (x1, x2) = (a["x1"].as_f64().unwrap(), a["x2"].as_f64().unwrap());
            let aq = a["aQ"].as_f64().unwrap();
            let d = (c.area(x1, x2) * Q - aq).abs();
            // rel 1e-9 + abs floor: symmetric shapes integrate to ~0 over the full domain and the
            // vector itself is quantized to 1 pbps·Q·x unit.
            let tol = aq.abs() * 1e-9 + 2.0;
            worst_area_abs = worst_area_abs.max(d);
            if aq.abs() >= 1e6 {
                // symmetric shapes integrate to ~0 over centered bands — rel is meaningless there
                worst_area_rel = worst_area_rel.max(d / aq.abs());
            }
            assert!(
                d <= tol,
                "area parity {name} [{x1},{x2}]: |d|={d} tol={tol}"
            );
        }
    }
    println!("worst eval |d| (pbps*1e9): {worst_eval:.3}");
    println!(
        "worst area |d| (pbps*1e9*x): {worst_area_abs:.3}, rel (non-degenerate): {worst_area_rel:.3e}"
    );
}

#[test]
fn monotone_all_shapes() {
    let vec = vectors();
    for (name, entry) in vec.as_object().unwrap() {
        let c = curve_of(entry);
        let mut prev = c.eval(0.0);
        let mut x = 10.0;
        while x <= XSPAN {
            let y = c.eval(x);
            assert!(y >= prev - 1e-11, "nondecreasing {name} at x={x}");
            prev = y;
            x += 10.0;
        }
    }
}
