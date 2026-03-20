/**
 * ChartDataStore - Signal-based chart state management
 * Replaces 5 useState calls in usePriceChartEngine.ts with centralized signal store
 * Optimizes high-frequency updates (crosshair, overlays, price ticks)
 */
import { signal, computed, batch } from '@preact/signals';
import type { OHLC } from '@/types/market';
import type { IndicatorKey } from '@/components/features/chart/indicatorsConfig';

export interface OverlayDisplay {
  name1: string;
  value1: number;
  color1: string;
  name2: string;
  value2: number;
  color2: string;
}

export interface PaneDisplay {
  name1: string;
  value1: number;
  color1: string;
  name2: string;
  value2: number;
  color2: string;
}

export interface SpreadData {
  bid: number;
  ask: number;
  mid: number;
}

export class ChartDataStore {
  // Crosshair/hover state signals
  public hoveredOHLC = signal<OHLC | null>(null);
  public overlayValues = signal<OverlayDisplay | null>(null);

  // Sub-pane indicator values (use Map for efficient updates)
  public paneValues = signal<Map<IndicatorKey, PaneDisplay>>(new Map());

  // Layout state
  public paneHeights = signal<number[]>([]);

  // Price spread (bid/ask/mid)
  public spread = signal<SpreadData | null>(null);

  // Computed: current OHLC (fallback to latest candle if no hover)
  public currentOHLC = computed(() => this.hoveredOHLC.value);

  // Computed: has overlay indicators
  public hasOverlayValues = computed(() => this.overlayValues.value !== null);

  // Computed: spread as percentage
  public spreadPercent = computed(() => {
    const s = this.spread.value;
    if (!s || s.mid === 0) return 0;
    return ((s.ask - s.bid) / s.mid) * 100;
  });

  /**
   * Update hovered OHLC from crosshair
   * High-frequency update (on mouse move)
   */
  public setHoveredOHLC(ohlc: OHLC | null) {
    this.hoveredOHLC.value = ohlc;
  }

  /**
   * Batch update overlay values from crosshair
   * Updates both value1 and value2 together
   */
  public updateOverlayValues(value1: number, value2: number) {
    const current = this.overlayValues.value;
    if (!current) return;

    this.overlayValues.value = {
      ...current,
      value1,
      value2,
    };
  }

  /**
   * Set initial overlay display structure
   */
  public setOverlayDisplay(display: OverlayDisplay | null) {
    this.overlayValues.value = display;
  }

  /**
   * Update pane indicator value (efficient Map mutation)
   * Instead of recreating Map, we mutate in place for better performance
   */
  public updatePaneValue(key: IndicatorKey, value1?: number, value2?: number) {
    const current = this.paneValues.value;
    const existing = current.get(key);

    if (!existing) return;

    // Create new Map with updated value
    const newMap = new Map(current);
    newMap.set(key, {
      ...existing,
      value1: value1 ?? existing.value1,
      value2: value2 ?? existing.value2,
    });

    this.paneValues.value = newMap;
  }

  /**
   * Set pane display structure (initial setup)
   */
  public setPaneDisplay(key: IndicatorKey, display: PaneDisplay) {
    const newMap = new Map(this.paneValues.value);
    newMap.set(key, display);
    this.paneValues.value = newMap;
  }

  /**
   * Clear pane value
   */
  public removePaneDisplay(key: IndicatorKey) {
    const newMap = new Map(this.paneValues.value);
    newMap.delete(key);
    this.paneValues.value = newMap;
  }

  /**
   * Clear all pane values
   */
  public clearPaneDisplays() {
    this.paneValues.value = new Map();
  }

  /**
   * Update pane heights array
   */
  public setPaneHeights(heights: number[]) {
    this.paneHeights.value = heights;
  }

  /**
   * Update spread data (bid/ask/mid)
   * High-frequency update (on price ticks)
   */
  public setSpread(spread: SpreadData | null) {
    this.spread.value = spread;
  }

  /**
   * Batch update spread values
   */
  public updateSpread(bid: number, ask: number, mid: number) {
    this.spread.value = { bid, ask, mid };
  }

  /**
   * Reset all chart data state
   */
  public reset() {
    batch(() => {
      this.hoveredOHLC.value = null;
      this.overlayValues.value = null;
      this.paneValues.value = new Map();
      this.paneHeights.value = [];
      this.spread.value = null;
    });
  }

  /**
   * Clear crosshair-related state (on mouse leave)
   */
  public clearCrosshair() {
    this.hoveredOHLC.value = null;
  }
}
