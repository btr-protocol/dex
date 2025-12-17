import * as React from 'react';
import { Loader2 } from 'lucide-react';
import { cn } from '@utils/cn';

export interface LoadingStateProps extends React.HTMLAttributes<HTMLDivElement> {
  message?: string;
  variant?: 'default' | 'fullscreen' | 'inline';
}

const LoadingState = React.forwardRef<HTMLDivElement, LoadingStateProps>(
  ({ className, message = 'Loading...', variant = 'default', ...props }, ref) => {
    const variantStyles = {
      fullscreen: 'min-h-screen bg-background flex items-center justify-center',
      default: 'bg-bg-1 rounded-lg p-8 border border-border',
      inline: 'p-4',
    };

    return (
      <div
        ref={ref}
        className={cn(variantStyles[variant], 'flex items-center justify-center', className)}
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
