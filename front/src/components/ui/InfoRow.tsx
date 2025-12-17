/**
 * InfoRow - Consolidated component for label + value rows
 * Replaces 30+ lines of duplicated cost/info row patterns
 */
import { MaskIcon } from './MaskIcon';
import { FlexRow, FlexBetween } from './Flex';
import type { ReactNode } from 'react';

interface InfoRowProps {
  label: string;
  value: string | ReactNode;
  icon?: string; // Path to icon SVG
  iconColor?: string;
  iconLabel?: string;
  secondaryValue?: string; // Optional second value (e.g., USD amount)
  className?: string;
  labelClassName?: string;
  valueClassName?: string;
}

/**
 * Standard info row with optional icon, label, and value(s)
 * Use cases: gas fees, price impact, totals, stats
 */
export function InfoRow({
  label,
  value,
  icon,
  iconColor = 'var(--fg-3)',
  iconLabel,
  secondaryValue,
  className = '',
  labelClassName = 'text-fg-3',
  valueClassName = 'text-foreground',
}: InfoRowProps) {
  return (
    <FlexBetween className={`px-1 text-sm ${className}`}>
      <FlexRow gap="2" className={labelClassName}>
        {icon && (
          <MaskIcon
            src={icon}
            size="md"
            color={iconColor}
            aria-label={iconLabel || label}
          />
        )}
        <span>{label}</span>
      </FlexRow>
      <div className={`text-right font-numeric ${valueClassName}`}>
        {typeof value === 'string' ? <span>{value}</span> : value}
        {secondaryValue && (
          <span className="text-foreground ml-2">{secondaryValue}</span>
        )}
      </div>
    </FlexBetween>
  );
}

/**
 * Compact variant without icon for simple label/value pairs
 */
export function InfoRowCompact({
  label,
  value,
  className = '',
}: {
  label: string;
  value: string | ReactNode;
  className?: string;
}) {
  return (
    <FlexBetween className={`px-1 text-sm ${className}`}>
      <span className="text-muted-foreground">{label}</span>
      <span className="text-foreground font-numeric">{value}</span>
    </FlexBetween>
  );
}

/**
 * Section header for groups of info rows
 */
export function InfoSection({
  title,
  children,
  className = '',
}: {
  title?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`${className}`}>
      {title && (
        <div className="text-md font-title font-medium text-fg-3 uppercase tracking-wide px-1">
          {title}
        </div>
      )}
      {children}
    </div>
  );
}
