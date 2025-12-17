import { useState, useEffect, useSyncExternalStore } from 'preact/hooks';
import {
  eip6963Store,
  detectLegacy,
  mergeWallets,
  isMobile,
  getIcon,
  getDownloadUrl,
  getTooltip,
  WC_ICONS,
  DISCOVER_MOBILE,
  DISCOVER_DESKTOP,
  type WalletInfo,
} from '@sdk/eth/wallets';

// Re-export for convenience
export { isMobile, getIcon as getWalletIcon, getDownloadUrl as getWalletDownloadUrl, getTooltip as getWalletTooltipName, WC_ICONS, DISCOVER_MOBILE, DISCOVER_DESKTOP };
export type { WalletInfo as Wallet };

export function useInjectedWallets(): WalletInfo[] {
  const eip6963 = useSyncExternalStore(eip6963Store.subscribe, eip6963Store.getSnapshot, eip6963Store.getServerSnapshot);
  const [legacy, setLegacy] = useState<WalletInfo[]>([]);

  useEffect(() => {
    setLegacy(detectLegacy());
  }, []);

  return mergeWallets(eip6963, legacy);
}
