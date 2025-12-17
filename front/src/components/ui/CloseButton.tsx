/**
 * CloseButton - Consolidated close button
 * Replaces 103 close button instances across modals/dialogs
 */
import { X } from 'lucide-react';
import { cn } from '@utils/cn';

interface CloseButtonProps {
  onClick: () => void;
  className?: string;
  size?: 'sm' | 'md' | 'lg';
  title?: string;
}

export function CloseButton({
  onClick,
  className = '',
  size = 'md',
  title = 'Close',
}: CloseButtonProps) {
  const sizeClasses = {
    sm: 'w-4 h-4',
    md: 'w-5 h-5',
    lg: 'w-6 h-6',
  };

  return (
    <button
      onClick={onClick}
      className={cn(
        'text-muted-foreground hover:text-foreground transition-colors p-1 rounded hover:bg-bg-2',
        className
      )}
      title={title}
      aria-label={title}
    >
      <X className={sizeClasses[size]} />
    </button>
  );
}
