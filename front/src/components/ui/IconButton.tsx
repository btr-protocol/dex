import { ReactNode } from 'react';
import { cn } from '@utils/cn';
import { type Size, SIZE_HEIGHTS, SIZE_ICON_WIDTHS } from './sizes';

interface IconButtonProps {
  icon: ReactNode;
  onClick?: () => void;
  size?: Size;
  variant?: 'ghost' | 'outlined' | 'default';
  'aria-label': string;
  className?: string;
  disabled?: boolean;
}

const VARIANT_MAP = {
  ghost: 'hover:bg-bg-2',
  outlined: 'border border-border hover:bg-bg-2',
  default: 'bg-bg-2 hover:bg-bg-3',
};

export function IconButton({
  icon,
  onClick,
  size = 'default',
  variant = 'ghost',
  'aria-label': ariaLabel,
  className,
  disabled = false,
}: IconButtonProps) {
  return (
    <button
      onClick={onClick}
      aria-label={ariaLabel}
      disabled={disabled}
      className={cn(
        'flex items-center justify-center rounded-sm transition-colors',
        'disabled:opacity-50 disabled:cursor-not-allowed',
        SIZE_HEIGHTS[size],
        SIZE_ICON_WIDTHS[size],
        VARIANT_MAP[variant],
        className
      )}
    >
      {icon}
    </button>
  );
}
