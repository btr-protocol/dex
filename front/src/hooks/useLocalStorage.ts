import { useState, useCallback, useEffect } from 'preact/hooks';

export function useLocalStorage<T>(key: string, defaultValue: T) {
  const [value, setValue] = useState<T>(() => {
    try {
      const stored = localStorage.getItem(key);
      return stored ? JSON.parse(stored) : defaultValue;
    } catch {
      return defaultValue;
    }
  });

  const setStoredValue = useCallback((newValue: T) => {
    try {
      setValue(newValue);
      localStorage.setItem(key, JSON.stringify(newValue));
    } catch (error) {
      console.error(`Failed to save ${key}:`, error);
    }
  }, [key, setValue]);

  const removeValue = useCallback(() => {
    try {
      localStorage.removeItem(key);
      setValue(defaultValue);
    } catch (error) {
      console.error(`Failed to remove ${key}:`, error);
    }
  }, [key, setValue, defaultValue]);

  return [value, setStoredValue, removeValue] as const;
}
