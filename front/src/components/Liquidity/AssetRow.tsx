import { useMemo } from 'preact/hooks';
import { Sparkline } from '@components/Sparkline';
import { CoverageGauge } from '@components/CoverageGauge';
import { Button } from '@components/ui/Button';
import { useSparklineData } from '@/hooks/useSparklineData';
import { AssetData, formatUsd, formatPercent } from '@/hooks/useLiquidityData';
import { liquidityStore } from '@/lib/liquidity/LiquidityStore';

function formatPrice(price: number): string {
    if (price >= 10000) return '$' + price.toLocaleString(undefined, { maximumFractionDigits: 0 });
    if (price >= 100) return '$' + price.toLocaleString(undefined, { maximumFractionDigits: 2 });
    if (price >= 1) return '$' + price.toFixed(2);
    return '$' + price.toFixed(4);
}

function calc24hPriceChange(prices: number[]): number {
    if (prices.length < 2) return 0;
    const oldPrice = prices[0];
    const newPrice = prices[prices.length - 1];
    if (oldPrice === 0) return 0;
    return ((newPrice - oldPrice) / oldPrice) * 100;
}

interface AssetRowProps {
    poolName: string;
    asset: AssetData;
    feedSymbol: string | null;
}

export function AssetRow({ poolName, asset, feedSymbol }: AssetRowProps) {
    const { prices, lastPrice, loading: sparklineLoading } = useSparklineData(feedSymbol);
    const assetId = `${poolName}-${asset.symbol}`;

    const priceChange = useMemo(() => calc24hPriceChange(prices), [prices]);
    const sparklineColor = priceChange >= 0 ? '#10b981' : '#ef4444';
    const displayPrice = feedSymbol === null ? 1.0 : (lastPrice ?? asset.price);

    const reservesUsd = asset.reserves * asset.price;
    const liabilitiesUsd = asset.liabilities * asset.price;
    const utilization = asset.reserves > 0 ? (asset.liabilities / asset.reserves) * 100 : 0;
    const coverage = asset.liabilities > 0 ? (asset.reserves / asset.liabilities) * 100 : 100;

    return (
        <div className="group">
            <div
                className="flex items-center gap-4 p-4 hover:bg-bg-2/50 transition-colors cursor-pointer"
                onClick={() => liquidityStore.toggleAsset(assetId)}
            >
                <div className="w-[180px] flex items-center gap-3 pl-2">
                    <div className="w-10 h-10 rounded-full bg-white">
                        <img
                            src={`/tokens/${asset.symbol.toLowerCase()}.svg`}
                            alt={asset.symbol}
                            className="w-full h-full"
                        />
                    </div>
                    <div>
                        <div className="font-bold text-foreground">{asset.symbol}</div>
                        <div className="text-xs text-muted-foreground">{asset.name}</div>
                    </div>
                </div>
                <div className="w-[120px] text-right">
                    <span className="font-numeric text-foreground">{formatUsd(asset.volume24h)}</span>
                </div>
                <div className="w-[180px] flex items-center gap-2">
                    {sparklineLoading ? (
                        <div className="w-[60px] h-[24px] bg-bg-2 animate-pulse rounded" />
                    ) : (
                        <Sparkline data={prices} width={60} height={24} color={sparklineColor} />
                    )}
                    <div className="flex-1 text-right">
                        <span className="text-sm font-numeric text-foreground">
                            {sparklineLoading ? '...' : formatPrice(displayPrice)}
                        </span>
                    </div>
                </div>
                <div className="w-[100px] text-right">
                    <span className="font-numeric text-foreground">{formatPercent(utilization)}</span>
                </div>
                <div className="w-[80px] text-right">
                    <span className="font-numeric text-green-500">{formatPercent(asset.apy)}</span>
                </div>
                <div className="w-[120px] flex items-center justify-center">
                    <CoverageGauge ratio={coverage / 100} />
                </div>
                <div className="flex-1 text-right">
                    <div className="font-numeric text-foreground">{formatUsd(reservesUsd)}</div>
                    <div className="text-xs font-numeric text-muted-foreground">{formatUsd(liabilitiesUsd)} debt</div>
                </div>
            </div>

            {liquidityStore.expandedAsset.value === assetId && (
                <div className="bg-bg-2/30 p-6 border-t border-border">
                    <div className="flex gap-6">
                        <div className="flex-1 bg-bg-1 rounded-md border border-border p-4 flex items-center justify-center min-h-[200px]">
                            <span className="text-muted-foreground">Liquidity Chart Placeholder</span>
                        </div>
                        <div className="w-72 space-y-3">
                            <div className="bg-bg-1 rounded-md border border-border p-4 space-y-2">
                                <div className="text-sm text-muted-foreground">Your Position</div>
                                <div className="text-2xl font-bold font-numeric text-foreground">$0.00</div>
                                <div className="flex gap-2 pt-2">
                                    <Button className="flex-1" size="sm">
                                        Deposit
                                    </Button>
                                    <Button variant="outlined" className="flex-1" size="sm">
                                        Withdraw
                                    </Button>
                                </div>
                            </div>
                            <div className="bg-bg-1 rounded-md border border-border p-4 space-y-2">
                                <div className="text-sm text-muted-foreground">Rewards</div>
                                <div className="text-xl font-bold font-numeric text-foreground">$0.00</div>
                                <Button
                                    variant="ghost"
                                    className="w-full text-primary hover:text-primary/80"
                                    size="sm"
                                >
                                    Claim
                                </Button>
                            </div>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
}
