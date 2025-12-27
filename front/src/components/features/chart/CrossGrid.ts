/**
 * Custom cross-grid primitive for lightweight-charts
 * Renders small crosses at grid intersections aligned with price/time axis ticks
 *
 * Performance optimized:
 * - Caches computed coordinates between frames
 * - Only recalculates when chart state actually changes
 * - Reuses renderer instance and arrays
 * - Single batched path for all crosses
 */
import type {
  ISeriesPrimitive,
  IPrimitivePaneView,
  IPrimitivePaneRenderer,
  PrimitivePaneViewZOrder,
  Time,
} from 'lightweight-charts';

interface CrossGridOptions {
  color: string;
  crossSize: number;
}

interface GridData {
  xCoords: number[];
  yCoords: number[];
  color: string;
  crossSize: number;
}

// Nice intervals for grid alignment
const NICE_INTERVALS = [1, 2, 5, 10, 15, 20, 30, 60];
const CELL_SIZE = 80;

class CrossGridRenderer implements IPrimitivePaneRenderer {
  private _data: GridData;

  constructor(data: GridData) {
    this._data = data;
  }

  setData(data: GridData): void {
    this._data = data;
  }

  draw(target: any): void {
    target.useBitmapCoordinateSpace((scope: any) => {
      const ctx: CanvasRenderingContext2D = scope.context;
      const { xCoords, yCoords, color, crossSize } = this._data;
      const xLen = xCoords.length, yLen = yCoords.length;

      if (xLen === 0 || yLen === 0) return;

      const ratio = scope.horizontalPixelRatio ?? 1;
      const scaledSize = Math.round(crossSize * ratio);

      ctx.strokeStyle = color;
      ctx.lineWidth = ratio;
      ctx.beginPath();

      // Batch all crosses into single path - O(n*m) but minimal per-cross overhead
      for (let i = 0; i < xLen; i++) {
        const x = Math.round(xCoords[i] * ratio);
        for (let j = 0; j < yLen; j++) {
          const y = Math.round(yCoords[j] * ratio);
          ctx.moveTo(x - scaledSize, y);
          ctx.lineTo(x + scaledSize, y);
          ctx.moveTo(x, y - scaledSize);
          ctx.lineTo(x, y + scaledSize);
        }
      }

      ctx.stroke();
    });
  }
}

class CrossGridPaneView implements IPrimitivePaneView {
  private _source: CrossGridPrimitive;
  private _renderer: CrossGridRenderer;
  private _data: GridData = { xCoords: [], yCoords: [], color: '', crossSize: 3 };
  private _dirty = true;

  // Cache keys for invalidation
  private _lastWidth = 0;
  private _lastHeight = 0;
  private _lastRangeFrom = 0;
  private _lastRangeTo = 0;
  private _lastTopPrice = 0;
  private _lastBottomPrice = 0;

  constructor(source: CrossGridPrimitive) {
    this._source = source;
    this._renderer = new CrossGridRenderer(this._data);
  }

  zOrder(): PrimitivePaneViewZOrder {
    return 'bottom';
  }

  markDirty(): void {
    this._dirty = true;
  }

  private _needsUpdate(): boolean {
    if (this._dirty) return true;

    const chart = this._source.chart;
    const series = this._source.series;
    if (!chart || !series) return false;

    const timeScale = chart.timeScale();
    const width = timeScale.width();
    const height = this._source.paneHeight;

    if (width !== this._lastWidth || height !== this._lastHeight) return true;

    try {
      const range = timeScale.getVisibleLogicalRange();
      if (range && (range.from !== this._lastRangeFrom || range.to !== this._lastRangeTo)) return true;

      const topPrice = series.coordinateToPrice(0);
      const bottomPrice = series.coordinateToPrice(height);
      if (topPrice !== this._lastTopPrice || bottomPrice !== this._lastBottomPrice) return true;
    } catch {
      return true;
    }

    return false;
  }

  private _updateCache(): void {
    const chart = this._source.chart;
    const series = this._source.series;
    if (!chart || !series) return;

    const timeScale = chart.timeScale();
    this._lastWidth = timeScale.width();
    this._lastHeight = this._source.paneHeight;

    try {
      const range = timeScale.getVisibleLogicalRange();
      if (range) {
        this._lastRangeFrom = range.from;
        this._lastRangeTo = range.to;
      }
      this._lastTopPrice = series.coordinateToPrice(0) ?? 0;
      this._lastBottomPrice = series.coordinateToPrice(this._lastHeight) ?? 0;
    } catch {}

    this._dirty = false;
  }

  update(): void {
    if (!this._needsUpdate()) return;

    const chart = this._source.chart;
    const series = this._source.series;
    if (!chart || !series) return;

    const timeScale = chart.timeScale();
    const height = this._source.paneHeight;
    const width = timeScale.width();

    // Reuse arrays - clear instead of allocating new
    const xCoords: number[] = [];
    const yCoords: number[] = [];

    // X coordinates from time axis
    try {
      const range = timeScale.getVisibleLogicalRange();
      if (range) {
        const logicalFrom = Math.floor(range.from);
        const logicalTo = Math.ceil(range.to);
        const coord0 = timeScale.logicalToCoordinate(0);
        const coord1 = timeScale.logicalToCoordinate(1);

        if (coord0 !== null && coord1 !== null) {
          const barWidth = Math.abs(coord1 - coord0);
          const barsPerGrid = Math.max(1, Math.round(CELL_SIZE / barWidth));

          let niceStep = barsPerGrid;
          for (let i = 0; i < NICE_INTERVALS.length; i++) {
            if (NICE_INTERVALS[i] >= barsPerGrid * 0.7) {
              niceStep = NICE_INTERVALS[i];
              break;
            }
          }

          const startAligned = Math.ceil(logicalFrom / niceStep) * niceStep;
          for (let logical = startAligned; logical <= logicalTo; logical += niceStep) {
            const x = timeScale.logicalToCoordinate(logical);
            if (x !== null && x > 0 && x < width) xCoords.push(x);
          }
        }
      }
    } catch {
      const targetLines = Math.max(4, Math.floor(width / CELL_SIZE));
      for (let i = 1; i <= targetLines; i++) {
        xCoords.push((width * i) / (targetLines + 1));
      }
    }

    // Y coordinates from price axis
    try {
      const targetYLines = Math.max(2, Math.floor(height / CELL_SIZE));
      const topPrice = series.coordinateToPrice(0);
      const bottomPrice = series.coordinateToPrice(height);

      if (topPrice !== null && bottomPrice !== null) {
        const priceRange = Math.abs(topPrice - bottomPrice);
        const rawStep = priceRange / targetYLines;
        const magnitude = Math.pow(10, Math.floor(Math.log10(rawStep)));
        const normalized = rawStep / magnitude;

        let niceStep: number;
        if (normalized <= 1.5) niceStep = magnitude;
        else if (normalized <= 3) niceStep = 2 * magnitude;
        else if (normalized <= 7) niceStep = 5 * magnitude;
        else niceStep = 10 * magnitude;

        const minPrice = Math.min(topPrice, bottomPrice);
        const maxPrice = Math.max(topPrice, bottomPrice);
        const startPrice = Math.ceil(minPrice / niceStep) * niceStep;

        for (let price = startPrice; price <= maxPrice; price += niceStep) {
          const y = series.priceToCoordinate(price);
          if (y !== null && y > 0 && y < height) yCoords.push(y);
        }

        if (yCoords.length < 2) {
          yCoords.length = 0;
          for (let i = 1; i <= 2; i++) yCoords.push((height * i) / 3);
        }
      }
    } catch {
      const targetLines = Math.max(2, Math.floor(height / CELL_SIZE));
      for (let i = 1; i <= targetLines; i++) {
        yCoords.push((height * i) / (targetLines + 1));
      }
    }

    this._data = {
      xCoords,
      yCoords,
      color: this._source.options.color,
      crossSize: this._source.options.crossSize,
    };

    this._renderer.setData(this._data);
    this._updateCache();
  }

  renderer(): IPrimitivePaneRenderer | null {
    this.update();
    return this._renderer;
  }
}

export class CrossGridPrimitive implements ISeriesPrimitive<Time> {
  private _paneView: CrossGridPaneView;
  public chart: any = null;
  public series: any = null;
  public paneHeight = 300;
  public options: CrossGridOptions;
  private _requestUpdate?: () => void;

  constructor(options: Partial<CrossGridOptions> = {}) {
    this.options = {
      color: options.color ?? 'rgba(255, 255, 255, 0.12)',
      crossSize: options.crossSize ?? 5,
    };
    this._paneView = new CrossGridPaneView(this);
  }

  attached({ chart, series, requestUpdate }: { chart: any; series: any; requestUpdate: () => void }): void {
    this.chart = chart;
    this.series = series;
    this._requestUpdate = requestUpdate;
  }

  detached(): void {
    this.chart = null;
    this.series = null;
    this._requestUpdate = undefined;
  }

  paneViews(): IPrimitivePaneView[] {
    return [this._paneView];
  }

  updateAllViews(): void {
    this._paneView.markDirty();
    this._paneView.update();
  }

  updateOptions(options: Partial<CrossGridOptions>): void {
    Object.assign(this.options, options);
    this._paneView.markDirty();
    this._requestUpdate?.();
  }

  updatePaneHeight(height: number): void {
    this.paneHeight = height;
    this._paneView.markDirty();
    this._requestUpdate?.();
  }
}
