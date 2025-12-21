/**
 * TableCell - Consolidated table cell patterns
 * Reduces duplication in dashboard/table components
 */
import { FlexBetween } from './Flex';
import { PercentageChange } from './PercentageChange';
import type { ReactNode } from 'react';

interface TableCellWithChangeProps {
  value: string | ReactNode;
  changeValue?: number;
  changeLabel?: string;
  className?: string;
  valueClassName?: string;
}

/**
 * Table cell with value and optional percentage change indicator
 * Replaces 6x identical patterns in PoolDashboard
 */
export function TableCellWithChange({
  value,
  changeValue,
  changeLabel,
  className = 'px-4 py-3 font-mono text-sm text-gray-300',
  valueClassName = '',
}: TableCellWithChangeProps) {
  return (
    <td className={className}>
      <FlexBetween>
        <span className={valueClassName}>{value}</span>
        {changeValue !== undefined && (
          <PercentageChange value={changeValue} label={changeLabel} />
        )}
      </FlexBetween>
    </td>
  );
}
