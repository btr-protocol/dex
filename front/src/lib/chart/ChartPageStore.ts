/**
 * ChartPageStore - Signal-based chart page state management
 * Replaces 5 useState calls in ChartPage.tsx (ready, pairSelectorOpen, currentTimeframe, currentChartType, currentIndicators)
 * Optimizes URL state tracking with batched updates
 */
import { signal, computed, batch } from '@preact/signals';
import type { InitialIndicator } from '@components/features/chart/useIndicatorParams';
import type { ChartType } from '@components/features/chart/indicatorsConfig';

export class ChartPageStore {
  // UI state
  public ready = signal(false);
  public pairSelectorOpen = signal(false);

  // Chart state tracking (for URL preservation during pair changes)
  public currentTimeframe = signal<number | null>(null);
  public currentChartType = signal<ChartType | null>(null);
  public currentIndicators = signal<InitialIndicator[] | null>(null);

  // Computed: has chart state been initialized
  public hasChartState = computed(() =>
    this.currentTimeframe.value !== null &&
    this.currentChartType.value !== null &&
    this.currentIndicators.value !== null
  );

  /**
   * Initialize chart state from URL params (batched update)
   */
  public initializeChartState(
    timeframe: number,
    chartType: ChartType,
    indicators: InitialIndicator[]
  ) {
    batch(() => {
      if (this.currentTimeframe.value === null) {
        this.currentTimeframe.value = timeframe;
      }
      if (this.currentChartType.value === null) {
        this.currentChartType.value = chartType;
      }
      if (this.currentIndicators.value === null) {
        this.currentIndicators.value = indicators;
      }
    });
  }

  /**
   * Update chart state (batched update for multiple changes)
   */
  public updateChartState(
    timeframe?: number,
    chartType?: ChartType,
    indicators?: InitialIndicator[]
  ) {
    batch(() => {
      if (timeframe !== undefined) this.currentTimeframe.value = timeframe;
      if (chartType !== undefined) this.currentChartType.value = chartType;
      if (indicators !== undefined) this.currentIndicators.value = indicators;
    });
  }

  /**
   * Update timeframe
   */
  public setTimeframe(timeframe: number) {
    this.currentTimeframe.value = timeframe;
  }

  /**
   * Update chart type
   */
  public setChartType(chartType: ChartType) {
    this.currentChartType.value = chartType;
  }

  /**
   * Update indicators
   */
  public setIndicators(indicators: InitialIndicator[]) {
    this.currentIndicators.value = indicators;
  }

  /**
   * Open pair selector
   */
  public openPairSelector() {
    this.pairSelectorOpen.value = true;
  }

  /**
   * Close pair selector
   */
  public closePairSelector() {
    this.pairSelectorOpen.value = false;
  }

  /**
   * Mark page as ready
   */
  public setReady() {
    this.ready.value = true;
  }

  /**
   * Reset all state
   */
  public reset() {
    batch(() => {
      this.ready.value = false;
      this.pairSelectorOpen.value = false;
      this.currentTimeframe.value = null;
      this.currentChartType.value = null;
      this.currentIndicators.value = null;
    });
  }
}
