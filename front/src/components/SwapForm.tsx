import { useState, useEffect, useMemo } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { ButtonGroup } from '@components/ui/ButtonGroup';
import { TokenRow } from '@components/TokenRow';
import { InfoRow, InfoSection } from '@components/ui/InfoRow';
import { BorderedThemedIcon, plusIcon, doubleDownIcon } from '@/components/ui/BorderedThemedIcon';
import { Dropdown, DropdownItem } from '@components/ui/Dropdown';
import { Tooltip } from '@components/ui/Tooltip';
import TokenSelector from '@components/TokenSelector';
import { cn } from '@utils/cn';
import { useSwap, formatQuote } from '@/hooks/useSwap';
import { formatUnits } from '@sdk/eth';

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
}

interface TokenData {
  id: string;
  symbol: string;
  amount: string;
  usdValue: string;
  balance: string;
}

type OrderDirection = 'sell' | 'buy';
type OrderType = 'market' | 'limit' | 'stop';
type EditingSide = 'primary' | 'secondary' | null;

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
  onTokenChange
}: SwapFormProps) {
  // Order state
  const [direction, setDirection] = useState<OrderDirection>('sell');
  const [orderType, setOrderType] = useState<OrderType>('market');

  // Token state - primary is always what user "has", secondary is what they "want"
  const [primaryTokens, setPrimaryTokens] = useState<TokenData[]>([
    { id: '1', symbol: initialPrimaryToken, amount: '', usdValue: '$0.00', balance: '0.00' }
  ]);
  const [secondaryTokens, setSecondaryTokens] = useState<TokenData[]>([
    { id: '1', symbol: initialSecondaryToken, amount: '', usdValue: '$0.00', balance: '0.00' }
  ]);

  // Track which side user is actively editing (for two-way binding)
  const [editingSide, setEditingSide] = useState<EditingSide>(null);

  // Get swap quote from contract
  const primaryToken = primaryTokens[0]?.symbol || '';
  const secondaryToken = secondaryTokens[0]?.symbol || '';
  const primaryAmount = primaryTokens[0]?.amount || '';

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

  // Sync with parent when initial tokens change (e.g., from URL params)
  useEffect(() => {
    setPrimaryTokens(prev => prev.map((t, i) => i === 0 ? { ...t, symbol: initialPrimaryToken } : t));
  }, [initialPrimaryToken]);

  useEffect(() => {
    setSecondaryTokens(prev => prev.map((t, i) => i === 0 ? { ...t, symbol: initialSecondaryToken } : t));
  }, [initialSecondaryToken]);

  // Notify parent when tokens change
  useEffect(() => {
    const primary = primaryTokens[0]?.symbol;
    const secondary = secondaryTokens[0]?.symbol;
    if (primary && secondary && onTokenChange) {
      onTokenChange(primary, secondary);
    }
  }, [primaryTokens, secondaryTokens, onTokenChange]);

  // Token selector state
  const [isTokenSelectorOpen, setIsTokenSelectorOpen] = useState(false);
  const [editingTokenId, setEditingTokenId] = useState<string | null>(null);
  const [editingTokenType, setEditingTokenType] = useState<'primary' | 'secondary'>('primary');

  // Update secondary amount when quote changes
  useEffect(() => {
    if (quote && editingSide === 'primary') {
      const estimatedOut = formatUnits(quote.amountOut, 18);
      setSecondaryTokens(prev => prev.map((t, i) => i === 0 ? { ...t, amount: estimatedOut } : t));
    }
  }, [quote, editingSide]);

  const handleAmountChange = (id: string, value: string, type: 'primary' | 'secondary') => {
    const cleaned = value.replace(/[^0-9.]/g, '');

    if (type === 'primary') {
      setPrimaryTokens(prev => prev.map(t => t.id === id ? { ...t, amount: cleaned } : t));
      setEditingSide('primary');
      // Secondary amount will be updated by quote effect
    } else {
      setSecondaryTokens(prev => prev.map(t => t.id === id ? { ...t, amount: cleaned } : t));
      setEditingSide('secondary');
      // Note: reverse quote not implemented yet - would need quoteBuy
    }
  };

  const addToken = (type: 'primary' | 'secondary') => {
    const newToken: TokenData = {
      id: Date.now().toString(),
      symbol: '',
      amount: '',
      usdValue: '$0.00',
      balance: '0.00'
    };

    if (type === 'primary') {
      setPrimaryTokens(prev => [...prev, newToken]);
    } else {
      setSecondaryTokens(prev => [...prev, newToken]);
    }

    setEditingTokenId(newToken.id);
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

    // Check if selected token exists on the opposite side
    if (editingTokenType === 'primary') {
      const oppositeToken = secondaryTokens.find(t => t.symbol === selectedToken);
      const currentToken = primaryTokens.find(t => t.id === editingTokenId);

      if (oppositeToken && currentToken?.symbol) {
        // Swap: move current token to opposite side, selected token to current side
        setSecondaryTokens(prev => prev.map(t =>
          t.symbol === selectedToken ? { ...t, symbol: currentToken.symbol } : t
        ));
      }

      setPrimaryTokens(prev => prev.map(t =>
        t.id === editingTokenId ? { ...t, symbol: selectedToken } : t
      ));
    } else {
      const oppositeToken = primaryTokens.find(t => t.symbol === selectedToken);
      const currentToken = secondaryTokens.find(t => t.id === editingTokenId);

      if (oppositeToken && currentToken?.symbol) {
        // Swap: move current token to opposite side, selected token to current side
        setPrimaryTokens(prev => prev.map(t =>
          t.symbol === selectedToken ? { ...t, symbol: currentToken.symbol } : t
        ));
      }

      setSecondaryTokens(prev => prev.map(t =>
        t.id === editingTokenId ? { ...t, symbol: selectedToken } : t
      ));
    }
  };

  const handleTokenSelectorClose = () => {
    // Remove empty token if no selection was made
    if (editingTokenId) {
      const token = editingTokenType === 'primary'
        ? primaryTokens.find(t => t.id === editingTokenId)
        : secondaryTokens.find(t => t.id === editingTokenId);

      if (token && !token.symbol) {
        removeToken(editingTokenId, editingTokenType);
      }
    }

    setIsTokenSelectorOpen(false);
    setEditingTokenId(null);
  };

  const removeToken = (id: string, type: 'primary' | 'secondary') => {
    if (type === 'primary' && primaryTokens.length <= 1) return;
    if (type === 'secondary' && secondaryTokens.length <= 1) return;

    if (type === 'primary') {
      setPrimaryTokens(prev => prev.filter(t => t.id !== id));
    } else {
      setSecondaryTokens(prev => prev.filter(t => t.id !== id));
    }
  };

  // Switch direction
  const handleDirectionSwitch = () => {
    setDirection(prev => prev === 'sell' ? 'buy' : 'sell');
    // Don't swap tokens - the direction change itself is the inversion
  };

  const canSwap = isConnected && primaryTokens.some(t => t.amount && t.symbol);

  // Get the primary token symbol for button text
  const primaryTokenSymbol = primaryTokens[0]?.symbol || 'token';

  // Section label and button text based on direction
  const secondaryLabel = direction === 'sell' ? 'For' : 'With';
  const switchTooltip = direction === 'sell' ? 'Buy instead' : 'Sell instead';
  const actionVerb = direction === 'sell' ? 'sell' : 'buy';

  // Plus separator between token rows
  const PlusSeparator = () => (
    <div className="relative h-0">
      <div className="absolute left-1/2 -translate-x-1/2 -top-[1.1rem] p-1">
        <BorderedThemedIcon icon={plusIcon} size={20} color="primary" />
      </div>
    </div>
  );

  // Add token button with + icon floating above
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

  // Token list with + separators between items
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
              onAmountChange={(value) => handleAmountChange(token.id, value, type)}
              onTokenClick={() => handleTokenClick(token.id, type)}
              walletBalance={token.balance}
              usdValue={token.usdValue}
              readOnly={readOnly}
              onRemove={() => removeToken(token.id, type)}
              showRemove={showRemoveButtons}
            />
          </div>
        ))}
        <AddTokenButton onClick={() => addToken(type)} />
      </div>
    );
  };

  // Direction toggle component - glassy segmented control
  const DirectionToggle = () => {
    return (
      <ButtonGroup direction="horizontal" variant="outlined" className="bg-white/5">
        <Button
          onClick={() => setDirection('sell')}
          size="compact-xl"
          variant="ghost"
          className={cn("font-title min-w-[4rem]", direction === 'sell' ? 'btn-selected' : 'btn-unselected')}
        >
          Sell
        </Button>
        <Button
          onClick={() => setDirection('buy')}
          size="compact-xl"
          variant="ghost"
          className={cn("font-title min-w-[4rem]", direction === 'buy' ? 'btn-selected' : 'btn-unselected')}
        >
          Buy
        </Button>
      </ButtonGroup>
    );
  };

  const content = (
    <>
      <div className="relative flex flex-col gap-2">
        {/* Header: Direction Toggle + Order Type */}
        <div className="flex items-center justify-between -mb-0.5">
          <DirectionToggle />
          <Dropdown
            items={ORDER_TYPE_OPTIONS}
            value={orderType}
            onChange={(v) => setOrderType(v as OrderType)}
            size="compact-xl"
            styleVariant="glass"
            className="min-w-[120px] bg-white/5 border border-white/10"
          />
        </div>

        {/* Primary Section - no label, direction is shown in toggle */}
        <div>
          <TokenList tokens={primaryTokens} type="primary" readOnly={false} />
        </div>

        {/* Secondary Section with label + arrow inline */}
        <div className="flex items-center gap-2 mt-1 relative">
          <span className="text-2xl font-title text-fg-3 -mb-2">{secondaryLabel}</span>
          <div className={cn(
            'absolute left-1/2 -translate-x-1/2',
            direction === 'buy' && 'mt-4' || 'mt-8'
          )}>
            <Tooltip content={switchTooltip} side="right">
              <button
                onClick={handleDirectionSwitch}
                className={cn(
                  'group cursor-pointer transition-transform duration-200 hover:scale-110',
                  direction === 'buy' && 'rotate-180'
                )}
              >
                <BorderedThemedIcon icon={doubleDownIcon} size={46} />
              </button>
            </Tooltip>
          </div>
        </div>

        <div>
          <TokenList tokens={secondaryTokens} type="secondary" readOnly={false} />
        </div>

        {/* Breakdown Section */}
        <InfoSection className="pt-3">
          <InfoRow
            label="Price impact"
            value={formattedQuote ? `${formattedQuote.priceImpact}%` : '--.--% '}
            icon="/icons/slippage.svg"
            iconLabel="Slippage"
            valueClassName={cn(
              "font-numeric",
              formattedQuote ? "text-fg-0" : "text-muted-foreground"
            )}
          />
          <InfoRow
            label="Spread"
            value={formattedQuote ? `${formattedQuote.spreadPercent}%` : '--.--% '}
            icon="/icons/fee.svg"
            iconLabel="Fee"
            valueClassName={cn(
              "font-numeric",
              formattedQuote ? "text-fg-0" : "text-muted-foreground"
            )}
          />
          <InfoRow
            label="Fees"
            value={formattedQuote ? `${parseFloat(formattedQuote.totalFee).toFixed(6)}` : '--.--'}
            icon="/icons/gas.svg"
            iconLabel="Fees"
            valueClassName={cn(
              "font-numeric",
              formattedQuote ? "text-fg-0" : "text-muted-foreground"
            )}
          />
          {quoteError && (
            <div className="text-xs text-red-500 mt-1">{quoteError}</div>
          )}
          {isMockMode && formattedQuote && (
            <div className="text-xs text-yellow-500 mt-1">Using estimated prices (no contract)</div>
          )}
        </InfoSection>

        {/* Action Button */}
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
      </div>

      {/* Token Selector Modal */}
      <TokenSelector
        isOpen={isTokenSelectorOpen}
        onClose={handleTokenSelectorClose}
        onSelect={handleTokenSelect}
        chainId={chainId}
        multiSelect={false}
        disabledTokens={
          editingTokenType === 'primary'
            ? primaryTokens.map(t => t.symbol).filter(s => s !== '')
            : secondaryTokens.map(t => t.symbol).filter(s => s !== '')
        }
      />
    </>
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
