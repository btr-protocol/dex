/**
 * Generic EmptyState Component
 * Simple, consistent empty state matching SearchEmptyState pattern
 */
import { FilterX } from 'lucide-react';
import { Button } from './Button';

export interface EmptyStateProps {
  message: string;
  query?: string;
  onReset?: () => void;
  resetLabel?: string;
  showResetButton?: boolean;
}

export function EmptyState({
  message,
  query,
  onReset,
  resetLabel = 'Reset filters',
  showResetButton = true,
}: EmptyStateProps) {
  const displayMessage = query ? `${message} for "${query}"` : message;

  return (
    <div className="px-4 py-12 text-center">
      <p className="text-muted-foreground mb-4 text-sm">{displayMessage}</p>
      {showResetButton && onReset && (
        <Button
          onClick={onReset}
          variant="default"
          size="sm"
          leftIcon={<FilterX className="w-4 h-4" />}
        >
          {resetLabel}
        </Button>
      )}
    </div>
  );
}
