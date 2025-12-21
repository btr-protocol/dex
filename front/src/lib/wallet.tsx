import { createContext } from 'preact';
import { useContext, useState, useEffect, useCallback } from 'preact/hooks';
import type { ReactNode } from 'preact/compat';
import type { Address, Eip1193Provider, TransactionRequest, TypedData, Hex, TransactionReceipt } from '@sdk/eth';
import {
  requestAccounts,
  getAccounts,
  getChainId,
  getNativeBalance,
  switchChain as rpcSwitchChain,
  addChain,
  onAccountsChanged,
  onChainChanged,
  ethCall,
  sendTransaction,
  signMessage,
  signTypedData,
  waitForTransaction,
  getChain,
} from '@sdk/eth';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

interface WalletContextType {
  address?: Address;
  isConnected: boolean;
  isConnecting: boolean;
  connect: () => Promise<void>;
  connectWithProvider: (provider: Eip1193Provider) => Promise<void>;
  disconnect: () => void;
  switchChain: (chainId: number) => Promise<void>;
  provider?: Eip1193Provider;
  chainId?: number;
  // Utility methods
  getBalance: () => Promise<bigint>;
  call: (to: Address, data: Hex) => Promise<Hex>;
  sendTx: (tx: Omit<TransactionRequest, 'from'>) => Promise<Hex>;
  waitForTx: (hash: Hex) => Promise<TransactionReceipt>;
  sign: (message: string) => Promise<Hex>;
  signTyped: (data: TypedData) => Promise<Hex>;
}

// ─────────────────────────────────────────────────────────────
// Chain configurations - use SDK chains
// ─────────────────────────────────────────────────────────────

function getChainConfig(chainId: number) {
  const chain = getChain(chainId);
  if (!chain) return null;
  return {
    chainId: chain.id,
    chainName: chain.name,
    rpcUrls: chain.rpcUrls,
    nativeCurrency: chain.nativeCurrency,
    blockExplorerUrls: chain.blockExplorerUrls,
  };
}

// ─────────────────────────────────────────────────────────────
// Context
// ─────────────────────────────────────────────────────────────

const WalletContext = createContext<WalletContextType>({} as WalletContextType);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<Address>();
  const [isConnecting, setIsConnecting] = useState(false);
  const [provider, setProvider] = useState<Eip1193Provider>();
  const [chainId, setChainId] = useState<number>(1);

  // Check if already connected on mount
  useEffect(() => {
    if (typeof window === 'undefined' || !window.ethereum) return;

    const injectedProvider = window.ethereum as Eip1193Provider;

    // Try to get existing accounts (doesn't prompt user)
    getAccounts(injectedProvider)
      .then((accounts) => {
        if (accounts.length > 0) {
          setAddress(accounts[0]);
          setProvider(injectedProvider);
          // Get current chain
          getChainId(injectedProvider).then(setChainId).catch(() => {});
        }
      })
      .catch(() => {});
  }, []);

  // Subscribe to wallet events when provider is set
  useEffect(() => {
    if (!provider) return;

    const unsubAccounts = onAccountsChanged(provider, (accounts) => {
      if (accounts.length === 0) {
        setAddress(undefined);
      } else {
        setAddress(accounts[0]);
      }
    });

    const unsubChain = onChainChanged(provider, (newChainId) => {
      setChainId(newChainId);
    });

    return () => {
      unsubAccounts();
      unsubChain();
    };
  }, [provider]);

  const connect = useCallback(async () => {
    if (typeof window === 'undefined' || !window.ethereum) {
      throw new Error('No wallet found');
    }
    await connectWithProvider(window.ethereum as Eip1193Provider);
  }, []);

  const connectWithProvider = useCallback(async (newProvider: Eip1193Provider) => {
    if (!newProvider) {
      throw new Error('No provider specified');
    }

    try {
      setIsConnecting(true);
      const accounts = await requestAccounts(newProvider);

      if (accounts.length === 0) {
        throw new Error('No accounts returned');
      }

      setAddress(accounts[0]);
      setProvider(newProvider);

      // Get current chain
      const currentChainId = await getChainId(newProvider);
      setChainId(currentChainId);
    } catch (error) {
      console.error('Failed to connect', error);
      throw error;
    } finally {
      setIsConnecting(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    setAddress(undefined);
    setProvider(undefined);
  }, []);

  const switchChain = useCallback(async (id: number) => {
    if (!provider) return;

    try {
      await rpcSwitchChain(provider, id);
      setChainId(id);
    } catch (error) {
      // If chain not added, try to add it
      const errMsg = error instanceof Error ? error.message : String(error);
      if (errMsg.includes('not added') || (error as { code?: number })?.code === 4902) {
        const config = getChainConfig(id);
        if (config) {
          await addChain(provider, config);
          await rpcSwitchChain(provider, id);
          setChainId(id);
        } else {
          throw new Error(`Unknown chain ${id}`);
        }
      } else {
        throw error;
      }
    }
  }, [provider]);

  // Utility methods
  const getBalance = useCallback(async (): Promise<bigint> => {
    if (!provider || !address) throw new Error('Not connected');
    return getNativeBalance(provider, address);
  }, [provider, address]);

  const call = useCallback(async (to: Address, data: Hex): Promise<Hex> => {
    if (!provider) throw new Error('Not connected');
    return ethCall(provider, to, data);
  }, [provider]);

  const sendTx = useCallback(async (tx: Omit<TransactionRequest, 'from'>): Promise<Hex> => {
    if (!provider || !address) throw new Error('Not connected');
    return sendTransaction(provider, { ...tx, from: address } as TransactionRequest);
  }, [provider, address]);

  const waitForTx = useCallback(async (hash: Hex): Promise<TransactionReceipt> => {
    if (!provider) throw new Error('Not connected');
    return waitForTransaction(provider, hash);
  }, [provider]);

  const sign = useCallback(async (message: string): Promise<Hex> => {
    if (!provider || !address) throw new Error('Not connected');
    return signMessage(provider, address, message);
  }, [provider, address]);

  const signTyped = useCallback(async (data: TypedData): Promise<Hex> => {
    if (!provider || !address) throw new Error('Not connected');
    return signTypedData(provider, address, data);
  }, [provider, address]);

  return (
    <WalletContext.Provider
      value={{
        address,
        isConnected: !!address,
        isConnecting,
        connect,
        connectWithProvider,
        disconnect,
        switchChain,
        provider,
        chainId,
        getBalance,
        call,
        sendTx,
        waitForTx,
        sign,
        signTyped,
      }}
    >
      {children}
    </WalletContext.Provider>
  ) as JSX.Element;
}


export function useWallet() {
  const context = useContext(WalletContext);
  if (!context) {
    throw new Error('useWallet must be used within a WalletProvider');
  }
  return context;
}
