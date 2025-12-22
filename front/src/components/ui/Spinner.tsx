import { cva } from '@utils/cva';

interface SpinnerProps {
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl';
  color?: 'primary' | 'foreground' | 'muted' | 'fg-1';
  variant?: 'ring' | 'border-b';
  className?: string;
}

const spinnerVariants = cva('animate-spin', {
  variants: {
    size: {
      xs: 'w-3 h-3 border',
      sm: 'w-4 h-4 border',
      md: 'w-6 h-6 border-2',
      lg: 'w-8 h-8 border-2',
      xl: 'w-12 h-12 border-[3px]',
    },
    variant: {
      ring: 'rounded-full',
      'border-b': 'border-b-2',
    },
    color: {
      primary: '',
      foreground: '',
      muted: '',
      'fg-1': '',
    },
  },
  defaultVariants: {
    size: 'md',
    variant: 'ring',
    color: 'primary',
  },
  compoundVariants: [
    // Ring variant color combinations
    { variant: 'ring', color: 'primary', className: 'border-primary border-t-transparent' },
    { variant: 'ring', color: 'foreground', className: 'border-foreground border-t-transparent' },
    { variant: 'ring', color: 'muted', className: 'border-muted-foreground border-t-transparent' },
    { variant: 'ring', color: 'fg-1', className: 'border-fg-1 border-t-transparent' },
    // Border-b variant color combinations
    { variant: 'border-b', color: 'primary', className: 'border-primary' },
    { variant: 'border-b', color: 'foreground', className: 'border-foreground' },
    { variant: 'border-b', color: 'muted', className: 'border-muted-foreground' },
    { variant: 'border-b', color: 'fg-1', className: 'border-fg-1' },
  ],
});

export function Spinner({
  size = 'md',
  color = 'primary',
  variant = 'ring',
  className,
}: SpinnerProps) {
  return (
    <div className={spinnerVariants({ size, variant, color, className })} />
  );
}
