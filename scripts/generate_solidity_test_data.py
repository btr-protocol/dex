#!/usr/bin/env python3
"""
Generate Solidity test data for LibSpline unit tests.

Uses unified spline_lib for consistent data generation.
All values use 1e18 scaling (WAD).
"""

from spline_lib import (
    get_all_distributions,
    compute_spline_area,
    export_solidity_test_data,
    to_wad,
)

if __name__ == "__main__":
    print("LibSpline Test Data Generator")
    print("All y-values in basis points (bps), x in [0, 10000]")
    print("WAD = 1e18 for Solidity scaling")

    distributions_gens = get_all_distributions()

    for gen in distributions_gens:
        pts, title, params = gen()
        print(f"\n{'=' * 80}")
        print(f"{title.upper()}")
        print(f"{'=' * 80}")
        print(f"\nControl Points ({len(pts)} points):")
        for x, y in pts:
            print(f"  ({x}, {y:.2f})")

        area = compute_spline_area(pts)
        print(f"\nExpected area [0, 10000]: {area:.2f}")
        print(f"WAD-scaled area: {to_wad(area)}")

        print(f"\n// Solidity test data:")
        export_solidity_test_data(pts, title)

    print(f"\n{'=' * 80}")
    print("GENERATION COMPLETE")
    print(f"{'=' * 80}")
