/**
 * Shared size configuration for all UI components.
 * Ensures consistent sizing across Button, Input, Dropdown, IconButton, etc.
 *
 * Size scale:
 * - xs: 24px height, extra small text
 * - sm: 32px height, small text (toolbar buttons)
 * - default: 40px height, base text
 * - lg: 48px height, large text
 * - xl: 56px height, extra large text
 * - compact-xl: xl text but compact padding (toggle buttons)
 */

export type Size = 'xs' | 'sm' | 'default' | 'lg' | 'xl' | 'compact-xl';

// Height classes for each size
export const SIZE_HEIGHTS = {
  xs: 'h-6',      // 24px
  sm: 'h-8',      // 32px
  default: 'h-10', // 40px
  lg: 'h-12',     // 48px
  xl: 'h-14',     // 56px
  'compact-xl': 'h-auto', // Auto height for compact
} as const;

// Width classes for icon-only buttons
export const SIZE_ICON_WIDTHS = {
  xs: 'w-6',
  sm: 'w-8',
  default: 'w-10',
  lg: 'w-12',
  xl: 'w-14',
  'compact-xl': 'w-10',
} as const;

// Padding classes for buttons with text
export const SIZE_PADDINGS = {
  xs: 'px-2',
  sm: 'px-3',
  default: 'px-4',
  lg: 'px-6',
  xl: 'px-8',
  'compact-xl': 'px-4 py-1.5',
} as const;

// Text size classes
export const SIZE_TEXT = {
  xs: 'text-xs',
  sm: 'text-sm',
  default: 'text-base',
  lg: 'text-lg',
  xl: 'text-xl',
  'compact-xl': 'text-2xl leading-tight',
} as const;

// Icon size classes (for lucide icons)
export const SIZE_ICONS = {
  xs: 'w-3 h-3',
  sm: 'w-3.5 h-3.5',
  default: 'w-4 h-4',
  lg: 'w-5 h-5',
  xl: 'w-6 h-6',
  'compact-xl': 'w-6 h-6',
} as const;

// Gap between icon and text
export const SIZE_GAPS = {
  xs: 'gap-1.5',
  sm: 'gap-2',
  default: 'gap-2.5',
  lg: 'gap-3',
  xl: 'gap-3',
  'compact-xl': 'gap-2',
} as const;

// Checkmark sizes in dropdowns
export const SIZE_CHECK = {
  xs: 'w-3 h-3',
  sm: 'w-3.5 h-3.5',
  default: 'w-4 h-4',
  lg: 'w-5 h-5',
  xl: 'w-6 h-6',
  'compact-xl': 'w-6 h-6',
} as const;

// Combined size map for dropdown items
export const DROPDOWN_ITEM_SIZES = {
  xs: { item: 'px-2 py-1 text-xs gap-1.5', icon: 'w-3 h-3', check: 'w-3 h-3' },
  sm: { item: 'px-2 py-1.5 text-xs gap-2', icon: 'w-3.5 h-3.5', check: 'w-3.5 h-3.5' },
  default: { item: 'px-3 py-2 text-sm gap-2.5', icon: 'w-4 h-4', check: 'w-4 h-4' },
  lg: { item: 'px-4 py-2.5 text-base gap-3', icon: 'w-5 h-5', check: 'w-5 h-5' },
  xl: { item: 'px-5 py-3 text-lg gap-3', icon: 'w-6 h-6', check: 'w-6 h-6' },
  'compact-xl': { item: 'px-4 py-2 text-xl gap-2', icon: 'w-6 h-6', check: 'w-6 h-6' },
} as const;
