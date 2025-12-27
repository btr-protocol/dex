/**
 * Unified spline interpolation utilities
 * Supports both Catmull-Rom/Monotone Cubic Hermite and Makima algorithms
 */

// ============ Shared Types ============

export interface Knot {
  x: number;
  y: number;
}

// ============ Catmull-Rom / Monotone Cubic Hermite ============

export namespace CatmullRom {
  export interface LiquidityProfile {
    weights: number[];    // uint8[], must sum to 200
    knots: number[];      // int8[17], price offset knots
    baseBreadth: number;  // uint32, base breadth in bps
    maxBreadth: number;   // uint32, max breadth in bps
    volKappa: number;     // uint32, volatility sensitivity
  }

  export function computeTangents(knots: Knot[]): number[] {
    if (knots.length < 2) return [];

    const n = knots.length;
    const tangents: number[] = new Array(n);
    const secants: number[] = [];

    for (let i = 0; i < n - 1; i++) {
      const dx = knots[i + 1].x - knots[i].x;
      const dy = knots[i + 1].y - knots[i].y;
      secants.push(dx !== 0 ? dy / dx : 0);
    }

    for (let i = 0; i < n; i++) {
      if (i === 0) {
        tangents[i] = secants[0];
      } else if (i === n - 1) {
        tangents[i] = secants[n - 2];
      } else {
        const s1 = secants[i - 1];
        const s2 = secants[i];
        tangents[i] =
          (s1 < 0 && s2 > 0) || (s1 > 0 && s2 < 0) ? 0 : (s1 + s2) / 2;
      }
    }

    return tangents;
  }

  export function evaluateHermite(
    t: number,
    y0: number,
    y1: number,
    m0: number,
    m1: number,
    dx: number
  ): number {
    t = Math.max(0, Math.min(1, t));
    const t2 = t * t;
    const t3 = t2 * t;

    const h00 = 2 * t3 - 3 * t2 + 1;
    const h10 = t3 - 2 * t2 + t;
    const h01 = -2 * t3 + 3 * t2;
    const h11 = t3 - t2;

    return y0 * h00 + m0 * h10 * dx + y1 * h01 + m1 * h11 * dx;
  }

  export function interpolateCurve(
    knots: Knot[],
    samples: number = 100
  ): { x: number; y: number }[] {
    if (knots.length < 2) return [];

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

  export function knotsToProfile(
    knots: Knot[],
    baseBreadth: number = 100000,
    maxBreadth: number = 1000000,
    volKappa: number = 1000000
  ): LiquidityProfile {
    const sortedKnots = [...knots].sort((a, b) => a.x - b.x);
    const WEIGHT_SUM = 200;
    const weights: number[] = [];

    for (let i = 1; i < sortedKnots.length; i++) {
      const dx = sortedKnots[i].x - sortedKnots[i - 1].x;
      weights.push(Math.round((dx * WEIGHT_SUM) / 10000));
    }

    const weightSum = weights.reduce((a, b) => a + b, 0);
    if (weights.length > 0) {
      weights[weights.length - 1] += WEIGHT_SUM - weightSum;
    }

    while (weights.length < 16) weights.push(0);

    const knotsArray = sortedKnots.map((k) => Math.round(k.y));
    while (knotsArray.length < 17) knotsArray.push(0);

    return { weights, knots: knotsArray, baseBreadth, maxBreadth, volKappa };
  }

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

  export function buildSplinePoints(
    weights: number[],
    knots: number[],
    dispersion: number = 10000
  ): Knot[] {
    const WEIGHT_SUM = 200;
    const points: Knot[] = [];

    let segmentCount = 0;
    for (let i = 0; i < 16; i++) {
      if (weights[i] === 0) break;
      segmentCount++;
    }

    const firstOffsetBps = (knots[0] * dispersion) / 100;
    points.push({ x: 0, y: firstOffsetBps });

    let cumulativeWeight = 0;
    for (let i = 0; i < segmentCount; i++) {
      cumulativeWeight += weights[i];
      const xPos = (cumulativeWeight * 10000) / WEIGHT_SUM;
      const offsetBps = (knots[i + 1] * dispersion) / 100;
      points.push({ x: xPos, y: offsetBps });
    }

    return points;
  }

  export function evalSpline(x: number, points: Knot[]): number {
    if (points.length === 0) return 0;
    if (points.length === 1 || x <= points[0].x) return points[0].y;
    if (x >= points[points.length - 1].x) return points[points.length - 1].y;

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

    const tangents = computeTangents(points);
    const m0 = tangents[i];
    const m1 = tangents[i + 1];
    const t = (x - p0.x) / dx;

    return evaluateHermite(t, p0.y, p1.y, m0, m1, dx);
  }
}

// ============ Makima ============

export namespace Makima {
  export interface LiquidityProfile {
    weights: number[];      // uint8[], must sum to 255
    endOffsets: number[];   // int8[], TWAP offsets as % of breadth
    slopes: number[];       // int32[], pre-computed Makima slopes (scaled by 1e9)
    baseBreadth: number;    // uint32, base breadth in bps
    maxBreadth: number;     // uint32, max breadth in bps
    volKappa: number;       // uint32, volatility sensitivity
  }

  export function computeMakimaSlopes(knots: Knot[]): number[] {
    if (knots.length < 2) return [];

    const n = knots.length;
    const slopes: number[] = [];
    const sortedKnots = [...knots].sort((a, b) => a.x - b.x);

    const deltas: number[] = [];
    for (let i = 0; i < n - 1; i++) {
      const dx = sortedKnots[i + 1].x - sortedKnots[i].x;
      const dy = sortedKnots[i + 1].y - sortedKnots[i].y;
      deltas.push(dx !== 0 ? dy / dx : 0);
    }

    for (let i = 0; i < n; i++) {
      if (i === 0) {
        slopes.push(deltas[0]);
      } else if (i === n - 1) {
        slopes.push(deltas[n - 2]);
      } else {
        const d1 = deltas[i - 1];
        const d2 = deltas[i];
        const w1 = Math.abs(d2 - d1);
        const w2 = Math.abs(d2 - d1);

        slopes.push(w1 + w2 === 0 ? (d1 + d2) / 2 : (w1 * d1 + w2 * d2) / (w1 + w2));
      }
    }

    return slopes.map((s) => Math.round(s * 1e9));
  }

  export function evaluateCubicHermite(
    t: number,
    y0: number,
    y1: number,
    slope0: number,
    slope1: number,
    dx: number
  ): number {
    t = Math.max(0, Math.min(1, t));
    const d0 = slope0 / 1e9;
    const d1 = slope1 / 1e9;

    const t2 = t * t;
    const t3 = t2 * t;

    const h00 = 2 * t3 - 3 * t2 + 1;
    const h10 = t3 - 2 * t2 + t;
    const h01 = -2 * t3 + 3 * t2;
    const h11 = t3 - t2;

    return y0 * h00 + d0 * h10 * dx + y1 * h01 + d1 * h11 * dx;
  }

  export function interpolateCurve(
    knots: Knot[],
    samples: number = 100
  ): { x: number; y: number }[] {
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

      const segmentSamples = Math.max(
        2,
        Math.floor(samples / (sortedKnots.length - 1))
      );

      for (let j = 0; j < segmentSamples; j++) {
        const t = j / (segmentSamples - 1);
        const x = x0 + t * dx;
        const y = evaluateCubicHermite(t, y0, y1, slope0, slope1, dx);
        points.push({ x, y });
      }
    }

    return points;
  }

  export function knotsToProfile(
    knots: Knot[],
    baseBreadth: number = 100000,
    maxBreadth: number = 1000000,
    volKappa: number = 1000000
  ): LiquidityProfile {
    const sortedKnots = [...knots].sort((a, b) => a.x - b.x);
    const slopes = computeMakimaSlopes(sortedKnots);

    const totalWeight = sortedKnots.reduce((sum, k) => sum + k.y, 0);
    const weights = sortedKnots.map((k) =>
      Math.round((k.y / totalWeight) * 255)
    );

    const weightSum = weights.reduce((a, b) => a + b, 0);
    weights[weights.length - 1] += 255 - weightSum;

    return {
      weights,
      endOffsets: sortedKnots.map((k) => Math.round(k.x)),
      slopes,
      baseBreadth,
      maxBreadth,
      volKappa,
    };
  }

  export function encodeProfile(profile: LiquidityProfile): string {
    return JSON.stringify(
      {
        weights: profile.weights,
        endOffsets: profile.endOffsets,
        slopes: profile.slopes,
        baseBreadth: profile.baseBreadth,
        maxBreadth: profile.maxBreadth,
        volKappa: profile.volKappa,
      },
      null,
      2
    );
  }
}
