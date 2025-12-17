/**
 * useWalletConnection - Consolidated wallet connection state management
 * Extracts 10 useState calls from WalletModal into reusable hook
 */
import { useState, useCallback } from 'preact/hooks';

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
  const [agreedToTerms, setAgreedToTerms] = useState(false);
  const [connectingWallet, setConnectingWallet] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [view, setView] = useState<'list' | 'qr'>(initialView);
  const [isLoadingWC, setIsLoadingWC] = useState(false);
  const [qrCodeUrl, setQrCodeUrl] = useState<string | null>(null);
  const [wcUri, setWcUri] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const reset = useCallback(() => {
    setView('list');
    setQrCodeUrl(null);
    setWcUri(null);
    setIsLoadingWC(false);
    setError('');
  }, []);

  const resetSearch = useCallback(() => {
    setSearchQuery('');
  }, []);

  const handleBack = useCallback(() => {
    setView('list');
    setQrCodeUrl(null);
    setWcUri(null);
    setIsLoadingWC(false);
  }, []);

  const startWalletConnect = useCallback(() => {
    setIsLoadingWC(true);
    setError('');
    setView('qr');
  }, []);

  const setWalletConnectError = useCallback((err: string) => {
    setError(err);
    setView('list');
    setIsLoadingWC(false);
  }, []);

  const copyUri = useCallback(async () => {
    if (!wcUri) return false;
    try {
      await navigator.clipboard.writeText(wcUri);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
      return true;
    } catch {
      return false;
    }
  }, [wcUri]);

  return {
    // State
    agreedToTerms,
    connectingWallet,
    error,
    searchQuery,
    view,
    isLoadingWC,
    qrCodeUrl,
    wcUri,
    copied,
    // Setters
    setAgreedToTerms,
    setConnectingWallet,
    setError,
    setSearchQuery,
    setView,
    setIsLoadingWC,
    setQrCodeUrl,
    setWcUri,
    setCopied,
    // Helpers
    reset,
    resetSearch,
    handleBack,
    startWalletConnect,
    setWalletConnectError,
    copyUri,
  };
}
