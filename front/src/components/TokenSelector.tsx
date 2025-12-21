import { useState, useMemo } from 'preact/hooks';
import { SelectionModal, SelectionItem } from '@components/ui/SelectionModal';
import { MultiSelectModal, FilterButton, FilterOption } from '@components/ui/MultiSelectModal';
import { Badge } from '@components/ui/Badge';
import { TOKENS, CHAINS, getAllTokensForChain, getSupportedChainIds, tokenMatchesSearch, getTokenIcon, getChainIcon, isTestOrLocalChain } from '@sdk/eth';
import { SUPPORTED_CHAINS_CONFIG, SUPPORTED_TOKENS_CONFIG, isTokenSupported } from '@config/tokens';
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

// Helper to get token symbols for a chain (filtered by config)
function getTokensForChain(chainId: number): string[] {
  const allTokens = getAllTokensForChain(chainId);
  return Object.keys(allTokens).filter(symbol => isTokenSupported(symbol));
}

export default function TokenSelector({
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
  const chainFilterOptions: FilterOption[] = useMemo(() => {
    return supportedChainIds.map((id) => {
      const icon = getChainIcon(id);
      return {
        id: String(id),
        name: CHAINS[id].name,
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
      SUPPORTED_TOKENS_CONFIG.indexOf(a as typeof SUPPORTED_TOKENS_CONFIG[number]) -
      SUPPORTED_TOKENS_CONFIG.indexOf(b as typeof SUPPORTED_TOKENS_CONFIG[number])
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

  // Filter section with chain selector button
  const filterSection = (
    <div className="p-3 border-b border-border">
      <FilterButton
        label="Chains"
        options={chainFilterOptions}
        selected={selectedChains}
        onClick={() => setIsChainFilterOpen(true)}
      />
    </div>
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
        filterSection={filterSection}
        emptyMessage="No tokens found"
        maxWidth="max-w-md"
        applyLabel="Ok"
      />

      <MultiSelectModal
        isOpen={isChainFilterOpen}
        onClose={() => setIsChainFilterOpen(false)}
        title="Filter by Chain"
        placeholder="Network or chain id..."
        options={chainFilterOptions}
        selected={selectedChains}
        onApply={setSelectedChains}
      />
    </>
  );
}
