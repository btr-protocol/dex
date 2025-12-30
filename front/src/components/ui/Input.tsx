import { Ref } from 'preact';
import type { HTMLAttributes } from 'preact/compat';
import { cn } from '@utils/cn';
import { cva } from '@utils/cva';
import { type Size, BORDER_RADIUS, SIZE_HEIGHTS, SIZE_PADDINGS, SIZE_TEXT } from '@/constants/design';

type InputVariant = 'default' | 'amount' | 'address' | 'number' | 'search';

export interface InputProps extends Omit<HTMLAttributes<HTMLInputElement>, 'size'> {
  variant?: InputVariant
  size?: Size
  type?: string
  ref?: Ref<HTMLInputElement>
  value?: string | number
  placeholder?: string
  onChange?: (e: Event) => void
  disabled?: boolean
  readOnly?: boolean
  min?: number | string
  max?: number | string
  step?: number | string
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
      size: Object.fromEntries(
          Object.keys(SIZE_HEIGHTS).map(s => [
            s,
            cn(SIZE_HEIGHTS[s as Size], SIZE_PADDINGS[s as Size], SIZE_TEXT[s as Size])
          ])
        ),
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

export function Input({ className, variant = 'default', size = 'default', type, style, ref, ...props }: InputProps) {
  const borderStyle = { border: 'var(--border)' };
  const shouldHaveBorder = variant !== 'amount';
  const styleValue = typeof style === 'object' && style !== null ? style : undefined;
  const combinedStyle = shouldHaveBorder && styleValue ? { ...borderStyle, ...styleValue } : shouldHaveBorder ? borderStyle : styleValue;
  const classNameValue = typeof className === 'string' ? className : undefined;

  return (
    <input
      type={type}
      className={inputVariants({ variant, size, className: classNameValue })}
      style={combinedStyle}
      lang="en-US"
      inputMode={type === 'number' ? 'decimal' : undefined}
      ref={ref}
      {...props}
    />
  );
}