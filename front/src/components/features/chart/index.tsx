/**
 * PriceChart - Composable candlestick/bar/line chart with technical indicators
 */
import { useState, useMemo, useEffect } from 'preact/hooks';
import type { PriceScaleMode } from 'lightweight-charts';
import { precision } from '@utils/format';
import {
  usePriceStream,
  fetchAvailableTickers,
  getPairFeedInfo,
  getCanonicalPair,
  isInvertedPair,
  invertPriceData,
} from '@/hooks/usePriceFeed';
import {
  type IndicatorKey,
  type ChartType,
  INDICATORS,
  SUB_PANE_KEYS,
  formatChartPrice,
  formatIndicatorValue,
  formatSeriesWithParams,
  getIndicatorBaseName,
} from '../chart/indicatorsConfig';
import { usePriceChartEngine } from '../chart/usePriceChartEngine';
import type { InitialIndicator } from '../chart/useIndicatorParams';
import { DrawingToolbar } from '../chart/DrawingToolbar';
import { IndicatorParamsModal } from '../chart/IndicatorParamsModal';
import { buildExportRows } from '../chart/chartExport';
import { useChartData } from './hooks/useChartData';
import { useDrawingSystem } from './hooks/useDrawingSystem';
import { useDrawingHandlers } from './hooks/useDrawingHandlers';
import { useDrawingPersistence } from './hooks/useDrawingPersistence';
import { useIndicatorManager } from './hooks/useIndicatorManager';
import { ChartContainer } from './ChartContainer';
import { VerticalLineOverlay } from './components/VerticalLineOverlay';
import { HeaderButton } from './components/HeaderButton';

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

  // Core state
  const [chartType, setChartType] = useState<ChartType>(initialChartType);
  const [timeframe, setTimeframe] = useState(initialTimeframe);
  const [priceScaleMode, setPriceScaleMode] = useState<PriceScaleMode>(0);
  const [activeIndicators, setActiveIndicators] = useState<IndicatorKey[]>(() =>
    initialIndicators.map(i => i.preset)
  );

  // Notify parent of state changes
  useEffect(() => { onTimeframeChange?.(timeframe); }, [timeframe, onTimeframeChange]);
  useEffect(() => { onChartTypeChange?.(chartType); }, [chartType, onChartTypeChange]);

  // Pair info
  const [pairInfoLoading, setPairInfoLoading] = useState(true);
  const [pairInfo, setPairInfo] = useState<ReturnType<typeof getPairFeedInfo>>({
    isSynthetic: false,
    feed: '',
    symbol: '',
  });

  // Indicator management
  const { editorState, openEditor, closeEditor, applyParams, updateDraft, getParams } =
    useIndicatorManager(activeIndicators, initialIndicators, onIndicatorsChange);

  // Drawing tools
  const { activeTool } = useDrawingSystem();
  const drawingTool = activeTool.value;
  const [selectedCount, setSelectedCount] = useState(0);
  const [isAreaSelectMode, setIsAreaSelectMode] = useState(false);

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
  const baseSymbol = pairInfo.isSynthetic ? pairInfo.baseSymbol! : (pairInfo.symbol || `${fetchBase}USDC`);
  const quoteSymbol = pairInfo.isSynthetic ? pairInfo.quoteSymbol! : '';

  const { candles, loading: dataLoading, error } = useChartData(
    base,
    quote,
    timeframe,
    pairInfo.isSynthetic,
    baseSymbol,
    quoteSymbol,
    needsInversion
  );

  const rawLivePrice = usePriceStream(
    pairInfo.isSynthetic ? pairInfo.baseFeed! : pairInfo.feed || `agg:spot:${baseSymbol}`
  );
  const rawQuotePrice = usePriceStream(pairInfo.isSynthetic ? pairInfo.quoteFeed! : '');

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

  const loading = pairInfoLoading || dataLoading;

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

  // Drawing persistence
  useDrawingPersistence(engine.drawingTools, drawingsStorageKey);

  // Auto-exit drawing mode when drawing completes
  useEffect(() => {
    if (!engine.drawingTools) return;
    engine.drawingTools.setOnDrawingComplete(() => {
      activeTool.value = null;
      engine.drawingTools?.setTool(null);
    });
  }, [engine.drawingTools, activeTool]);

  // Export rows
  const exportRows = useMemo(
    () => buildExportRows(candles, activeIndicators, getParams),
    [candles, activeIndicators, getParams]
  );

  // Helpers
  const hasOverlay = activeIndicators.includes('ema-trend');
  const subPaneIndicators = activeIndicators.filter(k => SUB_PANE_KEYS.includes(k));
  const mainChartHeight = engine.paneHeights[0] || (height - subPaneIndicators.length * 104);

  // Indicator helpers
  const removeIndicator = (key: IndicatorKey) => {
    setActiveIndicators(prev => prev.filter(k => k !== key));
  };

  // Selection state and drawing handlers
  const updateSelectionState = () => {
    if (!engine.drawingTools) return;
    setSelectedCount(engine.drawingTools.getSelectedCount());
  };

  const hasDrawingSelection = selectedCount > 0;

  const {
    handlePointerDown: handleChartPointerDown,
    handlePointerMove: handleChartPointerMove,
    handlePointerUp: handleChartPointerUp,
    handleSelectAll,
    handleDelete: handleDeleteDrawing,
    handleStyleChange,
    handleKeyDown,
  } = useDrawingHandlers({
    engine: engine.drawingTools,
    drawingTool,
    isAreaSelectMode,
    onToolChange: (tool) => { activeTool.value = tool; },
    onAreaSelectModeChange: setIsAreaSelectMode,
    onSelectionChange: updateSelectionState,
  });

  // Tool change handler
  const handleDrawingToolChange = (tool: any) => {
    activeTool.value = tool;
    if (engine.drawingTools) {
      engine.drawingTools.setTool(tool);
    }
  };

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleKeyDown]);

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

      <ChartContainer
        height={height}
        displayBase={displayBase}
        displayQuote={displayQuote}
        loading={loading}
        error={error}
        cursor={drawingTool || isAreaSelectMode ? 'crosshair' : undefined}
        onPointerDown={handleChartPointerDown}
        onPointerMove={handleChartPointerMove}
        onPointerUp={handleChartPointerUp}
      >
        {/* OHLC Header + Overlay Values */}
        <div className="absolute top-1 left-1 z-10 flex flex-col font-numeric">
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
                  <HeaderButton iconName="pencil" onClick={() => openEditor('ema-trend')} tooltip="Edit parameters" />
                  <HeaderButton iconName="x" onClick={() => removeIndicator('ema-trend')} tooltip="Remove indicator" danger />
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
              <HeaderButton iconName="pencil" onClick={() => openEditor(key)} tooltip="Edit parameters" />
              <HeaderButton iconName="x" onClick={() => removeIndicator(key)} tooltip="Remove indicator" danger />
            </div>
          );
        })}

        {/* Chart Container - Internal to ChartContainer UI wrapper */}
        <div
          ref={engine.containerRef}
          className="w-full h-full"
        />

        {/* Vertical Line Overlays - spans all panes */}
        <VerticalLineOverlay
          drawingTools={engine.drawingTools}
          chartRef={engine.chartRef}
          height={height}
        />
      </ChartContainer>

      {/* Params Modal */}
      <IndicatorParamsModal
        open={!!editorState.editingKey}
        preset={editorState.editingKey}
        params={editorState.editDraft}
        onChange={updateDraft}
        onCancel={closeEditor}
        onApply={applyParams}
      />
    </div>
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
