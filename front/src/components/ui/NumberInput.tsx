import { forwardRef } from 'react';

interface NumberInputProps {
  label?: string;
  value: number;
  onChange: (value: number) => void;
  min?: number;
  max?: number;
  step?: number;
  layout?: 'vertical' | 'horizontal';
  variant?: 'default' | 'inline';
  error?: string;
  helperText?: string;
  className?: string;
  disabled?: boolean;
  [key: string]: any;
}

/**
 * Standardized number input component
 * Consolidates repeated pattern: label + number input across LiquidityShaper, SettingsModal, etc.
 *
 * @example
 * <NumberInput
 *   label="Base Breadth (bps)"
 *   value={baseBreadth}
 *   onChange={setBaseBreadth}
 *   min={0}
 *   max={1000000}
 *   layout="vertical"
 * />
 */
export const NumberInput = forwardRef<HTMLInputElement, NumberInputProps>(
  ({
    label,
    value,
    onChange,
    layout = 'vertical',
    variant = 'default',
    error,
    helperText,
    min,
    max,
    step,
    className = '',
    ...props
  }, ref) => {
    const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
      const numValue = Number(e.currentTarget.value);
      if (!isNaN(numValue)) {
        onChange(numValue);
      }
    };

    const containerClasses = layout === 'horizontal'
      ? 'flex items-center justify-between gap-4'
      : 'flex flex-col gap-2';

    const inputClasses = `w-full px-3 py-2 border border-border rounded-sm bg-bg-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary disabled:opacity-50 disabled:cursor-not-allowed ${className}`;

    return (
      <div className={containerClasses}>
        {label && (
          <label className={`text-sm font-medium ${layout === 'horizontal' ? 'shrink-0' : ''}`}>
            {label}
          </label>
        )}
        <div className={layout === 'horizontal' ? '' : 'w-full'}>
          <input
            ref={ref}
            type="number"
            value={value}
            onChange={handleChange}
            min={min}
            max={max}
            step={step}
            lang="en-US"
            className={inputClasses}
            {...props}
          />
          {error && <p className="text-xs text-red-500 mt-1">{error}</p>}
          {helperText && <p className="text-xs text-muted-foreground mt-1">{helperText}</p>}
        </div>
      </div>
    );
  }
);

NumberInput.displayName = 'NumberInput';
