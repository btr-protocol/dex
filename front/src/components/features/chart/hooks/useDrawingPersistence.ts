import { useEffect } from 'preact/hooks';
import type { DrawingToolsPrimitive } from '../DrawingTools';
import { logger } from '@sdk/utils';

const log = logger.withContext('drawingPersistence');

export function useDrawingPersistence(
  engine: DrawingToolsPrimitive | null,
  storageKey: string
) {
  // Load on mount
  useEffect(() => {
    if (!engine) return;
    try {
      const saved = localStorage.getItem(storageKey);
      if (saved) {
        const drawings = JSON.parse(saved);
        engine.loadDrawings(drawings);
      }
    } catch (e) {
      log.warn('Failed to load drawings', e);
    }
  }, [engine, storageKey]);

  // Save periodically and on storage changes
  useEffect(() => {
    if (!engine) return;

    const saveDrawings = () => {
      try {
        const drawings = engine.getDrawings();
        if (drawings.length === 0) {
          localStorage.removeItem(storageKey);
        } else {
          localStorage.setItem(storageKey, JSON.stringify(drawings));
        }
      } catch (e) {
        log.warn('Failed to save drawings', e);
      }
    };

    const handleStorageChange = (e: StorageEvent) => {
      if (e.key === storageKey && e.newValue) {
        try {
          const drawings = JSON.parse(e.newValue);
          engine.loadDrawings(drawings);
        } catch (err) {
          log.warn('Failed to sync drawings', err);
        }
      }
    };

    const interval = setInterval(saveDrawings, 1000);
    window.addEventListener('storage', handleStorageChange);

    return () => {
      clearInterval(interval);
      window.removeEventListener('storage', handleStorageChange);
      saveDrawings();
    };
  }, [engine, storageKey]);
}
