/**
 * Drawing Tools Plugin for Lightweight Charts
 * Clean, optimized implementation using Series Primitives
 */
import type {
  ISeriesPrimitive,
  IPrimitivePaneView,
  IPrimitivePaneRenderer,
  PrimitivePaneViewZOrder,
  Time,
  IChartApi,
  ISeriesApi,
  SeriesType,
  IPriceLine,
  CreatePriceLineOptions,
  LineStyle,
} from 'lightweight-charts';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export type DrawingToolType =
  | 'freedraw'
  | 'highlight'
  | 'vertical'
  | 'horizontal'
  | 'cross'
  | 'trendline'
  | 'ray'
  | 'extended'
  | 'rectangle'
  | 'circle'
  | 'triangle'
  | 'channel';

export interface Point {
  x: number;
  y: number;
}

export interface DrawingPoint {
  logical: number;
  price: number;
}

export interface DrawingStyle {
  color: string;
  lineWidth: number;
  lineStyle: 'solid' | 'dashed' | 'dotted';
  fillColor?: string;
  fillOpacity?: number;
}

export interface Drawing {
  id: string;
  type: DrawingToolType;
  points: DrawingPoint[];
  style: DrawingStyle;
  locked?: boolean;
  paneIndex?: number; // 0 = main pane, 1+ = sub-panes
}

interface DrawingState {
  drawings: Drawing[];
  selectedIds: Set<string>;
}

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────

// Default style factory: uses theme colors
function createDefaultStyle(color: string): DrawingStyle {
  return {
    color,
    lineWidth: 2,
    lineStyle: 'solid', // Will be overridden per-tool in setTool()
    fillColor: color,
    fillOpacity: 0.05,
  };
}

const HIT_TOLERANCE = 8;

// ─────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────

const genId = () => Math.random().toString(36).slice(2, 10);

function dist(a: Point, b: Point): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  return Math.sqrt(dx * dx + dy * dy);
}

function distToSegment(p: Point, a: Point, b: Point): number {
  const l2 = (b.x - a.x) ** 2 + (b.y - a.y) ** 2;
  if (l2 === 0) return dist(p, a);
  let t = ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / l2;
  t = Math.max(0, Math.min(1, t));
  return dist(p, { x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) });
}

function distToLine(p: Point, a: Point, b: Point): number {
  const num = Math.abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x);
  const den = Math.sqrt((b.y - a.y) ** 2 + (b.x - a.x) ** 2);
  return den === 0 ? dist(p, a) : num / den;
}

function setDash(ctx: CanvasRenderingContext2D, style: 'solid' | 'dashed' | 'dotted', width: number) {
  if (style === 'dashed') {
    ctx.setLineDash([width * 2, width * 1.5]);
  } else if (style === 'dotted') {
    ctx.setLineDash([width, width * 2]);
  } else {
    ctx.setLineDash([]);
  }
}

// Intersect ray from origin a through direction point b with box edges
// Returns the furthest intersection point (to extend past b)
function intersectRayWithBox(a: Point, b: Point, w: number, h: number): Point | null {
  const dx = b.x - a.x, dy = b.y - a.y;
  if (dx === 0 && dy === 0) return null;

  // Find all valid t values where P(t) = a + t*(b-a) hits a box edge
  // t > 1 means we're extending beyond point b (in the direction from a through b)
  const intersections: { t: number; point: Point }[] = [];

  // Check each edge, ensuring intersection is within the edge bounds
  // Left edge (x=0)
  if (dx !== 0) {
    const t = -a.x / dx;
    if (t > 1) {  // Must be beyond point b
      const y = a.y + t * dy;
      if (y >= 0 && y <= h) {
        intersections.push({ t, point: { x: 0, y } });
      }
    }
  }

  // Right edge (x=w)
  if (dx !== 0) {
    const t = (w - a.x) / dx;
    if (t > 1) {  // Must be beyond point b
      const y = a.y + t * dy;
      if (y >= 0 && y <= h) {
        intersections.push({ t, point: { x: w, y } });
      }
    }
  }

  // Top edge (y=0)
  if (dy !== 0) {
    const t = -a.y / dy;
    if (t > 1) {  // Must be beyond point b
      const x = a.x + t * dx;
      if (x >= 0 && x <= w) {
        intersections.push({ t, point: { x, y: 0 } });
      }
    }
  }

  // Bottom edge (y=h)
  if (dy !== 0) {
    const t = (h - a.y) / dy;
    if (t > 1) {  // Must be beyond point b
      const x = a.x + t * dx;
      if (x >= 0 && x <= w) {
        intersections.push({ t, point: { x, y: h } });
      }
    }
  }

  if (intersections.length === 0) return null;

  // Sort by t and return the first valid intersection (closest to b but beyond it)
  intersections.sort((x, y) => x.t - y.t);
  return intersections[0].point;
}

// ─────────────────────────────────────────────────────────────
// Renderer
// ─────────────────────────────────────────────────────────────

interface RenderData {
  drawings: Drawing[];
  selectedIds: Set<string>;
  hoveredId: string | null;
  toScreen: (pt: DrawingPoint) => Point | null;
  toScreenX: (pt: DrawingPoint) => number | null;  // For vertical lines
  toScreenY: (pt: DrawingPoint) => number | null;  // For horizontal lines
  selectionRect?: { start: Point; end: Point } | null;
  themeColor: string;
  themeFg0: string;
}

const _ptsBuffer: Point[] = [];
const _sptsBuffer: Point[] = [];

class DrawingRenderer implements IPrimitivePaneRenderer {
  private _data: RenderData;

  constructor(data: RenderData) {
    this._data = data;
  }

  setData(data: RenderData): void {
    this._data = data;
  }

  draw(target: any): void {
    target.useBitmapCoordinateSpace((scope: any) => {
      const ctx: CanvasRenderingContext2D = scope.context;
      const ratio = scope.horizontalPixelRatio ?? 1;
      const { drawings, selectedIds, hoveredId, toScreen, toScreenX, toScreenY, selectionRect } = this._data;
      // Use actual canvas dimensions instead of passed-in values (which may be 0)
      const W = ctx.canvas.width;
      const H = ctx.canvas.height;

      for (let di = 0; di < drawings.length; di++) {
        const d = drawings[di];
        const isTemp = d.id === '__temp__';

        // For single-point tools (vertical/horizontal/cross), handle coordinate conversion specially
        const isSinglePointLine = d.type === 'vertical' || d.type === 'horizontal' || d.type === 'cross';

        _ptsBuffer.length = 0;
        if (isSinglePointLine && d.points.length > 0) {
          // For single-point lines, we only need the relevant coordinate
          const pt = d.points[0];
          const x = toScreenX(pt);
          const y = toScreenY(pt);
          // For vertical, we need valid x; for horizontal, we need valid y; for cross, we need both
          const hasValidCoords =
            (d.type === 'vertical' && x !== null) ||
            (d.type === 'horizontal' && y !== null) ||
            (d.type === 'cross' && x !== null && y !== null);
          if (hasValidCoords) {
            _ptsBuffer.push({
              x: x ?? W / (2 * ratio),
              y: y ?? H / (2 * ratio)
            });
          }
        } else {
          for (let i = 0; i < d.points.length; i++) {
            const p = toScreen(d.points[i]);
            if (p) _ptsBuffer.push(p);
          }
        }
        if (_ptsBuffer.length === 0) continue;

        _sptsBuffer.length = 0;
        for (let i = 0; i < _ptsBuffer.length; i++) {
          _sptsBuffer.push({ x: _ptsBuffer[i].x * ratio, y: _ptsBuffer[i].y * ratio });
        }

        const isSelected = selectedIds.has(d.id);
        const isHovered = d.id === hoveredId;
        const { color, lineWidth, fillColor, fillOpacity } = d.style;
        // Use dashed style for temp/preview drawings
        const lineStyle = isTemp ? 'dashed' : d.style.lineStyle;

        // For highlight, use semi-transparent color and thicker line
        const isHighlight = d.type === 'highlight';
        const effectiveLineWidth = isHighlight ? 20 : lineWidth;

        // Skip stroke if color is 'transparent'
        const hasStroke = color !== 'transparent';
        if (hasStroke) {
          if (isHighlight) {
            // Make highlight semi-transparent
            ctx.globalAlpha = 0.4;
          }
          ctx.strokeStyle = color;
          ctx.lineWidth = effectiveLineWidth * ratio;
        }
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        setDash(ctx, lineStyle, effectiveLineWidth * ratio);

        const spts = _sptsBuffer;

        switch (d.type) {
          case 'freedraw':
          case 'highlight':
            if (hasStroke) this._drawPath(ctx, spts, false);
            if (isHighlight) ctx.globalAlpha = 1;
            break;

          case 'vertical':
            // Only draw for temp/preview - finalized verticals use DOM overlay
            if (spts[0] && hasStroke && isTemp) {
              this._drawVertical(ctx, spts[0].x, H);
            }
            break;

          case 'horizontal':
            // Only draw line for temp/preview - finalized horizontals use native PriceLine
            if (spts[0] && hasStroke && isTemp) {
              this._drawHorizontal(ctx, spts[0].y, W);
            }
            break;

          case 'cross':
            // Only draw for temp/preview - finalized crosses use DOM overlay
            if (spts[0] && hasStroke && isTemp) {
              this._drawVertical(ctx, spts[0].x, H);
              this._drawHorizontal(ctx, spts[0].y, W);
            }
            break;

          case 'trendline':
            if (spts.length >= 2 && hasStroke) this._drawSegment(ctx, spts[0], spts[1]);
            break;

          case 'ray':
            if (spts.length >= 2 && hasStroke) this._drawRay(ctx, spts[0], spts[1], W, H);
            break;

          case 'extended':
            if (spts.length >= 2 && hasStroke) this._drawExtended(ctx, spts[0], spts[1], W, H);
            break;

          case 'rectangle':
            if (spts.length >= 2) this._drawRect(ctx, spts[0], spts[1], fillColor, fillOpacity, hasStroke);
            break;

          case 'circle':
            if (spts.length >= 2) this._drawCircle(ctx, spts[0], spts[1], fillColor, fillOpacity, hasStroke);
            break;

          case 'triangle':
            // Show preview lines while placing points
            if (spts.length === 2 && hasStroke) {
              // Show line from first to second point
              this._drawSegment(ctx, spts[0], spts[1]);
            } else if (spts.length >= 3) {
              this._drawTriangle(ctx, spts[0], spts[1], spts[2], fillColor, fillOpacity, hasStroke);
            }
            break;

          case 'channel':
            // Show preview ray while placing points (center line)
            if (spts.length === 2 && hasStroke) {
              this._drawRay(ctx, spts[0], spts[1], W, H);
            } else if (spts.length >= 3) {
              this._drawChannel(ctx, spts[0], spts[1], spts[2], W, H, fillColor, fillOpacity, hasStroke, lineStyle, effectiveLineWidth * ratio);
            }
            break;
        }

        if (isSelected || isHovered) {
          const anchorColor = isSelected ? (hasStroke ? color : this._data.themeColor) : `${this._data.themeFg0}99`; // 60% opacity
          this._drawAnchors(ctx, spts, anchorColor, ratio);
        }
      }

      if (selectionRect) {
        const { start, end } = selectionRect;
        const x = Math.min(start.x, end.x) * ratio;
        const y = Math.min(start.y, end.y) * ratio;
        const w = Math.abs(end.x - start.x) * ratio;
        const h = Math.abs(end.y - start.y) * ratio;

        // Use theme color with alpha for selection rectangle
        const colorMatch = this._data.themeColor.match(/^#([0-9a-f]{6})$/i);
        const rgb = colorMatch ? colorMatch[1] : '3d7eff';
        const r = parseInt(rgb.slice(0, 2), 16);
        const g = parseInt(rgb.slice(2, 4), 16);
        const b = parseInt(rgb.slice(4, 6), 16);
        ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.8)`;
        ctx.fillStyle = `rgba(${r}, ${g}, ${b}, 0.1)`;
        ctx.lineWidth = ratio;
        ctx.setLineDash([4 * ratio, 2 * ratio]);
        ctx.fillRect(x, y, w, h);
        ctx.strokeRect(x, y, w, h);
        ctx.setLineDash([]);
      }
    });
  }

  private _drawPath(ctx: CanvasRenderingContext2D, pts: Point[], closed: boolean) {
    if (pts.length < 2) return;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    if (closed) ctx.closePath();
    ctx.stroke();
  }

  private _drawSegment(ctx: CanvasRenderingContext2D, a: Point, b: Point) {
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.stroke();
  }

  private _drawVertical(ctx: CanvasRenderingContext2D, x: number, h: number) {
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
  }

  private _drawHorizontal(ctx: CanvasRenderingContext2D, y: number, w: number) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  private _drawRay(ctx: CanvasRenderingContext2D, a: Point, b: Point, w: number, h: number) {
    // Ray from a through b, extending to the edge of the canvas
    const end = intersectRayWithBox(a, b, w, h);
    if (end) {
      this._drawSegment(ctx, a, end);
    } else {
      // Fallback: draw to b
      this._drawSegment(ctx, a, b);
    }
  }

  private _drawExtended(ctx: CanvasRenderingContext2D, a: Point, b: Point, w: number, h: number) {
    const dx = b.x - a.x, dy = b.y - a.y;
    if (dx === 0 && dy === 0) return;

    const intersections: Point[] = [];

    // Check all four edges
    if (dx !== 0) {
      // Left edge (x=0)
      const t0 = -a.x / dx;
      const y0 = a.y + dy * t0;
      if (y0 >= 0 && y0 <= h) intersections.push({ x: 0, y: y0 });

      // Right edge (x=w)
      const t1 = (w - a.x) / dx;
      const y1 = a.y + dy * t1;
      if (y1 >= 0 && y1 <= h) intersections.push({ x: w, y: y1 });
    }

    if (dy !== 0) {
      // Top edge (y=0)
      const t0 = -a.y / dy;
      const x0 = a.x + dx * t0;
      if (x0 >= 0 && x0 <= w) intersections.push({ x: x0, y: 0 });

      // Bottom edge (y=h)
      const t1 = (h - a.y) / dy;
      const x1 = a.x + dx * t1;
      if (x1 >= 0 && x1 <= w) intersections.push({ x: x1, y: h });
    }

    // Handle vertical/horizontal lines
    if (dx === 0) {
      this._drawVertical(ctx, a.x, h);
      return;
    }
    if (dy === 0) {
      this._drawHorizontal(ctx, a.y, w);
      return;
    }

    if (intersections.length >= 2) {
      // Sort by x then y to get consistent ordering
      intersections.sort((p1, p2) => p1.x - p2.x || p1.y - p2.y);
      this._drawSegment(ctx, intersections[0], intersections[intersections.length - 1]);
    }
  }

  private _drawRect(ctx: CanvasRenderingContext2D, a: Point, b: Point, fill?: string, opacity?: number, hasStroke = true) {
    const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    const w = Math.abs(b.x - a.x), hh = Math.abs(b.y - a.y);

    ctx.beginPath();
    ctx.rect(x, y, w, hh);

    if (fill && fill !== 'transparent') {
      ctx.fillStyle = fill;
      ctx.globalAlpha = opacity ?? 0.05;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    if (hasStroke) ctx.stroke();
  }

  private _drawCircle(ctx: CanvasRenderingContext2D, center: Point, edge: Point, fill?: string, opacity?: number, hasStroke = true) {
    const r = dist(center, edge);
    ctx.beginPath();
    ctx.arc(center.x, center.y, r, 0, Math.PI * 2);

    if (fill && fill !== 'transparent') {
      ctx.fillStyle = fill;
      ctx.globalAlpha = opacity ?? 0.05;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    if (hasStroke) ctx.stroke();
  }

  private _drawTriangle(ctx: CanvasRenderingContext2D, a: Point, b: Point, c: Point, fill?: string, opacity?: number, hasStroke = true) {
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.lineTo(c.x, c.y);
    ctx.closePath();

    if (fill && fill !== 'transparent') {
      ctx.fillStyle = fill;
      ctx.globalAlpha = opacity ?? 0.05;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    if (hasStroke) ctx.stroke();
  }

  private _drawChannel(ctx: CanvasRenderingContext2D, a: Point, b: Point, c: Point, w: number, h: number, fill?: string, opacity?: number, hasStroke = true, lineStyle: 'solid' | 'dashed' | 'dotted' = 'dashed', lineWidth = 2) {
    const dx = b.x - a.x, dy = b.y - a.y;
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;

    // Perpendicular unit vector
    const px = -dy / len, py = dx / len;

    // Calculate perpendicular distance from point c to the center line (a->b)
    // Using signed distance to preserve direction
    const acx = c.x - a.x, acy = c.y - a.y;
    const perpDist = acx * px + acy * py;

    // Upper and lower line offsets (symmetric around center)
    const upperStart = { x: a.x + px * perpDist, y: a.y + py * perpDist };
    const upperEnd = { x: b.x + px * perpDist, y: b.y + py * perpDist };
    const lowerStart = { x: a.x - px * perpDist, y: a.y - py * perpDist };
    const lowerEnd = { x: b.x - px * perpDist, y: b.y - py * perpDist };

    // Fill between upper and lower rays
    if (fill && fill !== 'transparent') {
      ctx.fillStyle = fill;
      ctx.globalAlpha = opacity ?? 0.05;

      // Get ray endpoints extended to edges
      const upperEdge = intersectRayWithBox(upperStart, upperEnd, w, h);
      const lowerEdge = intersectRayWithBox(lowerStart, lowerEnd, w, h);

      if (upperEdge && lowerEdge) {
        ctx.beginPath();
        ctx.moveTo(upperStart.x, upperStart.y);
        ctx.lineTo(upperEdge.x, upperEdge.y);
        ctx.lineTo(lowerEdge.x, lowerEdge.y);
        ctx.lineTo(lowerStart.x, lowerStart.y);
        ctx.closePath();
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }

    if (hasStroke) {
      // Draw center ray (solid)
      ctx.setLineDash([]);
      this._drawRay(ctx, a, b, w, h);

      // Draw outer rays (use same dash style as other shapes)
      setDash(ctx, lineStyle, lineWidth);
      this._drawRay(ctx, upperStart, upperEnd, w, h);
      this._drawRay(ctx, lowerStart, lowerEnd, w, h);
      ctx.setLineDash([]);
    }
  }

  private _drawAnchors(ctx: CanvasRenderingContext2D, pts: Point[], color: string, ratio: number) {
    const r = 4 * ratio;
    ctx.fillStyle = color;
    ctx.strokeStyle = this._data.themeFg0;
    ctx.lineWidth = ratio;
    ctx.setLineDash([]);

    for (const p of pts) {
      ctx.beginPath();
      ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Pane View
// ─────────────────────────────────────────────────────────────

class DrawingPaneView implements IPrimitivePaneView {
  private _source: DrawingToolsPrimitive;

  constructor(source: DrawingToolsPrimitive) {
    this._source = source;
  }

  zOrder(): PrimitivePaneViewZOrder {
    return 'top';
  }

  renderer(): IPrimitivePaneRenderer | null {
    const { chart, series, _state, _hoveredId } = this._source;
    if (!chart || !series) return null;

    const timeScale = chart.timeScale();

    const toScreen = (pt: DrawingPoint): Point | null => {
      const x = timeScale.logicalToCoordinate(pt.logical as any);
      const y = series.priceToCoordinate(pt.price);
      if (x === null || y === null) return null;
      return { x, y };
    };

    const toScreenX = (pt: DrawingPoint): number | null => {
      return timeScale.logicalToCoordinate(pt.logical as any);
    };

    const toScreenY = (pt: DrawingPoint): number | null => {
      return series.priceToCoordinate(pt.price);
    };

    // Filter to only main pane drawings (pane 0)
    const mainPaneDrawings = _state.drawings.filter(d => (d.paneIndex ?? 0) === 0);

    return new DrawingRenderer({
      drawings: mainPaneDrawings,
      selectedIds: _state.selectedIds,
      hoveredId: _hoveredId,
      toScreen,
      toScreenX,
      toScreenY,
      selectionRect: this._source._selectionRect,
      themeColor: this._source._themeColor,
      themeFg0: this._source._themeFg0,
    });
  }
}

// ─────────────────────────────────────────────────────────────
// Sub-Pane Renderer - renders drawings for a specific sub-pane
// ─────────────────────────────────────────────────────────────

// Pane view for sub-pane renderers
class SubPaneDrawingView implements IPrimitivePaneView {
  private _renderer: SubPaneDrawingRenderer;

  constructor(renderer: SubPaneDrawingRenderer) {
    this._renderer = renderer;
  }

  zOrder(): PrimitivePaneViewZOrder {
    return 'top';
  }

  renderer(): IPrimitivePaneRenderer | null {
    const { chart, series, _source, _paneIndex } = this._renderer;
    if (!chart || !series) return null;

    const _state = _source._state;
    // Filter drawings to only those in this pane
    const paneDrawings = _state.drawings.filter(d => (d.paneIndex ?? 0) === _paneIndex);

    const timeScale = chart.timeScale();

    const toScreen = (pt: DrawingPoint): Point | null => {
      const x = timeScale.logicalToCoordinate(pt.logical as any);
      const y = series.priceToCoordinate(pt.price);
      if (x === null || y === null) return null;
      return { x, y };
    };

    const toScreenX = (pt: DrawingPoint): number | null => {
      return timeScale.logicalToCoordinate(pt.logical as any);
    };

    const toScreenY = (pt: DrawingPoint): number | null => {
      return series.priceToCoordinate(pt.price);
    };

    return new DrawingRenderer({
      drawings: paneDrawings,
      selectedIds: _state.selectedIds,
      hoveredId: _source._hoveredId,
      toScreen,
      toScreenX,
      toScreenY,
      selectionRect: null, // No selection rect for sub-panes
      themeColor: _source._themeColor,
      themeFg0: _source._themeFg0,
    });
  }
}

export class SubPaneDrawingRenderer implements ISeriesPrimitive<Time> {
  private _paneView: SubPaneDrawingView;
  public _source: DrawingToolsPrimitive;
  public _paneIndex: number;
  private _requestUpdate?: () => void;

  public chart: IChartApi | null = null;
  public series: ISeriesApi<SeriesType> | null = null;

  constructor(source: DrawingToolsPrimitive, paneIndex: number) {
    this._source = source;
    this._paneIndex = paneIndex;
    this._paneView = new SubPaneDrawingView(this);
  }

  attached({ chart, series, requestUpdate }: { chart: any; series: any; requestUpdate: () => void }): void {
    this.chart = chart;
    this.series = series;
    this._requestUpdate = requestUpdate;
    // Register with the main primitive
    this._source.registerPaneSeries(this._paneIndex, series, this);
  }

  detached(): void {
    this._source.unregisterPaneSeries(this._paneIndex);
    this.chart = null;
    this.series = null;
    this._requestUpdate = undefined;
  }

  paneViews(): IPrimitivePaneView[] {
    return [this._paneView];
  }

  updateAllViews(): void {}

  requestUpdate(): void {
    this._requestUpdate?.();
  }
}

// ─────────────────────────────────────────────────────────────
// Main Primitive
// ─────────────────────────────────────────────────────────────

export class DrawingToolsPrimitive implements ISeriesPrimitive<Time> {
  private _paneView: DrawingPaneView;
  private _requestUpdate?: () => void;
  private _onDrawingComplete?: () => void;

  public chart: IChartApi | null = null;
  public series: ISeriesApi<SeriesType> | null = null;
  public _state: DrawingState = { drawings: [], selectedIds: new Set() };
  public _hoveredId: string | null = null;
  public _width = 0;
  public _height = 0;

  // Multi-pane support
  private _paneSeries: Map<number, ISeriesApi<SeriesType>> = new Map(); // paneIndex -> series
  private _paneRenderers: Map<number, SubPaneDrawingRenderer> = new Map(); // paneIndex -> renderer
  private _paneHeights: number[] = []; // Cumulative heights: [mainHeight, mainHeight+pane1Height, ...]
  private _activePaneIndex = 0; // Current pane being drawn in

  // Drawing state
  private _activeTool: DrawingToolType | null = null;
  private _activeStyle: DrawingStyle;
  private _tempPoints: DrawingPoint[] = [];
  private _isDrawing = false;
  private _confirmedCount = 0; // How many points have been clicked/confirmed

  // Editing state
  private _isDragging = false;
  private _dragPointIndex = -1;

  // Selection state
  public _selectionRect: { start: Point; end: Point } | null = null;
  private _isSelecting = false;

  // Native price lines for horizontal drawings (for proper axis labels)
  private _priceLines: Map<string, IPriceLine> = new Map();

  // Theme colors (public for sub-pane access)
  public _themeColor: string;
  public _themeFg0: string;

  constructor(themeColor: string = '#3d7eff', themeFg0: string = '#FBF8F4') {
    this._themeColor = themeColor;
    this._themeFg0 = themeFg0;
    this._activeStyle = createDefaultStyle(themeColor);
    this._paneView = new DrawingPaneView(this);
  }

  attached({ chart, series, requestUpdate }: { chart: any; series: any; requestUpdate: () => void }): void {
    this.chart = chart;
    this.series = series;
    this._requestUpdate = requestUpdate;
  }

  detached(): void {
    // Clean up price lines
    this._cleanupAllPriceLines();
    this.chart = null;
    this.series = null;
    this._requestUpdate = undefined;
  }

  // ─────────────────────────────────────────────────────────────
  // Native Price Line Management (for horizontal lines)
  // ─────────────────────────────────────────────────────────────

  private _createPriceLine(drawing: Drawing): void {
    if (!this.series || drawing.points.length === 0) return;
    // Support horizontal and cross (both have horizontal component)
    if (drawing.type !== 'horizontal' && drawing.type !== 'cross') return;

    const price = drawing.points[0].price;
    const lineStyle = drawing.style.lineStyle === 'dashed' ? 1 : drawing.style.lineStyle === 'dotted' ? 2 : 0;

    const options: CreatePriceLineOptions = {
      price,
      color: drawing.style.color,
      lineWidth: drawing.style.lineWidth as 1 | 2 | 3 | 4,
      lineStyle: lineStyle as LineStyle,
      axisLabelVisible: true,
      title: '',
    };

    const priceLine = this.series.createPriceLine(options);
    this._priceLines.set(drawing.id, priceLine);
  }

  private _updatePriceLine(drawing: Drawing): void {
    // Support horizontal and cross
    if (drawing.type !== 'horizontal' && drawing.type !== 'cross') return;

    const priceLine = this._priceLines.get(drawing.id);
    if (!priceLine || drawing.points.length === 0) return;

    const lineStyle = drawing.style.lineStyle === 'dashed' ? 1 : drawing.style.lineStyle === 'dotted' ? 2 : 0;

    priceLine.applyOptions({
      price: drawing.points[0].price,
      color: drawing.style.color,
      lineWidth: drawing.style.lineWidth as 1 | 2 | 3 | 4,
      lineStyle: lineStyle as LineStyle,
    });
  }

  private _removePriceLine(drawingId: string): void {
    const priceLine = this._priceLines.get(drawingId);
    if (priceLine && this.series) {
      this.series.removePriceLine(priceLine);
      this._priceLines.delete(drawingId);
    }
  }

  private _cleanupAllPriceLines(): void {
    for (const [, priceLine] of this._priceLines) {
      if (this.series) {
        this.series.removePriceLine(priceLine);
      }
    }
    this._priceLines.clear();
  }

  paneViews(): IPrimitivePaneView[] {
    return [this._paneView];
  }

  updateAllViews(): void {}

  updateDimensions(width: number, height: number): void {
    this._width = width;
    this._height = height;
    this._requestUpdate?.();
  }

  // Register a sub-pane series and its renderer for multi-pane drawing support
  registerPaneSeries(paneIndex: number, series: ISeriesApi<SeriesType>, renderer?: SubPaneDrawingRenderer): void {
    this._paneSeries.set(paneIndex, series);
    if (renderer) {
      this._paneRenderers.set(paneIndex, renderer);
    }
  }

  // Unregister a sub-pane series
  unregisterPaneSeries(paneIndex: number): void {
    this._paneSeries.delete(paneIndex);
    this._paneRenderers.delete(paneIndex);
  }

  // Request updates from all sub-pane renderers
  private _requestSubPaneUpdates(): void {
    for (const renderer of this._paneRenderers.values()) {
      renderer.requestUpdate();
    }
  }

  // Update pane heights for detecting which pane is clicked
  // heights should be cumulative: [mainPaneBottom, pane1Bottom, pane2Bottom, ...]
  updatePaneHeights(cumulativeHeights: number[]): void {
    this._paneHeights = cumulativeHeights;
  }

  // Get the pane index from a Y coordinate
  private _getPaneFromY(y: number): number {
    for (let i = 0; i < this._paneHeights.length; i++) {
      if (y < this._paneHeights[i]) {
        return i;
      }
    }
    return 0; // Default to main pane
  }

  // Get the series for a specific pane
  private _getSeriesForPane(paneIndex: number): ISeriesApi<SeriesType> | null {
    if (paneIndex === 0) return this.series;
    return this._paneSeries.get(paneIndex) ?? null;
  }

  // ─────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────

  setTool(tool: DrawingToolType | null): void {
    this._activeTool = tool;
    this._tempPoints = [];
    this._isDrawing = false;
    this._confirmedCount = 0;

    // Set default line style based on tool type
    if (tool) {
      const isShape = tool === 'rectangle' || tool === 'circle' || tool === 'triangle' || tool === 'channel';
      const isVertical = tool === 'vertical';
      this._activeStyle.lineStyle = isShape ? 'dashed' : isVertical ? 'dotted' : 'solid';
    }
  }

  getTool(): DrawingToolType | null {
    return this._activeTool;
  }

  setStyle(style: Partial<DrawingStyle>): void {
    Object.assign(this._activeStyle, style);
  }

  getStyle(): DrawingStyle {
    return { ...this._activeStyle };
  }

  setOnDrawingComplete(callback: () => void): void {
    this._onDrawingComplete = callback;
  }

  // Freedraw/highlight uses hold-to-draw: onPointerDown starts, onPointerMove adds points, onPointerUp finishes
  onPointerDown(screenX: number, screenY: number): boolean {
    if (!this._activeTool || !this.chart || !this.series) return false;

    const pt = this._screenToDrawingPoint(screenX, screenY);
    if (!pt) return false;

    // Freedraw/highlight: start drawing on pointer down
    if (this._activeTool === 'freedraw' || this._activeTool === 'highlight') {
      this._isDrawing = true;
      this._tempPoints = [pt];
      this._updateTempDrawing();
      return true;
    }

    // Single-point tools (vertical/horizontal/cross): complete immediately
    if (this._activeTool === 'vertical' || this._activeTool === 'horizontal' || this._activeTool === 'cross') {
      this._tempPoints = [pt];
      this._confirmedCount = 1;
      this._finishDrawing();
      return true;
    }

    return false;
  }

  onPointerMove(screenX: number, screenY: number): void {
    if (!this.chart || !this.series) return;

    // Update hover state
    const hitId = this._hitTest(screenX, screenY);
    if (hitId !== this._hoveredId) {
      this._hoveredId = hitId;
      this._requestUpdate?.();
    }

    if (!this._isDrawing || !this._activeTool) return;

    const pt = this._screenToDrawingPoint(screenX, screenY);
    if (!pt) return;

    // FreeDraw/highlight adds points continuously while holding
    if (this._activeTool === 'freedraw' || this._activeTool === 'highlight') {
      const last = this._tempPoints[this._tempPoints.length - 1];
      const d = this._distScreen(last, pt);
      if (d > 3) {
        this._tempPoints.push(pt);
        this._updateTempDrawing();
      }
      return;
    }

    // Multi-point tools: add or update preview point
    const requiredPoints = this._getRequiredPoints(this._activeTool);
    if (this._confirmedCount < requiredPoints) {
      if (this._tempPoints.length <= this._confirmedCount) {
        // Need a new preview point
        this._tempPoints.push(pt);
      } else {
        // Update existing preview point
        this._tempPoints[this._tempPoints.length - 1] = pt;
      }
      this._updateTempDrawing();
    }
  }

  onPointerUp(): void {
    if (!this._isDrawing || !this._activeTool) return;

    // Freedraw/highlight: finish on pointer up
    if (this._activeTool === 'freedraw' || this._activeTool === 'highlight') {
      if (this._tempPoints.length >= 2) this._finishDrawingNoSelect();
      else this._cancelDrawing();
      return;
    }

    // Multi-point tools wait for clicks, not pointer up
  }

  // Click handler for multi-point tools (trendline, ray, rectangle, etc.)
  onClick(screenX: number, screenY: number): boolean {
    if (!this._activeTool || !this.chart || !this.series) return false;

    // Freedraw/highlight doesn't use click
    if (this._activeTool === 'freedraw' || this._activeTool === 'highlight') return false;
    // Single-point tools handled in onPointerDown
    if (this._activeTool === 'vertical' || this._activeTool === 'horizontal' || this._activeTool === 'cross') return false;

    const pt = this._screenToDrawingPoint(screenX, screenY);
    if (!pt) return false;

    const requiredPoints = this._getRequiredPoints(this._activeTool);

    // Start new drawing
    if (!this._isDrawing) {
      this._isDrawing = true;
      this._tempPoints = [pt];
      this._confirmedCount = 1;
      this._updateTempDrawing();
      return true;
    }

    // Confirm the current position
    this._confirmedCount++;

    // Update the point at the confirmed position (preview becomes confirmed)
    if (this._tempPoints.length >= this._confirmedCount) {
      this._tempPoints[this._confirmedCount - 1] = pt;
    } else {
      // No preview was added yet (shouldn't happen normally)
      this._tempPoints.push(pt);
    }

    if (this._confirmedCount >= requiredPoints) {
      // Trim to required points
      this._tempPoints = this._tempPoints.slice(0, requiredPoints);
      this._finishDrawing();
    } else {
      this._updateTempDrawing();
    }

    return true;
  }

  clearSelection(): void {
    if (this._state.selectedIds.size === 0) return;
    this._state.selectedIds.clear();
    this._requestUpdate?.();
  }

  deleteSelected(): void {
    if (this._state.selectedIds.size === 0) return;
    // Remove associated price lines for horizontal drawings
    for (const id of this._state.selectedIds) {
      this._removePriceLine(id);
    }
    this._state.drawings = this._state.drawings.filter(d => !this._state.selectedIds.has(d.id));
    this._state.selectedIds.clear();
    this._requestUpdate?.();
  }

  clearAll(): void {
    // Remove all price lines
    this._cleanupAllPriceLines();
    this._state.drawings = [];
    this._state.selectedIds.clear();
    this._isDrawing = false;
    this._tempPoints = [];
    this._requestUpdate?.();
  }

  selectAll(): void {
    this._state.selectedIds.clear();
    for (const d of this._state.drawings) {
      if (d.id !== '__temp__') {
        this._state.selectedIds.add(d.id);
      }
    }
    this._requestUpdate?.();
  }

  // Start rectangular area selection
  startAreaSelect(screenX: number, screenY: number): void {
    this._isSelecting = true;
    this._selectionRect = { start: { x: screenX, y: screenY }, end: { x: screenX, y: screenY } };
    this._state.selectedIds.clear();
    this._requestUpdate?.();
  }

  updateAreaSelect(screenX: number, screenY: number): void {
    if (!this._isSelecting || !this._selectionRect) return;
    this._selectionRect.end = { x: screenX, y: screenY };

    this._state.selectedIds.clear();
    const minX = Math.min(this._selectionRect.start.x, this._selectionRect.end.x);
    const maxX = Math.max(this._selectionRect.start.x, this._selectionRect.end.x);
    const minY = Math.min(this._selectionRect.start.y, this._selectionRect.end.y);
    const maxY = Math.max(this._selectionRect.start.y, this._selectionRect.end.y);

    for (const d of this._state.drawings) {
      if (d.id === '__temp__') continue;
      const paneIndex = d.paneIndex ?? 0;
      for (const pt of d.points) {
        const screenPt = this._drawingPointToScreen(pt, paneIndex);
        if (screenPt && screenPt.x >= minX && screenPt.x <= maxX && screenPt.y >= minY && screenPt.y <= maxY) {
          this._state.selectedIds.add(d.id);
          break;
        }
      }
    }

    this._requestUpdate?.();
  }

  endAreaSelect(): void {
    this._isSelecting = false;
    this._selectionRect = null;
    this._requestUpdate?.();
  }

  isAreaSelecting(): boolean {
    return this._isSelecting;
  }

  // Click to select single drawing or start control point drag
  selectAt(screenX: number, screenY: number): boolean {
    // Check for control point on ANY drawing (not just selected) for immediate drag
    const controlPointHit = this._hitTestAnyControlPoint(screenX, screenY);
    if (controlPointHit) {
      const { drawingId, pointIndex } = controlPointHit;
      // Select the drawing and start dragging immediately
      this._state.selectedIds.clear();
      this._state.selectedIds.add(drawingId);
      this._isDragging = true;
      this._dragPointIndex = pointIndex;
      this._requestUpdate?.();
      return true;
    }

    // Check for drawing hit
    const hitId = this._hitTest(screenX, screenY);
    if (hitId) {
      this._state.selectedIds.clear();
      this._state.selectedIds.add(hitId);
      this._requestUpdate?.();
      return true;
    }

    // Clicked empty space - deselect
    if (this._state.selectedIds.size > 0) {
      this._state.selectedIds.clear();
      this._requestUpdate?.();
    }
    return false;
  }

  onDragMove(screenX: number, screenY: number): void {
    if (!this._isDragging || this._dragPointIndex < 0) return;
    if (this._state.selectedIds.size !== 1) return;

    const selectedId = Array.from(this._state.selectedIds)[0];
    const drawing = this._state.drawings.find(d => d.id === selectedId);
    if (!drawing || this._dragPointIndex >= drawing.points.length) return;

    // Use the drawing's pane for coordinate conversion
    const paneIndex = drawing.paneIndex ?? 0;
    const newPt = this._screenToDrawingPoint(screenX, screenY, false, paneIndex);
    if (!newPt) return;

    drawing.points[this._dragPointIndex] = newPt;

    // Update native price line for horizontal/cross drawings
    if (drawing.type === 'horizontal' || drawing.type === 'cross') {
      this._updatePriceLine(drawing);
    }

    this._requestUpdate?.();
    this._requestSubPaneUpdates();
  }

  onDragEnd(): void {
    this._isDragging = false;
    this._dragPointIndex = -1;
  }

  isDragging(): boolean {
    return this._isDragging;
  }

  isDrawingActive(): boolean {
    return this._isDrawing;
  }

  getSelectedIds(): string[] {
    return Array.from(this._state.selectedIds);
  }

  getSelectedId(): string | null {
    if (this._state.selectedIds.size === 0) return null;
    return Array.from(this._state.selectedIds)[0];
  }

  hasSelection(): boolean {
    return this._state.selectedIds.size > 0;
  }

  getSelectedCount(): number {
    return this._state.selectedIds.size;
  }

  getSelectedDrawing(): Drawing | null {
    if (this._state.selectedIds.size !== 1) return null;
    const selectedId = Array.from(this._state.selectedIds)[0];
    return this._state.drawings.find(d => d.id === selectedId) ?? null;
  }

  updateSelectedStyle(style: Partial<DrawingStyle>): void {
    if (this._state.selectedIds.size === 0) return;
    for (const id of this._state.selectedIds) {
      const drawing = this._state.drawings.find(d => d.id === id);
      if (drawing) {
        Object.assign(drawing.style, style);
        // Update native price line for horizontal/cross drawings
        if (drawing.type === 'horizontal' || drawing.type === 'cross') {
          this._updatePriceLine(drawing);
        }
      }
    }
    this._requestUpdate?.();
  }

  getDrawings(): Drawing[] {
    return JSON.parse(JSON.stringify(this._state.drawings.filter(d => d.id !== '__temp__')));
  }

  // Get vertical lines with their screen x-coordinates for DOM overlay rendering
  // Includes standalone vertical lines AND cross lines (with price for horizontal component)
  getVerticalLines(): { id: string; x: number; y: number | null; price: number | null; color: string; lineWidth: number; lineStyle: string; isSelected: boolean; isTemp: boolean; time: number | null; isCross: boolean }[] {
    if (!this.chart || !this.series) return [];
    const timeScale = this.chart.timeScale();

    return this._state.drawings
      .filter(d => (d.type === 'vertical' || d.type === 'cross') && d.points.length > 0)
      .map(d => {
        const x = timeScale.logicalToCoordinate(d.points[0].logical as any);
        const y = d.type === 'cross' ? this.series!.priceToCoordinate(d.points[0].price) : null;
        // Get actual time from logical coordinate
        const time = x !== null ? timeScale.coordinateToTime(x) : null;
        return {
          id: d.id,
          x: x ?? -1000, // off-screen if null
          y: y,
          price: d.type === 'cross' ? d.points[0].price : null,
          color: d.style.color,
          lineWidth: d.style.lineWidth,
          lineStyle: d.style.lineStyle,
          isSelected: this._state.selectedIds.has(d.id),
          isTemp: d.id === '__temp__',
          time: time as number | null,
          isCross: d.type === 'cross',
        };
      })
      .filter(v => v.x > -900); // filter out off-screen
  }

  loadDrawings(drawings: Drawing[]): void {
    // Clean up existing price lines
    this._cleanupAllPriceLines();
    this._state.drawings = drawings;
    this._state.selectedIds.clear();
    // Recreate price lines for horizontal/cross drawings
    for (const drawing of drawings) {
      if (drawing.type === 'horizontal' || drawing.type === 'cross') {
        this._createPriceLine(drawing);
      }
    }
    this._requestUpdate?.();
  }

  // ─────────────────────────────────────────────────────────────
  // Private
  // ─────────────────────────────────────────────────────────────

  private _getRequiredPoints(tool: DrawingToolType): number {
    switch (tool) {
      case 'vertical':
      case 'horizontal':
      case 'cross':
        return 1;
      case 'trendline':
      case 'ray':
      case 'extended':
      case 'rectangle':
      case 'circle':
        return 2;
      case 'triangle':
      case 'channel':
        return 3;
      case 'freedraw':
      case 'highlight':
        return -1;
      default:
        return 2;
    }
  }

  private _screenToDrawingPoint(x: number, y: number, updateActivePane = true, forcePaneIndex?: number): DrawingPoint | null {
    if (!this.chart) return null;

    // Use forced pane index or detect from Y coordinate
    const paneIndex = forcePaneIndex ?? this._getPaneFromY(y);
    const series = this._getSeriesForPane(paneIndex);
    if (!series) return null;

    if (updateActivePane) {
      this._activePaneIndex = paneIndex;
    }

    // Convert screen Y to pane-local Y for sub-panes
    let paneLocalY = y;
    if (paneIndex > 0 && this._paneHeights.length >= paneIndex) {
      // Subtract the cumulative height of all panes before this one
      const prevPanesHeight = this._paneHeights[paneIndex - 1];
      paneLocalY = y - prevPanesHeight;
    }

    const timeScale = this.chart.timeScale();
    const logical = timeScale.coordinateToLogical(x);
    const price = series.coordinateToPrice(paneLocalY);

    if (logical === null || price === null) return null;
    return { logical, price };
  }

  private _drawingPointToScreen(pt: DrawingPoint, paneIndex = 0): Point | null {
    if (!this.chart) return null;

    const series = this._getSeriesForPane(paneIndex);
    if (!series) return null;

    const x = this.chart.timeScale().logicalToCoordinate(pt.logical as any);
    const paneLocalY = series.priceToCoordinate(pt.price);

    if (x === null || paneLocalY === null) return null;

    // Convert pane-local Y back to screen Y for sub-panes
    let screenY: number = paneLocalY;
    if (paneIndex > 0 && this._paneHeights.length >= paneIndex) {
      const prevPanesHeight = this._paneHeights[paneIndex - 1];
      screenY = paneLocalY + prevPanesHeight;
    }

    return { x, y: screenY };
  }

  private _distScreen(a: DrawingPoint, b: DrawingPoint): number {
    const sa = this._drawingPointToScreen(a);
    const sb = this._drawingPointToScreen(b);
    if (!sa || !sb) return 0;
    return dist(sa, sb);
  }

  private _updateTempDrawing(): void {
    this._state.drawings = this._state.drawings.filter(d => d.id !== '__temp__');

    if (this._tempPoints.length > 0 && this._activeTool) {
      this._state.drawings.push({
        id: '__temp__',
        type: this._activeTool,
        points: [...this._tempPoints],
        style: { ...this._activeStyle },
        paneIndex: this._activePaneIndex,
      });
    }

    this._requestUpdate?.();
    this._requestSubPaneUpdates();
  }

  private _finishDrawing(): void {
    this._state.drawings = this._state.drawings.filter(d => d.id !== '__temp__');

    if (this._tempPoints.length > 0 && this._activeTool) {
      const drawing: Drawing = {
        id: genId(),
        type: this._activeTool,
        points: [...this._tempPoints],
        style: { ...this._activeStyle },
        paneIndex: this._activePaneIndex,
      };
      this._state.drawings.push(drawing);
      this._state.selectedIds.clear();
      this._state.selectedIds.add(drawing.id);

      // Create native price line for horizontal/cross drawings (for Y-axis label)
      // Only for main pane (pane 0)
      if ((drawing.type === 'horizontal' || drawing.type === 'cross') && this._activePaneIndex === 0) {
        this._createPriceLine(drawing);
      }
    }

    this._tempPoints = [];
    this._isDrawing = false;
    this._confirmedCount = 0;
    this._activePaneIndex = 0; // Reset to main pane
    this._requestUpdate?.();
    this._requestSubPaneUpdates();

    // Auto-exit drawing mode after finishing
    this._onDrawingComplete?.();
  }

  // Same as _finishDrawing but doesn't auto-select (for freedraw/highlight with many control points)
  private _finishDrawingNoSelect(): void {
    this._state.drawings = this._state.drawings.filter(d => d.id !== '__temp__');

    if (this._tempPoints.length > 0 && this._activeTool) {
      const drawing: Drawing = {
        id: genId(),
        type: this._activeTool,
        points: [...this._tempPoints],
        style: { ...this._activeStyle },
        paneIndex: this._activePaneIndex,
      };
      this._state.drawings.push(drawing);
      // Don't auto-select - too many control points for freedraw/highlight
    }

    this._tempPoints = [];
    this._isDrawing = false;
    this._confirmedCount = 0;
    this._activePaneIndex = 0; // Reset to main pane
    this._requestUpdate?.();
    this._requestSubPaneUpdates();

    // Auto-exit drawing mode after finishing
    this._onDrawingComplete?.();
  }

  private _cancelDrawing(): void {
    this._state.drawings = this._state.drawings.filter(d => d.id !== '__temp__');
    this._tempPoints = [];
    this._isDrawing = false;
    this._confirmedCount = 0;
    this._requestUpdate?.();
  }

  private _hitTest(screenX: number, screenY: number): string | null {
    const p: Point = { x: screenX, y: screenY };

    for (let i = this._state.drawings.length - 1; i >= 0; i--) {
      const d = this._state.drawings[i];
      if (d.id === '__temp__') continue;

      const paneIndex = d.paneIndex ?? 0;
      const pts = d.points.map(pt => this._drawingPointToScreen(pt, paneIndex)).filter((pt): pt is Point => pt !== null);
      if (pts.length === 0) continue;

      if (this._hitTestDrawing(p, d.type, pts)) {
        return d.id;
      }
    }

    return null;
  }

  private _hitTestAnyControlPoint(screenX: number, screenY: number): { drawingId: string; pointIndex: number } | null {
    const p: Point = { x: screenX, y: screenY };
    const CONTROL_TOLERANCE = 10;

    // Check all drawings (in reverse order, so top drawings are checked first)
    for (let di = this._state.drawings.length - 1; di >= 0; di--) {
      const drawing = this._state.drawings[di];
      if (drawing.id === '__temp__') continue;

      const paneIndex = drawing.paneIndex ?? 0;
      for (let i = 0; i < drawing.points.length; i++) {
        const screenPt = this._drawingPointToScreen(drawing.points[i], paneIndex);
        if (screenPt && dist(p, screenPt) <= CONTROL_TOLERANCE) {
          return { drawingId: drawing.id, pointIndex: i };
        }
      }
    }

    return null;
  }

  private _hitTestDrawing(p: Point, type: DrawingToolType, pts: Point[]): boolean {
    switch (type) {
      case 'freedraw':
      case 'highlight':
        for (let i = 0; i < pts.length - 1; i++) {
          if (distToSegment(p, pts[i], pts[i + 1]) <= HIT_TOLERANCE) return true;
        }
        return false;

      case 'vertical':
        return pts[0] && Math.abs(p.x - pts[0].x) <= HIT_TOLERANCE;

      case 'horizontal':
        return pts[0] && Math.abs(p.y - pts[0].y) <= HIT_TOLERANCE;

      case 'cross':
        return pts[0] && (Math.abs(p.x - pts[0].x) <= HIT_TOLERANCE || Math.abs(p.y - pts[0].y) <= HIT_TOLERANCE);

      case 'trendline':
        return pts.length >= 2 && distToSegment(p, pts[0], pts[1]) <= HIT_TOLERANCE;

      case 'ray':
      case 'extended':
        return pts.length >= 2 && distToLine(p, pts[0], pts[1]) <= HIT_TOLERANCE;

      case 'rectangle':
        if (pts.length < 2) return false;
        const corners = [
          pts[0],
          { x: pts[1].x, y: pts[0].y },
          pts[1],
          { x: pts[0].x, y: pts[1].y },
        ];
        for (let i = 0; i < 4; i++) {
          if (distToSegment(p, corners[i], corners[(i + 1) % 4]) <= HIT_TOLERANCE) return true;
        }
        return false;

      case 'circle':
        if (pts.length < 2) return false;
        const r = dist(pts[0], pts[1]);
        const d = dist(p, pts[0]);
        return Math.abs(d - r) <= HIT_TOLERANCE;

      case 'triangle':
        if (pts.length < 3) return false;
        for (let i = 0; i < 3; i++) {
          if (distToSegment(p, pts[i], pts[(i + 1) % 3]) <= HIT_TOLERANCE) return true;
        }
        return false;

      case 'channel':
        if (pts.length < 3) return false;
        // Channel is 3 rays: center + symmetric upper/lower
        const chDx = pts[1].x - pts[0].x, chDy = pts[1].y - pts[0].y;
        const chLen = Math.sqrt(chDx * chDx + chDy * chDy);
        if (chLen < 0.001) return false;
        // Perpendicular unit vector
        const chPx = -chDy / chLen, chPy = chDx / chLen;
        // Perpendicular distance from pts[2] to center line
        const chAcx = pts[2].x - pts[0].x, chAcy = pts[2].y - pts[0].y;
        const chPerpDist = chAcx * chPx + chAcy * chPy;
        // Upper and lower line starts
        const chUpperStart = { x: pts[0].x + chPx * chPerpDist, y: pts[0].y + chPy * chPerpDist };
        const chLowerStart = { x: pts[0].x - chPx * chPerpDist, y: pts[0].y - chPy * chPerpDist };
        const chUpperEnd = { x: pts[1].x + chPx * chPerpDist, y: pts[1].y + chPy * chPerpDist };
        const chLowerEnd = { x: pts[1].x - chPx * chPerpDist, y: pts[1].y - chPy * chPerpDist };
        // Check distance to all three rays (using distToLine for infinite extension)
        return distToLine(p, pts[0], pts[1]) <= HIT_TOLERANCE ||
               distToLine(p, chUpperStart, chUpperEnd) <= HIT_TOLERANCE ||
               distToLine(p, chLowerStart, chLowerEnd) <= HIT_TOLERANCE;

      default:
        return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Tool Metadata
// ─────────────────────────────────────────────────────────────

export interface ToolDef {
  id: DrawingToolType;
  name: string;
  icon: string;
  group: 'draw' | 'line' | 'shape';
}

export const DRAWING_TOOLS: ToolDef[] = [
  { id: 'freedraw', name: 'Pen', icon: 'Pencil', group: 'draw' },
  { id: 'highlight', name: 'Highlight', icon: 'Highlighter', group: 'draw' },
  { id: 'vertical', name: 'Vertical Line', icon: 'ArrowDownUp', group: 'line' },
  { id: 'horizontal', name: 'Horizontal Line', icon: 'ArrowLeftRight', group: 'line' },
  { id: 'cross', name: 'Cross Line', icon: 'Crosshair', group: 'line' },
  { id: 'trendline', name: 'Trend Line', icon: 'TrendingUp', group: 'line' },
  { id: 'ray', name: 'Ray', icon: 'MoveUpRight', group: 'line' },
  { id: 'extended', name: 'Extended Line', icon: 'Minus', group: 'line' },
  { id: 'rectangle', name: 'Rectangle', icon: 'Square', group: 'shape' },
  { id: 'circle', name: 'Circle', icon: 'Circle', group: 'shape' },
  { id: 'triangle', name: 'Triangle', icon: 'Triangle', group: 'shape' },
  { id: 'channel', name: 'Channel', icon: 'Layers', group: 'shape' },
];
