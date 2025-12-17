import { cn } from '@utils/cn';

interface SpinnerProps {
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl';
  color?: 'primary' | 'foreground' | 'muted' | 'fg-1';
  variant?: 'ring' | 'border-b';
  className?: string;
}

const SIZE_MAP = {
  xs: 'w-3 h-3 border',
  sm: 'w-4 h-4 border',
  md: 'w-6 h-6 border-2',
  lg: 'w-8 h-8 border-2',
  xl: 'w-12 h-12 border-[3px]',
};

const COLOR_MAP = {
  primary: 'border-primary border-t-transparent',
  foreground: 'border-foreground border-t-transparent',
  muted: 'border-muted-foreground border-t-transparent',
  'fg-1': 'border-fg-1 border-t-transparent',
};

const VARIANT_MAP = {
  ring: (color: string) => color,
  'border-b': (color: string) => {
    // For border-b variant, just use the color without border-t-transparent
    if (color.includes('primary')) return 'border-b-2 border-primary';
    if (color.includes('foreground')) return 'border-b-2 border-foreground';
    if (color.includes('muted')) return 'border-b-2 border-muted-foreground';
    if (color.includes('fg-1')) return 'border-b-2 border-fg-1';
    return 'border-b-2 border-primary';
  },
};

export function Spinner({
  size = 'md',
  color = 'primary',
  variant = 'ring',
  className,
}: SpinnerProps) {
  const variantClass = variant === 'border-b'
    ? VARIANT_MAP['border-b'](COLOR_MAP[color] || COLOR_MAP.primary)
    : COLOR_MAP[color];

  return (
    <div
      className={cn(
        'animate-spin',
        variant === 'ring' && 'rounded-full',
        SIZE_MAP[size],
        variantClass,
        className
      )}
    />
  );
}
