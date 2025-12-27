/**
 * Swap form constants and options
 */

import type { DropdownItem } from '@components/ui/Dropdown';
import type { OrderType } from '@/lib/swap/SwapStore';

/**
 * Order type options for swap form dropdown
 */
export const ORDER_TYPE_OPTIONS: DropdownItem<OrderType>[] = [
  { value: 'market', label: 'Market' },
  { value: 'limit', label: 'Limit', disabled: true, tooltip: 'Limit orders not available yet' },
  { value: 'stop', label: 'Stop', disabled: true, tooltip: 'Stop orders not available yet' },
];
