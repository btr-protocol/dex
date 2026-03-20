import { useCallback, useMemo, useRef, useState } from 'preact/hooks';
import { Ref } from 'preact';
import { cn } from '@utils/cn';

interface SliderProps {
  value?: number[];
  defaultValue?: number[];
  min?: number;
  max?: number;
  step?: number;
  disabled?: boolean;
  className?: string;
  onValueChange?: (value: number[]) => void;
  showValue?: boolean;
  formatValue?: (value: number) => string;
  showTicks?: boolean;
  tickCount?: number;
  readOnly?: boolean;
  ref?: Ref<HTMLDivElement>;
}

export function Slider({
  value,
  defaultValue,
  min = 0,
  max = 100,
  step = 1,
  disabled = false,
  className,
  onValueChange,
  showValue = true,
  formatValue,
  showTicks = false,
  tickCount = 5,
  readOnly = false,
  ref,
}: SliderProps) {
  const [isDragging, setIsDragging] = useState(false);
  const sliderRef = useRef<HTMLDivElement>(null);

  const currentValue = value?.[0] ?? defaultValue?.[0] ?? min;
  const displayValue = formatValue ? formatValue(currentValue) : currentValue.toString();

  // Convert value to position (0 to 1)
  const valueToPosition = useCallback(
    (val: number): number => {
      return (val - min) / (max - min);
    },
    [min, max]
  );

  // Convert position (0 to 1) to value
  const positionToValue = useCallback(
    (pos: number): number => {
      const clampedPos = Math.max(0, Math.min(1, pos));
      const val = min + clampedPos * (max - min);
      const roundedVal = Math.round(val / step) * step;
      return Math.min(Math.max(roundedVal, min), max);
    },
    [min, max, step]
  );

  const currentPosition = useMemo(() => {
    return Math.min(valueToPosition(currentValue), 1);
  }, [currentValue, valueToPosition]);

  const handleMouseDown = useCallback(
    (e: MouseEvent) => {
        if (disabled || readOnly) return;

        setIsDragging(true);
        e.preventDefault();

        const handleMouseMove = (moveEvent: MouseEvent) => {
          if (!sliderRef.current) return;

          const rect = sliderRef.current.getBoundingClientRect();
          const pos = (moveEvent.clientX - rect.left) / rect.width;
          const newValue = positionToValue(pos);
          onValueChange?.([newValue]);
        };

        const handleMouseUp = () => {
          setIsDragging(false);
          document.removeEventListener('mousemove', handleMouseMove);
          document.removeEventListener('mouseup', handleMouseUp);
        };

        // Initial click position
        if (sliderRef.current) {
          const rect = sliderRef.current.getBoundingClientRect();
          const pos = (e.clientX - rect.left) / rect.width;
          const newValue = positionToValue(pos);
          onValueChange?.([newValue]);
        }

        document.addEventListener('mousemove', handleMouseMove);
        document.addEventListener('mouseup', handleMouseUp);
      },
      [disabled, readOnly, positionToValue, onValueChange]
    );

    // Generate tick marks
    const ticks = useMemo(() => {
      if (!showTicks) return [];
      const tickArray = [];
      const tickStep = (max - min) / (tickCount - 1);
      for (let i = 0; i < tickCount; i++) {
        const tickValue = min + i * tickStep;
        const rawPosition = ((tickValue - min) / (max - min)) * 100;
        const position = 2 + rawPosition * 0.96;
        tickArray.push({ value: tickValue, position });
      }
      return tickArray;
    }, [showTicks, min, max, tickCount]);

    return (
      <div ref={ref} className="flex items-center gap-2 w-full">
        <div className={cn('relative w-full', showTicks && 'mb-4')}>
          <div
            ref={sliderRef}
            className={cn(
              'relative h-[6px] rounded-full cursor-pointer select-none bg-bg-3',
              disabled && 'opacity-50 cursor-not-allowed',
              readOnly && 'cursor-default',
              className
            )}
            onMouseDown={handleMouseDown}
          >
            {/* Track fill */}
            <div
              className="absolute top-0 left-0 h-full bg-primary rounded-full transition-all duration-75"
              style={{ width: `${currentPosition * 100}%` }}
            />

            {/* Thumb */}
            {!readOnly && (
              <div
                className={cn(
                  'absolute top-1/2 w-3 h-3 bg-white rounded-full transform -translate-y-1/2 -translate-x-1/2 transition-all duration-75 z-10 shadow-lg',
                  isDragging && 'scale-110',
                  !disabled && 'hover:scale-105',
                  disabled && 'cursor-not-allowed'
                )}
                style={{ left: `${currentPosition * 100}%` }}
              />
            )}
          </div>

          {showTicks && (
            <div className="absolute left-0 right-0 top-full">
              {ticks.map((tick, i) => (
                <div
                  key={i}
                  className="absolute flex flex-col items-center -translate-x-1/2"
                  style={{ left: `${tick.position}%` }}
                >
                  <div className="w-px h-1 bg-fg-3" />
                  {(i === 0 || i === ticks.length - 1 || i === Math.floor(ticks.length / 2)) && (
                    <span className="text-[10px] text-fg-3 whitespace-nowrap leading-none">
                      {formatValue ? formatValue(tick.value) : Math.round(tick.value)}
                    </span>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {showValue && (
          <span className="text-sm font-semibold text-foreground tabular-nums min-w-[2.5rem] text-right mb-3">
            {displayValue}
          </span>
        )}
      </div>
    );
}
