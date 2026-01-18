import { useState, useEffect, useCallback } from 'preact/hooks';
import type { JSX } from 'preact';

export interface KeyboardNavOptions<T> {
  items: T[];
  onSelect: (item: T, index: number) => void;
  isEnabled?: boolean;
  onEscape?: () => void;
  loop?: boolean;
}

/**
 * Reusable hook for keyboard navigation in modals and dropdowns
 * Handles arrow up/down navigation, enter to select, and escape to cancel
 */
export function useKeyboardNav<T>({
  items,
  onSelect,
  isEnabled = true,
  onEscape,
  loop = true,
}: KeyboardNavOptions<T>) {
  const [selectedIndex, setSelectedIndex] = useState(0);

  // Reset selected index when items change
  useEffect(() => {
    setSelectedIndex(0);
  }, [items]);

  const handleKeyDown = useCallback((e: JSX.TargetedKeyboardEvent<HTMLInputElement> | KeyboardEvent) => {
    if (!isEnabled || items.length === 0) return;

    switch (e.key) {
      case 'Escape':
        e.preventDefault();
        onEscape?.();
        break;
      case 'ArrowDown':
        e.preventDefault();
        const next = selectedIndex + 1;
        setSelectedIndex(next >= items.length ? (loop ? 0 : items.length - 1) : next);
        break;
      case 'ArrowUp':
        e.preventDefault();
        const prev = selectedIndex - 1;
        setSelectedIndex(prev < 0 ? (loop ? items.length - 1 : 0) : prev);
        break;
      case 'Enter':
        e.preventDefault();
        if (selectedIndex >= 0 && selectedIndex < items.length) {
          onSelect(items[selectedIndex], selectedIndex);
        }
        break;
    }
  }, [isEnabled, items, selectedIndex, onSelect, onEscape, loop]);

  return {
    selectedIndex,
    setSelectedIndex,
    handleKeyDown,
  };
}
