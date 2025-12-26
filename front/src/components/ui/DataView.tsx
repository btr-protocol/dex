/**
 * DataView - Consolidated loading/error/empty state handling
 * Replaces 16+ instances of conditional state rendering
 */
import { EmptyState } from './EmptyState';
import type { ComponentChildren } from 'preact';

interface DataViewProps {
  isLoading?: boolean;
  error?: Error | string | null;
  isEmpty?: boolean;
  emptyMessage?: string;
  emptyIcon?: 'inbox' | 'database' | 'search' | 'alert';
  children: ComponentChildren;
}

export function DataView({
  isLoading = false,
  error = null,
  isEmpty = false,
  emptyMessage = 'No data found',
  children,
}: DataViewProps) {
  if (isLoading) {
    return <EmptyState variant="loading" message="Loading..." />;
  }

  if (error) {
    const errorMessage = typeof error === 'string' ? error : error?.message || 'An error occurred';
    return <EmptyState variant="error" title="Error" message={errorMessage} />;
  }

  if (isEmpty) {
    return <EmptyState variant="empty" message={emptyMessage} layout="inline" />;
  }

  return <>{children}</>;
}
