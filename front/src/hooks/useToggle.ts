/**
 * useToggle - Simple boolean toggle hook
 * Replaces: onClick={() => setState(!state)}
 */
import { useState, useCallback } from 'preact/hooks';

export function useToggle(
  initialValue = false
): [boolean, () => void, (value: boolean) => void] {
  const [value, setValue] = useState(initialValue);

  const toggle = useCallback(() => {
    setValue(prev => !prev);
  }, []);

  const set = useCallback((newValue: boolean) => {
    setValue(newValue);
  }, []);

  return [value, toggle, set];
}
