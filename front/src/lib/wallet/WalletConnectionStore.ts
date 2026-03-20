/**
 * WalletConnectionStore - Signal-based wallet connection state management
 * Replaces 9 useState calls in useWalletConnection.ts with centralized signal store
 * Optimizes batch operations (reset, handleBack, etc.)
 */
import { signal, computed, batch } from '@preact/signals';

export class WalletConnectionStore {
  // Terms agreement
  public agreedToTerms = signal(false);

  // Connection state
  public connectingWallet = signal<string | null>(null);
  public error = signal('');

  // UI state
  public searchQuery = signal('');
  public view = signal<'list' | 'qr'>('list');

  // WalletConnect state
  public isLoadingWC = signal(false);
  public qrCodeUrl = signal<string | null>(null);
  public wcUri = signal<string | null>(null);
  public copied = signal(false);

  // Computed: whether ready to connect
  public canConnect = computed(() =>
    this.agreedToTerms.value && !this.error.value
  );

  // Computed: whether in QR view
  public isQrView = computed(() => this.view.value === 'qr');

  // Computed: whether in list view
  public isListView = computed(() => this.view.value === 'list');

  // Computed: has active connection attempt
  public isConnecting = computed(() =>
    this.connectingWallet.value !== null || this.isLoadingWC.value
  );

  /**
   * Set terms agreement
   */
  public setAgreedToTerms(agreed: boolean) {
    this.agreedToTerms.value = agreed;
  }

  /**
   * Set connecting wallet
   */
  public setConnectingWallet(wallet: string | null) {
    this.connectingWallet.value = wallet;
  }

  /**
   * Set error message
   */
  public setError(error: string) {
    this.error.value = error;
  }

  /**
   * Set search query
   */
  public setSearchQuery(query: string) {
    this.searchQuery.value = query;
  }

  /**
   * Set view mode
   */
  public setView(view: 'list' | 'qr') {
    this.view.value = view;
  }

  /**
   * Set WalletConnect loading state
   */
  public setIsLoadingWC(loading: boolean) {
    this.isLoadingWC.value = loading;
  }

  /**
   * Set QR code URL
   */
  public setQrCodeUrl(url: string | null) {
    this.qrCodeUrl.value = url;
  }

  /**
   * Set WalletConnect URI
   */
  public setWcUri(uri: string | null) {
    this.wcUri.value = uri;
  }

  /**
   * Set copied state (auto-resets after 2s)
   */
  public setCopied(copied: boolean) {
    this.copied.value = copied;
    if (copied) {
      setTimeout(() => {
        this.copied.value = false;
      }, 2000);
    }
  }

  /**
   * Reset connection state (batched update)
   */
  public reset() {
    batch(() => {
      this.view.value = 'list';
      this.qrCodeUrl.value = null;
      this.wcUri.value = null;
      this.isLoadingWC.value = false;
      this.error.value = '';
    });
  }

  /**
   * Reset search query
   */
  public resetSearch() {
    this.searchQuery.value = '';
  }

  /**
   * Handle back navigation (batched update)
   */
  public handleBack() {
    batch(() => {
      this.view.value = 'list';
      this.qrCodeUrl.value = null;
      this.wcUri.value = null;
      this.isLoadingWC.value = false;
    });
  }

  /**
   * Start WalletConnect flow (batched update)
   */
  public startWalletConnect() {
    batch(() => {
      this.isLoadingWC.value = true;
      this.error.value = '';
      this.view.value = 'qr';
    });
  }

  /**
   * Set WalletConnect error and return to list (batched update)
   */
  public setWalletConnectError(error: string) {
    batch(() => {
      this.error.value = error;
      this.view.value = 'list';
      this.isLoadingWC.value = false;
    });
  }

  /**
   * Copy WalletConnect URI to clipboard
   * Returns promise that resolves to success boolean
   */
  public async copyUri(): Promise<boolean> {
    const uri = this.wcUri.value;
    if (!uri) return false;

    try {
      await navigator.clipboard.writeText(uri);
      this.setCopied(true);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Full reset (including terms agreement)
   */
  public resetAll() {
    batch(() => {
      this.agreedToTerms.value = false;
      this.connectingWallet.value = null;
      this.error.value = '';
      this.searchQuery.value = '';
      this.view.value = 'list';
      this.isLoadingWC.value = false;
      this.qrCodeUrl.value = null;
      this.wcUri.value = null;
      this.copied.value = false;
    });
  }
}

export const walletConnectionStore = new WalletConnectionStore();
