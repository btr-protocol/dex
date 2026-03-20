/**
 * Unified EmptyState Component
 * Consolidates EmptyState, ErrorState, and LoadingState into a single component with variants
 */
import { Ref, type ComponentChildren } from 'preact';
import type { HTMLAttributes } from 'preact/compat';
import { Icon } from './Icon';
import { cva } from '@utils/cva';
import { Button } from './Button';

export interface EmptyStateProps extends HTMLAttributes<HTMLDivElement> {
  ref?: Ref<HTMLDivElement>;
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

  /** Custom icon name or ComponentChildren */
  icon?: ComponentChildren | string;

  /** Action button configuration */
  action?: {
    label: string;
    onClick: () => void;
    icon?: ComponentChildren;
  };
}

const emptyStateVariants = cva('', {
  variants: {
    layout: {
      fullscreen: 'h-screen bg-bg-0 flex items-center justify-center',
      default: 'bg-bg-1 p-6',
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

const DEFAULT_ICONS: Record<'empty' | 'error' | 'loading', string> = {
  empty: 'funnel-x',
  error: 'alert-circle',
  loading: 'loader',
};

export function EmptyState({
  className,
  variant = 'empty',
  layout = 'default',
  title,
  message,
  query,
  icon,
  action,
  ref,
  ...props
}: EmptyStateProps) {
    const displayMessage = query ? `${message} for "${query}"` : message;

    // Resolve icon
    const iconName = icon || DEFAULT_ICONS[variant];
    const isLoading = variant === 'loading';
    const isError = variant === 'error';

    return (
      <div
        ref={ref}
        className={emptyStateVariants({ variant, layout, className: className as any })}
        {...props}
      >
        <div className="text-center max-w-md mx-auto">
          {/* Icon */}
          {iconName && (
            <div className="flex justify-center mb-4">
              <div
                className={`w-12 h-12 rounded-full flex items-center justify-center ${
                  isError ? 'bg-red/10' : 'bg-muted'
                }`}
              >
                {typeof iconName === 'string' ? (
                  <Icon
                    name={iconName}
                    className={`w-6 h-6 ${
                      isLoading
                        ? 'animate-spin text-primary'
                        : isError
                        ? 'text-red'
                        : 'text-muted-foreground'
                    }`}
                  />
                ) : (
                  iconName as any
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
          {action && (
            <Button
              onClick={action.onClick}
              variant={isError ? 'outlined' : 'default'}
              size="sm"
              leftIcon={action.icon}
            >
              {action.label}
            </Button>
          )}
        </div>
      </div>
    );
}