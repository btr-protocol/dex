/**
 * Chart Engine Hook - manages lightweight-charts instance and all series
 */
import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import {
  createChart,
  ColorType,
  type IChartApi,
  type ISeriesApi,
  type Time,
  type MouseEventParams,
  type PriceScaleMode,
  CandlestickSeries,
  BarSeries,
  LineSeries,
  HistogramSeries,
} from 'lightweight-charts';
import type { OHLC, PriceData } from '@/hooks/usePriceFeed';
import type { IndicatorParams } from '@utils/indicators';
import { precision } from '@utils/format';
import { getColors, useTheme } from '@lib/theme';
import {
  type IndicatorKey,
  type ChartType,
  INDICATORS,
  SUB_PANE_KEYS,
  formatChartPrice,
  formatIndicatorValue,
} from './indicatorsConfig';
import { CrossGridPrimitive } from './CrossGrid';
import { DrawingToolsPrimitive, SubPaneDrawingRenderer } from './DrawingTools';

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

interface PaneIndicatorRef {
  series1: ISeriesApi<any> | null;
  series2: ISeriesApi<any> | null;
  crossGrid: CrossGridPrimitive | null;
  drawingRenderer: SubPaneDrawingRenderer | null;
}

export interface ChartEngineProps {
  height: number;
  chartType: ChartType;
  activeIndicators: IndicatorKey[];
  candles: OHLC[];
  livePrice: PriceData | null;
  quotePrice: PriceData | null;
  timeframe: number;
  isSynthetic: boolean;
  needsInversion?: boolean; // For synthetic pairs, invert AFTER synthetic calculation
  getParams: (key: IndicatorKey) => IndicatorParams;
  priceScaleMode?: PriceScaleMode;
}

export interface ChartEngineState {
  containerRef: React.RefObject<HTMLDivElement>;
  chartRef: React.MutableRefObject<IChartApi | null>;
  currentOHLC: OHLC | null;
  overlayValues: OverlayDisplay | null;
  paneValues: Map<IndicatorKey, PaneDisplay>;
  paneHeights: number[];
  decimals: number;
  spread: { bid: number; ask: number; mid: number } | null;
  // Drawing tools
  drawingTools: DrawingToolsPrimitive | null;
}

export function usePriceChartEngine({
  height,
  chartType,
  activeIndicators,
  candles,
  livePrice,
  quotePrice: _quotePrice,
  timeframe,
  isSynthetic: _isSynthetic,
  needsInversion: _needsInversion = false,
  getParams,
  priceScaleMode = 0, // PriceScaleMode.Normal by default
}: ChartEngineProps): ChartEngineState {
  const { theme } = useTheme();
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<any> | null>(null);
  const emaFastRef = useRef<ISeriesApi<any> | null>(null);
  const emaSlowRef = useRef<ISeriesApi<any> | null>(null);
  const paneIndicatorsRef = useRef<Map<IndicatorKey, PaneIndicatorRef>>(new Map());
  const crossGridRef = useRef<CrossGridPrimitive | null>(null);
  const drawingToolsRef = useRef<DrawingToolsPrimitive | null>(null);
  const savedDrawingsRef = useRef<ReturnType<DrawingToolsPrimitive['getDrawings']>>([]);
  const decimalsRef = useRef<number>(2);

  const [hoveredOHLC, setHoveredOHLC] = useState<OHLC | null>(null);
  const [overlayValues, setOverlayValues] = useState<OverlayDisplay | null>(null);
  const [paneValues, setPaneValues] = useState<Map<IndicatorKey, PaneDisplay>>(new Map());
  const [paneHeights, setPaneHeights] = useState<number[]>([]);

  const hasOverlay = activeIndicators.includes('ema-trend');
  const subPaneIndicators = activeIndicators.filter(k => SUB_PANE_KEYS.includes(k));
  const numSubPanes = subPaneIndicators.length;

  const currentOHLC = hoveredOHLC || (candles.length > 0 ? candles[candles.length - 1] : null);

  // Update pane heights
  const updatePaneHeights = useCallback(() => {
    const chart = chartRef.current;
    if (!chart || numSubPanes === 0) {
      setPaneHeights([]);
      // Update cross grid height for single pane
      if (crossGridRef.current) {
        crossGridRef.current.updatePaneHeight(height - 28); // subtract time scale height
      }
      return;
    }

    try {
      const panes = (chart as any).panes?.();
      if (panes && panes.length > 1) {
        const heights: number[] = [];
        let cumulative = 0;
        for (let i = 0; i < panes.length; i++) {
          cumulative += panes[i].getHeight?.() || 100;
          heights.push(cumulative);
        }
        setPaneHeights(heights);
        // Update drawing tools with pane heights for multi-pane support
        if (drawingToolsRef.current) {
          drawingToolsRef.current.updatePaneHeights(heights);
        }
        // Update cross grid with main pane height
        if (crossGridRef.current && panes[0]) {
          crossGridRef.current.updatePaneHeight(panes[0].getHeight?.() || height - 28);
        }
        // Update sub-pane cross grids
        let paneIdx = 1;
        paneIndicatorsRef.current.forEach((indicator) => {
          if (indicator.crossGrid && panes[paneIdx]) {
            indicator.crossGrid.updatePaneHeight(panes[paneIdx].getHeight?.() || 100);
          }
          paneIdx++;
        });
      }
    } catch {
      // Fallback
      const paneHeight = 100;
      const mainHeight = height - (numSubPanes * (paneHeight + 4));
      const heights = [mainHeight];
      for (let i = 0; i < numSubPanes; i++) {
        heights.push(mainHeight + (i + 1) * (paneHeight + 4));
      }
      setPaneHeights(heights);
      // Update drawing tools with pane heights for multi-pane support
      if (drawingToolsRef.current) {
        drawingToolsRef.current.updatePaneHeights(heights);
      }
      if (crossGridRef.current) {
        crossGridRef.current.updatePaneHeight(mainHeight);
      }
      // Update sub-pane cross grids with fallback height
      paneIndicatorsRef.current.forEach((indicator) => {
        if (indicator.crossGrid) {
          indicator.crossGrid.updatePaneHeight(paneHeight);
        }
      });
    }
  }, [height, numSubPanes]);

  // Create chart
  useEffect(() => {
    if (!containerRef.current) return;

    const container = containerRef.current;
    const colors = getColors();

    const chart = createChart(container, {
      autoSize: false,
      width: container.clientWidth || 800,
      height,
      layout: {
        background: { type: ColorType.Solid, color: 'transparent' },
        textColor: colors.chartText,
        fontFamily: 'var(--font-numbers)',
        fontSize: 11,
        attributionLogo: false as any,
      },
      grid: {
        vertLines: { visible: false },
        horzLines: { visible: false },
      },
      timeScale: {
        borderColor: colors.chartBorder,
        timeVisible: true,
        secondsVisible: false,
        rightOffset: 8, // Show future space beyond last candle
      },
      rightPriceScale: {
        borderColor: colors.chartBorder,
        textColor: colors.chartText,
        visible: true,
        scaleMargins: { top: 0.05, bottom: 0.05 },
        mode: priceScaleMode,
      },
      leftPriceScale: { visible: false },
      crosshair: {
        mode: 0, // Normal - follow cursor, not series data points
        vertLine: { labelBackgroundColor: colors.bg2, color: colors.fg2 },
        horzLine: { labelBackgroundColor: colors.bg2, color: colors.fg2 },
      },
    });

    (chart as any).applyOptions({
      layout: {
        panes: {
          separatorColor: colors.chartBorder,
          separatorHoverColor: colors.chartBorder,
          enableResize: true,
        },
      },
    });

    chartRef.current = chart;

    // Crosshair handler
    chart.subscribeCrosshairMove((param: MouseEventParams) => {
      if (param.time && param.seriesData && seriesRef.current) {
        const candleData = param.seriesData.get(seriesRef.current);
        if (candleData) setHoveredOHLC(candleData as any);

        if (emaFastRef.current && emaSlowRef.current) {
          const v1 = param.seriesData.get(emaFastRef.current) as any;
          const v2 = param.seriesData.get(emaSlowRef.current) as any;
          if (v1?.value !== undefined && v2?.value !== undefined) {
            setOverlayValues(prev => prev ? { ...prev, value1: v1.value, value2: v2.value } : null);
          }
        }

        paneIndicatorsRef.current.forEach((indicator, key) => {
          if (indicator.series1 && indicator.series2) {
            const v1 = param.seriesData.get(indicator.series1) as any;
            const v2 = param.seriesData.get(indicator.series2) as any;
            if (v1?.value !== undefined || v2?.value !== undefined) {
              setPaneValues(prev => {
                const newMap = new Map(prev);
                const existing = newMap.get(key);
                if (existing) {
                  newMap.set(key, {
                    ...existing,
                    value1: v1?.value ?? existing.value1,
                    value2: v2?.value ?? existing.value2,
                  });
                }
                return newMap;
              });
            }
          }
        });
      } else if (candles.length > 0) {
        setHoveredOHLC(candles[candles.length - 1]);
      }
    });

    const resizeObserver = new ResizeObserver(() => {
      chart.applyOptions({ width: container.clientWidth });
      updatePaneHeights();
    });
    resizeObserver.observe(container);

    const heightPoll = setInterval(updatePaneHeights, 500);

    return () => {
      clearInterval(heightPoll);
      resizeObserver.disconnect();
      chart.remove();
      chartRef.current = null;
      seriesRef.current = null;
      emaFastRef.current = null;
      emaSlowRef.current = null;
      paneIndicatorsRef.current.clear();
    };
  }, [height, updatePaneHeights, theme]);

  // Create/update series
  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) return;

    const colors = getColors();

    // Note: We don't save pane heights - always recalculate fresh based on current height

    // Save drawings before recreating the primitive
    if (drawingToolsRef.current) {
      savedDrawingsRef.current = drawingToolsRef.current.getDrawings();
    }

    // Remove old series
    [seriesRef, emaFastRef, emaSlowRef].forEach(ref => {
      if (ref.current) {
        try { chart.removeSeries(ref.current); } catch {}
        ref.current = null;
      }
    });
    paneIndicatorsRef.current.forEach(indicator => {
      if (indicator.series1) try { chart.removeSeries(indicator.series1); } catch {}
      if (indicator.series2) try { chart.removeSeries(indicator.series2); } catch {}
    });
    paneIndicatorsRef.current.clear();
    setOverlayValues(null);
    setPaneValues(new Map());

    const samplePrice = candles.length > 0 ? candles[candles.length - 1].close : 1;
    const decimals = Math.min(precision(samplePrice), 8);
    decimalsRef.current = decimals;
    const minMove = Math.pow(10, -decimals);

    const priceFormat = {
      type: 'custom' as const,
      formatter: (price: number) => formatChartPrice(price, decimals),
      minMove,
    };

    try {
      // Main series
      if (chartType === 'candles') {
        seriesRef.current = chart.addSeries(CandlestickSeries, {
          upColor: colors.green,
          downColor: colors.red,
          borderDownColor: colors.red,
          borderUpColor: colors.green,
          wickDownColor: colors.red,
          wickUpColor: colors.green,
          priceFormat,
          lastValueVisible: true,
        }, 0);
      } else if (chartType === 'bars') {
        seriesRef.current = chart.addSeries(BarSeries, {
          upColor: colors.green,
          downColor: colors.red,
          priceFormat,
          lastValueVisible: true,
        }, 0);
      } else {
        seriesRef.current = chart.addSeries(LineSeries, {
          color: colors.green,
          lineWidth: 2,
          crosshairMarkerVisible: true,
          crosshairMarkerRadius: 4,
          lastValueVisible: true,
          priceFormat,
        }, 0);
      }

      // Attach cross grid primitive to main series
      if (seriesRef.current) {
        crossGridRef.current = new CrossGridPrimitive({ color: colors.chartGrid });
        seriesRef.current.attachPrimitive(crossGridRef.current);

        // Attach drawing tools primitive with theme colors
        drawingToolsRef.current = new DrawingToolsPrimitive(colors.blue, colors.fg0);
        seriesRef.current.attachPrimitive(drawingToolsRef.current);

        // Restore saved drawings (and clear to prevent re-restoring on next effect run)
        if (savedDrawingsRef.current.length > 0) {
          drawingToolsRef.current.loadDrawings(savedDrawingsRef.current);
          savedDrawingsRef.current = [];
        }
      }

      // Overlay EMAs
      if (hasOverlay) {
        emaFastRef.current = chart.addSeries(LineSeries, {
          color: colors.blue,
          lineWidth: 1,
          priceFormat,
          lastValueVisible: false,
          priceLineVisible: false,
        }, 0);
        emaSlowRef.current = chart.addSeries(LineSeries, {
          color: colors.orange,
          lineWidth: 1,
          priceFormat,
          lastValueVisible: false,
          priceLineVisible: false,
        }, 0);
        setOverlayValues({
          name1: 'Fast', value1: 0, color1: colors.blue,
          name2: 'Slow', value2: 0, color2: colors.orange,
        });
      }

      // Sub-pane indicators (max 3 sub-panes)
      const indicatorPriceFormat = {
        type: 'custom' as const,
        formatter: (v: number) => formatIndicatorValue(v),
        minMove: 0.01,
      };

      const MAX_SUB_PANES = 3;
      const subPaneHeight = Math.round(height / 3.5);

      // Create all sub-pane series
      subPaneIndicators.slice(0, MAX_SUB_PANES).forEach((key, idx) => {
        const paneIndex = idx + 1;
        const def = INDICATORS[key];
        if (!def) return;

        // Determine color based on indicator type: blue for trend/momentum, pink for volatility
        const isVolatility = key.startsWith('sdev');
        const primaryColor = isVolatility ? colors.pink : colors.blue;

        const series1 = def.isDivergence
          ? chart.addSeries(HistogramSeries, {
              color: primaryColor,
              lastValueVisible: true,
              priceLineVisible: true, // Show price line for MACD divergence indicators
              priceFormat: indicatorPriceFormat,
              priceScaleId: 'right',
            }, paneIndex)
          : chart.addSeries(LineSeries, {
              color: primaryColor,
              lineWidth: 2,
              lastValueVisible: true,
              priceLineVisible: true,
              priceFormat: indicatorPriceFormat,
              priceScaleId: 'right',
            }, paneIndex);

        const series2 = chart.addSeries(LineSeries, {
          color: def.isDivergence ? colors.fg2 : colors.orange,
          lineWidth: 1,
          lineStyle: def.isDivergence ? 2 : 0,
          lastValueVisible: false,
          priceLineVisible: false,
          priceFormat: indicatorPriceFormat,
          priceScaleId: 'right',
        }, paneIndex);

        // Attach cross grid to sub-pane
        const paneCrossGrid = new CrossGridPrimitive({ color: colors.chartGrid });
        paneCrossGrid.updatePaneHeight(subPaneHeight);
        series1.attachPrimitive(paneCrossGrid);

        // Attach drawing renderer to sub-pane (if main drawing tools exist)
        let subPaneDrawingRenderer: SubPaneDrawingRenderer | null = null;
        if (drawingToolsRef.current) {
          subPaneDrawingRenderer = new SubPaneDrawingRenderer(drawingToolsRef.current, paneIndex);
          series1.attachPrimitive(subPaneDrawingRenderer);
        }

        paneIndicatorsRef.current.set(key, { series1, series2, crossGrid: paneCrossGrid, drawingRenderer: subPaneDrawingRenderer });

        setPaneValues(prev => {
          const newMap = new Map(prev);
          newMap.set(key, {
            name1: def.label1, value1: 0, color1: primaryColor,
            name2: def.isDivergence ? '' : def.label2, value2: 0, color2: def.isDivergence ? colors.fg2 : colors.orange,
          });
          return newMap;
        });
      });

      // After all panes created, set proper heights:
      // - Sub-panes get height/3.5 each (capped at reasonable size)
      // - Main pane gets remaining space (should be largest)
      const setPaneHeightsNow = () => {
        const panes = (chart as any).panes?.();
        if (!panes || panes.length === 0) return;

        const numSubPanesActual = panes.length - 1;
        if (numSubPanesActual === 0) return; // No sub-panes to set

        // Sub-pane height: 1/3.5 of total, but max 120px each
        const idealSubPaneHeight = Math.round(height / 3.5);
        const maxSubPaneHeight = 120;
        const actualSubPaneHeight = Math.min(idealSubPaneHeight, maxSubPaneHeight);

        const totalSubPaneHeight = actualSubPaneHeight * numSubPanesActual;
        const timeScaleHeight = 28;
        const mainHeight = Math.max(height - totalSubPaneHeight - timeScaleHeight, 150);

        try {
          // Set main pane first (index 0)
          panes[0].setHeight(mainHeight);

          // Then set all sub-panes
          for (let i = 1; i < panes.length; i++) {
            panes[i].setHeight(actualSubPaneHeight);
          }
        } catch (e) {
          console.warn('Failed to set pane heights:', e);
        }
      };

      // Set heights immediately and also with delays to handle race conditions
      setPaneHeightsNow();
      setTimeout(setPaneHeightsNow, 50);
      setTimeout(setPaneHeightsNow, 150);
      setTimeout(updatePaneHeights, 200);
    } catch (e) {
      console.error('Could not create series:', e);
    }
  }, [chartType, candles.length > 0, hasOverlay, subPaneIndicators.join(','), updatePaneHeights, height]);

  // Track if initial data load has occurred (to only fitContent once)
  const hasInitializedRef = useRef(false);
  const prevCandlesLenRef = useRef(0);

  // Update data
  useEffect(() => {
    if (!seriesRef.current || candles.length === 0) return;
    const colors = getColors();

    // Detect if this is initial load or major data change (symbol/timeframe change)
    const isInitialLoad = !hasInitializedRef.current;
    const isMajorChange = Math.abs(candles.length - prevCandlesLenRef.current) > 10;
    prevCandlesLenRef.current = candles.length;

    try {
      if (chartType === 'line') {
        seriesRef.current.setData(candles.map(c => ({ time: c.time as Time, value: c.close })));
      } else {
        seriesRef.current.setData(candles.map(c => ({
          time: c.time as Time, open: c.open, high: c.high, low: c.low, close: c.close,
        })));
      }

      // Overlay
      if (hasOverlay && emaFastRef.current && emaSlowRef.current) {
        const def = INDICATORS['ema-trend'];
        const data = def.calc(candles, getParams('ema-trend'));
        emaFastRef.current.setData(data.map((d: any) => ({ time: d.time as Time, value: d[def.series1Field] })));
        emaSlowRef.current.setData(data.map((d: any) => ({ time: d.time as Time, value: d[def.series2Field] })));
        if (data.length > 0) {
          const last = data[data.length - 1];
          setOverlayValues({
            name1: 'Fast', value1: last[def.series1Field], color1: colors.cyan,
            name2: 'Slow', value2: last[def.series2Field], color2: colors.orange,
          });
        }
      }

      // Sub-pane indicators
      subPaneIndicators.forEach(key => {
        const indicator = paneIndicatorsRef.current.get(key);
        const def = INDICATORS[key];
        if (!indicator?.series1 || !indicator?.series2 || !def) return;

        const data = def.calc(candles, getParams(key));
        indicator.series1.setData(data.map((d: any) => ({ time: d.time as Time, value: d[def.series1Field] })));
        indicator.series2.setData(data.map((d: any) => ({ time: d.time as Time, value: d[def.series2Field] })));

        if (data.length > 0) {
          const last = data[data.length - 1];
          setPaneValues(prev => {
            const newMap = new Map(prev);
            const existing = newMap.get(key);
            if (existing) {
              newMap.set(key, {
                ...existing,
                value1: last[def.series1Field],
                value2: last[def.series2Field],
              });
            }
            return newMap;
          });
        }
      });

      // Only fit content on initial load or major data change (symbol/timeframe switch)
      // This preserves user's zoom/pan during live updates
      if (isInitialLoad || isMajorChange) {
        const ts = chartRef.current?.timeScale();
        if (ts) {
          ts.fitContent();
          ts.scrollToPosition(8, false);
        }
        hasInitializedRef.current = true;
      }
    } catch (e) {
      console.error('Could not set data:', e);
    }
  }, [candles, chartType, hasOverlay, subPaneIndicators.join(','), getParams]);

  // Reset initialization flag when symbol/timeframe changes
  useEffect(() => {
    hasInitializedRef.current = false;
    prevCandlesLenRef.current = 0;
  }, [timeframe]);

  // Update price scale mode
  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) return;

    try {
      chart.priceScale('right').applyOptions({
        mode: priceScaleMode,
      });
    } catch (e) {
      console.warn('Failed to update price scale mode:', e);
    }
  }, [priceScaleMode]);

  // Track current spread
  const [spread, setSpread] = useState<{ bid: number; ask: number; mid: number } | null>(null);

  // Live price updates (price already has synthetic/inversion applied by PriceChart)
  useEffect(() => {
    if (!seriesRef.current || !livePrice || candles.length === 0) return;

    const { mid: price, bid, ask } = livePrice;

    // Update spread state
    setSpread({ bid, ask, mid: price });

    const now = Math.floor(Date.now() / 1000);
    const bucketTime = Math.floor(now / timeframe) * timeframe;
    const last = candles[candles.length - 1];

    try {
      if (chartType === 'line') {
        seriesRef.current.update({ time: now as Time, value: price });
      } else if (last && last.time === bucketTime) {
        seriesRef.current.update({
          time: bucketTime as Time,
          open: last.open,
          high: Math.max(last.high, price),
          low: Math.min(last.low, price),
          close: price,
        });
      } else if (bucketTime > last?.time) {
        seriesRef.current.update({
          time: bucketTime as Time,
          open: price,
          high: price,
          low: price,
          close: price,
        });
      }
    } catch {}
  }, [livePrice, candles, timeframe, chartType]);

  return {
    containerRef,
    chartRef,
    currentOHLC,
    overlayValues,
    paneValues,
    paneHeights,
    decimals: decimalsRef.current,
    spread,
    drawingTools: drawingToolsRef.current,
  };
}
