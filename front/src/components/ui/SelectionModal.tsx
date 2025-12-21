import { BaseModal } from '@/components/ui/BaseModal';
import { Input } from '@/components/ui/Input';
import { Search } from 'lucide-react';
import { useState, useMemo, type ReactNode } from 'react';
import { SelectableListItem } from '@/components/ui/SelectableListItem';

export interface SelectionItem {
  id: string;
  label: string;
  caption?: string;
  icon?: ReactNode;
  badge?: ReactNode;
  data?: any;
}

interface SelectionModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  searchPlaceholder?: string;
  items: SelectionItem[];
  selectedIds: string[];
  onSelect: (id: string | string[]) => void;
  multiSelect?: boolean;
  filterFn?: (item: SelectionItem, search: string) => boolean;
  filterSection?: ReactNode;
  emptyMessage?: string;
  maxWidth?: string;
}

export function SelectionModal({
  isOpen,
  onClose,
  title,
  searchPlaceholder = 'Search...',
  items,
  selectedIds,
  onSelect,
  multiSelect = false,
  filterFn,
  filterSection,
  emptyMessage = 'No items found',
  maxWidth = 'max-w-lg',
}: SelectionModalProps) {
  const [search, setSearch] = useState('');

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

  const handleSelect = (id: string) => {
    onSelect(id);
    if (!multiSelect) {
      onClose();
    }
  };

  return (
    <BaseModal isOpen={isOpen} onClose={onClose} title={title} maxWidth={maxWidth}>
      <div className="flex flex-col h-full">
        {/* Search bar */}
        <div className="p-4 border-b border-border">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
            <Input
              type="text"
              placeholder={searchPlaceholder}
              className="pl-9"
              variant="search"
              value={search}
              onInput={(e) => setSearch((e.target as HTMLInputElement).value)}
              autoFocus
            />
          </div>
        </div>

        {/* Filter section */}
        {filterSection}

        {/* Items list */}
        <div className="flex-1 overflow-y-auto max-h-96">
          {filteredItems.length === 0 ? (
            <div className="p-8 text-center text-muted-foreground">{emptyMessage}</div>
          ) : (
            <div className="divide-y divide-border">
              {filteredItems.map((item) => (
                <SelectableListItem
                  key={item.id}
                  label={item.label}
                  caption={item.caption}
                  icon={item.icon}
                  badge={item.badge}
                  selected={selectedIds.includes(item.id)}
                  onClick={() => handleSelect(item.id)}
                />
              ))}
            </div>
          )}
        </div>
      </div>
    </BaseModal>
  );
}
