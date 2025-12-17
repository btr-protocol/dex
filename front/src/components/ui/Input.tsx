import * as React from 'react';
import { cn } from '@utils/cn';
import { type Size, SIZE_HEIGHTS, SIZE_PADDINGS, SIZE_TEXT } from './sizes';

type InputVariant = 'default' | 'amount' | 'address' | 'number' | 'search';

export interface InputProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, 'size'> {
  variant?: InputVariant;
  size?: Size;
}

const sizeHeights: Record<Size, string> = SIZE_HEIGHTS;
const sizePaddings: Record<Size, string> = SIZE_PADDINGS;
const sizeText: Record<Size, string> = SIZE_TEXT;

const Input = React.forwardRef<HTMLInputElement, InputProps>(
  ({ className, variant = 'default', size = 'default', type, style, ...props }, ref) => {
    const baseStyles = 'bg-bg-2 rounded-sm focus:outline-none transition-colors font-medium';
    const borderStyle = { border: 'var(--border)' };
    const focusBorderStyle = 'focus:border-primary';

    // Size classes from shared config
    const sizeClass = cn(sizeHeights[size], sizePaddings[size], sizeText[size]);

    const variantStyles: Record<InputVariant, string> = {
      default: `w-full ${baseStyles} ${focusBorderStyle} ${sizeClass}`,
      amount: 'outline-none w-full text-right placeholder:text-fg-2 text-fg-0 font-numeric font-medium',
      address: `w-full ${baseStyles} ${focusBorderStyle} ${sizeClass} font-mono`,
      number: `w-20 ${baseStyles} ${focusBorderStyle} h-8 px-3 text-sm text-right font-numeric`,
      search: `${baseStyles} ${focusBorderStyle} ${sizeClass} pl-9 pr-4`,
    };

    const shouldHaveBorder = variant !== 'amount';
    const combinedStyle = shouldHaveBorder ? { ...borderStyle, ...style } : style;

    return (
      <input
        type={type}
        className={cn(variantStyles[variant], className)}
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
