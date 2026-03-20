import { Icon } from '@components/ui/Icon';
import { Input } from '@components/ui/Input';
import { getTokenAddress, getTokenIcon, getChainIcon } from '@sdk/eth';
import { MaskIcon } from '@components/ui/MaskIcon';
import { Tooltip } from '@components/ui/FloatingPanel';
import { addNotification } from '@lib/notifications';
import { useExternalLink } from '@/lib/external-links';
import { useState } from 'preact/hooks';
import type { JSX } from 'preact';

export type TokenSymbol = string;

interface ChainInfo {
  name: string;
  icon: string;
}

interface TokenRowProps {
  token: TokenSymbol;
  chain: ChainInfo;
  amount: string;
  onAmountChange: (value: string) => void;
  onTokenClick: () => void;
  walletBalance: string;
  usdValue: string;
  readOnly: boolean;
  chainId?: number;
  onRemove?: () => void;
  showRemove?: boolean;
}

export function TokenRow({
  token,
  chain,
  amount,
  onAmountChange,
  onTokenClick,
  walletBalance,
  usdValue,
  readOnly,
  chainId = 1,
  onRemove,
  showRemove = false,
}: TokenRowProps) {
  const [copiedAddress, setCopiedAddress] = useState(false);
  const { openExternalLink } = useExternalLink();
  const hasToken = token && token.length > 0;
  const iconSrc = hasToken ? getTokenIcon(token) : null;
  const tokenAddress = hasToken ? getTokenAddress(token, chainId) : null;
  const shortAddress = tokenAddress
    ? `${tokenAddress.slice(0, 4)}..${tokenAddress.slice(-2)}`
    : '0x00..00';

  // Get mono chain icon (assuming chainId is available)
  const chainIcon = typeof chainId === 'number' ? getChainIcon(chainId) : chain.icon;
  const chainMonoIcon = chainIcon.replace('.svg', '-mono.svg');

  const handleCopyAddress = (e: JSX.TargetedMouseEvent<HTMLButtonElement>) => {
    e.stopPropagation();
    if (tokenAddress) {
      navigator.clipboard.writeText(tokenAddress);
      setCopiedAddress(true);
      addNotification('success', `Copied ${token} address to clipboard`);
      setTimeout(() => setCopiedAddress(false), 2000);
    }
  };

  const handleOpenExplorer = (e: JSX.TargetedMouseEvent<HTMLButtonElement>) => {
    e.stopPropagation();
    if (tokenAddress) {
      const explorers: Record<number, string> = {
        1: 'https://etherscan.io',
        56: 'https://bscscan.com',
        8453: 'https://basescan.org',
        42161: 'https://arbiscan.io',
      };
      const baseUrl = explorers[chainId] || 'https://etherscan.io';
      const explorerUrl = `${baseUrl}/token/${tokenAddress}`;
      openExternalLink(explorerUrl);
    }
  };

  return (
    <div className="bg-bg-2 rounded-md overflow-hidden">
      {hasToken && (
        <>
          {/* Chain Header */}
          <div className="flex items-center justify-between">
            <div className="rounded-br px-1.5 py-1 bg-bg-3 flex items-center text-fg-2 text-sm">
              <MaskIcon src={chainMonoIcon} size="sm" color="var(--fg-2)" aria-label={chain.name} />
              <span className='px-0.5'>{chain.name}</span>
            </div>
            <div className="flex items-center bg-bg-3 text-fg-2 rounded-bl">
              <button aria-label="Wallet balance" className="px-2 py-1 flex items-center gap-1 text-xs font-numeric">
                <Icon name="wallet" className="w-3.5 h-3.5" />
                <span>{walletBalance}</span>
              </button>
              {showRemove && onRemove && (
                <button
                  onClick={onRemove}
                  className="p-1 text-primary bg-bg-primary hover:text-red hover:bg-bg-negative transition-all"
                  aria-label="Remove token"
                >
                  <Icon name="x" className="w-3.5 h-3.5" />
                </button>
              )}
            </div>
          </div>
        </>
      )}

      {/* Token Selection Area */}
      <div className="px-3 pt-3 pb-4">
        {hasToken ? (
          <div className="flex items-center justify-between gap-4">
            {/* Left: Token info */}
            <button
              onClick={onTokenClick}
              className="flex items-center gap-2 hover:opacity-80 transition-opacity"
            >
              {/* Token icon */}
              <img src={iconSrc!} alt={token} className="w-10 h-10 shrink-0" />

              {/* Token details */}
              <div className="flex flex-col items-start">
                <div className="flex items-center gap-1">
                  <span className="text-2xl font-semibold text-fg-0 h-7">{token}</span>
                  <Icon name="caret-down" className="w-4 h-4 text-fg-2 mt-1" />
                </div>
                <div className="flex items-center gap-1">
                  <Tooltip content={`Copy ${tokenAddress}`} side="bottom">
                    <button
                      onClick={handleCopyAddress}
                      className="flex items-center gap-1 hover:text-primary transition-colors group"
                    >
                      <span className="text-sm text-fg-3 font-numeric group-hover:text-primary">{shortAddress}</span>
                      <Icon name="copy" className={`w-3 h-3 ${copiedAddress ? 'text-green' : 'text-fg-3'} group-hover:text-primary`} />
                    </button>
                  </Tooltip>
                  <Tooltip content="Go to explorer" side="bottom">
                    <button
                      onClick={handleOpenExplorer}
                      className="hover:text-primary transition-colors"
                    >
                      <Icon name="arrow-square-out" className="w-3 h-3 text-fg-3" />
                    </button>
                  </Tooltip>
                </div>
              </div>
            </button>

            {/* Right: Amount input */}
            <div className="flex flex-col items-end min-w-[140px]">
              <Input
                variant="amount"
                type="text"
                placeholder="0.00"
                value={amount}
                onChange={(e: Event) => onAmountChange((e.target as HTMLInputElement).value)}
                readOnly={readOnly}
                className="text-3xl font-medium px-0 bg-transparent border-0 focus:ring-0 h-7 -mr-0.5"
              />
              <span className="text-sm text-fg-3 font-numeric">{usdValue}</span>
            </div>
          </div>
        ) : (
          <button
            onClick={onTokenClick}
            className="flex items-center gap-2 py-2 hover:opacity-80 transition-opacity"
          >
            <Icon name="plus" className="w-5 h-5 text-fg-2" />
            <span className="text-lg text-fg-1 font-medium">Select token</span>
          </button>
        )}
      </div>
    </div>
  );
}
