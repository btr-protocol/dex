import { useState, useMemo } from 'preact/hooks';
import { ChevronDown, Search } from 'lucide-react';
import { Button } from '@components/ui/Button';
import { Badge } from '@components/ui/Badge';
import { Input } from '@components/ui/Input';
import { Dropdown, DropdownItem } from '@components/ui/Dropdown';
import { Tooltip } from '@components/ui/Tooltip';
import { useRouter } from '@lib/router';
import PageContainer from '@components/layout/PageContainer';
import { Sparkline } from '@components/Sparkline';
import { CoverageGauge } from '@components/CoverageGauge';
import { useSparklineData } from '@/hooks/useSparklineData';
import { BorderedThemedIcon, plusIcon } from '@/components/ui/BorderedThemedIcon';
import { useLiquidityData, formatUsd, formatPercent, type AssetData } from '@/hooks/useLiquidityData';
import { ROUTES } from '@/constants/navigation';

// Format price for display
function formatPrice(price: number): string {
    if (price >= 10000) return '$' + price.toLocaleString(undefined, { maximumFractionDigits: 0 });
    if (price >= 100) return '$' + price.toLocaleString(undefined, { maximumFractionDigits: 2 });
    if (price >= 1) return '$' + price.toFixed(2);
    return '$' + price.toFixed(4);
}

// Calculate 24h price change from sparkline data
function calc24hPriceChange(prices: number[]): number {
    if (prices.length < 2) return 0;
    const oldPrice = prices[0];
    const newPrice = prices[prices.length - 1];
    if (oldPrice === 0) return 0;
    return ((newPrice - oldPrice) / oldPrice) * 100;
}

type Timeframe = '1h' | '4h' | '12h' | '24h' | '3d' | '7d' | '30d';

const TIMEFRAME_OPTIONS: DropdownItem<Timeframe>[] = [
    { value: '1h', label: '1H' },
    { value: '4h', label: '4H' },
    { value: '12h', label: '12H' },
    { value: '24h', label: '24H' },
    { value: '3d', label: '3D' },
    { value: '7d', label: '7D' },
    { value: '30d', label: '30D' },
];

// Hero metric component with tooltip
function HeroMetric({
    label,
    value,
    tooltip,
    emphasized = false,
    align = 'left'
}: {
    label: string;
    value: string;
    tooltip?: string;
    emphasized?: boolean;
    align?: 'left' | 'right';
}) {
    const alignClass = align === 'right' ? 'text-right' : 'text-left';
    const content = (
        <div className={alignClass}>
            <div className="text-xs text-muted-foreground">{label}</div>
            <div className={`font-numeric ${emphasized ? 'text-xl font-bold text-primary' : 'text-base font-semibold text-foreground'}`}>
                {value}
            </div>
        </div>
    );

    if (tooltip) {
        return (
            <Tooltip content={tooltip} side="bottom">
                {content}
            </Tooltip>
        );
    }

    return content;
}

// AssetRow component that displays asset data with real metrics
interface AssetRowProps {
    poolName: string;
    asset: AssetData;
    feedSymbol: string | null;
    isExpanded: boolean;
    onToggleExpand: () => void;
}

function AssetRow({ poolName: _poolName, asset, feedSymbol, isExpanded, onToggleExpand }: AssetRowProps) {
    // Fetch sparkline data for price chart
    const { prices, lastPrice, loading: sparklineLoading } = useSparklineData(feedSymbol);

    // Calculate price change from sparkline
    const priceChange = useMemo(() => calc24hPriceChange(prices), [prices]);

    // Determine the color based on price trend
    const sparklineColor = priceChange >= 0 ? '#10b981' : '#ef4444';

    // For stablecoins, price is always $1
    const displayPrice = feedSymbol === null ? 1.0 : (lastPrice ?? asset.price);

    // Calculate metrics
    const reservesUsd = asset.reserves * asset.price;
    const liabilitiesUsd = asset.liabilities * asset.price;
    const utilization = asset.reserves > 0 ? (asset.liabilities / asset.reserves) * 100 : 0;
    const coverage = asset.liabilities > 0 ? (asset.reserves / asset.liabilities) * 100 : 100;

    return (
        <div className="group">
            <div
                className="flex items-center gap-4 p-4 hover:bg-bg-2/50 transition-colors cursor-pointer"
                onClick={onToggleExpand}
            >
                {/* Asset */}
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
                {/* Volume */}
                <div className="w-[120px] text-right">
                    <span className="font-numeric text-foreground">{formatUsd(asset.volume24h)}</span>
                </div>
                {/* Price with Sparkline */}
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
                {/* Utilization */}
                <div className="w-[100px] text-right">
                    <span className="font-numeric text-foreground">{formatPercent(utilization)}</span>
                </div>
                {/* APY */}
                <div className="w-[80px] text-right">
                    <span className="font-numeric text-green-500">{formatPercent(asset.apy)}</span>
                </div>
                {/* Coverage */}
                <div className="w-[120px] flex items-center justify-center">
                    <CoverageGauge ratio={coverage / 100} />
                </div>
                {/* TVL */}
                <div className="flex-1 text-right">
                    <div className="font-numeric text-foreground">{formatUsd(reservesUsd)}</div>
                    <div className="text-xs font-numeric text-muted-foreground">{formatUsd(liabilitiesUsd)} debt</div>
                </div>
            </div>

            {isExpanded && (
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
                                    <Button styleVariant="outlined" className="flex-1" size="sm">
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

// Add Asset Row - styled like the "Add token" button in SwapForm
function AddAssetRow({ onClick }: { onClick: () => void }) {
    return (
        <button onClick={onClick} className="add-asset-row group relative w-full cursor-pointer p-4">
            <div className="absolute left-1/2 -translate-x-1/2 -top-[0.5rem] p-1 transition-colors duration-150 group-hover:text-primary">
                <BorderedThemedIcon icon={plusIcon} size={20} className="transition-transform duration-150 group-hover:scale-140" />
            </div>
            <div className="w-full bg-bg-2 rounded-md py-2 text-fg-3 border-2 border-dashed border-border transition-all duration-150 group-hover:text-primary group-hover:bg-bg-primary group-hover:border-primary">
                <span className="text-sm font-medium">Add asset</span>
            </div>
        </button>
    );
}

// Feed symbol mapping for sparklines
const FEED_SYMBOLS: Record<string, string | null> = {
    WETH: 'ETHUSDC',
    WBTC: 'BTCUSDC',
    USDC: null,
    USDT: null,
    DAI: null,
};

export default function LiquidityPage() {
    const { navigate } = useRouter();
    const [expandedPool, setExpandedPool] = useState<string>('Genesis');
    const [expandedAsset, setExpandedAsset] = useState<string | null>(null);
    const [timeframe, setTimeframe] = useState<Timeframe>('24h');
    const [searchQuery, setSearchQuery] = useState('');
    const isOwner = true; // Mock owner check

    // Get pool data from hook
    const { pool, loading: poolLoading, isMockMode } = useLiquidityData();

    // Filter assets based on search query (symbol, name, or address)
    const filterAssets = (assets: AssetData[]) => {
        if (!searchQuery.trim()) return assets;
        const query = searchQuery.toLowerCase().trim();
        return assets.filter(asset =>
            asset.symbol.toLowerCase().includes(query) ||
            asset.name.toLowerCase().includes(query) ||
            asset.address.toLowerCase().includes(query)
        );
    };

    return (
        <PageContainer
            title="Liquidity Pools"
            actions={
                <div className="flex items-center gap-3">
                    <div className="relative">
                        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
                        <Input
                            type="text"
                            placeholder="Search pools or assets..."
                            className="pl-9 w-64"
                            variant="search"
                            value={searchQuery}
                            onInput={(e) => setSearchQuery((e.target as HTMLInputElement).value)}
                        />
                    </div>
                    <Dropdown
                        items={TIMEFRAME_OPTIONS}
                        value={timeframe}
                        onChange={(v) => setTimeframe(v as Timeframe)}
                        size="sm"
                        styleVariant="glass"
                        className="min-w-[70px]"
                    />
                </div>
            }
        >
            <div className="space-y-4">
                {poolLoading ? (
                    <div className="bg-bg-1 border border-border rounded-lg p-8 text-center text-muted-foreground">
                        Loading pool data...
                    </div>
                ) : pool ? (
                    <div className="bg-bg-1 border border-border rounded-lg overflow-hidden shadow-sm">
                        {/* Pool Header with Hero Metrics */}
                        <div
                            className="cursor-pointer hover:bg-bg-2/50 transition-colors border-b border-border p-4"
                            onClick={() => setExpandedPool(expandedPool === pool.name ? '' : pool.name)}
                        >
                            <div className="flex items-center justify-between">
                                {/* Left: Title */}
                                <div className="flex items-center gap-3">
                                    <ChevronDown
                                        className={`w-5 h-5 text-muted-foreground transition-transform ${
                                            expandedPool === pool.name ? 'rotate-180' : ''
                                        }`}
                                    />
                                    <div className="flex items-center gap-2">
                                        <h2 className="text-lg font-bold text-foreground">
                                            {pool.name}
                                            <span className="text-sm font-normal text-muted-foreground ml-1">
                                                [{pool.assets.length}]
                                            </span>
                                        </h2>
                                        <Badge variant="primary">Default</Badge>
                                        {isMockMode && (
                                            <Badge variant="secondary">Mock</Badge>
                                        )}
                                    </div>
                                </div>

                                {/* Right: Hero Metrics */}
                                <div className="flex items-center gap-8">
                                    <HeroMetric
                                        label="Volume"
                                        value={formatUsd(pool.volume24h)}
                                    />
                                    <HeroMetric
                                        label="Utilization"
                                        value={formatPercent(pool.utilization)}
                                        tooltip="Weighted average of asset utilization rates (borrowed / available)"
                                    />
                                    <HeroMetric
                                        label="Coverage"
                                        value={formatPercent(pool.coverage)}
                                        tooltip="Weighted average of reserves / liabilities across all assets"
                                    />
                                    <HeroMetric
                                        label="TVL"
                                        value={formatUsd(pool.tvl)}
                                        emphasized
                                        align="right"
                                    />
                                </div>
                            </div>
                        </div>

                        {/* Pool Assets */}
                        {expandedPool === pool.name && (
                            <div>
                                <div className="flex items-center gap-4 p-4 border-b border-border text-sm font-medium text-muted-foreground bg-bg-2/50">
                                    <div className="w-[180px] pl-2">Asset</div>
                                    <div className="w-[120px] text-right">Volume</div>
                                    <div className="w-[180px] text-right">Price</div>
                                    <div className="w-[100px] text-right">Utilization</div>
                                    <div className="w-[80px] text-right">APY</div>
                                    <div className="w-[120px] text-center">Coverage</div>
                                    <div className="flex-1 text-right">TVL</div>
                                </div>

                                <div className="divide-y divide-border">
                                    {filterAssets(pool.assets).length === 0 ? (
                                        <div className="p-8 text-center text-muted-foreground">
                                            No assets found matching "{searchQuery}"
                                        </div>
                                    ) : (
                                        filterAssets(pool.assets).map((asset) => (
                                            <AssetRow
                                                key={`${pool.name}-${asset.symbol}`}
                                                poolName={pool.name}
                                                asset={asset}
                                                feedSymbol={FEED_SYMBOLS[asset.symbol] ?? null}
                                                isExpanded={expandedAsset === `${pool.name}-${asset.symbol}`}
                                                onToggleExpand={() =>
                                                    setExpandedAsset(
                                                        expandedAsset === `${pool.name}-${asset.symbol}`
                                                            ? null
                                                            : `${pool.name}-${asset.symbol}`
                                                    )
                                                }
                                            />
                                        ))
                                    )}
                                    {isOwner && <AddAssetRow onClick={() => navigate(ROUTES.ADD_ASSET)} />}
                                </div>
                            </div>
                        )}
                    </div>
                ) : (
                    <div className="bg-bg-1 border border-border rounded-lg p-8 text-center text-muted-foreground">
                        No pool data available
                    </div>
                )}
            </div>
        </PageContainer>
    );
}
