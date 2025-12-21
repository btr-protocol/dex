/**
 * PriceChart - Composable candlestick/bar/line chart with technical indicators
 */
import { useState, useMemo, useEffect, useCallback } from 'preact/hooks';
import { X, Pencil } from 'lucide-react';
import type { PriceScaleMode } from 'lightweight-charts';
import { Tooltip } from '@components/ui/Tooltip';
import { precision } from '@utils/format';
import type { DrawingToolType } from './chart/DrawingTools';
import {
  useCandles,
  usePriceStream,
  fetchAvailableTickers,
  getPairFeedInfo,
  getCanonicalPair,
  isInvertedPair,
  invertOHLC,
  invertPriceData,
  type OHLC,
} from '@/hooks/usePriceFeed';
import type { IndicatorParams } from '@utils/indicators';
import {
  type IndicatorKey,
  type ChartType,
  INDICATORS,
  SUB_PANE_KEYS,
  DEFAULT_PARAMS,
  formatChartPrice,
  formatIndicatorValue,
  formatSeriesWithParams,
  getIndicatorBaseName,
} from './chart/indicatorsConfig';
import { usePriceChartEngine } from './chart/usePriceChartEngine';
import { useIndicatorParams, type InitialIndicator } from './chart/useIndicatorParams';
import { DrawingToolbar } from './chart/DrawingToolbar';
import { IndicatorParamsModal } from './chart/IndicatorParamsModal';
import { buildExportRows } from './chart/chartExport';

interface PriceChartProps {
  base: string;
  quote: string;
  height?: number;
  className?: string;
  initialTimeframe?: number;
  initialChartType?: ChartType;
  initialIndicators?: InitialIndicator[];
  standalone?: boolean;
  onChangePair?: (base: string, quote: string) => void;
  onInvertPair?: () => void;
  onTimeframeChange?: (timeframe: number) => void;
  onChartTypeChange?: (chartType: ChartType) => void;
  onIndicatorsChange?: (indicators: InitialIndicator[]) => void;
}

export function PriceChart({
  base,
  quote,
  height = 400,
  className = '',
  initialTimeframe = 60,
  initialChartType = 'candles',
  initialIndicators = [],
  standalone = false,
  onChangePair,
  onInvertPair,
  onTimeframeChange,
  onChartTypeChange,
  onIndicatorsChange,
}: PriceChartProps) {
  // Canonical pair - fetch data using canonical direction
  const canonical = getCanonicalPair(base, quote);
  const needsInversion = isInvertedPair(base, quote);

  // For data fetching, always use canonical direction
  const fetchBase = canonical.base;
  const fetchQuote = canonical.quote;

  // For display, use requested direction
  const displayBase = base;
  const displayQuote = quote;

  // State
  const [chartType, setChartType] = useState<ChartType>(initialChartType);
  const [timeframe, setTimeframe] = useState(initialTimeframe);
  const [priceScaleMode, setPriceScaleMode] = useState<PriceScaleMode>(0); // PriceScaleMode.Normal
  const [activeIndicators, setActiveIndicators] = useState<IndicatorKey[]>(() =>
    initialIndicators.map(i => i.preset)
  );

  // Notify parent when chart state changes
  useEffect(() => {
    onTimeframeChange?.(timeframe);
  }, [timeframe, onTimeframeChange]);

  useEffect(() => {
    onChartTypeChange?.(chartType);
  }, [chartType, onChartTypeChange]);

  const [pairInfoLoading, setPairInfoLoading] = useState(true);
  const [pairInfo, setPairInfo] = useState<ReturnType<typeof getPairFeedInfo>>({
    isSynthetic: false,
    feed: '',
    symbol: '',
  });

  // Params hook
  const { getParams, setParams } = useIndicatorParams(initialIndicators);

  useEffect(() => {
    const indicators: InitialIndicator[] = activeIndicators.map(preset => ({
      preset,
      params: getParams(preset),
    }));
    onIndicatorsChange?.(indicators);
  }, [activeIndicators, getParams, onIndicatorsChange]);

  // Modal state
  const [editingKey, setEditingKey] = useState<IndicatorKey | null>(null);
  const [editDraft, setEditDraft] = useState<IndicatorParams>({ ...DEFAULT_PARAMS });

  // Drawing tools state
  const [drawingTool, setDrawingTool] = useState<DrawingToolType | null>(null);
  const [_selectedDrawingId, setSelectedDrawingId] = useState<string | null>(null);
  const [selectedCount, setSelectedCount] = useState(0);
  const hasDrawingSelection = selectedCount > 0;
  const [isAreaSelectMode, setIsAreaSelectMode] = useState(false);

  // LocalStorage key for drawings persistence
  const drawingsStorageKey = `drawings:${displayBase}:${displayQuote}:${timeframe}`;

  // Fetch feed info (always use canonical pair for data fetching)
  useEffect(() => {
    // Mark as loading to prevent premature inversion decisions
    setPairInfoLoading(true);
    setPairInfo({ isSynthetic: false, feed: '', symbol: '' });
    fetchAvailableTickers().then((feeds) => {
      setPairInfo(getPairFeedInfo(fetchBase, fetchQuote, feeds));
      setPairInfoLoading(false);
    });
  }, [fetchBase, fetchQuote]);

  // Data - fetch using canonical pair (prefer USDC over USDT)
  // For synthetic pairs, we need BOTH base and quote candles
  const baseSymbol = pairInfo.isSynthetic ? pairInfo.baseSymbol! : (pairInfo.symbol || `${fetchBase}USDC`);
  const quoteSymbol = pairInfo.isSynthetic ? pairInfo.quoteSymbol! : '';

  const { candles: baseCandles, loading: baseLoading, error: baseError } = useCandles(baseSymbol, timeframe, 200);
  const { candles: quoteCandles, loading: quoteLoading } = useCandles(quoteSymbol, timeframe, 200);

  const loading = baseLoading || (pairInfo.isSynthetic && quoteLoading);
  const error = baseError;

  const rawLivePrice = usePriceStream(
    pairInfo.isSynthetic ? pairInfo.baseFeed! : pairInfo.feed || `agg:spot:${baseSymbol}`
  );
  const rawQuotePrice = usePriceStream(pairInfo.isSynthetic ? pairInfo.quoteFeed! : '');

  // Construct synthetic candles using variance-addition formula for ranges
  // For X = A/B: var(ln X) = var(ln A) + var(ln B) - 2·ρ·σ_A·σ_B
  // When ρ ≈ 1 (highly correlated), synthetic range ≈ |σ_A - σ_B| (nearly cancels)
  const rawCandles = useMemo(() => {
    if (!pairInfo.isSynthetic) return baseCandles;
    if (!baseCandles.length || !quoteCandles.length) return [];

    // Index quote candles by time for O(1) lookup
    const quoteByTime = new Map(quoteCandles.map(c => [c.time, c]));

    // Estimate rolling correlation from log returns (use ~20 bar window)
    const CORR_WINDOW = 20;
    const baseReturns: number[] = [];
    const quoteReturns: number[] = [];

    for (let i = 1; i < baseCandles.length && i < CORR_WINDOW + 1; i++) {
      const q = quoteByTime.get(baseCandles[i].time);
      const qPrev = quoteByTime.get(baseCandles[i - 1].time);
      if (!q || !qPrev || q.close <= 0 || qPrev.close <= 0) continue;
      if (baseCandles[i].close <= 0 || baseCandles[i - 1].close <= 0) continue;

      baseReturns.push(Math.log(baseCandles[i].close / baseCandles[i - 1].close));
      quoteReturns.push(Math.log(q.close / qPrev.close));
    }

    // Calculate correlation coefficient
    let rho = 0.85; // Default assumption for crypto pairs
    if (baseReturns.length >= 5) {
      const n = baseReturns.length;
      const meanB = baseReturns.reduce((a, b) => a + b, 0) / n;
      const meanQ = quoteReturns.reduce((a, b) => a + b, 0) / n;

      let covBQ = 0, varB = 0, varQ = 0;
      for (let i = 0; i < n; i++) {
        const db = baseReturns[i] - meanB;
        const dq = quoteReturns[i] - meanQ;
        covBQ += db * dq;
        varB += db * db;
        varQ += dq * dq;
      }

      if (varB > 0 && varQ > 0) {
        rho = Math.max(0, Math.min(0.99, covBQ / Math.sqrt(varB * varQ)));
      }
    }

    return baseCandles
      .map(b => {
        const q = quoteByTime.get(b.time);
        if (!q || q.close === 0 || q.open === 0 || q.high === 0 || q.low === 0) return null;

        // Exact open/close for synthetic ratio
        const open = b.open / q.open;
        const close = b.close / q.close;

        // Use variance-addition formula for synthetic range
        // Log-range of each asset (approximates intrabar volatility)
        const rangeB = Math.log(b.high / b.low);
        const rangeQ = Math.log(q.high / q.low);

        // Synthetic variance: σ² = σ_B² + σ_Q² - 2·ρ·σ_B·σ_Q
        // This correctly shrinks when ρ → 1 (correlated moves cancel out)
        const synthVar = rangeB * rangeB + rangeQ * rangeQ - 2 * rho * rangeB * rangeQ;
        const synthRange = Math.sqrt(Math.max(0, synthVar));

        // Apply synthetic range centered on the close price
        // (close is more recent/accurate than midpoint)
        const halfRange = synthRange / 2;
        const high = close * Math.exp(halfRange);
        const low = close * Math.exp(-halfRange);

        // Ensure OHLC consistency (high/low must contain open and close)
        const finalHigh = Math.max(high, open, close);
        const finalLow = Math.min(low, open, close);

        return { time: b.time, open, high: finalHigh, low: finalLow, close };
      })
      .filter((c): c is OHLC => c !== null);
  }, [baseCandles, quoteCandles, pairInfo.isSynthetic]);

  // Apply inversion if needed
  const candles = useMemo(() => {
    if (pairInfoLoading) return rawCandles;
    if (!needsInversion) return rawCandles;
    return rawCandles.map(invertOHLC);
  }, [rawCandles, needsInversion, pairInfoLoading]);

  // Compute final live price (synthetic calculation + inversion all done here)
  const livePrice = useMemo(() => {
    if (!rawLivePrice) return null;
    if (pairInfoLoading) return rawLivePrice;

    let price = rawLivePrice;

    // Step 1: Compute synthetic price (base/quote) if needed
    if (pairInfo.isSynthetic && rawQuotePrice) {
      price = {
        mid: rawLivePrice.mid / rawQuotePrice.mid,
        bid: rawLivePrice.bid / rawQuotePrice.ask,  // Conservative bid
        ask: rawLivePrice.ask / rawQuotePrice.bid,  // Conservative ask
      };
    }

    // Step 2: Apply inversion if needed
    if (needsInversion) {
      price = invertPriceData(price);
    }

    return price;
  }, [rawLivePrice, rawQuotePrice, needsInversion, pairInfo.isSynthetic, pairInfoLoading]);

  // Chart engine - receives final computed candles and live price (synthetic/inversion already applied)
  const engine = usePriceChartEngine({
    height,
    chartType,
    activeIndicators,
    candles,
    livePrice,
    quotePrice: null, // No longer needed - synthetic calc done above
    timeframe,
    isSynthetic: false, // No longer needed - synthetic calc done above
    needsInversion: false, // No longer needed - inversion done above
    getParams,
    priceScaleMode,
  });

  // Load drawings from localStorage on mount and when key changes
  useEffect(() => {
    if (!engine.drawingTools) return;
    try {
      const saved = localStorage.getItem(drawingsStorageKey);
      if (saved) {
        const drawings = JSON.parse(saved);
        engine.drawingTools.loadDrawings(drawings);
      }
    } catch (e) {
      console.warn('Failed to load drawings from localStorage:', e);
    }
  }, [engine.drawingTools, drawingsStorageKey]);

  // Set auto-exit callback - when a drawing is finished, exit drawing mode
  useEffect(() => {
    if (!engine.drawingTools) return;
    engine.drawingTools.setOnDrawingComplete(() => {
      setDrawingTool(null);
      if (engine.drawingTools) {
        engine.drawingTools.setTool(null);
      }
    });
  }, [engine.drawingTools]);

  // Save drawings to localStorage when they change (debounced)
  useEffect(() => {
    if (!engine.drawingTools) return;

    const saveDrawings = () => {
      try {
        const drawings = engine.drawingTools!.getDrawings();
        if (drawings.length === 0) {
          localStorage.removeItem(drawingsStorageKey);
        } else {
          localStorage.setItem(drawingsStorageKey, JSON.stringify(drawings));
        }
      } catch (e) {
        console.warn('Failed to save drawings to localStorage:', e);
      }
    };

    // Listen to storage events from other windows to sync drawings
    const handleStorageChange = (e: StorageEvent) => {
      if (e.key === drawingsStorageKey && e.newValue) {
        try {
          const drawings = JSON.parse(e.newValue);
          engine.drawingTools!.loadDrawings(drawings);
        } catch (err) {
          console.warn('Failed to sync drawings from storage event:', err);
        }
      }
    };

    // Use a debounced interval to save periodically
    const interval = setInterval(saveDrawings, 1000);
    window.addEventListener('storage', handleStorageChange);

    return () => {
      clearInterval(interval);
      window.removeEventListener('storage', handleStorageChange);
      saveDrawings(); // Final save on unmount
    };
  }, [engine.drawingTools, drawingsStorageKey]);

  // Export rows
  const exportRows = useMemo(
    () => buildExportRows(candles, activeIndicators, getParams),
    [candles, activeIndicators, getParams]
  );

  // Helpers
  const hasOverlay = activeIndicators.includes('ema-trend');
  const subPaneIndicators = activeIndicators.filter(k => SUB_PANE_KEYS.includes(k));
  const mainChartHeight = engine.paneHeights[0] || (height - subPaneIndicators.length * 104);

  const openParamsFor = (key: IndicatorKey) => {
    setEditingKey(key);
    setEditDraft({ ...getParams(key) });
  };

  const removeIndicator = (key: IndicatorKey) => {
    setActiveIndicators(prev => prev.filter(k => k !== key));
  };

  const applyParams = () => {
    if (editingKey) {
      setParams(editingKey, editDraft);
      setEditingKey(null);
    }
  };

  // Drawing tools handlers
  const handleDrawingToolChange = useCallback((tool: DrawingToolType | null) => {
    setDrawingTool(tool);
    if (engine.drawingTools) {
      engine.drawingTools.setTool(tool);
    }
  }, [engine.drawingTools]);

  const handleSelectAll = useCallback(() => {
    if (engine.drawingTools) {
      engine.drawingTools.selectAll();
      setSelectedCount(engine.drawingTools.getSelectedCount());
    }
  }, [engine.drawingTools]);

  const handleDeleteDrawing = useCallback(() => {
    if (engine.drawingTools) {
      engine.drawingTools.deleteSelected();
      setSelectedDrawingId(null);
      setSelectedCount(0);
    }
  }, [engine.drawingTools]);

  const handleStyleChange = useCallback((style: { color?: string; fillColor?: string }) => {
    if (engine.drawingTools) {
      engine.drawingTools.updateSelectedStyle(style);
    }
  }, [engine.drawingTools]);

  // Update selection state from drawing tools
  const updateSelectionState = useCallback(() => {
    if (!engine.drawingTools) return;
    setSelectedDrawingId(engine.drawingTools.getSelectedId());
    setSelectedCount(engine.drawingTools.getSelectedCount());
  }, [engine.drawingTools]);

  // Chart container mouse handlers for drawings
  const handleChartPointerDown = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    if (!engine.drawingTools) return;

    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    if (drawingTool) {
      // For freedraw/highlight and single-point tools, use onPointerDown
      // For multi-point tools (trendline, ray, shapes), use onClick
      if (drawingTool === 'freedraw' || drawingTool === 'highlight' || drawingTool === 'vertical' || drawingTool === 'horizontal' || drawingTool === 'cross') {
        const handled = engine.drawingTools.onPointerDown(x, y);
        if (handled) {
          e.stopPropagation();
          e.preventDefault();
        }
      } else {
        // Multi-point tools use click
        const handled = engine.drawingTools.onClick(x, y);
        if (handled) {
          e.stopPropagation();
          e.preventDefault();
        }
      }
    } else if (isAreaSelectMode) {
      // Area select mode - start selection rectangle
      engine.drawingTools.startAreaSelect(x, y);
      e.stopPropagation();
      e.preventDefault();
    } else {
      // No tool selected - check for control point drag first, then handle selection
      const controlHit = engine.drawingTools.selectAt(x, y);
      if (controlHit || engine.drawingTools.isDragging()) {
        e.stopPropagation();
        e.preventDefault();
      }
    }
    updateSelectionState();
  }, [engine.drawingTools, drawingTool, isAreaSelectMode, updateSelectionState]);

  const handleChartPointerMove = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    if (!engine.drawingTools) return;

    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Handle area selection - prevent chart pan
    if (engine.drawingTools.isAreaSelecting()) {
      e.stopPropagation();
      e.preventDefault();
      engine.drawingTools.updateAreaSelect(x, y);
      updateSelectionState();
      return;
    }

    // Handle control point dragging - prevent chart pan
    if (engine.drawingTools.isDragging()) {
      e.stopPropagation();
      e.preventDefault();
      engine.drawingTools.onDragMove(x, y);
      return;
    }

    // Handle active drawing (freedraw hold, or multi-point tool preview) - prevent chart pan
    if (drawingTool && engine.drawingTools.isDrawingActive()) {
      e.stopPropagation();
      e.preventDefault();
    }

    engine.drawingTools.onPointerMove(x, y);
  }, [engine.drawingTools, drawingTool, updateSelectionState]);

  const handleChartPointerUp = useCallback(() => {
    if (!engine.drawingTools) return;

    // End area selection
    if (engine.drawingTools.isAreaSelecting()) {
      engine.drawingTools.endAreaSelect();
      updateSelectionState();
      return;
    }

    // Finish freedraw on pointer up
    engine.drawingTools.onPointerUp();
    engine.drawingTools.onDragEnd();
    updateSelectionState();
  }, [engine.drawingTools, updateSelectionState]);

  // Keyboard handler for Delete/Backspace and Escape
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Don't handle if user is typing in an input
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;

      if ((e.key === 'Delete' || e.key === 'Backspace') && hasDrawingSelection) {
        e.preventDefault();
        handleDeleteDrawing();
      } else if (e.key === 'Escape') {
        // Cancel any active mode and revert to normal selection
        if (drawingTool) {
          handleDrawingToolChange(null);
        }
        if (isAreaSelectMode) {
          setIsAreaSelectMode(false);
        }
        if (engine.drawingTools) {
          engine.drawingTools.clearSelection();
          updateSelectionState();
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [hasDrawingSelection, handleDeleteDrawing, engine.drawingTools, updateSelectionState, drawingTool, handleDrawingToolChange, isAreaSelectMode]);

  const openWindow = () => {
    // Build clean URL without encoding parentheses and commas
    const parts: string[] = [
      `pair=${displayBase}${displayQuote}`,
      `tf=${timeframe}`,
      `type=${chartType}`,
    ];
    activeIndicators.forEach(key => {
      const p = getParams(key);
      parts.push(`ta=${key}(${p.fast},${p.slow},${p.signal})`);
    });
    const url = `/chart?${parts.join('&')}`;
    window.open(url, `btr-chart-${displayBase}-${displayQuote}`,
      'popup=yes,width=1200,height=800,left=100,top=100,menubar=no,toolbar=no,location=no,status=no');
  };

  return (
    <div className={`flex flex-col ${className}`}>
      {/* Unified Toolbar - Full width bar at top */}
      <DrawingToolbar
        chartType={chartType}
        timeframe={timeframe}
        activeIndicators={activeIndicators}
        onChangeType={setChartType}
        onChangeTimeframe={setTimeframe}
        onChangeIndicators={setActiveIndicators}
        standalone={standalone}
        onOpenWindow={standalone ? undefined : openWindow}
        exportRows={exportRows}
        chartRef={engine.chartRef}
        pairLabel={`${displayBase}/${displayQuote}`}
        base={displayBase}
        quote={displayQuote}
        onChangePair={onChangePair}
        onInvertPair={onInvertPair}
        activeTool={drawingTool}
        onToolChange={handleDrawingToolChange}
        onSelectAll={handleSelectAll}
        onDelete={handleDeleteDrawing}
        onStyleChange={handleStyleChange}
        hasSelection={hasDrawingSelection}
        selectedDrawing={engine.drawingTools?.getSelectedDrawing() ?? null}
        selectedCount={selectedCount}
        isAreaSelectMode={isAreaSelectMode}
        onAreaSelectModeChange={setIsAreaSelectMode}
        priceScaleMode={priceScaleMode}
        onScaleChange={setPriceScaleMode}
      />

      {/* Chart Area */}
      <div className="relative flex-1">
        {/* OHLC Header + Overlay Values */}
      <div
        className="absolute top-1 left-1 z-10 flex flex-col font-numeric"
      >
        {engine.currentOHLC && (
          <>
            <div className="text-[10px] text-fg-2 flex items-center gap-2">
              <span>O <span className="text-fg-1">{formatChartPrice(engine.currentOHLC.open, engine.decimals)}</span></span>
              <span>H <span className="text-fg-1">{formatChartPrice(engine.currentOHLC.high, engine.decimals)}</span></span>
              <span>L <span className="text-fg-1">{formatChartPrice(engine.currentOHLC.low, engine.decimals)}</span></span>
              <span>C <span className={engine.currentOHLC.close >= engine.currentOHLC.open ? 'text-green' : 'text-red'}>
                {formatChartPrice(engine.spread?.mid ?? engine.currentOHLC.close, engine.decimals)}
              </span></span>
              {engine.spread && (
                <span className="text-fg-3">
                  spread <span className="text-fg-2">{((engine.spread.ask - engine.spread.bid) / engine.spread.mid * 10000).toFixed(1)}bps</span>
                </span>
              )}
            </div>

            {hasOverlay && engine.overlayValues && (
              <div className="text-[10px] text-fg-2 flex items-center gap-2">
                <span className="text-fg-2">{getIndicatorBaseName('ema-trend')}</span>
                <span style={{ color: engine.overlayValues.color1 }}>
                  {formatSeriesWithParams('Fast', getParams('ema-trend'))} {formatIndicatorValue(engine.overlayValues.value1)}
                </span>
                <span style={{ color: engine.overlayValues.color2 }}>
                  {formatSeriesWithParams('Slow', getParams('ema-trend'))} {formatIndicatorValue(engine.overlayValues.value2)}
                </span>
                <HeaderButton icon={Pencil} onClick={() => openParamsFor('ema-trend')} tooltip="Edit parameters" />
                <HeaderButton icon={X} onClick={() => removeIndicator('ema-trend')} tooltip="Remove indicator" danger />
              </div>
            )}
          </>
        )}
      </div>

      {/* Sub-pane Headers */}
      {subPaneIndicators.map((key, idx) => {
        const top = engine.paneHeights[idx] || (mainChartHeight + idx * 104);
        const values = engine.paneValues.get(key);
        const params = getParams(key);
        const def = INDICATORS[key];

        return (
          <div
            key={key}
            className="absolute z-10 flex items-center gap-1 text-[10px] font-numeric"
            style={{
              top: top + 4,
              left: 4,
            }}
          >
            {values && (
              <>
                <span className="text-fg-2">{values.name1}</span>
                <span style={{ color: values.color1 }}>{formatSeriesWithParams(values.name1, params)} {formatIndicatorValue(values.value1)}</span>
                {!def?.isDivergence && values.name2 && (
                  <span style={{ color: values.color2 }}>{formatSeriesWithParams(values.name2, params)} {formatIndicatorValue(values.value2)}</span>
                )}
              </>
            )}
            <HeaderButton icon={Pencil} onClick={() => openParamsFor(key)} tooltip="Edit parameters" />
            <HeaderButton icon={X} onClick={() => removeIndicator(key)} tooltip="Remove indicator" danger />
          </div>
        );
      })}


      {/* Loading/Error */}
      {loading && (
        <div className="absolute inset-0 flex items-center justify-center bg-bg-1/80 z-20">
          <div className="text-muted-foreground text-sm">Loading chart...</div>
        </div>
      )}
      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-bg-1/80 z-20">
          <div className="text-red-400 text-sm">Error: {error}</div>
        </div>
      )}

      {/* Watermark - behind chart */}
      <div
        className="absolute inset-0 flex items-center justify-center pointer-events-none"
        style={{ height: mainChartHeight, zIndex: 0 }}
      >
        <div className="font-title font-bold text-fg-3 opacity-10" style={{ fontSize: '5rem' }}>
          {displayBase}/{displayQuote}
        </div>
      </div>

      {/* Chart Container */}
      <div
        ref={engine.containerRef}
        className="relative"
        style={{ height, width: '100%', zIndex: 1, cursor: drawingTool || isAreaSelectMode ? 'crosshair' : undefined }}
        onPointerDown={handleChartPointerDown}
        onPointerMove={handleChartPointerMove}
        onPointerUp={handleChartPointerUp}
        onPointerLeave={handleChartPointerUp}
      />

      {/* Vertical Line Overlays - spans all panes */}
      <VerticalLineOverlay
        drawingTools={engine.drawingTools}
        chartRef={engine.chartRef}
        height={height}
      />
      </div>
      {/* End Chart Area */}

      {/* Params Modal */}
      <IndicatorParamsModal
        open={!!editingKey}
        preset={editingKey}
        params={editDraft}
        onChange={setEditDraft}
        onCancel={() => setEditingKey(null)}
        onApply={applyParams}
      />
    </div>
  );
}

// Small header button for edit/remove
function HeaderButton({
  icon: Icon,
  onClick,
  tooltip,
  danger,
}: {
  icon: typeof Pencil;
  onClick: () => void;
  tooltip: string;
  danger?: boolean;
}) {
  return (
    <Tooltip content={tooltip} side="top">
      <button
        onClick={onClick}
        className={`w-4 h-4 flex items-center justify-center rounded-xs hover:bg-bg-2 text-fg-2 transition-colors ${
          danger ? 'hover:text-red' : 'hover:text-primary'
        }`}
      >
        <Icon className="w-2.5 h-2.5" />
      </button>
    </Tooltip>
  );
}

// Simple price display component
interface PriceDisplayProps {
  base: string;
  quote: string;
  className?: string;
}

export function PriceDisplay({ base, quote, className = '' }: PriceDisplayProps) {
  const canonical = getCanonicalPair(base, quote);
  const symbol = `${canonical.base}${canonical.quote}`;
  const [pairInfo, setPairInfo] = useState<ReturnType<typeof getPairFeedInfo>>({
    isSynthetic: false,
    feed: '',
    symbol: '',
  });

  const basePriceData = usePriceStream(pairInfo.isSynthetic ? pairInfo.baseFeed! : `agg:spot:${symbol}`);
  const quotePriceData = usePriceStream(pairInfo.isSynthetic ? pairInfo.quoteFeed! : '');

  useEffect(() => {
    fetchAvailableTickers().then(feeds => setPairInfo(getPairFeedInfo(canonical.base, canonical.quote, feeds)));
  }, [canonical.base, canonical.quote]);

  let displayPrice: number | null = null;
  if (pairInfo.isSynthetic && basePriceData && quotePriceData) {
    displayPrice = basePriceData.mid / quotePriceData.mid;
  } else if (!pairInfo.isSynthetic && basePriceData) {
    displayPrice = basePriceData.mid;
  }

  return (
    <span className={className}>
      {displayPrice ? formatChartPrice(displayPrice, precision(displayPrice) + 1) : '...'}
    </span>
  );
}

// Format time for vertical line label (UTC to match chart)
function formatVerticalLineTime(timestamp: number): string {
  const date = new Date(timestamp * 1000);
  const day = date.getUTCDate().toString().padStart(2, '0');
  const month = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const hours = date.getUTCHours().toString().padStart(2, '0');
  const minutes = date.getUTCMinutes().toString().padStart(2, '0');
  return `${day}/${month} ${hours}:${minutes}`;
}

// Vertical line overlay - renders DOM elements that span all chart panes
function VerticalLineOverlay({
  drawingTools,
  chartRef,
  height,
}: {
  drawingTools: ReturnType<typeof usePriceChartEngine>['drawingTools'];
  chartRef: React.MutableRefObject<any>;
  height: number;
}) {
  const [lines, setLines] = useState<ReturnType<NonNullable<typeof drawingTools>['getVerticalLines']>>([]);

  // Subscribe to chart updates to re-render vertical lines
  useEffect(() => {
    if (!drawingTools || !chartRef.current) return;

    const updateLines = () => {
      setLines(drawingTools.getVerticalLines());
    };

    // Initial update
    updateLines();

    // Subscribe to time scale changes
    const timeScale = chartRef.current.timeScale();
    timeScale.subscribeVisibleLogicalRangeChange(updateLines);

    // Also poll periodically for drawing changes
    const interval = setInterval(updateLines, 100);

    return () => {
      timeScale.unsubscribeVisibleLogicalRangeChange(updateLines);
      clearInterval(interval);
    };
  }, [drawingTools, chartRef]);

  if (lines.length === 0) return null;

  // Time axis is ~28px from bottom
  const timeAxisHeight = 28;
  const chartHeight = height - timeAxisHeight;

  return (
    <div
      className="absolute inset-0 pointer-events-none"
      style={{ zIndex: 2, bottom: timeAxisHeight }}
    >
      {lines.map(line => {
        const dashStyle = line.isTemp || line.lineStyle === 'dashed'
          ? `${line.lineWidth * 4}px ${line.lineWidth * 2}px`
          : line.lineStyle === 'dotted'
          ? `${line.lineWidth}px ${line.lineWidth * 2}px`
          : 'none';

        const timeLabel = line.time ? formatVerticalLineTime(line.time) : '';

        return (
          <div key={line.id}>
            {/* Vertical line */}
            <div
              className="absolute top-0"
              style={{
                left: line.x,
                height: chartHeight,
                transform: 'translateX(-50%)',
              }}
            >
              {/* The line */}
              <div
                style={{
                  position: 'absolute',
                  left: '50%',
                  transform: 'translateX(-50%)',
                  width: line.lineWidth,
                  height: '100%',
                  backgroundColor: dashStyle === 'none' ? line.color : undefined,
                  backgroundImage: dashStyle !== 'none'
                    ? `repeating-linear-gradient(to bottom, ${line.color}, ${line.color} ${line.lineWidth * 4}px, transparent ${line.lineWidth * 4}px, transparent ${line.lineWidth * 6}px)`
                    : undefined,
                }}
              />
              {/* Time label - right side, bottom aligned with background */}
              {timeLabel && !line.isTemp && (
                <div
                  style={{
                    position: 'absolute',
                    bottom: 10,
                    left: 8,
                    transform: 'rotate(-90deg)',
                    transformOrigin: 'bottom left',
                    lineHeight: '13px',
                    fontSize: '11px',
                    fontFamily: 'var(--font-numbers)',
                    fontVariantNumeric: 'tabular-nums',
                    whiteSpace: 'nowrap',
                    backgroundColor: line.color,
                    color: 'white',
                    padding: '2px 4px',
                    borderRadius: '2px',
                  }}
                >
                  {timeLabel}
                </div>
              )}
            </div>

            {/* Horizontal line is rendered by native PriceLine API for both horizontal and cross types */}
            {/* We don't render it here to avoid duplication */}
          </div>
        );
      })}
    </div>
  );
}
