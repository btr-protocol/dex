import { useState, useMemo, useEffect } from 'preact/hooks';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { MultiSelectModal, FilterButton, FilterOption } from '@components/ui/MultiSelectModal';
import { Badge } from '@components/ui/Badge';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { TOKENS, tokenMatchesSearch, getTokenIcon } from '@sdk/eth';
import { SUPPORTED_TOKENS_CONFIG } from '@config/tokens';
import { useKeyboardNav } from '@hooks/useKeyboardNav';

interface PairSelectorProps {
  isOpen: boolean;
  onClose: () => void;
  onSelect: (base: string, quote: string) => void;
  currentBase: string;
  currentQuote: string;
}

// Use all supported tokens (including wrapped versions)
const SUPPORTED_TOKENS = SUPPORTED_TOKENS_CONFIG.filter(symbol => symbol in TOKENS);

// Generate all token pairs in BOTH directions
function generateAllPairs(): Array<{ base: string; quote: string }> {
  const pairs: Array<{ base: string; quote: string }> = [];

  for (const base of SUPPORTED_TOKENS) {
    for (const quote of SUPPORTED_TOKENS) {
      if (base === quote) continue;
      // Add both directions: ETH/USDC and USDC/ETH
      pairs.push({ base, quote });
    }
  }

  return pairs;
}

// Get wrapper info for a token (e.g., "Wraps ETH" for WETH)
function getTokenCaption(symbol: string): string {
  const token = TOKENS[symbol];
  if (!token) return '';
  if (token.wrapperOf) {
    return `Wraps ${token.wrapperOf}`;
  }
  return token.name || '';
}

// Build token filter options from all supported tokens
const tokenFilterOptions: FilterOption[] = SUPPORTED_TOKENS
  .map((symbol) => ({
    id: symbol,
    name: symbol,
    caption: getTokenCaption(symbol),
    icon: getTokenIcon(symbol),
  }));

export default function PairSelector({
  isOpen,
  onClose,
  onSelect,
  currentBase,
  currentQuote,
}: PairSelectorProps) {
  const [search, setSearch] = useState('');
  const [selectedTokens, setSelectedTokens] = useState<string[]>([...SUPPORTED_TOKENS]);
  const [isTokenFilterOpen, setIsTokenFilterOpen] = useState(false);

  // Reset state when dialog opens
  useEffect(() => {
    if (isOpen) {
      setSelectedTokens([...SUPPORTED_TOKENS]);
      setSearch('');
    }
  }, [isOpen]);

  // Generate all pairs
  const allPairs = useMemo(() => generateAllPairs(), []);

  // Helper to normalize pair strings for flexible matching
  const normalizePairString = (pair: string): string => {
    // Remove all delimiters (/, -, _, .) and convert to lowercase
    return pair.toLowerCase().replace(/[\/-_.]/g, '');
  };

  // Filter pairs by selected tokens and search
  const filteredPairs = useMemo(() => {
    return allPairs.filter(({ base, quote }) => {
      // Must include at least one selected token
      if (!selectedTokens.includes(base) && !selectedTokens.includes(quote)) {
        return false;
      }

      // Search filter with flexible delimiter matching
      if (search) {
        const searchLower = search.toLowerCase();
        const searchNormalized = normalizePairString(search);

        // Check if search includes alias (e.g., "WETH" should find "ETH" pairs)
        const baseMatchesAlias = tokenMatchesSearch(base, search);
        const quoteMatchesAlias = tokenMatchesSearch(quote, search);

        // Generate all possible pair formats (including alias-resolved versions)
        const pairFormats = [
          `${base}${quote}`,           // ETHUSDC
          `${base}/${quote}`,          // ETH/USDC
          `${base}-${quote}`,          // ETH-USDC
          `${base}_${quote}`,          // ETH_USDC
          `${base}.${quote}`,          // ETH.USDC
          `${quote}${base}`,           // USDCETH (reverse)
          `${quote}/${base}`,          // USDC/ETH
          `${quote}-${base}`,          // USDC-ETH
          `${quote}_${base}`,          // USDC_ETH
          `${quote}.${base}`,          // USDC.ETH
        ];

        const baseName = TOKENS[base]?.name.toLowerCase() || '';
        const quoteName = TOKENS[quote]?.name.toLowerCase() || '';

        // Check exact format matches and normalized matches
        const formatMatch = pairFormats.some(fmt =>
          fmt.includes(searchLower) || normalizePairString(fmt).includes(searchNormalized)
        );

        const nameMatch = baseName.includes(searchLower) || quoteName.includes(searchLower);

        // Check alias matches
        const aliasMatch = baseMatchesAlias || quoteMatchesAlias;

        return formatMatch || nameMatch || aliasMatch;
      }

      return true;
    });
  }, [allPairs, selectedTokens, search]);

  // Sort pairs: current pair first, then by token priority
  const sortedPairs = useMemo(() => {
    return [...filteredPairs].sort((a, b) => {
      // Prioritize current pair
      if (a.base === currentBase && a.quote === currentQuote) return -1;
      if (b.base === currentBase && b.quote === currentQuote) return 1;

      // Group by token pair (ignoring direction)
      const aPairKey = [a.base, a.quote].sort().join('-');
      const bPairKey = [b.base, b.quote].sort().join('-');
      const pairCmp = aPairKey.localeCompare(bPairKey);
      if (pairCmp !== 0) return pairCmp;

      // Within same pair, prioritize USDC/USDT as quote (canonical direction first)
      const priorityQuotes = ['USDC', 'USDT', 'ETH', 'BTC'];
      const aIsCanonical = priorityQuotes.includes(a.quote);
      const bIsCanonical = priorityQuotes.includes(b.quote);
      if (aIsCanonical && !bIsCanonical) return -1;
      if (bIsCanonical && !aIsCanonical) return 1;

      return 0;
    });
  }, [filteredPairs, currentBase, currentQuote]);

  // Keyboard navigation
  const { selectedIndex, handleKeyDown } = useKeyboardNav({
    items: sortedPairs,
    onSelect: (pair) => handleSelect(pair.base, pair.quote),
    isEnabled: isOpen,
  });

  const handleSelect = (base: string, quote: string) => {
    onSelect(base, quote);
    onClose();
    setSearch('');
  };

  return (
    <>
      <BaseModal
        isOpen={isOpen}
        onClose={(open) => !open && onClose()}
        title="Select trading pair"
        headerType="input"
        placeholder="Search pairs..."
        searchValue={search}
        onSearchChange={setSearch}
        onSearchKeyDown={handleKeyDown}
        maxWidth="max-w-md"
        headerRight={
          <FilterButton
            label="Tokens"
            options={tokenFilterOptions}
            selected={selectedTokens}
            onClick={() => setIsTokenFilterOpen(true)}
            partialFilter={true}
          />
        }
        footerNav={
          <KeyboardShortcutGroup
            shortcuts={[
              { keys: '↑↓', label: 'Navigate' },
              { keys: 'Enter', label: 'Select' },
              { keys: 'Esc', label: 'Close' },
            ]}
          />
        }
      >
        <div className="divide-y divide-border">
          {sortedPairs.map(({ base, quote }, idx) => {
            const isSelected = base === currentBase && quote === currentQuote;
            const isHighlighted = idx === selectedIndex;
            const baseIcon = getTokenIcon(base);
            const quoteIcon = getTokenIcon(quote);
            const baseToken = TOKENS[base];
            const quoteToken = TOKENS[quote];
            const baseName = baseToken?.name || base;
            const quoteName = quoteToken?.name || quote;
            const baseWraps = baseToken?.wrapperOf;
            const quoteWraps = quoteToken?.wrapperOf;

            return (
              <button
                key={`${base}-${quote}`}
                className={`w-full flex items-center justify-between ${MODAL_PADDING} py-2 transition-colors ${
                  isHighlighted ? 'bg-bg-2' : 'hover:bg-bg-2'
                } cursor-pointer`}
                style={isSelected ? { backgroundColor: 'var(--bg-primary)' } : undefined}
                onClick={() => handleSelect(base, quote)}
              >
                <div className="flex items-center gap-4">
                  {/* Overlapping token icons */}
                  <div className="relative w-10 h-8 flex items-center -mt-2">
                    <img
                      src={baseIcon}
                      alt={base}
                      className="absolute left-0 w-8 h-8 rounded-full"
                    />
                    <img
                      src={quoteIcon}
                      alt={quote}
                      className="absolute left-5 -bottom-2.5 w-6 h-6 rounded-full"
                    />
                  </div>

                  <div className="text-left">
                    <div className={`mt-1 font-title font-medium ${isSelected ? 'text-primary' : ''}`}>
                      {base}/{quote}
                    </div>
                    <div className="text-xs text-fg-3 -mt-1">
                      {baseWraps ? `Wrapped ${baseWraps}` : baseName} / {quoteWraps ? `Wrapped ${quoteWraps}` : quoteName}
                    </div>
                  </div>
                </div>

                {isSelected && (
                  <Badge variant="primary">Current</Badge>
                )}
              </button>
            );
          })}

          {sortedPairs.length === 0 && (
            <div className={`${MODAL_PADDING} py-8 text-center text-muted-foreground text-sm`}>
              No pairs found
            </div>
          )}
        </div>
      </BaseModal>

      <MultiSelectModal
        isOpen={isTokenFilterOpen}
        onClose={() => setIsTokenFilterOpen(false)}
        title="Filter by Token"
        placeholder="Token symbol or name..."
        options={tokenFilterOptions}
        selected={selectedTokens}
        onApply={setSelectedTokens}
      />
    </>
  );
}
