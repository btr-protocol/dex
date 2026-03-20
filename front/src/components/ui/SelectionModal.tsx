import { useState, useEffect, useMemo } from 'preact/hooks';
import { ComponentChildren } from 'preact';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { Button } from '@components/ui/Button';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { EmptyState } from '@components/ui/EmptyState';
import { Icon } from './Icon';
import { MaskIcon } from '@components/ui/MaskIcon';
import { addNotification } from '@lib/notifications';
import { useKeyboardNav } from '@hooks/useKeyboardNav';
import { renderIcon, isStringIcon, isSvgPath } from '@utils/iconHelpers';
import { SelectionItem } from '@/types/ui';
import { useDebounce } from '@/hooks/useDebounce';
import { cn } from '@utils/cn';

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
  headerRight?: ComponentChildren; // Filters in header row
  emptyMessage?: string;
  onResetFilters?: () => void; // Optional: called when reset button is clicked
  hasActiveFilters?: boolean; // Optional: show reset button if true
  maxWidth?: string;
  multiSelect?: boolean;
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
  headerRight,
  emptyMessage = 'No items found',
  onResetFilters,
  hasActiveFilters = false,
  maxWidth = 'max-w-lg',
  multiSelect = false,
  applyLabel = 'Ok',
}: SelectionModalProps) {
  const [search, setSearch] = useState('');
  const [tempSelected, setTempSelected] = useState<string[]>(selectedIds);

  // Debounce search to prevent excessive filtering on every keystroke
  const debouncedSearch = useDebounce(search, 300);

  // Derive selection constraints
  const isMulti = multiSelect || (maxSelect !== undefined && maxSelect !== 1);
  const minSelections = minSelect ?? (isMulti ? 1 : 0);
  const maxSelections = maxSelect ?? (isMulti ? Infinity : 1);

  useEffect(() => {
    if (isOpen) {
      setTempSelected(selectedIds);
      setSearch('');
    }
  }, [isOpen]);

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

  // Filtered items (use debounced search for performance)
  const filteredItems = useMemo(() => {
    return items.filter((item) => filterFunction(item, debouncedSearch));
  }, [items, debouncedSearch, filterFunction]);

  // Keyboard navigation
  const { selectedIndex, handleKeyDown } = useKeyboardNav({
    items: filteredItems,
    onSelect: (item) => handleToggle(item.id),
    isEnabled: isOpen,
  });

  const handleToggle = (id: string) => {
    if (isMulti) {
      setTempSelected((prev) => {
        const idx = prev.indexOf(id);
        const isSelected = idx !== -1;

        // Don't allow deselecting below minimum
        if (isSelected && prev.length <= minSelections) {
          addNotification('warning', `At least ${minSelections} must remain selected`);
          return prev;
        }
        // Don't allow selecting above maximum
        if (!isSelected && prev.length >= maxSelections) {
          addNotification('warning', `Maximum ${maxSelections} selections allowed`);
          return prev;
        }
        return isSelected ? prev.filter((_, i) => i !== idx) : [...prev, id];
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
      headerRight={headerRight}
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
                {allSelected ? 'Unselect All' : 'Select All'}
              </Button>
              <Button variant="primary" size="default" onClick={handleApply}>
                {applyLabel}
              </Button>
            </div>
          </div>
        ) : undefined
      }
    >
      <div className="divide-y divide-border">
        {filteredItems.map((item, idx) => {
          const isSelected = tempSelected.includes(item.id);
          const isHighlighted = idx === selectedIndex;
          return (
            <button
              key={item.id}
              onClick={() => handleToggle(item.id)}
              className={cn(
                `w-full flex items-center gap-3 ${MODAL_PADDING} py-2 transition-colors`,
                isHighlighted ? 'bg-bg-2' : 'hover:bg-bg-2',
                isSelected ? 'bg-bg-primary' : ''
              )}
            >
              {item.icon && (
                isStringIcon(item.icon) ? (
                  <img src={item.icon} alt={item.label} className="w-8 h-8 rounded-xs" />
                ) : (
                  <div className={`w-10 h-8 flex items-center justify-center ${isSelected ? 'text-primary' : 'text-fg-2'}`}>
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
            action={(hasActiveFilters || !!search) ? {
              label: 'Reset',
              onClick: onResetFilters || (() => setSearch('')),
            } : undefined}
          />
        )}
      </div>
    </BaseModal>
  );
}

// Filter button component to trigger the modal
interface FilterButtonProps {
  label: string;
  options: SelectionItem[];
  selected: string[];
  maxVisible?: number;
  onClick: () => void;
  partialFilter?: boolean; // Use 50% opacity overlay instead of full mask (for colorful icons)
  onClear?: () => void; // Optional: clear filter action (renders x icon inside button)
}

export function FilterButton({
  label,
  options,
  selected,
  maxVisible = 3,
  onClick,
  partialFilter = false,
  onClear,
}: FilterButtonProps) {
  const selectedOptions = options.filter((opt) => selected.includes(opt.id));
  const visibleOptions = selectedOptions.slice(0, maxVisible);
  const remainingCount = Math.max(0, selectedOptions.length - maxVisible);

  return (
    <button
      onClick={onClick}
      className="flex items-center gap-1.5 h-8 px-2.5 rounded-sm transition-colors bg-bg-primary border"
      style={{ border: '1px solid color-mix(in srgb, var(--primary) 50%, transparent)' }}
    >
      <span className="text-sm text-primary font-medium">{label}</span>
      <div className="flex items-center gap-0.5">
        {visibleOptions.length === 0 ? (
          <MaskIcon src="/icons/filter-on.svg" size="md" color="var(--primary)" />
        ) : (
          <>
            {visibleOptions.map((opt) => {
              const iconSrc = opt.miniIcon || opt.icon;
              return isStringIcon(iconSrc) && isSvgPath(iconSrc) ? (
                partialFilter ? (
                  // Partial filter: use regular image with orange overlay
                  <div key={opt.id} className="relative w-5 h-5" title={opt.label}>
                    <img src={iconSrc} alt={opt.label} className="w-5 h-5 rounded-full" />
                    <div
                      className="absolute inset-0 rounded-full pointer-events-none bg-primary opacity-50"
                      style={{ mixBlendMode: 'multiply' }}
                    />
                  </div>
                ) : (
                  // Full mask: monochromatic
                  <MaskIcon
                    key={opt.id}
                    src={iconSrc}
                    size="md"
                    color="var(--primary)"
                    aria-label={opt.label}
                  />
                )
              ) : (
                <div
                  key={opt.id}
                  title={opt.label}
                  className="w-5 h-5 flex items-center justify-center text-primary"
                >
                  {renderIcon(iconSrc, 'w-4 h-4')}
                </div>
              );
            })}
            {remainingCount > 0 && (
              <span className="text-sm text-primary font-bold pl-0.5">
                +{remainingCount}
              </span>
            )}
            {onClear && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  onClear();
                }}
                className="ml-0.5 flex items-center justify-center w-4 h-4 hover:bg-bg-3 rounded-sm text-primary transition-colors"
                title="Clear filter"
              >
                <Icon name="x" className="w-3 h-3" />
              </button>
            )}
          </>
        )}
      </div>
    </button>
  );
}
