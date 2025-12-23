import { useState, useEffect, useMemo, ReactNode } from 'react';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { Button } from '@components/ui/Button';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { EmptyState } from '@components/ui/EmptyState';
import { Check } from 'lucide-react';
import { MaskIcon } from '@components/ui/MaskIcon';
import { addNotification } from '@lib/notifications';
import { useKeyboardNav } from '@hooks/useKeyboardNav';
import { renderIcon, isStringIcon } from '@utils/iconHelpers';
import { FilterOption } from '@/types/ui';

export type { FilterOption } from '@/types/ui';

interface MultiSelectModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  placeholder?: string;
  options: FilterOption[];
  selected: string[];
  onApply: (selected: string[]) => void;
}

export function MultiSelectModal({
  isOpen,
  onClose,
  title,
  placeholder = 'Search...',
  options,
  selected,
  onApply,
}: MultiSelectModalProps) {
  const [search, setSearch] = useState('');
  const [tempSelected, setTempSelected] = useState<string[]>(selected);

  useEffect(() => {
    if (isOpen) {
      setTempSelected(selected);
      setSearch('');
    }
  }, [isOpen, selected]);

  const filteredOptions = useMemo(() => {
    if (!search.trim()) return options;
    const q = search.toLowerCase();
    return options.filter((opt) =>
      opt.name.toLowerCase().includes(q) ||
      opt.id.toLowerCase().includes(q) ||
      opt.caption?.toLowerCase().includes(q)
    );
  }, [options, search]);

  // Keyboard navigation
  const { selectedIndex, handleKeyDown } = useKeyboardNav({
    items: filteredOptions,
    onSelect: (option) => handleToggle(option.id),
    isEnabled: isOpen,
  });

  const handleToggle = (id: string) => {
    setTempSelected((prev) => {
      // Don't allow deselecting the last item
      if (prev.includes(id) && prev.length === 1) {
        addNotification('warning', 'At least 1 must remain selected');
        return prev;
      }
      return prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id];
    });
  };

  const handleSelectAll = () => {
    setTempSelected(options.map((opt) => opt.id));
  };

  const handleDeselectAll = () => {
    // Keep at least one selected
    if (tempSelected.length > 1) {
      setTempSelected([tempSelected[0]]);
    }
  };

  const allSelected = tempSelected.length === options.length && options.length > 0;

  const handleApply = () => {
    // Require at least 1 selection
    if (tempSelected.length === 0) {
      addNotification('error', 'Select at least 1');
      return;
    }
    onApply(tempSelected);
    onClose();
  };

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={() => onClose()}
      title={title}
      headerType="input"
      placeholder={placeholder}
      searchValue={search}
      onSearchChange={setSearch}
      onSearchKeyDown={handleKeyDown}
      maxWidth="max-w-sm"
      footerNav={
        <KeyboardShortcutGroup
          shortcuts={[
            { keys: '↑↓', label: 'Navigate' },
            { keys: 'Enter', label: 'Toggle' },
            { keys: 'Esc', label: 'Close' },
          ]}
        />
      }
      footerContent={
        <div className="flex items-center justify-between gap-2">
          <span className="text-sm text-muted-foreground">
            {tempSelected.length} selected
          </span>
          <div className="flex items-center gap-2">
            <Button
              styleVariant="outlined"
              size="default"
              onClick={allSelected ? handleDeselectAll : handleSelectAll}
              disabled={allSelected && tempSelected.length === 1}
            >
              {allSelected ? 'Keep First' : 'Select All'}
            </Button>
            <Button variant="primary" size="default" onClick={handleApply}>
              Ok
            </Button>
          </div>
        </div>
      }
    >
      <div className="divide-y divide-border">
        {filteredOptions.map((option, idx) => {
          const isSelected = tempSelected.includes(option.id);
          const isHighlighted = idx === selectedIndex;
          return (
            <button
              key={option.id}
              onClick={() => handleToggle(option.id)}
              className={`w-full flex items-center gap-3 ${MODAL_PADDING} py-2 transition-colors ${
                isHighlighted ? 'bg-bg-2' : 'hover:bg-bg-2'
              }`}
              style={isSelected ? { backgroundColor: 'var(--bg-primary)' } : undefined}
            >
              {isStringIcon(option.icon) ? (
                <img src={option.icon} alt={option.name} className="w-8 h-8 rounded-xs" />
              ) : (
                <div className={`w-8 h-8 flex items-center justify-center ${isSelected ? 'text-primary' : 'text-muted-foreground'}`}>
                  {renderIcon(option.icon, 'w-5 h-5')}
                </div>
              )}
              <div className="flex-1 text-left min-w-0">
                <div className={`font-title text-sm truncate mt-0.5 ${isSelected ? 'text-primary font-medium' : ''}`}>
                  {option.name}
                </div>
                {option.caption && (
                  <div className="text-xs text-fg-3 truncate -mt-1">
                    {option.caption}
                  </div>
                )}
              </div>
              {isSelected && <Check className="w-5 h-5 text-primary shrink-0" />}
            </button>
          );
        })}
        {filteredOptions.length === 0 && (
          <EmptyState
            query={search}
            message="No options found"
            onReset={() => setSearch('')}
            showResetButton={false}
          />
        )}
      </div>
    </BaseModal>
  );
}

// Filter button component to trigger the modal
interface FilterButtonProps {
  label: string;
  options: FilterOption[];
  selected: string[];
  maxVisible?: number;
  onClick: () => void;
  partialFilter?: boolean; // Use 50% opacity overlay instead of full mask (for colorful icons)
}

export function FilterButton({
  label,
  options,
  selected,
  maxVisible = 3,
  onClick,
  partialFilter = false,
}: FilterButtonProps) {
  const selectedOptions = options.filter((opt) => selected.includes(opt.id));
  const visibleOptions = selectedOptions.slice(0, maxVisible);
  const remainingCount = Math.max(0, selectedOptions.length - maxVisible);

  return (
    <button
      onClick={onClick}
      className="flex items-center gap-1.5 h-8 px-2.5 rounded-sm transition-colors"
      style={{
        backgroundColor: 'var(--bg-primary)',
        border: '1px solid color-mix(in srgb, var(--primary) 50%, transparent)',
      }}
    >
      <span className="text-sm text-primary font-medium">{label}</span>
      <div className="flex items-center gap-0.5">
        {visibleOptions.length === 0 ? (
          <MaskIcon src="/icons/filter-on.svg" size="md" color="var(--primary)" />
        ) : (
          <>
            {visibleOptions.map((opt) => {
              const iconSrc = opt.miniIcon || opt.icon;
              return isStringIcon(iconSrc) ? (
                partialFilter ? (
                  // Partial filter: use regular image with orange overlay
                  <div key={opt.id} className="relative w-5 h-5" title={opt.name}>
                    <img src={iconSrc} alt={opt.name} className="w-5 h-5 rounded-full" />
                    <div
                      className="absolute inset-0 rounded-full pointer-events-none"
                      style={{
                        backgroundColor: 'var(--primary)',
                        opacity: 0.5,
                        mixBlendMode: 'multiply'
                      }}
                    />
                  </div>
                ) : (
                  // Full mask: monochromatic
                  <MaskIcon
                    key={opt.id}
                    src={iconSrc}
                    size="md"
                    color="var(--primary)"
                    aria-label={opt.name}
                  />
                )
              ) : (
                <div
                  key={opt.id}
                  title={opt.name}
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
          </>
        )}
      </div>
    </button>
  );
}
