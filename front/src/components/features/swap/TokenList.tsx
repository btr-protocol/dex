/**
 * TokenList component - renders list of tokens with add/remove buttons
 */

import { TokenRow } from '@components/shared/token';
import { TokenData } from '@/lib/swap/SwapStore';
import { PlusSeparator } from './PlusSeparator';
import { AddTokenButton } from './AddTokenButton';

interface TokenListProps {
  tokens: TokenData[];
  type: 'primary' | 'secondary';
  chainInfo: { name: string; icon: string };
  chainId?: number;
  readOnly?: boolean;
  onAmountChange: (tokenId: string, amount: string) => void;
  onTokenClick: (tokenId: string) => void;
  onRemove: (tokenId: string) => void;
  onAddToken: () => void;
}

export function TokenList({
  tokens,
  type: _type,
  chainInfo,
  chainId = 1,
  readOnly = false,
  onAmountChange,
  onTokenClick,
  onRemove,
  onAddToken,
}: TokenListProps) {
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
            onAmountChange={(value) => onAmountChange(token.id, value)}
            onTokenClick={() => onTokenClick(token.id)}
            walletBalance={token.balance}
            usdValue={token.usdValue}
            readOnly={readOnly}
            onRemove={() => onRemove(token.id)}
            showRemove={showRemoveButtons}
          />
        </div>
      ))}
      <AddTokenButton onClick={onAddToken} />
    </div>
  );
}
