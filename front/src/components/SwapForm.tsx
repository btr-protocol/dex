import { useState, useEffect, useMemo } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { TokenRow } from '@components/TokenRow';
import { InfoRow, InfoSection } from '@components/ui/InfoRow';
import { BorderedThemedIcon, plusIcon, doubleDownIcon } from '@/components/ui/BorderedThemedIcon';
import { Dropdown, DropdownItem } from '@components/ui/Dropdown';
import { Tooltip } from '@components/ui/Tooltip';
import TokenSelector from '@components/TokenSelector';
import { cn } from '@utils/cn';
import { useSwap, formatQuote } from '@/hooks/useSwap';
import { formatUnits } from '@sdk/eth';
import { SwapStore, OrderType, TokenData } from '@/lib/swap/SwapStore';
import { DirectionToggle } from './Swap/DirectionToggle';

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

const ORDER_TYPE_OPTIONS: DropdownItem<OrderType>[] = [
  { value: 'market', label: 'Market' },
  { value: 'limit', label: 'Limit', disabled: true, tooltip: 'Limit orders not available yet' },
  { value: 'stop', label: 'Stop', disabled: true, tooltip: 'Stop orders not available yet' },
];

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

  const PlusSeparator = () => (
    <div className="relative h-0">
      <div className="absolute left-1/2 -translate-x-1/2 -top-[1.1rem] p-1">
        <BorderedThemedIcon icon={plusIcon} size={20} color="primary" />
      </div>
    </div>
  );

  const AddTokenButton = ({ onClick }: { onClick: () => void }) => (
    <button onClick={onClick} className="add-token-btn group relative w-full cursor-pointer">
      <div className="absolute left-1/2 -translate-x-1/2 -top-[1.1rem] p-1 transition-colors duration-150 group-hover:text-primary">
        <BorderedThemedIcon icon={plusIcon} size={20} className="transition-transform duration-150 group-hover:scale-140" />
      </div>
      <div className="w-full bg-bg-2 rounded-md py-0.5 text-fg-3 border-2 border-dashed border-border transition-all duration-150 group-hover:text-primary group-hover:bg-bg-primary group-hover:border-primary">
        <span className="text-sm font-medium">Add token</span>
      </div>
    </button>
  );

  const TokenList = ({ tokens, type, readOnly }: { tokens: TokenData[]; type: 'primary' | 'secondary'; readOnly: boolean }) => {
    const showRemoveButtons = tokens.length > 1;

    return (
      <div className="flex flex-col gap-1">
        {tokens.map((token, index) => (
          <div key={token.id}>
            {index > 0 && <PlusSeparator />}
            <TokenRow
              token={token.symbol}
              chain={chainInfo}
              chainId={chainId}
              amount={token.amount}
              onAmountChange={(value) => store.updateTokenAmount(token.id, value, type)}
              onTokenClick={() => handleTokenClick(token.id, type)}
              walletBalance={token.balance}
              usdValue={token.usdValue}
              readOnly={readOnly}
              onRemove={() => store.removeToken(token.id, type)}
              showRemove={showRemoveButtons}
            />
          </div>
        ))}
        <AddTokenButton onClick={() => addToken(type)} />
      </div>
    );
  };

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
        <TokenList tokens={store.primaryTokens.value} type="primary" readOnly={false} />
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
        <TokenList tokens={store.secondaryTokens.value} type="secondary" readOnly={false} />
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