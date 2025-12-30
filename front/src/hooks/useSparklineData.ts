import { useState, useEffect } from 'preact/hooks';
import { usePriceStream, type OHLC } from './usePriceFeed';

const API_URL = import.meta.env.VITE_COLLECTOR_URL || 'http://localhost:3001';
const SPARKLINE_TIMEFRAME = 1800; // 30 minutes in seconds
const SPARKLINE_LIMIT = 48; // 48 * 30min = 24 hours

interface SparklineData {
    prices: number[];
    lastPrice: number | null;
    loading: boolean;
    error: string | null;
}

/**
 * Fetches 24h of 30min candles for sparkline display and subscribes to live price updates
 * @param feedSymbol - The symbol to fetch (e.g., 'ETHUSDC', 'BTCUSDC')
 * @returns Sparkline data with prices array and current price
 */
export function useSparklineData(feedSymbol: string | null): SparklineData {
    const [prices, setPrices] = useState<number[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    // Subscribe to live price updates
    const priceData = usePriceStream(feedSymbol ? `agg:spot:${feedSymbol}` : '');
    const lastPrice = priceData?.mid ?? null;

    // Fetch historical 30min candles
    useEffect(() => {
        if (!feedSymbol) {
            // Stablecoin - use flat line at $1
            setPrices(Array(SPARKLINE_LIMIT).fill(1));
            setLoading(false);
            return;
        }

        let active = true;
        setLoading(true);
        setError(null);

        fetch(`${API_URL}/api/candles?symbol=${feedSymbol}&timeframe=${SPARKLINE_TIMEFRAME}&limit=${SPARKLINE_LIMIT}`)
            .then(r => {
                if (!r.ok) throw new Error(`HTTP ${r.status}`);
                const contentType = r.headers.get('content-type');
                if (!contentType || !contentType.includes('application/json')) {
                    throw new Error('Server returned non-JSON response (backend may not be running)');
                }
                return r.json();
            })
            .then(data => {
                if (!active) return;
                // API returns DESC (newest first), reverse to chronological order (oldest first)
                // Extract close prices for sparkline
                const candles: OHLC[] = (data.candles || []).reverse();
                const closePrices = candles.map(c => c.close);
                setPrices(closePrices);
                setLoading(false);
            })
            .catch(e => {
                if (!active) return;
                // Silently use empty array for sparklines when backend is unavailable
                setPrices([]);
                setLoading(false);
                // Only log once to avoid console spam
                if (error === null) {
                    console.warn(`[useSparklineData] ${feedSymbol}: Backend unavailable`);
                }
            });

        return () => { active = false; };
    }, [feedSymbol]);

    // Update the last price in the sparkline when we get live updates
    useEffect(() => {
        if (lastPrice !== null && prices.length > 0) {
            setPrices(prev => {
                if (prev.length === 0) return prev;
                // Replace last price with current live price
                const updated = [...prev];
                updated[updated.length - 1] = lastPrice;
                return updated;
            });
        }
    }, [lastPrice]);

    return {
        prices,
        lastPrice,
        loading,
        error,
    };
}

/**
 * Hook for getting live price data for an asset
 * Handles stablecoins by returning fixed $1 price
 */
export function useLivePrice(feedSymbol: string | null): { price: number | null; loading: boolean } {
    const priceData = usePriceStream(feedSymbol ? `agg:spot:${feedSymbol}` : '');

    // Stablecoin - return $1
    if (!feedSymbol) {
        return { price: 1.0, loading: false };
    }

    return {
        price: priceData?.mid ?? null,
        loading: priceData === null,
    };
}
