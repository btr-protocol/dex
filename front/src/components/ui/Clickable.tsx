/**
 * Clickable Micro-Components
 * Consolidates common interactive patterns
 */
import { cn } from '@utils/cn';
import type { ComponentChildren } from 'preact';

interface ClickableProps {
  children: ComponentChildren;
  className?: string;
  onClick?: (e?: any) => void;
  disabled?: boolean;
  title?: string;
  style?: any;
}

// Common hover:bg-bg-2 pattern (22 instances)
export function HoverBg2({ children, className, onClick, disabled, title, style }: ClickableProps) {
  return (
    <button
      className={cn('hover:bg-bg-2 transition-colors', className)}
      onClick={onClick}
      disabled={disabled}
      title={title}
      style={style}
    >
      {children}
    </button>
  );
}

// Common hover:bg-bg-3 pattern (15 instances)
export function HoverBg3({ children, className, onClick, disabled, title, style }: ClickableProps) {
  return (
    <button
      className={cn('hover:bg-bg-3 transition-colors', className)}
      onClick={onClick}
      disabled={disabled}
      title={title}
      style={style}
    >
      {children}
    </button>
  );
}

// Small icon button pattern (common in toolbars)
export function IconButton({ children, className, onClick, disabled, title, style }: ClickableProps) {
  return (
    <button
      className={cn(
        'w-6 h-6 flex items-center justify-center hover:bg-bg-3 text-fg-2 transition-colors rounded-xs',
        className
      )}
      onClick={onClick}
      disabled={disabled}
      title={title}
      style={style}
    >
      {children}
    </button>
  );
}

// List item hover pattern
export function ListItem({ children, className, onClick, style }: ClickableProps) {
  return (
    <button
      className={cn(
        'w-full flex items-center gap-2 px-3 py-2 hover:bg-bg-2 transition-colors text-left',
        className
      )}
      onClick={onClick}
      style={style}
    >
      {children}
    </button>
  );
}
