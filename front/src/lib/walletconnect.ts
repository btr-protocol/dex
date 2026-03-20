/**
 * Minimal WalletConnect v2 integration using sign-client
 * Lazy loaded to avoid bundling heavy dependencies upfront
 */

import type { Address, Eip1193Provider } from '@sdk/eth';
import { logger } from '@sdk/utils';

const log = logger.withContext('walletConnect');

// WalletConnect Project ID - get one from https://cloud.reown.com
const WC_PROJECT_ID = import.meta.env.VITE_WC_PROJECT_ID || ''; // TODO: Add to env

let signClient: any | null = null;
let activeSession: any | null = null;

async function getSignClient() {
  if (!signClient) {
    const SignClient = (await import('@walletconnect/sign-client')).default;
    signClient = await SignClient.init({
      projectId: WC_PROJECT_ID,
      metadata: {
        name: 'BTR DEX',
        description: 'Adaptive Inventory Market Maker',
        url: typeof window !== 'undefined' ? window.location.origin : 'https://btr.dev',
        icons: [typeof window !== 'undefined' ? `${window.location.origin}/brand/logo-b.svg` : 'https://btr.dev/brand/logo-b.svg'],
      },
    });
  }
  return signClient;
}

export type WalletConnectCallbacks = {
  onUri: (uri: string) => void;
  onConnected: () => void;
  onError: (error: Error) => void;
};

export interface WalletConnectResult {
  provider: Eip1193Provider;
  address: Address;
  disconnect: () => Promise<void>;
}

/**
 * Connect using WalletConnect sign-client
 * Returns an EIP-1193 provider that works like any injected wallet
 */
export async function connectWithWalletConnect(
  callbacks: WalletConnectCallbacks
): Promise<WalletConnectResult> {
  if (!WC_PROJECT_ID) {
    throw new Error('WalletConnect Project ID not configured. Please set VITE_WC_PROJECT_ID in your environment.');
  }

  const client = await getSignClient();

  // Propose a session (yields a WC URI for QR)
  const { uri, approval } = await client.connect({
    optionalNamespaces: {
      eip155: {
        methods: [
          'eth_sendTransaction',
          'eth_signTransaction',
          'eth_sign',
          'personal_sign',
          'eth_signTypedData',
          'eth_signTypedData_v4',
        ],
        chains: ['eip155:1'], // Mainnet - add more as needed
        events: ['accountsChanged', 'chainChanged'],
      },
    },
  });

  if (uri) {
    callbacks.onUri(uri);
  }

  // Wait for wallet approval (user scans QR and approves)
  const session = await approval();
  activeSession = session;
  callbacks.onConnected();

  // Extract account & topic from namespaces
  const accounts = session.namespaces.eip155.accounts as string[];
  const first = accounts[0];
  if (!first) throw new Error('No account returned from WalletConnect');

  const [, , address] = first.split(':');
  const topic: string = session.topic;

  // Minimal EIP-1193 provider backed by SignClient
  const provider: Eip1193Provider = {
    async request({ method, params }: { method: string; params?: unknown[] }): Promise<unknown> {
      // Handle some methods locally
      if (method === 'eth_accounts' || method === 'eth_requestAccounts') {
        return [address];
      }
      if (method === 'eth_chainId') {
        return '0x1'; // mainnet
      }

      const chainId = 'eip155:1';
      return client.request({
        topic,
        chainId,
        request: { method, params: params ?? [] },
      });
    },
    on(event: string, listener: (...args: unknown[]) => void) {
      if (event === 'accountsChanged' || event === 'chainChanged') {
        client.on('session_event', (ev: any) => {
          if (ev.topic !== topic) return;
          const name = ev.params?.event?.name;
          const data = ev.params?.event?.data;
          if (name === event) {
            listener(data);
          }
        });
      }
    },
    removeListener() {
      // WalletConnect doesn't support removing individual listeners
    },
  };

  // Disconnect function
  const disconnect = async () => {
    if (activeSession && client) {
      try {
        await client.disconnect({
          topic: activeSession.topic,
          reason: { code: 6000, message: 'User disconnected' },
        });
      } catch (e) {
        log.warn('WalletConnect disconnect error', e);
      }
      activeSession = null;
    }
  };

  return {
    provider,
    address: address as Address,
    disconnect,
  };
}

/**
 * Generate QR code SVG from WalletConnect URI
 */
export async function generateQRCode(uri: string): Promise<string> {
  const { createQR } = await import('../utils/qrcode');
  const svg = createQR(uri, { logo: true });
  // Convert SVG to data URL
  return `data:image/svg+xml;base64,${btoa(svg)}`;
}

/**
 * Check if there's an active WalletConnect session
 */
export function hasActiveSession(): boolean {
  return activeSession !== null;
}

/**
 * Get current session info
 */
export function getSessionInfo() {
  if (!activeSession) return null;
  return {
    topic: activeSession.topic,
    peer: activeSession.peer?.metadata,
  };
}
