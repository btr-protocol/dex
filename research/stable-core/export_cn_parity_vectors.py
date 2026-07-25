#!/usr/bin/env python3
"""export_cn_parity_vectors.py — append the central-normal-plateau presets to the Solidity parity
vectors (evm/test/proto/quartic_vectors.json).

The shipped parity harness (evm/test/unit/NUQuartic.t.sol) enumerates EVERY key in that file, so
adding entries here is all it takes to hold the deployed shape to the same Sol-vs-reference bar as
the retired 9-preset catalogue. Reference values come from scipy's clamped quartic B-spline — the
same object lognormal_fit.py fits and emit_prod_params.py ships — evaluated on the knot domain in
x-units of 1e-4 (0..10000), exactly NUQuartic's parameterization.

Keys are `CN_W<tier>`: one per wall tier actually referenced by the Sepolia risk params, since the
central-normal shape is cell-invariant and W is the only thing that changes the weights.

Run: python3 export_cn_parity_vectors.py     (after emit_prod_params.py)
"""
import json
from pathlib import Path
import numpy as np
from scipy.interpolate import BSpline

HERE = Path(__file__).parent
VEC = HERE.parent.parent / "evm" / "test" / "proto" / "quartic_vectors.json"
RISK = HERE.parent.parent / "evm" / "deployments" / "sepolia-risk-params.json"
BPS = 10_000


def curve(interior, wQ):
    """Clamped degree-4 B-spline on [0, BPS] in NUQuartic's exact knot layout: 5x0, interior, 5xBPS."""
    t = np.r_[[0.0] * 5, np.asarray(interior, float), [float(BPS)] * 5]
    return BSpline(t, np.asarray(wQ, float), 4, extrapolate=False)


def main():
    vec = json.loads(VEC.read_text())
    risk = json.loads(RISK.read_text())
    added = []
    for p in risk["presets"]:
        interior, wQ = p["interiorB"], p["wQ"]
        assert len(wQ) == len(interior) + 5, f"preset {p['id']}: wQ/interior length mismatch"
        assert all(wQ[i] >= wQ[i - 1] for i in range(1, len(wQ))), f"preset {p['id']}: dw<0"
        key = f"CN_W{str(p['W']).replace('.', '_')}"
        if key in vec:
            continue                                    # one entry per tier; shape is cell-invariant
        b = curve(interior, wQ)
        ib = b.antiderivative()
        # Sample the seams densely (both sides) plus a uniform sweep: seam continuity is where a
        # power-basis port breaks first, so the vector must interrogate it.
        xs = sorted({0, BPS} | {int(round(x)) for x in np.linspace(0, BPS, 61)}
                    | {k + d for k in interior for d in (-1, 0, 1) if 0 <= k + d <= BPS})
        vec[key] = dict(
            interior=list(interior),
            wQ=list(wQ),
            xs=xs,
            yQ=[int(round(float(b(x)))) for x in xs],
            # areaQ integrates in x-units; NUQuartic's areaQ returns the same raw integral.
            areas=[dict(x1=x1, x2=x2, aQ=int(round(float(ib(x2) - ib(x1)))))
                   for x1, x2 in ((0, BPS), (200, BPS - 200), (0, BPS // 2), (BPS // 2, BPS))],
            wall=p["flags"] == 1,
            modes=1,
            note=f"central-normal plateau m=3, W={p['W']}, dispRef={p['dispRef']} "
                 f"(preset {p['id']}, owner-FINAL 2026-07-24)",
        )
        added.append(key)
    VEC.write_text(json.dumps(vec, indent=1))
    print("appended", added or "(nothing new)", "->", VEC.relative_to(HERE.parent.parent.parent))


if __name__ == "__main__":
    main()
