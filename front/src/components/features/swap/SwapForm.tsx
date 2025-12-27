import { useState, useEffect, useMemo } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { InfoRow, InfoSection } from '@components/ui/InfoRow';
import { BorderedThemedIcon, doubleDownIcon } from '@/components/ui/BorderedThemedIcon';
import { Dropdown } from '@components/ui/Dropdown';
import { Tooltip } from '@components/ui/Tooltip';
import { TokenSelector } from '@components/shared/token';
import { cn } from '@utils/cn';
import { useSwap, formatQuote } from '@/hooks/useSwap';
import { formatUnits } from '@sdk/eth';
import { SwapStore, TokenData, type OrderType } from '@/lib/swap/SwapStore';
import { DirectionToggle } from './DirectionToggle';
import { TokenList } from './TokenList';
import { ORDER_TYPE_OPTIONS } from '@/constants/swap';

interface ChainInfo {
  name: string;
  icon: string;
}

interface SwapFormProps {
  bordered?: boolean;
  chainInfo: ChainInfo;
  chainId?: number;
  isConnected: boolean;
  onConnect: () => void;
  onSwap: () => void;
  initialPrimaryToken?: string;
  initialSecondaryToken?: string;
  onTokenChange?: (primary: string, secondary: string) => void;
  store?: SwapStore;
}

export function SwapForm({
  bordered = true,
  chainInfo,
  chainId = 1,
  isConnected,
  onConnect,
  onSwap,
  initialPrimaryToken = 'ETH',
  initialSecondaryToken = 'USDT',
  onTokenChange,
  store: externalStore
}: SwapFormProps) {
  const localStore = useMemo(() => new SwapStore(initialPrimaryToken, initialSecondaryToken), []);
  const store = externalStore || localStore;

  // Get swap quote from contract
  const primaryToken = store.primaryTokens.value[0]?.symbol || '';
  const secondaryToken = store.secondaryTokens.value[0]?.symbol || '';
  const primaryAmount = store.primaryTokens.value[0]?.amount || '';

  const {
    quote,
    quoteLoading,
    quoteError,
    executeSwap,
    swapLoading,
    needsApproval,
    approve,
    approveLoading,
    isMockMode,
  } = useSwap(primaryToken, secondaryToken, primaryAmount);

  // Format quote for display
  const formattedQuote = useMemo(() => formatQuote(quote), [quote]);

  // Sync with store when initial tokens change (e.g., from URL params)
  useEffect(() => {
    if (initialPrimaryToken) {
      store.setTokenSymbol('1', initialPrimaryToken, 'primary');
    }
  }, [initialPrimaryToken, store]);

  useEffect(() => {
    if (initialSecondaryToken) {
      store.setTokenSymbol('1', initialSecondaryToken, 'secondary');
    }
  }, [initialSecondaryToken, store]);

  // Notify parent when tokens change
  useEffect(() => {
    const primary = store.primaryTokens.value[0]?.symbol;
    const secondary = store.secondaryTokens.value[0]?.symbol;
    if (primary && secondary && onTokenChange) {
      onTokenChange(primary, secondary);
    }
  }, [store.primaryTokens, store.secondaryTokens, onTokenChange]);

  // Token selector state
  const [isTokenSelectorOpen, setIsTokenSelectorOpen] = useState(false);
  const [editingTokenId, setEditingTokenId] = useState<string | null>(null);
  const [editingTokenType, setEditingTokenType] = useState<'primary' | 'secondary'>('primary');

  // Update secondary amount when quote changes
  useEffect(() => {
    if (quote && store.editingSide.value === 'primary') {
      const estimatedOut = formatUnits(quote.amountOut, 18);
      store.updateTokenAmount('1', estimatedOut, 'secondary');
    }
  }, [quote, store.editingSide, store]);

  const addToken = (type: 'primary' | 'secondary') => {
    const id = store.addToken(type);
    setEditingTokenId(id);
    setEditingTokenType(type);
    setIsTokenSelectorOpen(true);
  };

  const handleTokenClick = (id: string, type: 'primary' | 'secondary') => {
    setEditingTokenId(id);
    setEditingTokenType(type);
    setIsTokenSelectorOpen(true);
  };

  const handleTokenSelect = (tokens: string[], _selectedChainId: number) => {
    if (tokens.length === 0 || !editingTokenId) return;
    const selectedToken = tokens[0];
    store.setTokenSymbol(editingTokenId, selectedToken, editingTokenType);
  };

  const handleTokenSelectorClose = () => {
    if (editingTokenId) {
      const tokens = editingTokenType === 'primary' ? store.primaryTokens.value : store.secondaryTokens.value;
      const token = tokens.find(t => t.id === editingTokenId);
      if (token && !token.symbol) {
        store.removeToken(editingTokenId, editingTokenType);
      }
    }
    setIsTokenSelectorOpen(false);
    setEditingTokenId(null);
  };

  const handleDirectionSwitch = () => {
    store.setDirection(store.direction.value === 'sell' ? 'buy' : 'sell');
  };

  const canSwap = isConnected && store.primaryTokens.value.some(t => t.amount && t.symbol);
  const primaryTokenSymbol = store.primaryTokens.value[0]?.symbol || 'token';
  const secondaryLabel = store.direction.value === 'sell' ? 'For' : 'With';
  const switchTooltip = store.direction.value === 'sell' ? 'Buy instead' : 'Sell instead';
  const actionVerb = store.direction.value === 'sell' ? 'sell' : 'buy';


  const content = (
    <div className="relative flex flex-col gap-2">
      <div className="flex items-center justify-between -mb-0.5">
        <DirectionToggle store={store} />
        <Dropdown
          items={ORDER_TYPE_OPTIONS}
          value={store.orderType.value}
          onChange={(v) => store.setOrderType(v as OrderType)}
          size="compact-xl"
                      variant="glass"          className="min-w-[120px] bg-white/5 border border-white/10"
        />
      </div>

      <div>
        <TokenList
          tokens={store.primaryTokens.value}
          type="primary"
          chainInfo={chainInfo}
          chainId={chainId}
          readOnly={false}
          onAmountChange={(tokenId, amount) => store.updateTokenAmount(tokenId, amount, 'primary')}
          onTokenClick={(tokenId) => handleTokenClick(tokenId, 'primary')}
          onRemove={(tokenId) => store.removeToken(tokenId, 'primary')}
          onAddToken={() => addToken('primary')}
        />
      </div>

      <div className="flex items-center gap-2 mt-1 relative">
        <span className="text-2xl font-title text-fg-3 -mb-2">{secondaryLabel}</span>
        <div className={cn('absolute left-1/2 -translate-x-1/2', store.direction.value === 'buy' ? 'mt-4' : 'mt-8')}>
          <Tooltip content={switchTooltip} side="right">
            <button
              onClick={handleDirectionSwitch}
              className={cn('group cursor-pointer transition-transform duration-200 hover:scale-110', store.direction.value === 'buy' && 'rotate-180')}
            >
              <BorderedThemedIcon icon={doubleDownIcon} size={46} />
            </button>
          </Tooltip>
        </div>
      </div>

      <div>
        <TokenList
          tokens={store.secondaryTokens.value}
          type="secondary"
          chainInfo={chainInfo}
          chainId={chainId}
          readOnly={false}
          onAmountChange={(tokenId, amount) => store.updateTokenAmount(tokenId, amount, 'secondary')}
          onTokenClick={(tokenId) => handleTokenClick(tokenId, 'secondary')}
          onRemove={(tokenId) => store.removeToken(tokenId, 'secondary')}
          onAddToken={() => addToken('secondary')}
        />
      </div>

      <InfoSection className="pt-3">
        <InfoRow
          label="Price impact"
          value={formattedQuote ? `${formattedQuote.priceImpact}%` : '--.--% '}
          icon="/icons/slippage.svg"
          iconLabel="Slippage"
          valueClassName={cn("font-numeric", formattedQuote ? "text-fg-0" : "text-muted-foreground")}
        />
        <InfoRow
          label="Spread"
          value={formattedQuote ? `${formattedQuote.spreadPercent}%` : '--.--% '}
          icon="/icons/fee.svg"
          iconLabel="Fee"
          valueClassName={cn("font-numeric", formattedQuote ? "text-fg-0" : "text-muted-foreground")}
        />
        <InfoRow
          label="Fees"
          value={formattedQuote ? `${parseFloat(formattedQuote.totalFee).toFixed(6)}` : '--.--'}
          icon="/icons/gas.svg"
          iconLabel="Fees"
          valueClassName={cn("font-numeric", formattedQuote ? "text-fg-0" : "text-muted-foreground")}
        />
        {quoteError && <div className="text-xs text-red-500 mt-1">{quoteError}</div>}
        {isMockMode && formattedQuote && (
          <div className="text-xs text-yellow-500 mt-1">Using estimated prices (no contract)</div>
        )}
      </InfoSection>

      <Button
        className="w-full mt-3 font-semibold"
        onClick={async () => {
          if (!isConnected) {
            onConnect();
          } else if (needsApproval) {
            await approve();
          } else {
            await executeSwap();
            onSwap();
          }
        }}
        variant={!isConnected || canSwap ? 'primary' : 'default'}
        disabled={isConnected && (!canSwap || swapLoading || approveLoading)}
        size="lg"
      >
        {!isConnected
          ? `Connect to ${actionVerb} ${primaryTokenSymbol}`
          : swapLoading
            ? 'Swapping...'
            : approveLoading
              ? 'Approving...'
              : needsApproval
                ? `Approve ${primaryTokenSymbol}`
                : quoteLoading
                  ? 'Getting quote...'
                  : `${actionVerb.charAt(0).toUpperCase()}${actionVerb.slice(1)}`
        }
      </Button>

      <TokenSelector
        isOpen={isTokenSelectorOpen}
        onClose={handleTokenSelectorClose}
        onSelect={handleTokenSelect}
        chainId={chainId}
        multiSelect={false}
        disabledTokens={
          editingTokenType === 'primary'
            ? store.primaryTokens.value.map((t: TokenData) => t.symbol).filter((s: string) => s !== '')
            : store.secondaryTokens.value.map((t: TokenData) => t.symbol).filter((s: string) => s !== '')
        }
      />
    </div>
  );

  if (bordered) {
    return (
      <div className="bg-bg-1 border border-border rounded-lg p-3">
        {content}
      </div>
    );
  }

  return content;
}