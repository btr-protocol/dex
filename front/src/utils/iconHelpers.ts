/**
 * Icon Helper Utilities
 * Centralized icon rendering logic for modals and dropdowns
 */
import { ComponentType, createElement } from 'preact/compat';
import type { LucideProps } from 'lucide-react';
import type { IconType } from '@/types/ui';

export type { IconType } from '@/types/ui';

/**
 * Render icon with proper className
 * String icons return null (handled separately with <img>)
 */
export function renderIcon(icon: IconType, className: string): ReactNode {
  if (typeof icon === 'string') {
    return null; // handled separately with img
  }
  if (typeof icon === 'function') {
    const IconComponent = icon as ComponentType<LucideProps>;
    return createElement(IconComponent, { className });
  }
  return icon;
}

/**
 * Check if icon is a string path (for <img> rendering)
 */
export function isStringIcon(icon: IconType): icon is string {
  return typeof icon === 'string';
}

/**
 * Check if icon is a Lucide component function
 */
export function isComponentIcon(icon: IconType): icon is ComponentType<LucideProps> {
  return typeof icon === 'function';
}
