import { useEffect } from 'preact/hooks';
import { useAccount } from '@/hooks/useContract';
import { formatUnits, Address } from '@sdk/eth';
import { loadAddresses } from '@/contracts/addresses';
import { useRegisteredAssets, useAssetState, useOraclePrice, useCoverageRatio } from '@/hooks/usePoolState';
import { useTokenInfo } from '@/hooks/useTokenInfo';
import { Badge } from '@components/ui/Badge';

interface AssetRowProps {
  address: Address;
}

interface AssetData {
  reserves: bigint;
  liabilities: bigint;
  minFeeBps: number;
  maxFeeBps: number;
}

function AssetRow({ address }: AssetRowProps) {
  const { data: assetRaw } = useAssetState(address);
  const { data: price } = useOraclePrice(address);
  const { data: coverageRatio } = useCoverageRatio(address);
  const { symbol, decimals } = useTokenInfo(address);

  const asset = assetRaw as AssetData | undefined;

  if (!asset || !price || decimals === undefined) {
    return (
      <tr className="border-b border-gray-700">
        <td colSpan={6} className="px-4 py-3 text-gray-500 text-center">
          Loading...
        </td>
      </tr>
    );
  }

  const formattedReserves = formatUnits(asset.reserves, decimals);
  const formattedLiabilities = formatUnits(asset.liabilities, decimals);
  const formattedPrice = formatUnits(price as bigint, 18); // Prices are in 18 decimals
  const formattedCoverage = coverageRatio ? Number(coverageRatio) / 10000 : 0; // BPS to percentage

  return (
    <tr className="border-b border-gray-700 hover:bg-gray-800/50 transition-colors">
      <td className="px-4 py-3 font-medium">{symbol || 'Unknown'}</td>
      <td className="px-4 py-3 font-mono text-sm text-gray-300">
        {parseFloat(formattedReserves).toLocaleString(undefined, { maximumFractionDigits: 6 })}
      </td>
      <td className="px-4 py-3 font-mono text-sm text-gray-300">
        {parseFloat(formattedLiabilities).toLocaleString(undefined, { maximumFractionDigits: 6 })}
      </td>
      <td className="px-4 py-3 font-mono text-sm">
        <span className={formattedCoverage >= 100 ? 'text-green-400' : 'text-orange-400'}>
          {formattedCoverage.toFixed(2)}%
        </span>
      </td>
      <td className="px-4 py-3 font-mono text-sm text-gray-300">
        ${parseFloat(formattedPrice).toLocaleString(undefined, { maximumFractionDigits: 2 })}
      </td>
      <td className="px-4 py-3">
        <div className="flex gap-2">
          <Badge variant="default" className="bg-cyan/20 text-cyan border-cyan">
            {asset.minFeeBps / 100}% - {asset.maxFeeBps / 100}%
          </Badge>
        </div>
      </td>
    </tr>
  );
}

export default function PoolDashboard() {
  const { address: account } = useAccount();
  const { data: registeredAssets, loading, error } = useRegisteredAssets();

  // Load addresses on mount
  useEffect(() => {
    loadAddresses();
  }, []);

  if (loading) {
    return (
      <div className="bg-gray-900 rounded-lg p-8 border border-gray-700">
        <div className="flex items-center justify-center">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-teal-500"></div>
          <span className="ml-3 text-gray-400">Loading pool data...</span>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="bg-gray-900 rounded-lg p-8 border border-red-500/50">
        <div className="text-center">
          <h3 className="text-lg font-semibold text-red-400 mb-2">Error Loading Pool</h3>
          <p className="text-gray-400 text-sm">
            Make sure Anvil is running and contracts are deployed.
          </p>
          <p className="text-gray-500 text-xs mt-2 font-mono">{error.message}</p>
        </div>
      </div>
    );
  }

  const assets = registeredAssets as Address[] | undefined;
  if (!assets || assets.length === 0) {
    return (
      <div className="bg-gray-900 rounded-lg p-8 border border-gray-700">
        <div className="text-center">
          <h3 className="text-lg font-semibold text-gray-400 mb-2">No Assets Found</h3>
          <p className="text-gray-500 text-sm">
            Deploy contracts and add assets to the pool to get started.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-gray-900 rounded-lg border border-gray-700 overflow-hidden">
      <div className="px-6 py-4 border-b border-gray-700">
        <h2 className="text-xl font-bold">Pool Overview</h2>
        <p className="text-sm text-gray-400 mt-1">
          {assets.length} asset{assets.length !== 1 ? 's' : ''} registered
        </p>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full">
          <thead className="bg-gray-800/50">
            <tr>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                Asset
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                Reserves
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                Liabilities
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                Coverage
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                Oracle Price
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                Fee Range
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-700">
            {assets.map((assetAddr: Address) => (
              <AssetRow key={assetAddr} address={assetAddr} />
            ))}
          </tbody>
        </table>
      </div>

      {account && (
        <div className="px-6 py-3 bg-gray-800/30 border-t border-gray-700">
          <p className="text-xs text-gray-500">
            Connected: <span className="font-mono text-teal-400">{account}</span>
          </p>
        </div>
      )}
    </div>
  );
}
