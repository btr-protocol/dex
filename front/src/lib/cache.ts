/**
 * Minimal IndexedDB Cache Wrapper
 */

import { logger } from '@sdk/utils';

const log = logger.withContext('cache');

const DB_NAME = 'btr-cache';
const VER = 1;

// TTL Config (ms)
const TTLS: Record<string, number> = {
  docs: 864e5,   // 24h
  search: 864e5, // 24h
  assets: 6048e5,// 7d
  api: 3e5       // 5m
};

interface Entry<T = any> { k: string; v: T; e: number }

let _db: Promise<IDBDatabase>;

const req = <T>(r: IDBRequest): Promise<T> => new Promise((res, rej) => {
  r.onsuccess = () => res(r.result);
  r.onerror = () => rej(r.error);
});

const getDB = () => {
  if (!_db) {
    _db = new Promise((res, rej) => {
      const r = indexedDB.open(DB_NAME, VER);
      r.onerror = () => rej(r.error);
      r.onsuccess = () => res(r.result);
      r.onupgradeneeded = (e: any) => {
        const db = e.target.result;
        Object.keys(TTLS).forEach(s => !db.objectStoreNames.contains(s) && db.createObjectStore(s, { keyPath: 'k' }));
      };
    });
  }
  return _db;
};

const tx = async (store: string, mode: IDBTransactionMode) => {
  const db = await getDB();
  return db.transaction(store, mode).objectStore(store);
};

// ─────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────

export async function cacheGet<T>(store: string, key: string): Promise<T | null> {
  try {
    const s = await tx(store, 'readonly');
    const data = await req<Entry<T>>(s.get(key));

    if (!data) return null;
    if (Date.now() > data.e) {
      cacheDel(store, key).catch(() => {}); // Async cleanup
      return null;
    }
    return data.v;
  } catch { return null; }
}

export async function cacheSet<T>(store: string, key: string, val: T, ttl?: number) {
  try {
    const s = await tx(store, 'readwrite');
    await req(s.put({ k: key, v: val, e: Date.now() + (ttl || TTLS[store] || 0) }));
  } catch (e) { log.error('cacheSet failed', e); }
}

export async function cacheDel(store: string, key: string) {
  try { await req((await tx(store, 'readwrite')).delete(key)); } catch {}
}

export async function cacheClear(store: string) {
  try { await req((await tx(store, 'readwrite')).clear()); } catch {}
}

export async function cacheGetOrFetch<T>(store: string, key: string, fetcher: () => Promise<T>, ttl?: number): Promise<T> {
  const cached = await cacheGet<T>(store, key);
  if (cached !== null) return cached;
  const val = await fetcher();
  await cacheSet(store, key, val, ttl);
  return val;
}

// ─────────────────────────────────────────────────────────────
// Maintenance
// ─────────────────────────────────────────────────────────────

export async function cachePrune() {
  try {
    const db = await getDB();
    const now = Date.now();
    Object.keys(TTLS).forEach(name => {
      const t = db.transaction(name, 'readwrite').objectStore(name);
      const r = t.openCursor();
      r.onsuccess = () => {
        const c = r.result;
        if (c) {
          if (c.value.e < now) c.delete();
          c.continue();
        }
      };
    });
  } catch {}
}

// Auto-prune
if (typeof window !== 'undefined') setTimeout(cachePrune, 5000);
