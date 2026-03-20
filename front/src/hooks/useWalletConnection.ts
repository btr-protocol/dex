/**
 * useWalletConnection - Consolidated wallet connection state management
 * Uses signal-based WalletConnectionStore for optimized batch operations
 */
import { useEffect } from 'preact/hooks';
import { walletConnectionStore } from '@/lib/wallet/WalletConnectionStore';

export interface WalletConnectionState {
  agreedToTerms: boolean;
  connectingWallet: string | null;
  error: string;
  searchQuery: string;
  view: 'list' | 'qr';
  isLoadingWC: boolean;
  qrCodeUrl: string | null;
  wcUri: string | null;
  copied: boolean;
}

export function useWalletConnection(initialView: 'list' | 'qr' = 'list') {
  // Use signal-based WalletConnectionStore singleton
  const store = walletConnectionStore;

  // Set initial view
  useEffect(() => {
    store.setView(initialView);
  }, [initialView]);

  return {
    // State (signal values)
    agreedToTerms: store.agreedToTerms.value,
    connectingWallet: store.connectingWallet.value,
    error: store.error.value,
    searchQuery: store.searchQuery.value,
    view: store.view.value,
    isLoadingWC: store.isLoadingWC.value,
    qrCodeUrl: store.qrCodeUrl.value,
    wcUri: store.wcUri.value,
    copied: store.copied.value,
    // Setters (bound methods)
    setAgreedToTerms: (v: boolean) => store.setAgreedToTerms(v),
    setConnectingWallet: (v: string | null) => store.setConnectingWallet(v),
    setError: (v: string) => store.setError(v),
    setSearchQuery: (v: string) => store.setSearchQuery(v),
    setView: (v: 'list' | 'qr') => store.setView(v),
    setIsLoadingWC: (v: boolean) => store.setIsLoadingWC(v),
    setQrCodeUrl: (v: string | null) => store.setQrCodeUrl(v),
    setWcUri: (v: string | null) => store.setWcUri(v),
    setCopied: (v: boolean) => store.setCopied(v),
    // Helpers (batched methods)
    reset: () => store.reset(),
    resetSearch: () => store.resetSearch(),
    handleBack: () => store.handleBack(),
    startWalletConnect: () => store.startWalletConnect(),
    setWalletConnectError: (err: string) => store.setWalletConnectError(err),
    copyUri: () => store.copyUri(),
  };
}
