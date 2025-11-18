/**
 * Makima interpolation utilities for liquidity profile design
 * Based on the Makima cubic spline algorithm used in contracts
 */

export interface Knot {
  x: number; // Price offset from midpoint (as % of breadth)
  y: number; // Liquidity weight
}

export interface LiquidityProfile {
  weights: number[];       // uint8[], must sum to 255
  endOffsets: number[];    // int8[], TWAP offsets as % of breadth (-100 to +100)
  slopes: number[];        // int32[], pre-computed Makima slopes (scaled by 1e9)
  baseBreadth: number;     // uint32, base breadth in bps (1M precision)
  maxBreadth: number;      // uint32, max breadth in bps
  volKappa: number;        // uint32, volatility sensitivity (1e6 precision)
}

/**
 * Compute Makima slopes for a set of knots
 * @param knots - Array of knots with x (price offset %) and y (liquidity weight)
 * @returns Array of slopes (scaled by 1e9 for int32 storage)
 */
export function computeMakimaSlopes(knots: Knot[]): number[] {
  if (knots.length < 2) return [];

  const n = knots.length;
  const slopes: number[] = [];

  // Sort knots by x
  const sortedKnots = [...knots].sort((a, b) => a.x - b.x);

  // Compute finite differences
  const deltas: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    const dx = sortedKnots[i + 1].x - sortedKnots[i].x;
    const dy = sortedKnots[i + 1].y - sortedKnots[i].y;
    deltas.push(dx !== 0 ? dy / dx : 0);
  }

  // Compute slopes using Makima algorithm
  for (let i = 0; i < n; i++) {
    if (i === 0) {
      // Left boundary: use forward difference
      slopes.push(deltas[0]);
    } else if (i === n - 1) {
      // Right boundary: use backward difference
      slopes.push(deltas[n - 2]);
    } else {
      // Interior: Makima weighted average
      const d1 = deltas[i - 1];
      const d2 = deltas[i];

      // Weights based on neighboring differences
      const w1 = Math.abs(d2 - d1);
      const w2 = Math.abs(d2 - d1);

      if (w1 + w2 === 0) {
        slopes.push((d1 + d2) / 2);
      } else {
        slopes.push((w1 * d1 + w2 * d2) / (w1 + w2));
      }
    }
  }

  // Scale slopes by 1e9 for int32 storage
  return slopes.map(s => Math.round(s * 1e9));
}

/**
 * Evaluate cubic Hermite polynomial at parameter t
 * @param t - Parameter in [0, 1]
 * @param y0 - Left knot value
 * @param y1 - Right knot value
 * @param slope0 - Left slope (scaled)
 * @param slope1 - Right slope (scaled)
 * @param dx - Segment width
 */
export function evaluateCubicHermite(
  t: number,
  y0: number,
  y1: number,
  slope0: number,
  slope1: number,
  dx: number
): number {
  // Clamp t to [0, 1]
  t = Math.max(0, Math.min(1, t));

  // Unscale slopes
  const d0 = slope0 / 1e9;
  const d1 = slope1 / 1e9;

  // Hermite basis functions
  const t2 = t * t;
  const t3 = t2 * t;

  const h00 = 2 * t3 - 3 * t2 + 1;
  const h10 = t3 - 2 * t2 + t;
  const h01 = -2 * t3 + 3 * t2;
  const h11 = t3 - t2;

  // Evaluate
  return y0 * h00 + d0 * h10 * dx + y1 * h01 + d1 * h11 * dx;
}

/**
 * Generate interpolated curve from knots
 * @param knots - Array of knots
 * @param samples - Number of sample points to generate
 */
export function interpolateCurve(knots: Knot[], samples: number = 100): { x: number; y: number }[] {
  if (knots.length < 2) return [];

  const sortedKnots = [...knots].sort((a, b) => a.x - b.x);
  const slopes = computeMakimaSlopes(sortedKnots);
  const points: { x: number; y: number }[] = [];

  for (let i = 0; i < sortedKnots.length - 1; i++) {
    const x0 = sortedKnots[i].x;
    const x1 = sortedKnots[i + 1].x;
    const y0 = sortedKnots[i].y;
    const y1 = sortedKnots[i + 1].y;
    const slope0 = slopes[i];
    const slope1 = slopes[i + 1];
    const dx = x1 - x0;

    const segmentSamples = Math.max(2, Math.floor(samples / (sortedKnots.length - 1)));

    for (let j = 0; j < segmentSamples; j++) {
      const t = j / (segmentSamples - 1);
      const x = x0 + t * dx;
      const y = evaluateCubicHermite(t, y0, y1, slope0, slope1, dx);
      points.push({ x, y });
    }
  }

  return points;
}

/**
 * Convert knots to LiquidityProfile struct
 * @param knots - Array of knots
 * @param baseBreadth - Base breadth in bps (default: 100000 = 0.1%)
 * @param maxBreadth - Max breadth in bps (default: 1000000 = 1%)
 * @param volKappa - Volatility sensitivity (default: 1000000 = 1x)
 */
export function knotsToProfile(
  knots: Knot[],
  baseBreadth: number = 100000,
  maxBreadth: number = 1000000,
  volKappa: number = 1000000
): LiquidityProfile {
  const sortedKnots = [...knots].sort((a, b) => a.x - b.x);
  const slopes = computeMakimaSlopes(sortedKnots);

  // Normalize weights to sum to 255
  const totalWeight = sortedKnots.reduce((sum, k) => sum + k.y, 0);
  const weights = sortedKnots.map(k =>
    Math.round((k.y / totalWeight) * 255)
  );

  // Adjust last weight to ensure exact sum of 255
  const weightSum = weights.reduce((a, b) => a + b, 0);
  weights[weights.length - 1] += 255 - weightSum;

  return {
    weights,
    endOffsets: sortedKnots.map(k => Math.round(k.x)),
    slopes,
    baseBreadth,
    maxBreadth,
    volKappa,
  };
}

/**
 * Encode profile for contract call
 * @param profile - Liquidity profile
 */
export function encodeProfile(profile: LiquidityProfile): string {
  return JSON.stringify({
    weights: profile.weights,
    endOffsets: profile.endOffsets,
    slopes: profile.slopes,
    baseBreadth: profile.baseBreadth,
    maxBreadth: profile.maxBreadth,
    volKappa: profile.volKappa,
  }, null, 2);
}
