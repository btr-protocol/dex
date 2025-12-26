/**
 * Shared UI Component Types
 * Centralized type definitions for modals, dropdowns, and related UI components
 */

import type { ComponentChildren } from 'preact';

/** Icon can be: UnoCSS class name, SVG path, or ComponentChildren */
export type IconType = string | ComponentChildren;

/**
 * Selection list item (used by SelectionModal)
 * Flexible item for single/multi-select modals with optional metadata
 */
export interface SelectionItem {
  id: string;
  label: string;
  caption?: string;
  icon?: IconType;
  badge?: ComponentChildren;
  data?: any;
  disabled?: boolean;
}

/**
 * Filter/multi-select option (used by MultiSelectModal)
 * Specialized item for filter buttons with primary + mini icons
 */
export interface FilterOption {
  id: string;
  name: string;
  caption?: string;
  icon: IconType;
  miniIcon?: IconType;
}

/**
 * Dropdown menu item (used by Dropdown component)
 * Generic dropdown item with value, label, and optional tooltip
 */
export interface DropdownItem<T = string> {
  value: T;
  label: string;
  icon?: IconType;
  disabled?: boolean;
  tooltip?: string;
}
