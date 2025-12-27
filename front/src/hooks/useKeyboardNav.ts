import { useState, useEffect } from 'preact/hooks';
import type { JSX } from 'preact';

export interface KeyboardNavOptions<T> {
  items: T[];
  onSelect: (item: T, index: number) => void;
  isEnabled?: boolean;
}

/**
 * Reusable hook for keyboard navigation in modals
 * Handles arrow up/down navigation and enter to select
 */
export function useKeyboardNav<T>({ items, onSelect, isEnabled = true }: KeyboardNavOptions<T>) {
  const [selectedIndex, setSelectedIndex] = useState(0);

  // Reset selected index when items change
  useEffect(() => {
    setSelectedIndex(0);
  }, [items]);

  const handleKeyDown = (e: JSX.TargetedKeyboardEvent<HTMLInputElement>) => {
    if (!isEnabled || items.length === 0) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setSelectedIndex((prev) => (prev + 1) % items.length);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setSelectedIndex((prev) => (prev - 1 + items.length) % items.length);
    } else if (e.key === 'Enter' && items[selectedIndex]) {
      e.preventDefault();
      onSelect(items[selectedIndex], selectedIndex);
    }
  };

  return {
    selectedIndex,
    setSelectedIndex,
    handleKeyDown,
  };
}
