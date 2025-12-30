import { useState } from 'preact/hooks';
import { Icon } from './Icon';

interface PercentageChangeProps {
  value: number; // percentage change (e.g., 5 for 5%)
  label?: string; // optional label for tooltip
}

export function PercentageChange({ value, label }: PercentageChangeProps) {
  const [showTooltip, setShowTooltip] = useState(false);
  const isPositive = value >= 0;
  const absValue = Math.abs(value);

  return (
    <div className="relative inline-flex items-center">
      <button
        onMouseEnter={() => setShowTooltip(true)}
        onMouseLeave={() => setShowTooltip(false)}
        className="flex items-center gap-1 px-2 py-1 rounded hover:bg-bg-2 transition-colors"
        aria-label={`${label || 'Change'}: ${isPositive ? '+' : '-'}${absValue.toFixed(2)}%`}
      >
        {isPositive ? (
          <Icon name="trend-up" className="w-4 h-4 text-green" />
        ) : (
          <Icon name="trend-down" className="w-4 h-4 text-red" />
        )}
      </button>

      {showTooltip && (
        <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 z-10">
          <div className="bg-bg-2 border border-border rounded px-3 py-2 text-xs whitespace-nowrap shadow-lg">
            <span className={isPositive ? 'text-green' : 'text-red'}>
              {isPositive ? '+' : '-'}{absValue.toFixed(2)}%
            </span>
            {label && <div className="text-fg-2 text-xs mt-1">{label}</div>}
          </div>
          <div className="absolute top-full left-1/2 -translate-x-1/2 w-2 h-2 bg-bg-2 border-r border-b border-border transform rotate-45 -mt-1" />
        </div>
      )}
    </div>
  );
}
