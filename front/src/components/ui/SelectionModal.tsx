import { useState, useEffect, useMemo } from 'preact/hooks';
import { ReactNode } from 'preact/compat';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { Button } from '@components/ui/Button';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { EmptyState } from '@components/ui/EmptyState';
import { Icon } from './Icon';
import { addNotification } from '@lib/notifications';
import { useKeyboardNav } from '@hooks/useKeyboardNav';
import { renderIcon, isStringIcon } from '@utils/iconHelpers';
import { SelectionItem } from '@/types/ui';

export type { SelectionItem } from '@/types/ui';

interface SelectionModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  searchPlaceholder?: string;
  items: SelectionItem[];
  selectedIds: string[];
  onSelect: (id: string | string[]) => void;
  minSelect?: number; // Min selections (default: 1 for multi, 0 for single)
  maxSelect?: number; // Max selections (default: 1 for single, unlimited for multi)
  filterFn?: (item: SelectionItem, search: string) => boolean;
  filterSection?: ReactNode;
  emptyMessage?: string;
  onResetFilters?: () => void; // Optional: called when reset button is clicked
  hasActiveFilters?: boolean; // Optional: show reset button if true
  maxWidth?: string;
  multiSelect?: boolean; // Backward compat - will derive from min/max
  applyLabel?: string; // Label for apply button (default: "Ok")
}

export function SelectionModal({
  isOpen,
  onClose,
  title,
  searchPlaceholder = 'Search...',
  items,
  selectedIds,
  onSelect,
  minSelect,
  maxSelect,
  filterFn,
  filterSection,
  emptyMessage = 'No items found',
  onResetFilters,
  hasActiveFilters = false,
  maxWidth = 'max-w-lg',
  multiSelect = false,
  applyLabel = 'Ok',
}: SelectionModalProps) {
  const [search, setSearch] = useState('');
  const [tempSelected, setTempSelected] = useState<string[]>(selectedIds);

  // Derive selection constraints
  const isMulti = multiSelect || (maxSelect !== undefined && maxSelect !== 1);
  const minSelections = minSelect ?? (isMulti ? 1 : 0);
  const maxSelections = maxSelect ?? (isMulti ? Infinity : 1);

  useEffect(() => {
    if (isOpen) {
      setTempSelected(selectedIds);
      setSearch('');
    }
  }, [isOpen, selectedIds]);

  // Default filter function
  const defaultFilterFn = (item: SelectionItem, searchQuery: string): boolean => {
    const query = searchQuery.toLowerCase().trim();
    if (!query) return true;

    return (
      item.label.toLowerCase().includes(query) ||
      (item.caption?.toLowerCase().includes(query) ?? false)
    );
  };

  const filterFunction = filterFn || defaultFilterFn;

  // Filtered items
  const filteredItems = useMemo(() => {
    return items.filter((item) => filterFunction(item, search));
  }, [items, search, filterFunction]);

  // Keyboard navigation
  const { selectedIndex, handleKeyDown } = useKeyboardNav({
    items: filteredItems,
    onSelect: (item) => handleToggle(item.id),
    isEnabled: isOpen,
  });

  const handleToggle = (id: string) => {
    if (isMulti) {
      setTempSelected((prev) => {
        // Don't allow deselecting below minimum
        if (prev.includes(id) && prev.length <= minSelections) {
          addNotification('warning', `At least ${minSelections} must remain selected`);
          return prev;
        }
        // Don't allow selecting above maximum
        if (!prev.includes(id) && prev.length >= maxSelections) {
          addNotification('warning', `Maximum ${maxSelections} selections allowed`);
          return prev;
        }
        return prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id];
      });
    } else {
      // Single select - close immediately
      onSelect(id);
      onClose();
    }
  };

  const handleSelectAll = () => {
    setTempSelected(items.map((item) => item.id));
  };

  const handleDeselectAll = () => {
    // Keep minimum selected
    if (tempSelected.length > minSelections) {
      setTempSelected(tempSelected.slice(0, minSelections));
    }
  };

  const allSelected = tempSelected.length === items.length && items.length > 0;

  const handleApply = () => {
    // Check minimum selections
    if (tempSelected.length < minSelections) {
      addNotification('error', `Select at least ${minSelections}`);
      return;
    }
    onSelect(tempSelected);
    onClose();
  };

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={onClose}
      title={title}
      headerType="input"
      placeholder={searchPlaceholder}
      searchValue={search}
      onSearchChange={setSearch}
      onSearchKeyDown={handleKeyDown}
      maxWidth={maxWidth}
      footerNav={
        <KeyboardShortcutGroup
          shortcuts={[
            { keys: '↑↓', label: 'Navigate' },
            { keys: 'Enter', label: isMulti ? 'Toggle' : 'Select' },
            { keys: 'Esc', label: 'Close' },
          ]}
        />
      }
      footerContent={
        isMulti ? (
          <div className="flex items-center justify-between gap-2">
            <span className="text-sm text-muted-foreground">
              {tempSelected.length} selected
            </span>
            <div className="flex items-center gap-2">
              <Button
                variant="outlined"
                size="default"
                onClick={allSelected ? handleDeselectAll : handleSelectAll}
                disabled={allSelected && tempSelected.length === minSelections}
              >
                {allSelected ? (minSelections > 1 ? 'Keep First' : 'Unselect All') : 'Select All'}
              </Button>
              <Button variant="primary" size="default" onClick={handleApply}>
                {applyLabel}
              </Button>
            </div>
          </div>
        ) : undefined
      }
    >
      {/* Filter section (e.g., chain/token filters) */}
      {filterSection}

      <div className="divide-y divide-border">
        {filteredItems.map((item, idx) => {
          const isSelected = tempSelected.includes(item.id);
          const isHighlighted = idx === selectedIndex;
          return (
            <button
              key={item.id}
              onClick={() => handleToggle(item.id)}
              className={`w-full flex items-center gap-3 ${MODAL_PADDING} py-2 transition-colors ${
                isHighlighted ? 'bg-bg-2' : 'hover:bg-bg-2'
              }`}
              style={isSelected ? { backgroundColor: 'var(--bg-primary)' } : undefined}
            >
              {item.icon && (
                isStringIcon(item.icon) ? (
                  <img src={item.icon} alt={item.label} className="w-8 h-8 rounded-xs" />
                ) : (
                  <div className={`w-10 h-8 flex items-center justify-center ${isSelected ? 'text-primary' : 'text-muted-foreground'}`}>
                    {renderIcon(item.icon, 'w-5 h-5')}
                  </div>
                )
              )}
              <div className="flex-1 text-left min-w-0">
                <div className={`font-title text-sm truncate mt-0.5 ${isSelected ? 'text-primary font-medium' : ''}`}>
                  {item.label}
                </div>
                {item.caption && (
                  <div className="text-xs text-fg-3 truncate -mt-1">
                    {item.caption}
                  </div>
                )}
              </div>
              {item.badge}
              {isSelected && <Icon name="check" className="w-5 h-5 text-primary shrink-0" />}
            </button>
          );
        })}
        {filteredItems.length === 0 && (
          <EmptyState
            query={search}
            message={emptyMessage}
            onReset={onResetFilters || (() => setSearch(''))}
            showResetButton={hasActiveFilters || !!search}
          />
        )}
      </div>
    </BaseModal>
  );
}
