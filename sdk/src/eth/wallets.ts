/**
 * Wallet Detection & Configuration
 * EIP-6963 + comprehensive legacy fallbacks
 */

import type { Eip1193Provider } from './types';

// Declare window for environments where it may not exist (Node.js)
// eslint-disable-next-line @typescript-eslint/no-explicit-any
declare const window: any;

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface WalletInfo {
  id: string;
  name: string;
  icon: string;
  provider: Eip1193Provider;
  rdns?: string;
  detected: boolean;
}

export interface Eip6963Detail {
  info: { uuid: string; name: string; icon: string; rdns: string };
  provider: Eip1193Provider;
}

// ─────────────────────────────────────────────────────────────
// Wallet Database (single source of truth)
// ─────────────────────────────────────────────────────────────

interface WalletDef {
  id: string;
  name: string;
  url: string;           // download URL
  rdns?: string;         // EIP-6963 reverse domain
  path?: string;         // window.* path for legacy detection
  flag?: string;         // ethereum.isX flag
  icon?: string;         // custom icon path (defaults to /wallets/{id}.svg)
  mobile?: boolean;      // available on mobile
  wc?: boolean;          // show in WalletConnect grid
  discoverMobile?: boolean;  // show in mobile discover section
  discoverDesktop?: boolean; // show in desktop discover section
}

export const WALLETS: WalletDef[] = [
  // Major wallets
  { id: 'metamask', name: 'MetaMask', url: 'https://metamask.io', rdns: 'io.metamask', flag: 'isMetaMask', mobile: true, wc: true, discoverMobile: true, discoverDesktop: true },
  { id: 'rabby', name: 'Rabby', url: 'https://rabby.io', rdns: 'io.rabby', path: 'rabby', flag: 'isRabby', discoverDesktop: true },
  { id: 'rainbow', name: 'Rainbow', url: 'https://rainbow.me', rdns: 'me.rainbow', path: 'rainbow', flag: 'isRainbow', mobile: true, wc: true, discoverMobile: true, discoverDesktop: true },
  { id: 'phantom', name: 'Phantom', url: 'https://phantom.com', rdns: 'app.phantom', path: 'phantom.ethereum', flag: 'isPhantom', mobile: true, wc: true, discoverMobile: true, discoverDesktop: true },
  { id: 'trust', name: 'Trust', url: 'https://trustwallet.com', rdns: 'com.trustwallet.app', path: 'trustwallet', flag: 'isTrust', mobile: true, wc: true, discoverMobile: true, discoverDesktop: true },
  { id: 'base', name: 'Base', url: 'https://wallet.coinbase.com', rdns: 'com.coinbase.wallet', path: 'coinbaseWalletExtension', flag: 'isCoinbaseWallet', mobile: true, wc: true, discoverMobile: true, discoverDesktop: true },
  { id: 'safe', name: 'Safe', url: 'https://safe.global', rdns: 'global.safe.wallet', wc: true },
  { id: 'backpack', name: 'Backpack', url: 'https://backpack.app', rdns: 'app.backpack', path: 'backpack.ethereum', flag: 'isBackpack' },

  // Hardware wallets
  { id: 'ledger', name: 'Ledger', url: 'https://ledger.com', wc: true },
  { id: 'trezor', name: 'Trezor', url: 'https://trezor.io', wc: true },
  { id: 'tangem', name: 'Tangem', url: 'https://tangem.com', wc: true },

  // Institutional
  { id: 'copper', name: 'Copper', url: 'https://copper.co', wc: true },
  { id: 'bitgo', name: 'BitGo', url: 'https://bitgo.com', wc: true },
  { id: 'fireblocks', name: 'Fireblocks', url: 'https://fireblocks.com', wc: true },

  // Exchange wallets
  { id: 'binance', name: 'Binance', url: 'https://www.binance.com', path: 'BinanceChain', flag: 'isBinance', wc: true },
  { id: 'okx', name: 'OKX', url: 'https://web3.okx.com', rdns: 'com.okex.wallet', path: 'okxwallet', flag: 'isOkxWallet', wc: true, discoverMobile: true, discoverDesktop: true },
  { id: 'bitget', name: 'Bitget', url: 'https://web3.bitget.com', rdns: 'com.bitget.wallet', path: 'bitkeep.ethereum', flag: 'isBitKeep', wc: true },
  { id: 'gate', name: 'Gate', url: 'https://web3.gate.io', rdns: 'io.gate.wallet', path: 'gatewallet', flag: 'isGateWallet', wc: true },
  { id: 'bybit', name: 'Bybit', url: 'https://www.bybit.com/en/web3', wc: true },
  { id: 'kucoin', name: 'KuCoin', url: 'https://kucoin.com', wc: true },

  // DeFi wallets
  { id: 'zerion', name: 'Zerion', url: 'https://zerion.io', rdns: 'io.zerion.wallet', path: 'zerionWallet', flag: 'isZerion' },
  { id: 'tokenpocket', name: 'TokenPocket', url: 'https://tokenpocket.pro', rdns: 'pro.tokenpocket', path: 'tokenpocket.ethereum', flag: 'isTokenPocket' },
  { id: 'coin98', name: 'Coin98', url: 'https://coin98.com', rdns: 'com.coin98', path: 'coin98.provider', flag: 'isCoin98' },
  { id: 'onekey', name: 'OneKey', url: 'https://onekey.so', rdns: 'so.onekey.wallet', path: '$onekey.ethereum', flag: 'isOneKey' },
  { id: 'family', name: 'Family', url: 'https://family.co', rdns: 'co.family.wallet', wc: true, discoverMobile: true },
  { id: '1inch', name: '1inch', url: 'https://1inch.io/wallet', rdns: 'io.1inch.wallet', wc: true, discoverMobile: true },
  { id: 'uniswap', name: 'Uniswap', url: 'https://wallet.uniswap.org', rdns: 'org.uniswap', wc: true, discoverMobile: true },
  { id: 'imtoken', name: 'imToken', url: 'https://token.im', rdns: 'im.token', wc: true },
  { id: 'safepal', name: 'SafePal', url: 'https://safepal.com', rdns: 'com.safepal', path: 'safepalProvider', flag: 'isSafePal', wc: true },
  { id: 'argent', name: 'Argent', url: 'https://argent.xyz', rdns: 'xyz.argent', wc: true },

  // Browser & other
  { id: 'brave', name: 'Brave', url: 'https://brave.com/wallet', rdns: 'com.brave.wallet', flag: 'isBraveWallet' },
  { id: 'frame', name: 'Frame', url: 'https://frame.sh', rdns: 'sh.frame', path: 'frame', flag: 'isFrame' },
  { id: 'ctrl', name: 'Ctrl', url: 'https://ctrl.xyz', rdns: 'xyz.ctrl', path: 'xfi.ethereum', flag: 'isXDEFI' },
  { id: 'exodus', name: 'Exodus', url: 'https://exodus.com', rdns: 'com.exodus', path: 'exodus.ethereum', flag: 'isExodus' },
  { id: 'tally', name: 'Taho', url: 'https://taho.xyz', rdns: 'xyz.taho', path: 'tally', flag: 'isTally' },
  { id: 'core', name: 'Core', url: 'https://core.app', rdns: 'app.core.extension', path: 'avalanche', flag: 'isAvalanche' },
  { id: 'zeal', name: 'Zeal', url: 'https://zeal.app', rdns: 'app.zeal' },
  { id: 'nightly', name: 'Nightly', url: 'https://nightly.app', rdns: 'app.nightly' },
  { id: 'guarda', name: 'Guarda', url: 'https://guarda.com' },
];

// Build lookup maps from WALLETS array
const byId = new Map(WALLETS.map(w => [w.id, w]));
const byRdns = new Map(WALLETS.filter(w => w.rdns).map(w => [w.rdns!, w.id]));

// Curated lists derived from WALLETS
export const WC_ICONS = WALLETS.filter(w => w.wc).map(w => w.id);
export const DISCOVER_MOBILE = WALLETS.filter(w => w.discoverMobile).map(w => w.id);
export const DISCOVER_DESKTOP = WALLETS.filter(w => w.discoverDesktop).map(w => w.id);

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const win = (): any => typeof window !== 'undefined' ? window : null;

function getPath(path: string): Eip1193Provider | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let obj: any = win();
    for (const p of path.split('.')) obj = obj?.[p];
    return obj?.request ? obj : null;
  } catch {
    return null;
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function hasFlag(p: any, f: string): boolean {
  try {
    return !!p?.[f];
  } catch {
    return false;
  }
}

function multiProviders(): Eip1193Provider[] {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const p: any = win()?.ethereum?.providers;
    return Array.isArray(p) ? p : [];
  } catch {
    return [];
  }
}

export const isMobile = () => typeof navigator !== 'undefined' && /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
export const getIcon = (id: string) => byId.get(id)?.icon || `/wallets/${id}.svg`;
export const getDownloadUrl = (id: string) => byId.get(id)?.url || null;
export const getName = (id: string) => byId.get(id)?.name || id;
export const getTooltip = (id: string) => {
  const w = byId.get(id);
  return w ? `${w.name}${w.mobile ? ' Mobile' : ''}` : id;
};

// ─────────────────────────────────────────────────────────────
// Legacy Detection
// ─────────────────────────────────────────────────────────────

export function detectLegacy(): WalletInfo[] {
  const w = win();
  if (!w) return [];

  const multi = multiProviders();
  const detected: WalletInfo[] = [];
  const seen = new Set<string>();

  for (const def of WALLETS) {
    if (!def.path && !def.flag) continue; // No legacy detection possible

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let provider: any = null;

    // 1. Check dedicated global
    if (def.path) provider = getPath(def.path);

    // 2. Check multi-provider array
    if (!provider && def.flag) provider = multi.find(p => hasFlag(p, def.flag!));

    // 3. Check window.ethereum
    if (!provider && def.flag && hasFlag(w.ethereum, def.flag)) provider = w.ethereum;

    // Special: MetaMask shouldn't be Rabby
    if (def.id === 'metamask' && provider?.isRabby) continue;

    if (provider && !seen.has(def.id)) {
      seen.add(def.id);
      detected.push({ id: def.id, name: def.name, icon: getIcon(def.id), provider, detected: true });
    }
  }

  // Fallback: generic injected
  if (!detected.length && w.ethereum?.request) {
    detected.push({ id: 'injected', name: 'Browser Wallet', icon: '/wallets/wallet.svg', provider: w.ethereum, detected: true });
  }

  return detected;
}

// ─────────────────────────────────────────────────────────────
// EIP-6963 Store
// ─────────────────────────────────────────────────────────────

export const eip6963Providers: Eip6963Detail[] = [];

if (typeof window !== 'undefined') {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  window.addEventListener('eip6963:announceProvider', (e: any) => {
    const detail: Eip6963Detail = e.detail;
    if (!eip6963Providers.some(p => p.info.uuid === detail.info.uuid)) {
      eip6963Providers.push(detail);
    }
  });
  window.dispatchEvent(new Event('eip6963:requestProvider'));
}

// ─────────────────────────────────────────────────────────────
// Convert EIP-6963 to WalletInfo
// ─────────────────────────────────────────────────────────────

export function toWalletInfo(detail: Eip6963Detail): WalletInfo {
  const id = byRdns.get(detail.info.rdns) || detail.info.rdns;
  const def = byId.get(id);
  return {
    id,
    name: def?.name || detail.info.name,
    icon: def ? getIcon(id) : detail.info.icon,
    rdns: detail.info.rdns,
    provider: detail.provider,
    detected: true,
  };
}

// ─────────────────────────────────────────────────────────────
// Merge EIP-6963 + Legacy (deduped)
// ─────────────────────────────────────────────────────────────

export function mergeWallets(eip6963: Eip6963Detail[], legacy: WalletInfo[]): WalletInfo[] {
  const wallets = eip6963.map(toWalletInfo);
  const seen = new Set(wallets.map(w => w.id));
  return [...wallets, ...legacy.filter(w => !seen.has(w.id))].sort((a, b) => a.name.localeCompare(b.name));
}

// ─────────────────────────────────────────────────────────────
// Specific Wallet Getters
// ─────────────────────────────────────────────────────────────

export function getMetaMask(): Eip1193Provider | null {
  const w = win();
  if (!w) return null;
  const multi = multiProviders().find(p => hasFlag(p, 'isMetaMask') && !hasFlag(p, 'isBraveWallet'));
  if (multi) return multi;
  return w.ethereum?.isMetaMask && !w.ethereum?.isBraveWallet ? w.ethereum : null;
}

export function getBaseWallet(): Eip1193Provider | null {
  const w = win();
  if (!w) return null;
  if (w.coinbaseWalletExtension?.request) return w.coinbaseWalletExtension;
  const multi = multiProviders().find(p => hasFlag(p, 'isCoinbaseWallet'));
  return multi || (w.ethereum?.isCoinbaseWallet ? w.ethereum : null);
}

export function getRabby(): Eip1193Provider | null {
  const w = win();
  return w?.rabby?.request ? w.rabby : (w?.ethereum?.isRabby ? w.ethereum : null);
}

export function getPhantom(): Eip1193Provider | null {
  const w = win();
  return w?.phantom?.ethereum?.request ? w.phantom.ethereum : (w?.ethereum?.isPhantom ? w.ethereum : null);
}

export function getInjected(): Eip1193Provider | null {
  return win()?.ethereum?.request ? win().ethereum : null;
}
