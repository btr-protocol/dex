/**
 * OHLC Storage - M1 candles only, higher timeframes reconstructed on-demand
 */

import { Database } from 'bun:sqlite';
import { mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { PairSymbol, OHLCCandle } from './types';
import { STORAGE_CONFIG } from './config';
import ccxt from 'ccxt';

type SourceMap = Record<string, { weight: number }>;

const log = (msg: string) => console.log(`[${new Date().toISOString().slice(11, 23)}] ${msg}`);
const warn = (msg: string) => console.warn(`[${new Date().toISOString().slice(11, 23)}] ${msg}`);

// ─────────────────────────────────────────────────────────────
// Rate Limiter
// ─────────────────────────────────────────────────────────────

class RateLimiter {
  private queues = new Map<string, Array<() => Promise<void>>>();
  private lastTime = new Map<string, number>();
  private processing = new Set<string>();

  async request<T>(id: string, fn: () => Promise<T>, delayMs = 200): Promise<T> {
    return new Promise((resolve, reject) => {
      const queue = this.queues.get(id) ?? [];
      this.queues.set(id, queue);

      queue.push(async () => {
        const wait = Math.max(0, delayMs - (Date.now() - (this.lastTime.get(id) ?? 0)));
        if (wait > 0) await new Promise(r => setTimeout(r, wait));
        this.lastTime.set(id, Date.now());
        try { resolve(await fn()); } catch (e) { reject(e); }
      });

      this.process(id);
    });
  }

  private async process(id: string) {
    if (this.processing.has(id)) return;
    this.processing.add(id);
    const queue = this.queues.get(id);
    while (queue?.length) await queue.shift()?.();
    this.processing.delete(id);
  }
}

const rateLimiter = new RateLimiter();

// ─────────────────────────────────────────────────────────────
// Storage
// ─────────────────────────────────────────────────────────────

export class OHLCStorage {
  private db: Database | null = null;
  private exchanges = new Map<string, any>();

  constructor(private dbPath = STORAGE_CONFIG.dbPath) {}

  async initialize(): Promise<void> {
    await mkdir(dirname(this.dbPath), { recursive: true });

    this.db = new Database(this.dbPath);
    this.db.run('PRAGMA journal_mode=WAL');
    this.db.run('PRAGMA busy_timeout=5000');

    // Only M1 table - all others reconstructed on-demand
    this.db.run(`
      CREATE TABLE IF NOT EXISTS candles_1m (
        pair TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        open REAL NOT NULL,
        high REAL NOT NULL,
        low REAL NOT NULL,
        close REAL NOT NULL,
        volume REAL NOT NULL,
        PRIMARY KEY (pair, timestamp)
      )
    `);
    this.db.run('CREATE INDEX IF NOT EXISTS idx_candles_1m ON candles_1m(pair, timestamp)');
    log('Storage initialized (M1 only)');
  }

  // ─────────────────────────────────────────────────────────────
  // Save
  // ─────────────────────────────────────────────────────────────

  saveCandle(pair: string, candle: OHLCCandle): void {
    if (!this.db) throw new Error('DB not initialized');
    this.db.prepare(
      'INSERT OR REPLACE INTO candles_1m (pair, timestamp, open, high, low, close, volume) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run(pair, candle.timestamp, candle.open, candle.high, candle.low, candle.close, candle.volume);
  }

  saveCandles(pair: string, candles: OHLCCandle[]): void {
    if (!this.db || !candles.length) return;
    const stmt = this.db.prepare(
      'INSERT OR REPLACE INTO candles_1m (pair, timestamp, open, high, low, close, volume) VALUES (?, ?, ?, ?, ?, ?, ?)'
    );
    this.db.transaction(() => {
      for (const c of candles) stmt.run(pair, c.timestamp, c.open, c.high, c.low, c.close, c.volume);
    })();
  }

  // ─────────────────────────────────────────────────────────────
  // Read
  // ─────────────────────────────────────────────────────────────

  getM1Candles(pair: string, startTime?: number, endTime?: number, limit?: number): OHLCCandle[] {
    if (!this.db) throw new Error('DB not initialized');

    let query = 'SELECT * FROM candles_1m WHERE pair = ?';
    const params: any[] = [pair];

    if (startTime) { query += ' AND timestamp >= ?'; params.push(startTime); }
    if (endTime) { query += ' AND timestamp <= ?'; params.push(endTime); }
    query += ' ORDER BY timestamp DESC';
    if (limit) { query += ' LIMIT ?'; params.push(limit); }

    return (this.db.prepare(query).all(...params) as any[]).map(r => ({
      timestamp: r.timestamp, open: r.open, high: r.high, low: r.low, close: r.close, volume: r.volume
    }));
  }

  /**
   * Get candles for any timeframe - reconstructs from M1
   * Returns DESC order (newest first)
   */
  getCandles(pair: string, timeframeSec: number, limit = 200): OHLCCandle[] {
    if (timeframeSec === 60) return this.getM1Candles(pair, undefined, undefined, limit);

    // Fetch enough M1 candles to build the requested higher TF candles
    const multiplier = timeframeSec / 60;
    const m1Candles = this.getM1Candles(pair, undefined, undefined, Math.ceil(limit * multiplier * 1.1));
    if (!m1Candles.length) return [];

    // M1 is DESC, reverse to ASC for aggregation
    m1Candles.reverse();

    const tfMs = timeframeSec * 1000;
    const result: OHLCCandle[] = [];

    for (let i = 0; i < m1Candles.length;) {
      const bucket = Math.floor(m1Candles[i].timestamp / tfMs) * tfMs;
      let { open, high, low, close, volume } = m1Candles[i++];

      while (i < m1Candles.length && m1Candles[i].timestamp < bucket + tfMs) {
        high = Math.max(high, m1Candles[i].high);
        low = Math.min(low, m1Candles[i].low);
        close = m1Candles[i].close;
        volume += m1Candles[i].volume;
        i++;
      }

      result.push({ timestamp: bucket, open, high, low, close, volume });
    }

    // Back to DESC, apply limit
    result.reverse();
    return result.slice(0, limit);
  }

  // ─────────────────────────────────────────────────────────────
  // Gap Detection & Filling
  // ─────────────────────────────────────────────────────────────

  private findGaps(candles: OHLCCandle[], targetStart: number, now: number): Array<{ start: number; end: number }> {
    const tfMs = 60_000; // M1
    const gaps: Array<{ start: number; end: number }> = [];

    if (!candles.length) {
      gaps.push({ start: targetStart, end: now });
      return gaps;
    }

    const newest = candles[0].timestamp;
    const oldest = candles[candles.length - 1].timestamp;

    // Gap at start (need at least 2 minutes to be worth filling)
    if (oldest > targetStart + tfMs * 2) gaps.push({ start: targetStart, end: oldest - tfMs });

    // Gap at end (allow 2 candles for in-progress)
    if (now - newest > tfMs * 3) gaps.push({ start: newest + tfMs, end: now });

    // Internal gaps (candles are DESC) - need at least 2 missing candles
    for (let i = 0; i < candles.length - 1; i++) {
      const gap = candles[i].timestamp - candles[i + 1].timestamp;
      if (gap > tfMs * 2) {
        gaps.push({ start: candles[i + 1].timestamp + tfMs, end: candles[i].timestamp - tfMs });
      }
    }

    // Filter out tiny gaps (< 2 min) and merge overlapping
    const valid = gaps.filter(g => g.end - g.start >= tfMs);
    if (valid.length < 2) return valid;

    valid.sort((a, b) => a.start - b.start);
    const merged: typeof valid = [valid[0]];
    for (let i = 1; i < valid.length; i++) {
      const last = merged[merged.length - 1];
      if (valid[i].start <= last.end + tfMs) last.end = Math.max(last.end, valid[i].end);
      else merged.push(valid[i]);
    }
    return merged.sort((a, b) => b.start - a.start); // Recent first
  }

  async fillHistoricalData(pair: string, sources: SourceMap): Promise<void> {
    const now = Date.now();
    const targetStart = now - STORAGE_CONFIG.historicalDataDays * 86_400_000;
    const existing = this.getM1Candles(pair, targetStart, now);
    const gaps = this.findGaps(existing, targetStart, now);

    if (!gaps.length) {
      log(`${pair}: Complete (${existing.length} M1 candles)`);
      return;
    }

    const totalHours = gaps.reduce((s, g) => s + (g.end - g.start), 0) / 3_600_000;
    log(`${pair}: ${existing.length} candles, ${gaps.length} gap(s) (~${totalHours.toFixed(1)}h to fill)`);

    for (const gap of gaps) {
      const gapStart = new Date(gap.start).toISOString().slice(11, 16);
      const gapEnd = new Date(gap.end).toISOString().slice(11, 16);
      const gapMins = Math.round((gap.end - gap.start) / 60_000);
      log(`  ${pair}: Gap ${gapStart}-${gapEnd} (${gapMins}m)`);

      const candles = await this.fetchFromSources(pair, sources, gap.start, gap.end);
      if (candles.length) {
        this.saveCandles(pair, candles);
        log(`  ${pair}: +${candles.length} candles filled`);
      } else {
        warn(`  ${pair}: No candles fetched for gap!`);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Exchange Fetching
  // ─────────────────────────────────────────────────────────────

  private async fetchFromSources(pair: string, sources: SourceMap, start: number, end: number): Promise<OHLCCandle[]> {
    const perSource: Record<string, OHLCCandle[]> = {};

    await Promise.all(Object.entries(sources).map(async ([key, { weight }]) => {
      if (weight <= 0) return;
      const [exchangeId, , rawPair] = key.split(':');
      try {
        const exchange = await this.getExchange(exchangeId);
        const symbol = this.toSymbol(rawPair);
        const candles = await this.fetchOHLCV(exchange, symbol, start, end);
        if (candles.length) perSource[key] = candles;
      } catch (e: any) {
        if (!e.message?.includes('previously failed')) warn(`  ${pair}/${exchangeId}: ${e.message?.slice(0, 60)}`);
      }
    }));

    return this.aggregateSources(perSource, sources);
  }

  private aggregateSources(perSource: Record<string, OHLCCandle[]>, sources: SourceMap): OHLCCandle[] {
    if (!Object.keys(perSource).length) return [];

    // Collect all timestamps
    const timestamps = new Set<number>();
    for (const candles of Object.values(perSource)) {
      for (const c of candles) timestamps.add(c.timestamp);
    }

    // Index for O(1) lookup
    const indexed = new Map<string, Map<number, OHLCCandle>>();
    for (const [key, candles] of Object.entries(perSource)) {
      indexed.set(key, new Map(candles.map(c => [c.timestamp, c])));
    }

    // Weighted aggregation
    const result: OHLCCandle[] = [];
    for (const ts of [...timestamps].sort((a, b) => a - b)) {
      let sumW = 0, o = 0, c = 0, v = 0, h = -Infinity, l = Infinity;

      for (const [key, { weight }] of Object.entries(sources)) {
        const candle = indexed.get(key)?.get(ts);
        if (!candle) continue;
        sumW += weight;
        o += candle.open * weight;
        c += candle.close * weight;
        v += candle.volume * weight;
        h = Math.max(h, candle.high);
        l = Math.min(l, candle.low);
      }

      if (sumW > 0) {
        result.push({ timestamp: ts, open: o / sumW, high: h, low: l, close: c / sumW, volume: v / sumW });
      }
    }

    return result;
  }

  private async fetchOHLCV(exchange: any, symbol: string, start: number, end: number): Promise<OHLCCandle[]> {
    const all: any[] = [];
    let cursor = start;

    while (cursor < end) {
      const data = await rateLimiter.request(exchange.id, () =>
        exchange.fetchOHLCV(symbol, '1m', cursor, 1000)
      ) as any[];
      if (!data || !data.length) break;
      all.push(...data);
      const lastTs = data[data.length - 1][0];
      cursor = lastTs + 60_000;
      // Only stop if: we got very few candles AND the last candle is recent (near end)
      // This handles both "reached end of data" and "exchange returned partial batch"
      if (data.length < 50 && lastTs >= end - 300_000) break;
    }

    // Dedupe & convert
    const seen = new Set<number>();
    return all
      .filter(d => !seen.has(d[0]) && seen.add(d[0]) && d[0] >= start && d[0] <= end)
      .sort((a, b) => a[0] - b[0])
      .map(([timestamp, open, high, low, close, volume]) =>
        ({ timestamp, open, high, low, close, volume: volume || 0 })
      );
  }

  private async getExchange(id: string): Promise<any> {
    const cached = this.exchanges.get(id);
    if (cached === null) throw new Error('Exchange previously failed');
    if (cached) return cached;

    const Ctor = (ccxt as any)[id];
    if (!Ctor) throw new Error(`Unknown exchange: ${id}`);

    const exchange = new Ctor({ enableRateLimit: true, timeout: 15000 });
    try {
      await Promise.race([
        exchange.loadMarkets(),
        new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 8000))
      ]);
      this.exchanges.set(id, exchange);
      return exchange;
    } catch {
      this.exchanges.set(id, null);
      throw new Error('Exchange unavailable');
    }
  }

  private toSymbol(pair: string): string {
    if (pair.includes('/')) return pair;
    if (pair.includes('-')) return pair.replace('-', '/');
    if (pair.includes('_')) return pair.replace('_', '/');
    const m = pair.match(/^(.+?)(USDT|USDC|USDE|BTC|ETH)$/);
    return m ? `${m[1]}/${m[2]}` : pair;
  }

  // ─────────────────────────────────────────────────────────────
  // Static helpers
  // ─────────────────────────────────────────────────────────────

  static async fillAll(
    pairs: Array<{ pair: string; sources: SourceMap }>,
    storage: OHLCStorage
  ): Promise<void> {
    // Init exchanges first
    const exchangeIds = new Set<string>();
    for (const { sources } of pairs) {
      for (const key of Object.keys(sources)) exchangeIds.add(key.split(':')[0]);
    }

    log(`Initializing ${exchangeIds.size} exchanges...`);
    for (const id of exchangeIds) {
      try { await storage.getExchange(id); log(`  ✓ ${id}`); }
      catch { log(`  ✗ ${id}`); }
    }

    log(`\nFilling M1 history for ${pairs.length} pairs...`);
    const t0 = Date.now();
    await Promise.all(pairs.map(({ pair, sources }) => storage.fillHistoricalData(pair, sources)));
    log(`✓ Done (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
  }

  async close(): Promise<void> {
    for (const [, ex] of this.exchanges) { try { await ex?.close(); } catch {} }
    this.db?.close();
  }
}

let instance: OHLCStorage | null = null;
export const getStorage = () => instance ??= new OHLCStorage();
