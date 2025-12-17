/**
 * Chart export utilities - CSV, JSON, PNG
 */
import type { IChartApi } from 'lightweight-charts';
import type { OHLC } from '@/hooks/usePriceFeed';
import type { IndicatorParams } from '@utils/indicators';
import { type IndicatorKey, INDICATORS } from './indicatorsConfig';
import { addNotification } from '@lib/notifications';

export interface ExportRow {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  [key: string]: number;
}

/**
 * Build export rows with OHLC + indicator values
 */
export function buildExportRows(
  candles: OHLC[],
  activeKeys: IndicatorKey[],
  getParams: (k: IndicatorKey) => IndicatorParams
): ExportRow[] {
  if (candles.length === 0) return [];

  // Pre-calculate all indicator data once
  const indicatorData = new Map<IndicatorKey, any[]>();
  activeKeys.forEach(key => {
    const def = INDICATORS[key];
    if (def) {
      indicatorData.set(key, def.calc(candles, getParams(key)));
    }
  });

  return candles.map((candle, idx) => {
    const row: ExportRow = {
      time: candle.time,
      open: candle.open,
      high: candle.high,
      low: candle.low,
      close: candle.close,
    };

    activeKeys.forEach(key => {
      const def = INDICATORS[key];
      const data = indicatorData.get(key);
      if (def && data?.[idx]) {
        const d = data[idx];
        row[def.series1Field] = d[def.series1Field];
        if (def.series2Field && !def.isDivergence) {
          row[def.series2Field] = d[def.series2Field];
        }
      }
    });

    return row;
  });
}

/**
 * Export as CSV
 */
export function exportCsv(
  rows: ExportRow[],
  filename: string,
  copyOnly = false
): void {
  if (!rows.length) return;

  const headers = Object.keys(rows[0]);
  const body = rows.map(r => headers.map(h => r[h] ?? '').join(',')).join('\n');
  const csv = `${headers.join(',')}\n${body}`;

  if (copyOnly) {
    navigator.clipboard.writeText(csv);
    addNotification('success', 'Chart data copied to clipboard');
    return;
  }

  downloadBlob(new Blob([csv], { type: 'text/csv' }), filename);
  addNotification('success', 'Chart data downloaded as CSV');
}

/**
 * Export as JSON
 */
export function exportJson(
  rows: ExportRow[],
  filename: string,
  copyOnly = false
): void {
  if (!rows.length) return;

  const json = JSON.stringify(rows, null, 2);

  if (copyOnly) {
    navigator.clipboard.writeText(json);
    addNotification('success', 'Chart data copied to clipboard');
    return;
  }

  downloadBlob(new Blob([json], { type: 'application/json' }), filename);
  addNotification('success', 'Chart data downloaded as JSON');
}

/**
 * Export chart as PNG
 */
export function exportPng(
  chartRef: React.MutableRefObject<IChartApi | null>,
  filename: string,
  copyOnly = false
): void {
  if (!chartRef.current) return;

  const canvas = (chartRef.current as any).takeScreenshot?.();
  if (!canvas) return;

  canvas.toBlob((blob: Blob | null) => {
    if (!blob) return;

    if (copyOnly) {
      navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
      addNotification('success', 'Chart image copied to clipboard');
      return;
    }

    downloadBlob(blob, filename);
    addNotification('success', 'Chart image downloaded');
  });
}

function downloadBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
