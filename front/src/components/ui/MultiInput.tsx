import { h, type ComponentChildren } from 'preact';
import { useRef, useCallback } from 'preact/hooks';
import { cn } from '@utils/cn';
import { cva } from '@utils/cva';

export interface MultiInputProps {
  length?: number;
  separator?: ComponentChildren;
  value: string[];
  onChange: (values: string[]) => void;
  disabled?: boolean;
  className?: string;
  inputClassName?: string;
  error?: boolean;
}

const multiInputVariants = cva(
  'inline-flex items-center justify-center font-medium font-title text-center transition-colors focus:outline-none',
  {
    variants: {
      error: {
        true: 'border-destructive focus:border-destructive',
        false: 'border-border focus:border-primary',
      },
    },
    defaultVariants: {
      error: 'false' as const,
    },
  }
);

export function MultiInput({
  length = 6,
  separator = <span class="text-fg-2">-</span>,
  value,
  onChange,
  disabled = false,
  className,
  inputClassName,
  error = false,
}: MultiInputProps) {
  const inputRefs = useRef<(HTMLInputElement | null)[]>([]);

  const handleInputChange = useCallback((index: number, inputValue: string) => {
    const cleaned = inputValue.replace(/[^A-Z0-9]/gi, '').toUpperCase().slice(0, 1);
    const newValues = [...value];
    newValues[index] = cleaned;
    onChange(newValues);

    if (cleaned && index < length - 1) {
      inputRefs.current[index + 1]?.focus();
    }
  }, [value, onChange, length]);

  const handleKeyDown = useCallback((index: number, e: KeyboardEvent) => {
    if (e.key === 'Backspace' && !value[index] && index > 0) {
      inputRefs.current[index - 1]?.focus();
    } else if (e.key === 'ArrowLeft' && index > 0) {
      inputRefs.current[index - 1]?.focus();
    } else if (e.key === 'ArrowRight' && index < length - 1) {
      inputRefs.current[index + 1]?.focus();
    }
  }, [value, length]);

  const handlePaste = useCallback((e: ClipboardEvent) => {
    e.preventDefault();
    const pastedData = e.clipboardData?.getData('text') || '';
    const cleaned = pastedData.replace(/[^A-Z0-9]/gi, '').toUpperCase().slice(0, length);

    if (cleaned.length === length) {
      onChange(cleaned.split(''));
    }
  }, [length, onChange]);

  const handleFocus = useCallback((e: FocusEvent) => {
    (e.target as HTMLInputElement).select();
  }, []);

  return (
    <div class={cn('flex items-center gap-2', className)}>
      {Array.from({ length }).map((_, index) => (
        <>
          <input
            key={index}
            ref={(el) => { inputRefs.current[index] = el; }}
            type="text"
            inputMode="text"
            maxLength={1}
            value={value[index] || ''}
            onInput={(e) => handleInputChange(index, (e.target as HTMLInputElement).value)}
            onKeyDown={(e) => handleKeyDown(index, e)}
            onPaste={handlePaste}
            onFocus={handleFocus}
            disabled={disabled}
            class={cn(
              multiInputVariants({ error: error ? 'true' : 'false' }),
              'w-16 h-20 border rounded-sm bg-bg-2 text-3xl uppercase',
              disabled && 'opacity-50 pointer-events-none',
              inputClassName
            )}
          />
          {/* Show separator after 3rd character (index 2) for 6-char input */}
          {separator && index === Math.floor(length / 2) - 1 && (
            <span class="mx-3 text-fg-2 text-4xl">-</span>
          )}
        </>
      ))}
    </div>
  );
}
