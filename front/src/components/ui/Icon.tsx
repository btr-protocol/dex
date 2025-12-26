/**
 * Icon Component - UnoCSS Phosphor Icons
 * Wrapper for Phosphor icons via UnoCSS presets
 */
import { JSX } from 'preact';
import { cn } from '@utils/cn';

export interface IconProps extends JSX.HTMLAttributes<HTMLElement> {
  /**
   * Phosphor icon name (without 'ph-' prefix)
   * Examples: 'arrow-left', 'check', 'x', 'caret-down'
   */
  name: string;
  /**
   * Icon size in pixels (default: 16)
   * Will be converted to width/height classes
   */
  size?: number | string;
  /**
   * Additional className for styling
   */
  className?: string;
}

/**
 * Icon component using UnoCSS Phosphor icons
 *
 * @example
 * <Icon name="arrow-left" />
 * <Icon name="check" size={20} className="text-primary" />
 */
export function Icon({ name, size = 16, className, ...props }: IconProps) {
  const sizeValue = typeof size === 'number' ? `${size}px` : size;

  return (
    <i
      className={cn(`i-ph-${name}`, className)}
      style={{ fontSize: sizeValue, width: sizeValue, height: sizeValue }}
      {...props}
    />
  );
}

/**
 * Common icon mappings from lucide-react to Phosphor
 * Use these constants for consistency across the codebase
 */
export const ICON_NAMES = {
  // Arrows & Navigation
  arrowLeft: 'arrow-left',
  arrowRight: 'arrow-right',
  arrowUp: 'arrow-up',
  arrowDown: 'arrow-down',
  caretDown: 'caret-down',
  caretLeft: 'caret-left',
  caretRight: 'caret-right',
  caretUp: 'caret-up',

  // Actions
  check: 'check',
  checkCircle: 'check-circle',
  x: 'x',
  xCircle: 'x-circle',
  plus: 'plus',
  minus: 'minus',
  copy: 'copy',
  download: 'download',
  upload: 'upload',
  send: 'paper-plane',
  save: 'floppy-disk',
  trash: 'trash',

  // UI Elements
  search: 'magnifying-glass',
  filter: 'funnel',
  filterX: 'funnel-x',
  settings: 'gear',
  bell: 'bell',
  info: 'info',
  warning: 'warning',
  alertCircle: 'warning-circle',

  // Social & External
  mail: 'envelope',
  externalLink: 'arrow-square-out',
  link: 'link',
  github: 'github-logo',
  twitter: 'twitter-logo',

  // Finance & Business
  wallet: 'wallet',
  trendUp: 'trend-up',
  trendDown: 'trend-down',

  // Content & Media
  bookOpen: 'book-open',
  users: 'users',

  // Status & Feedback
  loader: 'circle-notch',
  refreshCw: 'arrows-clockwise',

  // Auth & User
  logOut: 'sign-out',

  // Dev & Debug
  bug: 'bug',
} as const;

export type IconName = keyof typeof ICON_NAMES;
