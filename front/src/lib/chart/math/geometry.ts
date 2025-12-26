export interface Point {
  x: number;
  y: number;
}

export function dist(a: Point, b: Point): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  return Math.sqrt(dx * dx + dy * dy);
}

export function distToSegment(p: Point, a: Point, b: Point): number {
  const l2 = (b.x - a.x) ** 2 + (b.y - a.y) ** 2;
  if (l2 === 0) return dist(p, a);
  let t = ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / l2;
  t = Math.max(0, Math.min(1, t));
  return dist(p, { x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) });
}

export function distToLine(p: Point, a: Point, b: Point): number {
  const num = Math.abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x);
  const den = Math.sqrt((b.y - a.y) ** 2 + (b.x - a.x) ** 2);
  return den === 0 ? dist(p, a) : num / den;
}

export function intersectRayWithBox(a: Point, b: Point, w: number, h: number): Point | null {
  const dx = b.x - a.x, dy = b.y - a.y;
  if (dx === 0 && dy === 0) return null;

  const intersections: { t: number; point: Point }[] = [];

  if (dx !== 0) {
    const t0 = -a.x / dx;
    if (t0 > 1) {
      const y = a.y + t0 * dy;
      if (y >= 0 && y <= h) intersections.push({ t: t0, point: { x: 0, y } });
    }
    const t1 = (w - a.x) / dx;
    if (t1 > 1) {
      const y = a.y + t1 * dy;
      if (y >= 0 && y <= h) intersections.push({ t: t1, point: { x: w, y } });
    }
  }

  if (dy !== 0) {
    const t0 = -a.y / dy;
    if (t0 > 1) {
      const x = a.x + t0 * dx;
      if (x >= 0 && x <= w) intersections.push({ t: t0, point: { x, y: 0 } });
    }
    const t1 = (h - a.y) / dy;
    if (t1 > 1) {
      const x = a.x + t1 * dx;
      if (x >= 0 && x <= w) intersections.push({ t: t1, point: { x, y: h } });
    }
  }

  if (intersections.length === 0) return null;
  intersections.sort((x, y) => x.t - y.t);
  return intersections[0].point;
}
