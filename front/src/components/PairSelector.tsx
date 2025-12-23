import { useState, useMemo } from 'preact/hooks';
import { SelectionModal, SelectionItem } from '@components/ui/SelectionModal';
import { MultiSelectModal, FilterButton, FilterOption } from '@components/ui/MultiSelectModal';
import { Badge } from '@components/ui/Badge';
import { TOKENS, tokenMatchesSearch, getTokenIcon } from '@sdk/eth';
import { SUPPORTED_TOKENS_CONFIG } from '@/constants/tokens';
import { useModalState } from '@hooks/useModalState';

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

// Helper to normalize pair strings for flexible matching
const normalizePairString = (pair: string): string => {
  return pair.toLowerCase().replace(/[\/-_.]/g, '');
};

export default function PairSelector({
  isOpen,
  onClose,
  onSelect,
  currentBase,
  currentQuote,
}: PairSelectorProps) {
  const [selectedTokens, setSelectedTokens] = useModalState<string[]>(
    [...SUPPORTED_TOKENS],
    isOpen
  );
  const [isTokenFilterOpen, setIsTokenFilterOpen] = useState(false);

  // Generate all pairs
  const allPairs = useMemo(() => generateAllPairs(), []);

  // Filter pairs by selected tokens
  const availablePairs = useMemo(() => {
    return allPairs.filter(({ base, quote }) => {
      return selectedTokens.includes(base) || selectedTokens.includes(quote);
    });
  }, [allPairs, selectedTokens]);

  // Sort pairs: current pair first, then by token priority
  const sortedPairs = useMemo(() => {
    return [...availablePairs].sort((a, b) => {
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
  }, [availablePairs, currentBase, currentQuote]);

  // Convert pairs to SelectionItem format
  const items: SelectionItem[] = useMemo(() => {
    return sortedPairs.map(({ base, quote }) => {
      const pairId = `${base}-${quote}`;
      const isSelected = base === currentBase && quote === currentQuote;

      const baseIcon = getTokenIcon(base);
      const quoteIcon = getTokenIcon(quote);
      const baseToken = TOKENS[base];
      const quoteToken = TOKENS[quote];
      const baseName = baseToken?.name || base;
      const quoteName = quoteToken?.name || quote;
      const baseWraps = baseToken?.wrapperOf;
      const quoteWraps = quoteToken?.wrapperOf;

      // Custom icon with overlapping tokens
      const icon = (
        <div className="relative w-10 h-8 flex items-center -mt-2">
          <img
            src={baseIcon}
            alt={base}
            className="absolute -left-1 w-8 h-8 rounded-full"
          />
          <img
            src={quoteIcon}
            alt={quote}
            className="absolute left-4 -bottom-2 w-6 h-6 rounded-full"
          />
        </div>
      );

      return {
        id: pairId,
        label: `${base}/${quote}`,
        caption: `${baseWraps ? `Wrapped ${baseWraps}` : baseName} / ${quoteWraps ? `Wrapped ${quoteWraps}` : quoteName}`,
        icon,
        badge: isSelected ? <Badge variant="primary">Current</Badge> : undefined,
        data: { base, quote },
      };
    });
  }, [sortedPairs, currentBase, currentQuote]);

  // Handle selection
  const handleSelect = (pairId: string | string[]) => {
    const id = Array.isArray(pairId) ? pairId[0] : pairId;
    const item = items.find((i) => i.id === id);
    if (item?.data) {
      onSelect(item.data.base, item.data.quote);
    }
  };

  // Custom filter function with flexible pair matching
  const filterFn = (item: SelectionItem, search: string) => {
    const { base, quote } = item.data;
    const searchLower = search.toLowerCase();
    const searchNormalized = normalizePairString(search);

    // Check if search includes alias (e.g., "WETH" should find "ETH" pairs)
    const baseMatchesAlias = tokenMatchesSearch(base, search);
    const quoteMatchesAlias = tokenMatchesSearch(quote, search);

    // Generate all possible pair formats
    const pairFormats = [
      `${base}${quote}`,
      `${base}/${quote}`,
      `${base}-${quote}`,
      `${base}_${quote}`,
      `${base}.${quote}`,
      `${quote}${base}`,
      `${quote}/${base}`,
      `${quote}-${base}`,
      `${quote}_${base}`,
      `${quote}.${base}`,
    ];

    const baseName = TOKENS[base]?.name.toLowerCase() || '';
    const quoteName = TOKENS[quote]?.name.toLowerCase() || '';

    // Check matches
    const formatMatch = pairFormats.some(fmt =>
      fmt.includes(searchLower) || normalizePairString(fmt).includes(searchNormalized)
    );
    const nameMatch = baseName.includes(searchLower) || quoteName.includes(searchLower);
    const aliasMatch = baseMatchesAlias || quoteMatchesAlias;

    return formatMatch || nameMatch || aliasMatch;
  };

  // Filter section with token selector button
  const filterSection = (
    <div className="p-3 border-b border-border">
      <FilterButton
        label="Tokens"
        options={tokenFilterOptions}
        selected={selectedTokens}
        onClick={() => setIsTokenFilterOpen(true)}
        partialFilter={true}
      />
    </div>
  );

  // Reset all filters (token filter + search)
  const handleResetFilters = () => {
    setSelectedTokens([...SUPPORTED_TOKENS]);
  };

  const hasActiveFilters = selectedTokens.length < SUPPORTED_TOKENS.length;

  return (
    <>
      <SelectionModal
        isOpen={isOpen}
        onClose={onClose}
        title="Select trading pair"
        searchPlaceholder="Search pairs..."
        items={items}
        selectedIds={[`${currentBase}-${currentQuote}`]}
        onSelect={handleSelect}
        multiSelect={false}
        filterFn={filterFn}
        filterSection={filterSection}
        emptyMessage="No pairs found"
        onResetFilters={handleResetFilters}
        hasActiveFilters={hasActiveFilters}
        maxWidth="max-w-md"
      />

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
