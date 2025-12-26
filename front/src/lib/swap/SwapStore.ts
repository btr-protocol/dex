import { signal } from '@preact/signals';

export type OrderDirection = 'sell' | 'buy';
export type OrderType = 'market' | 'limit' | 'stop';

export interface TokenData {
  id: string;
  symbol: string;
  amount: string;
  usdValue: string;
  balance: string;
}

export class SwapStore {
  public direction = signal<OrderDirection>('sell');
  public orderType = signal<OrderType>('market');
  public primaryTokens = signal<TokenData[]>([]);
  public secondaryTokens = signal<TokenData[]>([]);
  public editingSide = signal<'primary' | 'secondary' | null>(null);

  constructor(initialPrimary: string, initialSecondary: string) {
    this.primaryTokens.value = [
      { id: '1', symbol: initialPrimary, amount: '', usdValue: '$0.00', balance: '0.00' }
    ];
    this.secondaryTokens.value = [
      { id: '1', symbol: initialSecondary, amount: '', usdValue: '$0.00', balance: '0.00' }
    ];
  }

  public setDirection = (dir: OrderDirection) => {
    this.direction.value = dir;
  };

  public setOrderType = (type: OrderType) => {
    this.orderType.value = type;
  };

  public updateTokenAmount = (id: string, value: string, side: 'primary' | 'secondary') => {
    const cleaned = value.replace(/[^0-9.]/g, '');
    const tokens = side === 'primary' ? this.primaryTokens : this.secondaryTokens;
    
    tokens.value = tokens.value.map(t => t.id === id ? { ...t, amount: cleaned } : t);
    this.editingSide.value = side;
  };

  public addToken = (side: 'primary' | 'secondary') => {
    const newToken: TokenData = {
      id: Date.now().toString(),
      symbol: '',
      amount: '',
      usdValue: '$0.00',
      balance: '0.00'
    };
    const tokens = side === 'primary' ? this.primaryTokens : this.secondaryTokens;
    tokens.value = [...tokens.value, newToken];
    return newToken.id;
  };

  public removeToken = (id: string, side: 'primary' | 'secondary') => {
    const tokens = side === 'primary' ? this.primaryTokens : this.secondaryTokens;
    if (tokens.value.length <= 1) return;
    tokens.value = tokens.value.filter(t => t.id !== id);
  };

  public setTokenSymbol = (id: string, symbol: string, side: 'primary' | 'secondary') => {
    const tokens = side === 'primary' ? this.primaryTokens : this.secondaryTokens;
    tokens.value = tokens.value.map(t => t.id === id ? { ...t, symbol } : t);
  };
}
