import { useState, useMemo } from 'preact/hooks';
import { SelectionModal, SelectionItem, FilterButton } from '@components/ui/SelectionModal';
import { Badge } from '@components/ui/Badge';
import { TOKENS, CHAINS, getAllTokensForChain, getSupportedChainIds, tokenMatchesSearch, getTokenIcon, getChainIcon, isTestOrLocalChain } from '@sdk/eth';
import { SUPPORTED_CHAINS_CONFIG, SUPPORTED_TOKENS_CONFIG, isTokenSupported } from '@/constants/tokens';
import { useModalState } from '@hooks/useModalState';
import { useSettings } from '@/lib/settings';

interface TokenSelectorProps {
  isOpen: boolean;
  onClose: () => void;
  onSelect: (tokens: string[], chainId: number) => void;
  selectedTokens?: string[];
  chainId: number;
  multiSelect?: boolean;
  disabledTokens?: string[];
}

// Get supported chain IDs from SDK filtered by config (maintain config order)
const ALL_SDK_CHAINS = getSupportedChainIds();
const ALL_SUPPORTED_CHAIN_IDS = SUPPORTED_CHAINS_CONFIG.filter(id =>
  ALL_SDK_CHAINS.includes(id as number)
) as number[];

// Build token index for fast sorting
const TOKEN_INDEX = new Map(SUPPORTED_TOKENS_CONFIG.map((t, i) => [t, i]));

// Helper to get token symbols for a chain (filtered by config)
function getTokensForChain(chainId: number): string[] {
  const allTokens = getAllTokensForChain(chainId);
  return Object.keys(allTokens).filter(symbol => isTokenSupported(symbol));
}

export function TokenSelector({
  isOpen,
  onClose,
  onSelect,
  selectedTokens = [],
  chainId,
  multiSelect = true,
  disabledTokens = [],
}: TokenSelectorProps) {
  const { settings } = useSettings();
  const [isChainFilterOpen, setIsChainFilterOpen] = useState(false);

  // Filter chains based on showTestNetworks setting
  const supportedChainIds = useMemo(() => {
    if (settings.showTestNetworks) {
      return ALL_SUPPORTED_CHAIN_IDS;
    }
    return ALL_SUPPORTED_CHAIN_IDS.filter(id => !isTestOrLocalChain(id));
  }, [settings.showTestNetworks]);

  // Build chain filter options from filtered SDK chains (in config order)
  const chainFilterOptions: SelectionItem[] = useMemo(() => {
    return supportedChainIds.map((id) => {
      const icon = getChainIcon(id);
      return {
        id: String(id),
        label: CHAINS[id].name,
        icon,
        miniIcon: icon.replace('.svg', '-mono.svg'),
      };
    });
  }, [supportedChainIds]);

  const [selectedChains, setSelectedChains] = useModalState<string[]>(
    supportedChainIds.map(String),
    isOpen
  );

  // Get available tokens for selected chains
  const availableTokens = useMemo(() => {
    const allTokens = new Set<string>();
    selectedChains.forEach((chain) => {
      getTokensForChain(Number(chain)).forEach((token) => allTokens.add(token));
    });
    return Array.from(allTokens).sort((a, b) =>
      (TOKEN_INDEX.get(a as typeof SUPPORTED_TOKENS_CONFIG[number]) ?? 1000) -
      (TOKEN_INDEX.get(b as typeof SUPPORTED_TOKENS_CONFIG[number]) ?? 1000)
    );
  }, [selectedChains]);

  // Convert tokens to SelectionItem format
  const items: SelectionItem[] = useMemo(() => {
    return availableTokens.map((symbol) => {
      const tokenInfo = TOKENS[symbol];
      const isDisabled = disabledTokens.includes(symbol);

      return {
        id: symbol,
        label: symbol,
        caption: tokenInfo?.name || symbol,
        icon: getTokenIcon(symbol),
        disabled: isDisabled,
        badge: isDisabled ? <Badge variant="primary">Already paired</Badge> : undefined,
      };
    });
  }, [availableTokens, disabledTokens]);

  // Handle selection
  const handleSelect = (selected: string | string[]) => {
    const tokens = Array.isArray(selected) ? selected : [selected];

    // Find chain for selected tokens
    const tokenChain = selectedChains.map(Number).find((chain) =>
      tokens.some((token) => getTokensForChain(chain).includes(token))
    ) || chainId;

    onSelect(tokens, tokenChain);
  };

  // Custom filter function (token symbol, name, aliases)
  const filterFn = (item: SelectionItem, search: string) => {
    return tokenMatchesSearch(item.id, search);
  };

  // Filter button for header row
  const headerFilter = (
    <FilterButton
      label="Chains"
      options={chainFilterOptions}
      selected={selectedChains}
      onClick={() => setIsChainFilterOpen(true)}
    />
  );

  return (
    <>
      <SelectionModal
        isOpen={isOpen}
        onClose={onClose}
        title="Select tokens"
        searchPlaceholder="Token address, symbol..."
        items={items}
        selectedIds={selectedTokens}
        onSelect={handleSelect}
        multiSelect={multiSelect}
        filterFn={filterFn}
        headerRight={headerFilter}
        emptyMessage="No tokens found"
        maxWidth="max-w-md"
        applyLabel="Ok"
      />

      <SelectionModal
        isOpen={isChainFilterOpen}
        onClose={() => setIsChainFilterOpen(false)}
        title="Filter by Chain"
        searchPlaceholder="Network or chain id..."
        items={chainFilterOptions}
        selectedIds={selectedChains}
        onSelect={(selected) => setSelectedChains(Array.isArray(selected) ? selected : [selected])}
        multiSelect={true}
        minSelect={1}
      />
    </>
  );
}
