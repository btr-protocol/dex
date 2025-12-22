import * as React from 'react';
import { cn } from '@utils/cn';
import { cva } from '@utils/cva';
import { type Size, BORDER_RADIUS, SIZE_HEIGHTS, SIZE_PADDINGS, SIZE_TEXT } from './sizes';

type InputVariant = 'default' | 'amount' | 'address' | 'number' | 'search';

export interface InputProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, 'size'> {
  variant?: InputVariant;
  size?: Size;
}

const inputVariants = cva(
  'focus:outline-none transition-colors font-medium font-title',
  {
    variants: {
      variant: {
        default: `w-full bg-bg-2 focus:border-primary ${BORDER_RADIUS}`,
        amount: 'outline-none w-full text-right placeholder:text-fg-2 text-fg-0 font-numeric',
        address: `w-full bg-bg-2 focus:border-primary ${BORDER_RADIUS} font-mono`,
        number: `w-20 bg-bg-2 focus:border-primary ${BORDER_RADIUS} text-right font-numeric`,
        search: `bg-bg-2 focus:border-primary ${BORDER_RADIUS} pl-9 pr-4`,
      },
      size: {
        ...Object.fromEntries(
          Object.keys(SIZE_HEIGHTS).map(s => [
            s,
            cn(SIZE_HEIGHTS[s as Size], SIZE_PADDINGS[s as Size], SIZE_TEXT[s as Size])
          ])
        ),
      },
    },
    defaultVariants: {
      variant: 'default',
      size: 'default',
    },
    compoundVariants: [
      {
        variant: 'number',
        className: 'h-8 px-3 text-sm',
      },
    ],
  }
);

const Input = React.forwardRef<HTMLInputElement, InputProps>(
  ({ className, variant = 'default', size = 'default', type, style, ...props }, ref) => {
    const borderStyle = { border: 'var(--border)' };
    const shouldHaveBorder = variant !== 'amount';
    const combinedStyle = shouldHaveBorder ? { ...borderStyle, ...style } : style;

    return (
      <input
        type={type}
        className={inputVariants({ variant, size, className })}
        style={combinedStyle}
        lang="en-US"
        inputMode={type === 'number' ? 'decimal' : undefined}
        ref={ref}
        {...props}
      />
    );
  }
);
Input.displayName = 'Input';

export { Input };
