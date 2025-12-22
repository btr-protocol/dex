import { FilterX } from 'lucide-react';
import { Button } from '@components/ui/Button';

interface SearchEmptyStateProps {
  query?: string;
  message?: string;
  onReset: () => void;
  hasFilters?: boolean;
}

export function SearchEmptyState({
  query,
  message = 'No results found',
  onReset,
  hasFilters = true,
}: SearchEmptyStateProps) {
  const displayMessage = query ? `${message} for "${query}"` : message;

  return (
    <div className="px-4 py-12 text-center">
      <p className="text-muted-foreground mb-4 text-sm">{displayMessage}</p>
      {hasFilters && (
        <Button
          onClick={onReset}
          variant="default"
          size="sm"
          leftIcon={<FilterX className="w-4 h-4" />}
        >
          Reset filters
        </Button>
      )}
    </div>
  );
}
