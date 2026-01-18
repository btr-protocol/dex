import { useMemo } from 'preact/hooks';
import { Icon } from '@components/ui/Icon';
import { Button } from '@components/ui/Button';
import { Badge } from '@components/ui/Badge';
import { Input } from '@components/ui/Input';
import { Dropdown, DropdownItem } from '@components/ui/Dropdown';
import { HeroMetric } from '@components/ui/HeroMetric';
import { Card } from '@components/ui/Card';
import { Spinner } from '@components/ui/Spinner';
import { useRouter } from '@lib/router';
import { PageContainer } from '@components/layout/PageContainer';
import { BorderedThemedIcon, plusIcon } from '@/components/ui/BorderedThemedIcon';
import { AssetRow } from '@components/features/liquidity/AssetRow';
import { useLiquidityData } from '@/hooks/useLiquidityData';
import { formatCurrencyCompact, formatPercent } from '@/utils/format';
import { ROUTES } from '@/constants/navigation';
import { liquidityStore, type Timeframe } from '@/lib/liquidity/LiquidityStore';

const TIMEFRAME_OPTIONS: DropdownItem<Timeframe>[] = [
    { value: '1h', label: '1H' },
    { value: '4h', label: '4H' },
    { value: '12h', label: '12H' },
    { value: '24h', label: '24H' },
    { value: '3d', label: '3D' },
    { value: '7d', label: '7D' },
    { value: '30d', label: '30D' },
];

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

export function LiquidityPage() {
    const { navigate } = useRouter();
    const isOwner = true; // Mock owner check

    // Get pool data from hook
    const { pool, loading: poolLoading, isMockMode } = useLiquidityData();

    return (
        <PageContainer
            title="Liquidity Pools"
            actions={
                <div className="flex items-center gap-3">
                    <div className="relative">
                        <Icon name="magnifying-glass" className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
                        <Input
                            type="text"
                            placeholder="Search pools or assets..."
                            className="pl-9 w-64"
                            variant="search"
                            value={liquidityStore.searchQuery.value}
                            onInput={(e) => liquidityStore.setSearchQuery((e.target as HTMLInputElement).value)}
                        />
                    </div>
                    <Dropdown
                        items={TIMEFRAME_OPTIONS}
                        value={liquidityStore.timeframe.value}
                        onChange={(v) => liquidityStore.setTimeframe(v as Timeframe)}
                        size="sm"
                        variant="glass"
                        className="min-w-[70px]"
                    />
                </div>
            }
        >
            <div className="space-y-4">
                {poolLoading ? (
                    <Card className="rounded-lg p-8 flex flex-col items-center justify-center gap-3">
                        <Spinner size="lg" />
                        <span className="text-muted-foreground">Loading pool data...</span>
                    </Card>
                ) : pool ? (
                    <Card className="rounded-lg overflow-hidden shadow-sm">
                        {/* Pool Header with Hero Metrics */}
                        <div
                            className="cursor-pointer hover:bg-bg-2/50 transition-colors border-b border-border p-4"
                            onClick={() => liquidityStore.togglePool(pool.name)}
                        >
                            <div className="flex items-center justify-between">
                                {/* Left: Title */}
                                <div className="flex items-center gap-3">
                                    <Icon
                                        name="caret-down"
                                        className={`w-5 h-5 text-muted-foreground transition-transform ${
                                            liquidityStore.expandedPool.value === pool.name ? 'rotate-180' : ''
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
                                        value={formatCurrencyCompact(pool.volume24h)}
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
                                        value={formatCurrencyCompact(pool.tvl)}
                                        emphasized
                                        align="right"
                                    />
                                </div>
                            </div>
                        </div>

                        {/* Pool Assets */}
                        {liquidityStore.expandedPool.value === pool.name && (
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
                                    {liquidityStore.getFilteredAssets(pool.assets).length === 0 ? (
                                        <div className="p-8 text-center text-muted-foreground">
                                            No assets found matching "{liquidityStore.searchQuery.value}"
                                        </div>
                                    ) : (
                                        liquidityStore.getFilteredAssets(pool.assets).map((asset) => (
                                            <AssetRow
                                                key={`${pool.name}-${asset.symbol}`}
                                                poolName={pool.name}
                                                asset={asset}
                                                feedSymbol={FEED_SYMBOLS[asset.symbol] ?? null}
                                            />
                                        ))
                                    )}
                                    {isOwner && <AddAssetRow onClick={() => navigate(ROUTES.ADD_ASSET)} />}
                                </div>
                            </div>
                        )}
                    </Card>
                ) : (
                    <Card className="rounded-lg p-8 text-center text-muted-foreground">
                        No pool data available
                    </Card>
                )}
            </div>
        </PageContainer>
    );
}
