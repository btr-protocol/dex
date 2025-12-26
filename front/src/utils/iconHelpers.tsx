/**
 * Icon Helper Utilities
 * Centralized icon rendering logic for modals and dropdowns
 * Uses UnoCSS Phosphor icons (CSS classes)
 */
import { cn } from './cn';
import type { IconType } from '@/types/ui';

export type { IconType } from '@/types/ui';

/**
 * Get UnoCSS icon class name from icon identifier
 * For Phosphor icons, converts 'ph-iconname' to 'i-ph-iconname'
 */
export function getIconClass(icon: string | undefined): string {
  if (!icon) return '';
  if (icon.startsWith('i-')) return icon; // Already formatted
  if (icon.startsWith('ph-')) return `i-${icon}`; // Phosphor icon
  if (icon.includes('/')) return ''; // SVG path - handled separately
  return `i-ph-${icon}`; // Default to Phosphor prefix
}

/**
 * Check if icon is a string path (for <img> rendering)
 */
export function isStringIcon(icon: IconType): icon is string {
  return typeof icon === 'string';
}

/**
 * Check if icon is an SVG path (vs icon class name)
 */
export function isSvgPath(icon: string): boolean {
  return icon.includes('/') && icon.endsWith('.svg');
}

/**
 * Render an icon based on its type
 * Handles UnoCSS classes, SVG paths, and ReactNodes
 */
export function renderIcon(icon: IconType | undefined, className?: string) {
  if (!icon) return null;

  if (typeof icon === 'string') {
    if (isSvgPath(icon)) {
      return <img src={icon} className={className} alt="" />;
    }
    const iconClass = getIconClass(icon);
    return <i className={cn(iconClass, className)} aria-hidden="true" />;
  }

  return icon;
}
