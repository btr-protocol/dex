/**
 * Unified EmptyState Component
 * Consolidates EmptyState, ErrorState, and LoadingState into a single component with variants
 */
import * as React from 'react';
import { FilterX, AlertCircle, RefreshCw, Loader2, type LucideIcon } from 'lucide-react';
import { cva } from '@utils/cva';
import { Button } from './Button';

export interface EmptyStateProps extends React.HTMLAttributes<HTMLDivElement> {
  /**
   * State variant
   * - empty: Generic empty state (default)
   * - error: Error state with red styling
   * - loading: Loading state with spinner
   */
  variant?: 'empty' | 'error' | 'loading';

  /**
   * Layout variant
   * - default: Card-like with padding and border
   * - fullscreen: Full height centered
   * - inline: Minimal padding
   */
  layout?: 'default' | 'fullscreen' | 'inline';

  /** Optional title (shows above message) */
  title?: string;

  /** Main message */
  message: string;

  /** Optional search query to append to message */
  query?: string;

  /** Custom icon (overrides variant default) */
  icon?: React.ReactNode | LucideIcon;

  /** Action button configuration */
  action?: {
    label: string;
    onClick: () => void;
    icon?: React.ReactNode;
  };

  /** @deprecated Use action prop instead */
  onReset?: () => void;
  /** @deprecated Use action.label instead */
  resetLabel?: string;
  /** @deprecated Use action instead */
  showResetButton?: boolean;
  /** @deprecated Use action.onClick instead */
  onRetry?: () => void;
}

const emptyStateVariants = cva('', {
  variants: {
    layout: {
      fullscreen: 'min-h-screen bg-background flex items-center justify-center',
      default: 'bg-bg-1 rounded-lg p-8 border border-border',
      inline: 'p-4',
    },
    variant: {
      empty: '',
      error: 'border-red/50',
      loading: '',
    },
  },
  defaultVariants: {
    layout: 'default',
    variant: 'empty',
  },
});

const DEFAULT_ICONS: Record<'empty' | 'error' | 'loading', LucideIcon> = {
  empty: FilterX,
  error: AlertCircle,
  loading: Loader2,
};

const DEFAULT_MESSAGES = {
  empty: 'No results found',
  error: 'Something went wrong. Please try again.',
  loading: 'Loading...',
};

export const EmptyState = React.forwardRef<HTMLDivElement, EmptyStateProps>(
  (
    {
      className,
      variant = 'empty',
      layout = 'default',
      title,
      message,
      query,
      icon,
      action,
      // Deprecated props (backwards compatibility)
      onReset,
      resetLabel = 'Reset filters',
      showResetButton = true,
      onRetry,
      ...props
    },
    ref
  ) => {
    // Handle deprecated props
    const finalAction = action || (onReset && showResetButton) || onRetry
      ? {
          label: resetLabel || 'Try Again',
          onClick: action?.onClick || onReset || onRetry || (() => {}),
          icon: action?.icon || (onReset ? <FilterX className="w-4 h-4" /> : <RefreshCw className="w-4 h-4" />),
        }
      : undefined;

    const displayMessage = query ? `${message} for "${query}"` : message;

    // Resolve icon
    const IconComponent = icon || DEFAULT_ICONS[variant];
    const isLoading = variant === 'loading';
    const isError = variant === 'error';

    return (
      <div
        ref={ref}
        className={emptyStateVariants({ variant, layout, className })}
        {...props}
      >
        <div className="text-center max-w-md mx-auto">
          {/* Icon */}
          {IconComponent && (
            <div className="flex justify-center mb-4">
              <div
                className={`w-12 h-12 rounded-full flex items-center justify-center ${
                  isError ? 'bg-red/10' : 'bg-muted'
                }`}
              >
                {typeof IconComponent === 'function' ? (
                  <IconComponent
                    className={`w-6 h-6 ${
                      isLoading
                        ? 'animate-spin text-primary'
                        : isError
                        ? 'text-red'
                        : 'text-muted-foreground'
                    }`}
                  />
                ) : (
                  IconComponent
                )}
              </div>
            </div>
          )}

          {/* Title */}
          {title && (
            <h3
              className={`text-lg font-semibold mb-2 ${
                isError ? 'text-red' : 'text-foreground'
              }`}
            >
              {title}
            </h3>
          )}

          {/* Message */}
          <p className="text-muted-foreground text-sm mb-4">{displayMessage}</p>

          {/* Action Button */}
          {finalAction && (
            <Button
              onClick={finalAction.onClick}
              styleVariant={isError ? 'outlined' : 'default'}
              size="sm"
              leftIcon={finalAction.icon}
            >
              {finalAction.label}
            </Button>
          )}
        </div>
      </div>
    );
  }
);

EmptyState.displayName = 'EmptyState';
