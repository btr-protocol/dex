import { useState, useMemo, useEffect } from 'preact/hooks';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { MultiSelectModal, FilterButton, FilterOption } from '@components/ui/MultiSelectModal';
import { Button } from '@components/ui/Button';
import { Badge } from '@components/ui/Badge';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { Check } from 'lucide-react';
import { TOKENS, CHAINS, getAllTokensForChain, getSupportedChainIds, tokenMatchesSearch, getTokenIcon, getChainIcon } from '@sdk/eth';
import { SUPPORTED_CHAINS_CONFIG, SUPPORTED_TOKENS_CONFIG, isTokenSupported } from '@config/tokens';
import { useKeyboardNav } from '@hooks/useKeyboardNav';

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
const SUPPORTED_CHAIN_IDS = SUPPORTED_CHAINS_CONFIG.filter(id =>
  ALL_SDK_CHAINS.includes(id as number)
) as number[];

// Build chain filter options from filtered SDK chains (in config order)
const chainFilterOptions: FilterOption[] = SUPPORTED_CHAIN_IDS.map((id) => {
  const icon = getChainIcon(id);
  return {
    id: String(id),
    name: CHAINS[id].name,
    icon,
    miniIcon: icon.replace('.svg', '-mono.svg'),
  };
});

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
  const [search, setSearch] = useState('');
  const [selectedChains, setSelectedChains] = useState<string[]>(SUPPORTED_CHAIN_IDS.map(String));
  const [isChainFilterOpen, setIsChainFilterOpen] = useState(false);
  const [tempSelected, setTempSelected] = useState<string[]>(selectedTokens);

  // Reset state when dialog opens
  useEffect(() => {
    if (isOpen) {
      setSelectedChains(SUPPORTED_CHAIN_IDS.map(String));
      setSearch('');
      setTempSelected(selectedTokens);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);

  // Get available tokens for selected chains
  const availableTokens = useMemo(() => {
    const allTokens = new Set<string>();
    selectedChains.forEach((chain) => {
      getTokensForChain(Number(chain)).forEach((token) => allTokens.add(token));
    });
    return Array.from(allTokens);
  }, [selectedChains]);

  // Filter tokens by search (symbol, name, and aliases) and maintain config order
  const filteredTokens = useMemo(() => {
    const filtered = availableTokens.filter((symbol) =>
      !search || tokenMatchesSearch(symbol, search)
    );
    // Sort by config order
    return filtered.sort((a, b) =>
      SUPPORTED_TOKENS_CONFIG.indexOf(a as typeof SUPPORTED_TOKENS_CONFIG[number]) -
      SUPPORTED_TOKENS_CONFIG.indexOf(b as typeof SUPPORTED_TOKENS_CONFIG[number])
    );
  }, [availableTokens, search]);

  // Keyboard navigation
  const { selectedIndex, handleKeyDown } = useKeyboardNav({
    items: filteredTokens,
    onSelect: (symbol) => handleToggle(symbol),
    isEnabled: isOpen,
  });

  const handleToggle = (token: string) => {
    if (disabledTokens.includes(token)) return;

    if (multiSelect) {
      setTempSelected((prev) =>
        prev.includes(token) ? prev.filter((t) => t !== token) : [...prev, token]
      );
    } else {
      // Single select mode - apply immediately
      const tokenChain = selectedChains.map(Number).find((chain) =>
        getTokensForChain(chain).includes(token)
      ) || chainId;
      onSelect([token], tokenChain);
      onClose();
      setSearch('');
    }
  };

  const handleApply = () => {
    const tokenChain = selectedChains.map(Number).find((chain) =>
      tempSelected.some((token) => getTokensForChain(chain).includes(token))
    ) || chainId;
    onSelect(tempSelected, tokenChain);
    onClose();
    setSearch('');
  };

  const handleSelectAll = () => {
    setTempSelected(filteredTokens);
  };

  const handleDeselectAll = () => {
    setTempSelected([]);
  };

  const allSelected = tempSelected.length === filteredTokens.length && filteredTokens.length > 0;
  const allFilteredAreDisabled = filteredTokens.length > 0 && filteredTokens.every(t => disabledTokens.includes(t));

  return (
    <>
      <BaseModal
        isOpen={isOpen}
        onClose={(open) => !open && onClose()}
        title="Select tokens"
        headerType="input"
        placeholder="Token address, symbol..."
        searchValue={search}
        onSearchChange={setSearch}
        onSearchKeyDown={handleKeyDown}
        maxWidth="max-w-md"
        headerRight={
          <FilterButton
            label="Chains"
            options={chainFilterOptions}
            selected={selectedChains}
            onClick={() => setIsChainFilterOpen(true)}
          />
        }
        footerNav={
          <KeyboardShortcutGroup
            shortcuts={[
              { keys: '↑↓', label: 'Navigate' },
              { keys: 'Enter', label: multiSelect ? 'Toggle' : 'Select' },
              { keys: 'Esc', label: 'Close' },
            ]}
          />
        }
        footerContent={multiSelect ? (
          <div className="flex items-center justify-between gap-2">
            {allFilteredAreDisabled ? (
              <span className="text-xs text-yellow-400">Already selected</span>
            ) : (
              <span className="text-sm text-muted-foreground">
                {tempSelected.length} selected
              </span>
            )}
            <div className="flex items-center gap-2">
              <Button
                styleVariant="outlined"
                size="default"
                onClick={allSelected ? handleDeselectAll : handleSelectAll}
                disabled={allFilteredAreDisabled}
              >
                {allSelected ? 'Deselect All' : 'Select All'}
              </Button>
              <Button variant="primary" size="default" onClick={handleApply}>
                Ok
              </Button>
            </div>
          </div>
        ) : undefined}
      >
        <div className="divide-y divide-border">
          {filteredTokens.map((symbol, idx) => {
            const tokenInfo = TOKENS[symbol];
            const isSelected = tempSelected.includes(symbol);
            const isDisabled = disabledTokens.includes(symbol);
            const isHighlighted = idx === selectedIndex;
            const iconSrc = getTokenIcon(symbol);

            return (
              <button
                key={symbol}
                className={`w-full flex items-center justify-between ${MODAL_PADDING} py-2 transition-colors ${
                  isDisabled
                    ? 'cursor-default'
                    : isHighlighted
                    ? 'bg-bg-2 cursor-pointer'
                    : 'hover:bg-bg-2 cursor-pointer'
                }`}
                style={isSelected ? { backgroundColor: 'var(--bg-primary)' } : undefined}
                onClick={() => handleToggle(symbol)}
                disabled={isDisabled}
              >
                <div className="flex items-center gap-3">
                  <img src={iconSrc} alt={symbol} className="w-10 h-10" />
                  <div className="text-left">
                    <div className={`mt-0.5 font-title font-medium ${isSelected ? 'text-primary' : ''}`}>{symbol}</div>
                    <div className="text-xs text-fg-3 -mt-1">
                      {tokenInfo?.name || symbol}
                    </div>
                  </div>
                </div>
                {isSelected && <Check className="w-5 h-5 text-primary" />}
                {isDisabled && !isSelected && (
                  <Badge variant="primary">Already paired</Badge>
                )}
              </button>
            );
          })}

          {filteredTokens.length === 0 && (
            <div className={`${MODAL_PADDING} py-8 text-center text-muted-foreground text-sm`}>
              No tokens found
            </div>
          )}
        </div>
      </BaseModal>

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
