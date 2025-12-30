/**
 * Icon Helper Utilities
 * Centralized icon rendering logic for modals and dropdowns
 * Uses lucide-preact icons
 */
import { Icon } from '@components/ui/Icon';
import type { IconType } from '@/types/ui';

export type { IconType } from '@/types/ui';

/**
 * Check if icon is a string path (for <img> rendering)
 */
export function isStringIcon(icon: IconType): icon is string {
  return typeof icon === 'string';
}

/**
 * Check if icon is an SVG path (vs icon name)
 */
export function isSvgPath(icon: string): boolean {
  return icon.includes('/') && icon.endsWith('.svg');
}

/**
 * Render an icon based on its type
 * Handles icon names (lucide-preact), SVG paths, and Preact nodes
 */
export function renderIcon(icon: IconType | undefined, className?: string) {
  if (!icon) return null;

  if (typeof icon === 'string') {
    if (isSvgPath(icon)) {
      return <img src={icon} className={className} alt="" />;
    }
    // Icon name - render using lucide-preact Icon component
    return <Icon name={icon} className={className} />;
  }

  return icon;
}
