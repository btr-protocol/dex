import { createContext } from 'preact';
import { useContext, useState, useEffect, useCallback } from 'preact/hooks';
import { ReactNode } from 'preact/compat';
import { getGPUInfo } from '@utils/gpu-detection';

export interface AppSettings {
  // Execution
  maxSlippage: number;
  detailRoute: boolean;
  // Interface
  hideSmallBalances: boolean;
  hideUnsupportedTokens: boolean;
  showTestNetworks: boolean;
  animateBackground: boolean;
  ringCount: number;
  rotationSpeed: number;
  eyeSize: number;
  // Region
  currency: string;
  language: string;
  // Other
  exportFormat: string;
  // Symbol preferences
  swapTokenIn: string;
  swapTokenOut: string;
  chartBase: string;
  chartQuote: string;
}

export const DEFAULT_SETTINGS: AppSettings = {
  // Execution
  maxSlippage: 0.5,
  detailRoute: false,
  // Interface
  hideSmallBalances: false,
  hideUnsupportedTokens: false,
  showTestNetworks: false,
  animateBackground: true,
  ringCount: 12,
  rotationSpeed: 30,
  eyeSize: 10,
  // Region
  currency: 'USD',
  language: 'en-US',
  // Other
  exportFormat: 'JSON',
  // Symbol preferences
  swapTokenIn: '',
  swapTokenOut: '',
  chartBase: '',
  chartQuote: '',
};

const SETTINGS_STORAGE_KEY = 'btr-settings';

interface SettingsContextType {
  settings: AppSettings;
  updateSettings: (updates: Partial<AppSettings>) => void;
  updateSetting: <K extends keyof AppSettings>(key: K, value: AppSettings[K]) => void;
}

const SettingsContext = createContext<SettingsContextType | undefined>(undefined);

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<AppSettings>(() => {
    const stored = localStorage.getItem(SETTINGS_STORAGE_KEY);
    if (stored) {
      try {
        return { ...DEFAULT_SETTINGS, ...JSON.parse(stored) };
      } catch {
        return DEFAULT_SETTINGS;
      }
    }
    return DEFAULT_SETTINGS;
  });

  // Detect GPU on mount and update animation setting if not explicitly set
  useEffect(() => {
    (async () => {
      const gpuInfo = await getGPUInfo();

      // Only update animateBackground if it's using the default value
      // (meaning user hasn't manually configured it)
      const stored = localStorage.getItem(SETTINGS_STORAGE_KEY);
      const userSettings = stored ? JSON.parse(stored) : {};

      if (!('animateBackground' in userSettings) && !gpuInfo.hasGPU) {
        setSettings((prev) => ({ ...prev, animateBackground: false }));
      }
    })();
  }, []);

  // Save settings to localStorage when they change (with debounce)
  useEffect(() => {
    const timeout = setTimeout(() => {
      localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
    }, 500);
    return () => clearTimeout(timeout);
  }, [settings]);

  const updateSettings = useCallback((updates: Partial<AppSettings>) => {
    setSettings((prev) => ({ ...prev, ...updates }));
  }, []);

  const updateSetting = useCallback(<K extends keyof AppSettings>(key: K, value: AppSettings[K]) => {
    setSettings((prev) => ({ ...prev, [key]: value }));
  }, []);

  return (
    <SettingsContext.Provider value={{ settings, updateSettings, updateSetting }}>
      {children}
    </SettingsContext.Provider>
  ) as JSX.Element;
}

export function useSettings() {
  const context = useContext(SettingsContext);
  if (!context) {
    throw new Error('useSettings must be used within a SettingsProvider');
  }
  return context;
}
