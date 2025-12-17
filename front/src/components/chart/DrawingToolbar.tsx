/**
 * Unified Chart Toolbar - All chart and drawing controls in one bar
 * Order: Ticker | Chart Type | Timeframe | Indicators | Select | Draw | Lines | Shapes | [Color/Delete] | Download | Expand
 */
import { useState } from 'preact/hooks';
import {
  Pencil,
  Highlighter,
  MousePointer2,
  SquareDashed,
  CheckSquare,
  Trash2,
  Palette,
  ChartCandlestick,
  BarChart3,
  TrendingUp,
  FunctionSquare,
  Download,
  Maximize2,
  FileText,
  Braces,
  Image,
  Sun,
  Moon,
  ArrowLeftRight,
} from 'lucide-react';
import type { IChartApi, PriceScaleMode } from 'lightweight-charts';
import { Tooltip } from '@components/ui/Tooltip';
import { MaskIcon } from '@components/ui/MaskIcon';
import { Dropdown } from '@components/ui/Dropdown';
import { ANALYSIS_PRESETS } from '@utils/indicators';
import { addNotification } from '@lib/notifications';
import { useTheme } from '@lib/theme';
import { getTokenIcon } from '@sdk/eth';
import { useHealthMonitor } from '@/hooks/useHealthMonitor';
import PairSelector from '@components/PairSelector';
import type { DrawingToolType, Drawing, DrawingStyle } from './DrawingTools';
import {
  type ChartType,
  type IndicatorKey,
  TIMEFRAME_OPTIONS,
  CHART_TYPE_OPTIONS,
  SUB_PANE_KEYS,
} from './indicatorsConfig';
import { type ExportRow, exportCsv, exportJson, exportPng } from './chartExport';

const MAX_SUB_PANES = 3;

const CHART_ICONS = {
  candles: ChartCandlestick,
  bars: BarChart3,
  line: TrendingUp,
};

// Tool definitions for dropdowns
type SelectMode = 'single' | 'area' | 'all';
const SELECT_ITEMS = [
  { value: 'single' as SelectMode, label: 'Single', icon: MousePointer2 },
  { value: 'area' as SelectMode, label: 'Area', icon: SquareDashed },
  { value: 'all' as SelectMode, label: 'All', icon: CheckSquare },
];

const DRAW_ITEMS = [
  { value: 'freedraw' as DrawingToolType, label: 'Pen', icon: Pencil },
  { value: 'highlight' as DrawingToolType, label: 'Highlighter', icon: Highlighter },
];

const LINE_ITEMS = [
  { value: 'horizontal' as DrawingToolType, label: 'Horizontal', icon: <MaskIcon src="/icons/horizontal-line.svg" size="sm" /> },
  { value: 'vertical' as DrawingToolType, label: 'Vertical', icon: <MaskIcon src="/icons/vertical-line.svg" size="sm" /> },
  { value: 'cross' as DrawingToolType, label: 'Cross', icon: <MaskIcon src="/icons/cross-line.svg" size="sm" /> },
  { value: 'trendline' as DrawingToolType, label: 'Trend Line', icon: <MaskIcon src="/icons/trend-line.svg" size="sm" /> },
  { value: 'ray' as DrawingToolType, label: 'Ray', icon: <MaskIcon src="/icons/ray.svg" size="sm" /> },
  { value: 'extended' as DrawingToolType, label: 'Extended', icon: <MaskIcon src="/icons/extended-line.svg" size="sm" /> },
];

const SHAPE_ITEMS = [
  { value: 'rectangle' as DrawingToolType, label: 'Rectangle', icon: <MaskIcon src="/icons/rectangle.svg" size="sm" /> },
  { value: 'triangle' as DrawingToolType, label: 'Triangle', icon: <MaskIcon src="/icons/triangle.svg" size="sm" /> },
  { value: 'circle' as DrawingToolType, label: 'Circle', icon: <MaskIcon src="/icons/circle.svg" size="sm" /> },
  { value: 'channel' as DrawingToolType, label: 'Channel', icon: <MaskIcon src="/icons/channel.svg" size="sm" /> },
];

// Preset colors
const PRESET_COLORS = [
  '#2962FF', '#FF6D00', '#00C853', '#D500F9',
  '#FF1744', '#FFEA00', '#00B8D4', '#FFFFFF',
];

// Price scale modes matching lightweight-charts
const PRICE_SCALE_OPTIONS = [
  { value: 0, label: 'Linear' },
  { value: 1, label: 'Log' },
  { value: 2, label: 'Percent' },
];

// Color palette component
function ColorPalette({
  open,
  onOpenChange,
  selectedDrawing,
  onStyleChange,
  canHaveFill,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  selectedDrawing: Drawing;
  onStyleChange: (style: Partial<DrawingStyle>) => void;
  canHaveFill: boolean;
}) {
  return (
    <Dropdown
      items={[]}
      value=""
      onChange={() => {}}
      open={open}
      onOpenChange={onOpenChange}
      size="sm"
      side="bottom"
      minWidth={180}
      trigger={
        <Tooltip content="Color" side="bottom">
          <div className="h-8 px-2 flex items-center cursor-pointer text-fg-2 hover:text-fg-1 hover:bg-bg-2 transition-colors">
            <div className="relative">
              <Palette className="w-4 h-4" />
              <div
                className="absolute -bottom-0.5 -right-0.5 w-2 h-2 rounded-full border border-bg-1"
                style={{ backgroundColor: selectedDrawing.style.color === 'transparent' ? '#888' : selectedDrawing.style.color }}
              />
            </div>
          </div>
        </Tooltip>
      }
      footer={
        <div className="p-3">
          <div className="text-[10px] text-fg-3 uppercase tracking-wider mb-2">Stroke</div>
          <div className="flex flex-wrap gap-1.5 mb-3">
            <ColorSwatch
              color="transparent"
              selected={selectedDrawing.style.color === 'transparent'}
              onClick={() => onStyleChange({ color: 'transparent' })}
              showEmpty
            />
            {PRESET_COLORS.map(color => (
              <ColorSwatch
                key={`stroke-${color}`}
                color={color}
                selected={selectedDrawing.style.color === color}
                onClick={() => onStyleChange({ color })}
              />
            ))}
          </div>

          {canHaveFill && (
            <>
              <div className="text-[10px] text-fg-3 uppercase tracking-wider mb-2">Fill</div>
              <div className="flex flex-wrap gap-1.5 mb-3">
                <ColorSwatch
                  color="transparent"
                  selected={!selectedDrawing.style.fillColor || selectedDrawing.style.fillColor === 'transparent'}
                  onClick={() => onStyleChange({ fillColor: 'transparent' })}
                  showEmpty
                />
                {PRESET_COLORS.map(color => (
                  <ColorSwatch
                    key={`fill-${color}`}
                    color={color}
                    selected={selectedDrawing.style.fillColor === color}
                    onClick={() => onStyleChange({ fillColor: color, fillOpacity: 0.25 })}
                    opacity={0.6}
                  />
                ))}
              </div>
            </>
          )}

          <div className="flex items-center gap-2 pt-2 border-t border-border">
            <input
              type="color"
              value={selectedDrawing.style.color === 'transparent' ? '#888888' : selectedDrawing.style.color}
              onChange={(e) => onStyleChange({ color: e.target.value })}
              className="w-5 h-5 cursor-pointer border-0 p-0"
            />
            <span className="text-xs text-fg-2">Custom</span>
          </div>
        </div>
      }
    />
  );
}

// Reusable color swatch button
function ColorSwatch({
  color,
  selected,
  onClick,
  showEmpty,
  opacity,
}: {
  color: string;
  selected: boolean;
  onClick: () => void;
  showEmpty?: boolean;
  opacity?: number;
}) {
  return (
    <button
      onClick={onClick}
      className={`w-5 h-5 border transition-all ${
        selected ? 'border-primary ring-1 ring-primary' : 'border-border'
      } ${showEmpty ? 'relative' : ''}`}
      style={showEmpty
        ? { background: 'repeating-linear-gradient(45deg, transparent, transparent 3px, rgba(255,255,255,0.1) 3px, rgba(255,255,255,0.1) 6px)' }
        : { backgroundColor: color, opacity }
      }
    >
      {showEmpty && <span className="absolute inset-0 flex items-center justify-center text-[9px] text-fg-3">∅</span>}
    </button>
  );
}

// StatusBeacon component for health indicator
function StatusBeacon({ status }: { status: 'healthy' | 'degraded' | 'down' }) {
  const color = status === 'healthy' ? 'var(--green)' : status === 'degraded' ? 'var(--yellow)' : 'var(--red)';

  return (
    <div className="relative w-2 h-2 shrink-0">
      <div
        className="absolute inset-0 rounded-full animate-ping opacity-75"
        style={{ backgroundColor: color }}
      />
      <div
        className="absolute inset-0 rounded-full"
        style={{ backgroundColor: color }}
      />
    </div>
  );
}


interface DrawingToolbarProps {
  // Chart props
  chartType: ChartType;
  timeframe: number;
  activeIndicators: IndicatorKey[];
  onChangeType: (t: ChartType) => void;
  onChangeTimeframe: (s: number) => void;
  onChangeIndicators: (keys: IndicatorKey[]) => void;
  standalone?: boolean;
  onOpenWindow?: () => void;
  exportRows: ExportRow[];
  chartRef: React.MutableRefObject<IChartApi | null>;
  pairLabel: string;
  base: string;
  quote: string;
  onChangePair?: (base: string, quote: string) => void;
  onInvertPair?: () => void;
  // Drawing props
  activeTool: DrawingToolType | null;
  onToolChange: (tool: DrawingToolType | null) => void;
  onSelectAll: () => void;
  onDelete: () => void;
  onStyleChange: (style: Partial<DrawingStyle>) => void;
  hasSelection: boolean;
  selectedDrawing: Drawing | null;
  selectedCount: number;
  // Area select mode
  isAreaSelectMode: boolean;
  onAreaSelectModeChange: (active: boolean) => void;
  // Price scale
  priceScaleMode?: PriceScaleMode;
  onScaleChange?: (mode: PriceScaleMode) => void;
}

export function DrawingToolbar({
  chartType,
  timeframe,
  activeIndicators,
  onChangeType,
  onChangeTimeframe,
  onChangeIndicators,
  standalone,
  onOpenWindow,
  exportRows,
  chartRef,
  pairLabel,
  base,
  quote,
  onChangePair,
  onInvertPair,
  activeTool,
  onToolChange,
  onSelectAll,
  onDelete,
  onStyleChange,
  hasSelection,
  selectedDrawing,
  selectedCount,
  isAreaSelectMode,
  onAreaSelectModeChange,
  priceScaleMode = 0,
  onScaleChange,
}: DrawingToolbarProps) {
  const { theme, toggleTheme } = useTheme();
  const health = useHealthMonitor();
  const [isPairSelectorOpen, setIsPairSelectorOpen] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);

  // Validate indicator selection - max 3 sub-pane indicators
  const handleIndicatorChange = (newIndicators: IndicatorKey[]) => {
    const newSubPanes = newIndicators.filter(k => SUB_PANE_KEYS.includes(k));
    const currentSubPanes = activeIndicators.filter(k => SUB_PANE_KEYS.includes(k));

    if (newSubPanes.length > MAX_SUB_PANES) {
      addNotification('warning', `Maximum ${MAX_SUB_PANES} indicator panes allowed`);
      const limitedIndicators = newIndicators.filter(k => {
        if (!SUB_PANE_KEYS.includes(k)) return true;
        return currentSubPanes.includes(k);
      });
      onChangeIndicators(limitedIndicators);
      return;
    }
    onChangeIndicators(newIndicators);
  };

  const handleSelectModeChange = (mode: SelectMode) => {
    if (mode === 'all') {
      onSelectAll();
      onAreaSelectModeChange(false);
    } else if (mode === 'area') {
      onToolChange(null);
      onAreaSelectModeChange(true);
    } else {
      onToolChange(null);
      onAreaSelectModeChange(false);
    }
  };

  // Active states for toolbar highlighting
  const isSelectActive = activeTool === null;
  const isDrawActive = DRAW_ITEMS.some(t => t.value === activeTool);
  const isLineActive = LINE_ITEMS.some(t => t.value === activeTool);
  const isShapeActive = SHAPE_ITEMS.some(t => t.value === activeTool);
  const canHaveFill = selectedDrawing && ['rectangle', 'circle', 'triangle', 'channel'].includes(selectedDrawing.type);

  const selectedTimeframe = TIMEFRAME_OPTIONS.find(t => t.value === timeframe)!;
  const ChartIcon = CHART_ICONS[chartType];
  const filename = `${pairLabel.replace('/', '-')}-${timeframe}s`;

  // Current select mode for dropdown value
  const currentSelectMode: SelectMode = isAreaSelectMode ? 'area' : 'single';

  // Reusable toolbar trigger style
  const toolbarTrigger = (icon: React.ReactNode, isActive: boolean, tooltip: string) => (
    <Tooltip content={tooltip} side="bottom">
      <div className={`h-8 px-2 flex items-center cursor-pointer transition-colors border-r border-border ${
        isActive ? 'bg-bg-primary text-primary' : 'text-fg-2 hover:text-fg-1 hover:bg-bg-2'
      }`}>
        {icon}
      </div>
    </Tooltip>
  );

  return (
    <>
      <div className="flex items-center bg-bg-1 border-b border-border">
        {/* Ticker Selector */}
        {onChangePair && (
          <Tooltip content="Select pair" side="bottom">
            <button
              onClick={() => setIsPairSelectorOpen(true)}
              className="h-8 px-2 flex items-center gap-1.5 text-xs font-medium text-fg-1 hover:bg-bg-2 transition-colors border-r border-border"
            >
              <img src={getTokenIcon(base)} alt={base} className="w-5 h-5 rounded-full z-10 -mr-3" />
              <img src={getTokenIcon(quote)} alt={quote} className="w-5 h-5 rounded-full" />
              <span>{pairLabel}</span>
              <Tooltip
                content={`${health.api.latency !== null ? `${health.api.latency}ms` : '—'} feed latency`}
                side="bottom"
              >
                <div className="inline-flex">
                  <StatusBeacon status={health.api.status} />
                </div>
              </Tooltip>
            </button>
          </Tooltip>
        )}

        {/* Invert Pair Button */}
        {onInvertPair && (
          <Tooltip content="Invert pair" side="bottom">
            <button
              onClick={onInvertPair}
              className="h-8 px-2 flex items-center text-fg-2 hover:text-fg-1 hover:bg-bg-2 transition-colors border-r border-border"
            >
              <ArrowLeftRight className="w-4 h-4" />
            </button>
          </Tooltip>
        )}

        {/* Chart Type */}
        <Dropdown
          items={CHART_TYPE_OPTIONS.map(opt => ({
            value: opt.value,
            label: opt.label,
            icon: CHART_ICONS[opt.value],
          }))}
          value={chartType}
          onChange={(v) => onChangeType(v as ChartType)}
          size="sm"
          side="bottom"
          trigger={
            <Tooltip content="Chart type" side="bottom">
              <div className="h-8 px-2 flex items-center text-fg-2 hover:text-fg-1 hover:bg-bg-2 cursor-pointer transition-colors border-r border-border">
                <ChartIcon className="w-4 h-4" />
              </div>
            </Tooltip>
          }
        />

        {/* Timeframe */}
        <Dropdown
          items={TIMEFRAME_OPTIONS.map(opt => ({
            value: opt.value,
            label: opt.label,
          }))}
          value={timeframe}
          onChange={(v) => onChangeTimeframe(v as number)}
          size="sm"
          side="bottom"
          trigger={
            <Tooltip content="Timeframe" side="bottom">
              <div className="h-8 px-2 flex items-center text-xs text-fg-2 hover:text-fg-1 hover:bg-bg-2 cursor-pointer transition-colors border-r border-border">
                {selectedTimeframe.label}
              </div>
            </Tooltip>
          }
        />

        {/* Price Scale */}
        {onScaleChange && (
          <Dropdown
            items={PRICE_SCALE_OPTIONS.map(opt => ({
              value: opt.value,
              label: opt.label,
            }))}
            value={priceScaleMode}
            onChange={(v) => onScaleChange(v as PriceScaleMode)}
            size="sm"
            side="bottom"
            trigger={
              <Tooltip content="Price scale" side="bottom">
                <div className="h-8 px-2 flex items-center text-xs text-fg-2 hover:text-fg-1 hover:bg-bg-2 cursor-pointer transition-colors border-r border-border">
                  {PRICE_SCALE_OPTIONS.find(o => o.value === priceScaleMode)?.label || 'Linear'}
                </div>
              </Tooltip>
            }
          />
        )}

        {/* Indicators */}
        <Dropdown
          items={ANALYSIS_PRESETS.filter(p => p.id !== 'none').map(preset => ({
            value: preset.id,
            label: preset.name,
          }))}
          value={activeIndicators}
          onChange={(v) => handleIndicatorChange(v as IndicatorKey[])}
          mode="multi"
          size="sm"
          side="bottom"
          minWidth={160}
          footer={activeIndicators.length > 0 ? (
            <button
              onClick={() => onChangeIndicators([])}
              className="block w-full px-2 py-1.5 text-left text-xs whitespace-nowrap text-red hover:bg-bg-2"
            >
              Clear all
            </button>
          ) : undefined}
          trigger={
            <Tooltip content="Presets" side="bottom">
              <div className={`h-8 px-2 flex items-center gap-1.5 text-xs hover:bg-bg-2 cursor-pointer transition-colors border-r border-border ${
                activeIndicators.length > 0 ? 'text-primary' : 'text-fg-2 hover:text-fg-1'
              }`}>
                <FunctionSquare className="w-4 h-4" />
                <span>Presets{activeIndicators.length > 0 ? ` (${activeIndicators.length})` : ''}</span>
              </div>
            </Tooltip>
          }
        />

        {/* Select Dropdown */}
        <Dropdown
          items={SELECT_ITEMS}
          value={currentSelectMode}
          onChange={(v) => handleSelectModeChange(v as SelectMode)}
          size="sm"
          side="bottom"
          trigger={toolbarTrigger(<MousePointer2 className="w-4 h-4" />, isSelectActive, 'Selection mode')}
        />

        {/* Draw Dropdown */}
        <Dropdown
          items={DRAW_ITEMS}
          value={activeTool ?? ''}
          onChange={(v) => onToolChange(v as DrawingToolType)}
          size="sm"
          side="bottom"
          trigger={toolbarTrigger(<Pencil className="w-4 h-4" />, isDrawActive, 'Draw tools')}
        />

        {/* Lines Dropdown */}
        <Dropdown
          items={LINE_ITEMS}
          value={activeTool ?? ''}
          onChange={(v) => onToolChange(v as DrawingToolType)}
          size="sm"
          side="bottom"
          trigger={toolbarTrigger(
            <MaskIcon src="/icons/trend-line.svg" size="sm" color={isLineActive ? 'var(--primary)' : 'var(--fg-2)'} />,
            isLineActive,
            'Line tools'
          )}
        />

        {/* Shapes Dropdown */}
        <Dropdown
          items={SHAPE_ITEMS}
          value={activeTool ?? ''}
          onChange={(v) => onToolChange(v as DrawingToolType)}
          size="sm"
          side="bottom"
          trigger={toolbarTrigger(
            <MaskIcon src="/icons/rectangle.svg" size="sm" color={isShapeActive ? 'var(--primary)' : 'var(--fg-2)'} />,
            isShapeActive,
            'Shape tools'
          )}
        />

        {/* Color Palette - Only when single drawing selected */}
        {hasSelection && selectedDrawing && (
          <ColorPalette
            open={paletteOpen}
            onOpenChange={setPaletteOpen}
            selectedDrawing={selectedDrawing}
            onStyleChange={onStyleChange}
            canHaveFill={!!canHaveFill}
          />
        )}

        {/* Delete Button - Shows for any selection (single or multiple) */}
        {hasSelection && (
          <Tooltip content={`Delete${selectedCount > 1 ? ` (${selectedCount})` : ''} (Del)`} side="bottom">
            <button
              onClick={onDelete}
              className="h-8 px-2 flex items-center text-fg-2 hover:text-red hover:bg-bg-2 transition-colors border-r border-border"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          </Tooltip>
        )}

        {/* Spacer - pushes Export/Window buttons to the right */}
        <div className="flex-1" />

        {/* Export */}
        <Dropdown
          items={[
            { value: 'csv', label: 'CSV', icon: FileText },
            { value: 'json', label: 'JSON', icon: Braces },
            { value: 'png', label: 'PNG', icon: Image },
          ]}
          value=""
          onChange={(format) => {
            if (format === 'csv') exportCsv(exportRows, `${filename}.csv`);
            else if (format === 'json') exportJson(exportRows, `${filename}.json`);
            else if (format === 'png') exportPng(chartRef, `${filename}.png`);
          }}
          size="sm"
          side="bottom"
          trigger={
            <Tooltip content="Export" side="bottom">
              <div className="h-8 px-2 flex items-center text-fg-2 hover:text-fg-1 hover:bg-bg-2 cursor-pointer transition-colors border-r border-border">
                <Download className="w-4 h-4" />
              </div>
            </Tooltip>
          }
        />

        {/* Open in Window - only when not standalone */}
        {!standalone && onOpenWindow && (
          <Tooltip content="Open in window" side="bottom">
            <button
              onClick={onOpenWindow}
              className="h-8 px-2 flex items-center text-fg-2 hover:text-fg-1 hover:bg-bg-2 transition-colors"
            >
              <Maximize2 className="w-4 h-4" />
            </button>
          </Tooltip>
        )}

        {/* Theme toggle - only on standalone chart pages */}
        {standalone && (
          <Tooltip content={theme === 'dark' ? 'Light mode' : 'Dark mode'} side="bottom">
            <button
              onClick={toggleTheme}
              className="h-8 px-2 flex items-center text-fg-2 hover:text-fg-1 hover:bg-bg-2 transition-colors"
            >
              {theme === 'dark' ? <Sun className="w-4 h-4" /> : <Moon className="w-4 h-4" />}
            </button>
          </Tooltip>
        )}
      </div>

      {/* Pair Selector Modal */}
      {onChangePair && (
        <PairSelector
          isOpen={isPairSelectorOpen}
          onClose={() => setIsPairSelectorOpen(false)}
          onSelect={(newBase, newQuote) => {
            onChangePair(newBase, newQuote);
            setIsPairSelectorOpen(false);
          }}
          currentBase={base}
          currentQuote={quote}
        />
      )}
    </>
  );
}
