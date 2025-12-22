import * as React from 'react';
import { Loader2 } from 'lucide-react';
import { cva } from '@utils/cva';

export interface LoadingStateProps extends React.HTMLAttributes<HTMLDivElement> {
  message?: string;
  variant?: 'default' | 'fullscreen' | 'inline';
}

const loadingStateVariants = cva('flex items-center justify-center', {
  variants: {
    variant: {
      fullscreen: 'min-h-screen bg-background',
      default: 'bg-bg-1 rounded-lg p-8 border border-border',
      inline: 'p-4',
    },
  },
  defaultVariants: {
    variant: 'default',
  },
});

const LoadingState = React.forwardRef<HTMLDivElement, LoadingStateProps>(
  ({ className, message = 'Loading...', variant = 'default', ...props }, ref) => {
    return (
      <div
        ref={ref}
        className={loadingStateVariants({ variant, className })}
        {...props}
      >
        <div className="flex items-center gap-3">
          <Loader2 className="w-6 h-6 animate-spin text-primary" />
          <span className="text-muted-foreground text-sm">{message}</span>
        </div>
      </div>
    );
  }
);
LoadingState.displayName = 'LoadingState';

export { LoadingState };
