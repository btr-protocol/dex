/**
 * Catmull-Rom / Monotone Cubic Hermite Spline utilities for liquidity profile design
 * Based on the Monotone Cubic Hermite Spline implementation in LibSpline.sol
 *
 * This implementation matches the on-chain spline behavior for accurate UI representation
 * of liquidity profiles with:
 * - Monotone tangent computation (preserves monotonicity)
 * - Cubic Hermite interpolation for smooth curves
 * - Exact same knot/offset semantics as contracts
 */

export interface Knot {
  x: number; // Cumulative depth (0 to 10000 = 0% to 100%)
  y: number; // Price offset in BPS units
}

export interface LiquidityProfile {
  weights: number[];       // uint8[], must sum to 200
  knots: number[];         // int8[17], price offset knots in % of dispersion (e.g., -50 = -50% of dispersion)
  baseBreadth: number;     // uint32, base breadth in bps
  maxBreadth: number;      // uint32, max breadth in bps
  volKappa: number;        // uint32, volatility sensitivity
}

/**
 * Compute monotone cubic Hermite tangents for spline interpolation
 * Uses monotonicity-preserving algorithm from LibSpline.sol
 * @param knots Array of control points (must be sorted by x)
 * @returns Tangent slopes at each knot
 */
export function computeTangents(knots: Knot[]): number[] {
  if (knots.length < 2) return [];

  const n = knots.length;
  const tangents: number[] = new Array(n);

  // Compute finite differences (secants)
  const secants: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    const dx = knots[i + 1].x - knots[i].x;
    const dy = knots[i + 1].y - knots[i].y;
    secants.push(dx !== 0 ? dy / dx : 0);
  }

  // Compute tangents using monotonicity-preserving algorithm
  for (let i = 0; i < n; i++) {
    if (i === 0) {
      // Left boundary: use forward difference
      tangents[i] = secants[0];
    } else if (i === n - 1) {
      // Right boundary: use backward difference
      tangents[i] = secants[n - 2];
    } else {
      // Interior point: weighted average of adjacent secants
      // If secants have different signs, use 0 (monotonicity constraint)
      const s1 = secants[i - 1];
      const s2 = secants[i];

      // Sign differs => zero tangent (monotonicity preservation)
      if ((s1 < 0 && s2 > 0) || (s1 > 0 && s2 < 0)) {
        tangents[i] = 0;
      } else {
        // Same sign: average the secants
        tangents[i] = (s1 + s2) / 2;
      }
    }
  }

  return tangents;
}

/**
 * Evaluate cubic Hermite polynomial at parameter t in [0, 1]
 * Formula: y(t) = y0*h00(t) + m0*h10(t) + y1*h01(t) + m1*h11(t)
 * where h00, h10, h01, h11 are Hermite basis functions
 */
export function evaluateHermite(
  t: number,
  y0: number,
  y1: number,
  m0: number, // left tangent
  m1: number, // right tangent
  dx: number  // segment width
): number {
  // Clamp t to [0, 1]
  t = Math.max(0, Math.min(1, t));

  const t2 = t * t;
  const t3 = t2 * t;

  // Hermite basis functions
  const h00 = 2 * t3 - 3 * t2 + 1;
  const h10 = t3 - 2 * t2 + t;
  const h01 = -2 * t3 + 3 * t2;
  const h11 = t3 - t2;

  return y0 * h00 + m0 * h10 * dx + y1 * h01 + m1 * h11 * dx;
}

/**
 * Interpolate curve from knots with Catmull-Rom / Monotone Cubic Hermite
 * @param knots Sorted array of control knots
 * @param samples Number of sample points to generate
 * @returns Array of interpolated points
 */
export function interpolateCurve(
  knots: Knot[],
  samples: number = 100
): { x: number; y: number }[] {
  if (knots.length < 2) return [];

  // Sort knots by x
  const sortedKnots = [...knots].sort((a, b) => a.x - b.x);
  const tangents = computeTangents(sortedKnots);
  const points: { x: number; y: number }[] = [];

  for (let i = 0; i < sortedKnots.length - 1; i++) {
    const x0 = sortedKnots[i].x;
    const x1 = sortedKnots[i + 1].x;
    const y0 = sortedKnots[i].y;
    const y1 = sortedKnots[i + 1].y;
    const m0 = tangents[i];
    const m1 = tangents[i + 1];
    const dx = x1 - x0;

    const segmentSamples = Math.max(
      2,
      Math.floor(samples / (sortedKnots.length - 1))
    );

    for (let j = 0; j < segmentSamples; j++) {
      const t = j / (segmentSamples - 1);
      const x = x0 + t * dx;
      const y = evaluateHermite(t, y0, y1, m0, m1, dx);
      points.push({ x, y });
    }
  }

  return points;
}

/**
 * Convert knots to LiquidityProfile struct
 * Normalizes weights to sum to 200 (contract requirement)
 * Maps x-coordinates from [0, 10000] domain
 * @param knots Array of knots
 * @param baseBreadth Base breadth in bps (default: 100000 = 0.1%)
 * @param maxBreadth Max breadth in bps (default: 1000000 = 1%)
 * @param volKappa Volatility sensitivity (default: 1000000 = 1x)
 */
export function knotsToProfile(
  knots: Knot[],
  baseBreadth: number = 100000,
  maxBreadth: number = 1000000,
  volKappa: number = 1000000
): LiquidityProfile {
  const sortedKnots = [...knots].sort((a, b) => a.x - b.x);

  // Normalize weights to sum to 200 (contract requirement)
  // Compute cumulative weights from x-coordinates
  const WEIGHT_SUM = 200;
  const weights: number[] = [];

  // Weights are the differences between consecutive x values
  for (let i = 1; i < sortedKnots.length; i++) {
    const dx = sortedKnots[i].x - sortedKnots[i - 1].x;
    const w = (dx * WEIGHT_SUM) / 10000;
    weights.push(Math.round(w));
  }

  // Adjust last weight to ensure exact sum of 200
  const weightSum = weights.reduce((a, b) => a + b, 0);
  if (weights.length > 0) {
    weights[weights.length - 1] += WEIGHT_SUM - weightSum;
  }

  // Pad to 16 segments (contract requirement)
  while (weights.length < 16) {
    weights.push(0);
  }

  // Knots are the y values (need weights.length + 1 = up to 17 knots)
  const knotsArray = sortedKnots.map((k) => Math.round(k.y));
  while (knotsArray.length < 17) {
    knotsArray.push(0);
  }

  return {
    weights,
    knots: knotsArray,
    baseBreadth,
    maxBreadth,
    volKappa,
  };
}

/**
 * Encode profile for contract call / export
 */
export function encodeProfile(profile: LiquidityProfile): string {
  return JSON.stringify(
    {
      weights: profile.weights.slice(0, 16),
      knots: profile.knots.slice(0, 17),
      baseBreadth: profile.baseBreadth,
      maxBreadth: profile.maxBreadth,
      volKappa: profile.volKappa,
    },
    null,
    2
  );
}

/**
 * Build spline points from liquidity profile for visualization
 * Matches the _buildSplinePoints logic from LibPricing.sol
 * @param weights Weight array (sum to 200)
 * @param knots Knot offset values as % of dispersion range around TWAP (e.g., -50 = -50% of dispersion)
 * @param dispersion Dispersion breadth around TWAP in bps (e.g., 10000 = ±1% range around TWAP)
 * @returns Array of spline control points
 *
 * Relationship:
 * - Dispersion defines liquidity range around TWAP (e.g., 1% = ±1% around TWAP)
 * - Knots are % of this dispersion range
 * - Formula: priceOffset = knot × dispersion / 100
 * - Example: TWAP=$1.00, dispersion=10000 (1%), knot=-50
 *   → offset = -50 × 10000 / 100 = -5000 bps = -0.5% from TWAP
 *   → price = $1.00 × (1 - 0.005) = $0.995
 */
export function buildSplinePoints(
  weights: number[],
  knots: number[],
  dispersion: number = 10000
): Knot[] {
  const WEIGHT_SUM = 200;
  const points: Knot[] = [];

  // Count valid segments (stop at first zero weight)
  let segmentCount = 0;
  for (let i = 0; i < 16; i++) {
    if (weights[i] === 0) break;
    segmentCount++;
  }

  // First knot: starting point at x=0
  const firstOffsetBps = (knots[0] * dispersion) / 100;
  points.push({
    x: 0,
    y: firstOffsetBps,
  });

  // Build remaining knot points from segments
  let cumulativeWeight = 0;
  for (let i = 0; i < segmentCount; i++) {
    cumulativeWeight += weights[i];

    // Rescale to [0, 10000] domain
    const xPos = (cumulativeWeight * 10000) / WEIGHT_SUM;
    const offsetBps = (knots[i + 1] * dispersion) / 100;

    points.push({
      x: xPos,
      y: offsetBps,
    });
  }

  return points;
}

/**
 * Evaluate spline at a specific x position
 * @param x Target x position (0 to 10000)
 * @param points Spline control points
 * @returns Interpolated y value
 */
export function evalSpline(x: number, points: Knot[]): number {
  if (points.length === 0) return 0;
  if (points.length === 1 || x <= points[0].x) return points[0].y;
  if (x >= points[points.length - 1].x) return points[points.length - 1].y;

  // Binary search for segment containing x
  let low = 0;
  let high = points.length - 2;
  while (low < high) {
    const mid = Math.floor((low + high + 1) / 2);
    if (x < points[mid].x) high = mid - 1;
    else low = mid;
  }

  const i = low;
  const p0 = points[i];
  const p1 = points[i + 1];

  const dx = p1.x - p0.x;
  if (dx === 0) return p0.y;

  // Get tangents
  const tangents = computeTangents(points);
  const m0 = tangents[i];
  const m1 = tangents[i + 1];

  // Evaluate Hermite at t
  const t = (x - p0.x) / dx;
  return evaluateHermite(t, p0.y, p1.y, m0, m1, dx);
}
