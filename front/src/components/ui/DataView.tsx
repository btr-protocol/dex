/**
 * DataView - Consolidated loading/error/empty state handling
 * Replaces 16+ instances of conditional state rendering
 */
import { LoadingState } from './LoadingState';
import { ErrorState } from './ErrorState';
import type { ReactNode } from 'react';

interface DataViewProps {
  isLoading?: boolean;
  error?: Error | string | null;
  isEmpty?: boolean;
  emptyMessage?: string;
  emptyIcon?: 'inbox' | 'database' | 'search' | 'alert';
  children: ReactNode;
}

export function DataView({
  isLoading = false,
  error = null,
  isEmpty = false,
  emptyMessage = 'No data found',
  children,
}: DataViewProps) {
  if (isLoading) {
    return <LoadingState message="Loading..." />;
  }

  if (error) {
    const errorMessage = typeof error === 'string' ? error : error?.message || 'An error occurred';
    return <ErrorState title="Error" message={errorMessage} />;
  }

  if (isEmpty) {
    return (
      <div className="text-center py-12">
        <p className="text-muted-foreground text-sm">{emptyMessage}</p>
      </div>
    );
  }

  return <>{children}</>;
}
