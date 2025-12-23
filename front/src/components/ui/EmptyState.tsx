/**
 * Unified EmptyState Component
 * Consolidates ErrorState, LoadingState, and SearchEmptyState
 */
import * as React from 'react';
import { AlertCircle, RefreshCw, Loader2, FilterX, SearchX } from 'lucide-react';
import { cva } from '@utils/cva';
import { Button } from './Button';

export interface EmptyStateProps extends React.HTMLAttributes<HTMLDivElement> {
  variant: 'error' | 'loading' | 'search' | 'empty';
  layout?: 'default' | 'fullscreen' | 'inline';
  title?: string;
  message?: string;
  onAction?: () => void;
  actionLabel?: string;
  query?: string;
  hasFilters?: boolean;
}

const emptyStateVariants = cva('', {
  variants: {
    layout: {
      fullscreen: 'min-h-screen bg-background flex items-center justify-center',
      default: 'bg-bg-1 rounded-lg p-8 border border-border',
      inline: 'p-4',
    },
    variant: {
      error: '',
      loading: 'flex items-center justify-center',
      search: '',
      empty: '',
    },
  },
  defaultVariants: {
    layout: 'default',
    variant: 'empty',
  },
});

const EmptyState = React.forwardRef<HTMLDivElement, EmptyStateProps>(
  (
    {
      className,
      variant,
      layout = 'default',
      title,
      message,
      onAction,
      actionLabel,
      query,
      hasFilters = true,
      ...props
    },
    ref
  ) => {
    // Default values based on variant
    const defaults = {
      error: {
        title: title ?? 'Error',
        message: message ?? 'Something went wrong. Please try again.',
        icon: AlertCircle,
        iconColor: 'text-red',
        iconBg: 'bg-red/10',
        actionLabel: actionLabel ?? 'Try Again',
        actionIcon: RefreshCw,
      },
      loading: {
        title: title,
        message: message ?? 'Loading...',
        icon: Loader2,
        iconColor: 'text-primary',
        iconBg: 'bg-primary/10',
        actionLabel: null,
        actionIcon: null,
      },
      search: {
        title: title,
        message: message ?? (query ? `No results found for "${query}"` : 'No results found'),
        icon: SearchX,
        iconColor: 'text-muted-foreground',
        iconBg: 'bg-bg-2',
        actionLabel: actionLabel ?? 'Reset filters',
        actionIcon: FilterX,
      },
      empty: {
        title: title ?? 'No data',
        message: message ?? 'Nothing to display yet.',
        icon: SearchX,
        iconColor: 'text-muted-foreground',
        iconBg: 'bg-bg-2',
        actionLabel: actionLabel,
        actionIcon: null,
      },
    };

    const config = defaults[variant];
    const Icon = config.icon;
    const ActionIcon = config.actionIcon;
    const showAction = onAction && (variant !== 'search' || hasFilters);

    if (variant === 'loading') {
      return (
        <div
          ref={ref}
          className={emptyStateVariants({ variant, layout, className })}
          {...props}
        >
          <div className="flex items-center gap-3">
            <Loader2 className="w-6 h-6 animate-spin text-primary" />
            <span className="text-muted-foreground text-sm">{config.message}</span>
          </div>
        </div>
      );
    }

    return (
      <div
        ref={ref}
        className={emptyStateVariants({ variant, layout, className })}
        {...props}
      >
        <div className="text-center max-w-md mx-auto">
          <div className="flex justify-center mb-4">
            <div className={`w-12 h-12 rounded-full ${config.iconBg} flex items-center justify-center`}>
              <Icon className={`w-6 h-6 ${variant === 'loading' ? 'animate-spin' : ''} ${config.iconColor}`} />
            </div>
          </div>
          {config.title && (
            <h3 className={`text-lg font-semibold mb-2 ${variant === 'error' ? 'text-red' : 'text-foreground'}`}>
              {config.title}
            </h3>
          )}
          <p className="text-muted-foreground text-sm mb-4">{config.message}</p>
          {showAction && config.actionLabel && (
            <Button
              onClick={onAction}
              styleVariant={variant === 'error' ? 'outlined' : 'default'}
              size="sm"
              leftIcon={ActionIcon ? <ActionIcon className="w-4 h-4" /> : undefined}
            >
              {config.actionLabel}
            </Button>
          )}
        </div>
      </div>
    );
  }
);
EmptyState.displayName = 'EmptyState';

export { EmptyState };
