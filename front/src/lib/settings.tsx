import { createContext, JSX } from 'preact';
import { useContext, useState, useEffect, useCallback } from 'preact/hooks';
import { ComponentChildren } from 'preact';
import { getGPUInfo } from '@utils/gpu-detection';
import { safeJson } from '@utils/json';
import { getDefaultSettings, type AppSettings } from '@config/settings';

export const DEFAULT_SETTINGS: AppSettings = getDefaultSettings();

const SETTINGS_STORAGE_KEY = 'btr-settings';

interface SettingsContextType {
  settings: AppSettings;
  updateSettings: (updates: Partial<AppSettings>) => void;
  updateSetting: <K extends keyof AppSettings>(key: K, value: AppSettings[K]) => void;
}

const SettingsContext = createContext<SettingsContextType | undefined>(undefined);

export function SettingsProvider({ children }: { children: ComponentChildren }) {
  const [settings, setSettings] = useState<AppSettings>(() => {
    const stored = localStorage.getItem(SETTINGS_STORAGE_KEY);
    const parsed = stored ? safeJson<Record<string, unknown>>(stored) : undefined;
    return { ...DEFAULT_SETTINGS, ...parsed } as AppSettings;
  });

  // Detect GPU on mount and update animation setting if not explicitly set
  useEffect(() => {
    (async () => {
      const gpuInfo = await getGPUInfo();

      // Only update animateBackground if it's using the default value
      // (meaning user hasn't manually configured it)
      const stored = localStorage.getItem(SETTINGS_STORAGE_KEY);
      const userSettings = (stored ? safeJson<Record<string, unknown>>(stored) : {}) || {};

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
