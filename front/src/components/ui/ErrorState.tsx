import * as React from 'react';
import { AlertCircle, RefreshCw } from 'lucide-react';
import { cva } from '@utils/cva';
import { Button } from './Button';

export interface ErrorStateProps extends React.HTMLAttributes<HTMLDivElement> {
  title?: string;
  message?: string;
  onRetry?: () => void;
  variant?: 'default' | 'fullscreen' | 'inline';
}

const errorStateVariants = cva('', {
  variants: {
    variant: {
      fullscreen: 'min-h-screen bg-background flex items-center justify-center',
      default: 'bg-bg-1 rounded-lg p-8 border border-red/50',
      inline: 'p-4',
    },
  },
  defaultVariants: {
    variant: 'default',
  },
});

const ErrorState = React.forwardRef<HTMLDivElement, ErrorStateProps>(
  (
    {
      className,
      title = 'Error',
      message = 'Something went wrong. Please try again.',
      onRetry,
      variant = 'default',
      ...props
    },
    ref
  ) => {
    return (
      <div ref={ref} className={errorStateVariants({ variant, className })} {...props}>
        <div className="text-center max-w-md mx-auto">
          <div className="flex justify-center mb-4">
            <div className="w-12 h-12 rounded-full bg-red/10 flex items-center justify-center">
              <AlertCircle className="w-6 h-6 text-red" />
            </div>
          </div>
          <h3 className="text-lg font-semibold text-red mb-2">{title}</h3>
          <p className="text-muted-foreground text-sm mb-4">{message}</p>
          {onRetry && (
            <Button onClick={onRetry} styleVariant="outlined" size="sm" className="gap-2">
              <RefreshCw className="w-4 h-4" />
              Try Again
            </Button>
          )}
        </div>
      </div>
    );
  }
);
ErrorState.displayName = 'ErrorState';

export { ErrorState };
