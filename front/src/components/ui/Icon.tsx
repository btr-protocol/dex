/**
 * Icon Component - Lucide Preact Icons
 * Wrapper for lucide-preact icons with automatic name mapping from Phosphor to Lucide
 */
import { JSX } from 'preact';
import { cn } from '@utils/cn';
import * as LucideIcons from 'lucide-preact';
import { logger } from '@sdk/utils';

const log = logger.withContext('icon');

/**
 * Mapping from Phosphor-style kebab-case names to Lucide PascalCase names
 * This allows existing code using Phosphor names to work with Lucide
 */
const PHOSPHOR_TO_LUCIDE: Record<string, string> = {
  // Arrows & Navigation
  'arrow-left': 'ArrowLeft',
  'arrow-right': 'ArrowRight',
  'arrow-up': 'ArrowUp',
  'arrow-down': 'ArrowDown',
  'caret-down': 'ChevronDown',
  'caret-left': 'ChevronLeft',
  'caret-right': 'ChevronRight',
  'caret-up': 'ChevronUp',
  'chevron-down': 'ChevronDown',
  'chevron-left': 'ChevronLeft',
  'chevron-right': 'ChevronRight',
  'chevron-up': 'ChevronUp',

  // Actions
  'check': 'Check',
  'check-circle': 'CheckCircle',
  'check-square': 'CheckSquare2',
  'x': 'X',
  'x-circle': 'XCircle',
  'plus': 'Plus',
  'minus': 'Minus',
  'copy': 'Copy',
  'download': 'Download',
  'upload': 'Upload',
  'paper-plane': 'Send',
  'send': 'Send',
  'floppy-disk': 'Save',
  'save': 'Save',
  'trash': 'Trash2',
  'pencil': 'Edit2', // Use Edit2 instead of Pencil
  'edit': 'Edit',
  'highlighter': 'Highlighter',
  'selection-all': 'MousePointerSquare',
  'cursor': 'MousePointer2', // Use MousePointer2 for cursor icon

  // UI Elements
  'magnifying-glass': 'Search',
  'search': 'Search',
  'funnel': 'Filter',
  'filter': 'Filter',
  'funnel-x': 'FilterX',
  'gear': 'Settings',
  'settings': 'Settings',
  'bell': 'Bell',
  'info': 'Info',
  'warning': 'AlertTriangle',
  'warning-circle': 'AlertCircle',
  'alert-circle': 'AlertCircle',
  'alert-triangle': 'AlertTriangle',

  // Social & External
  'envelope': 'Mail',
  'mail': 'Mail',
  'arrow-square-out': 'ExternalLink',
  'external-link': 'ExternalLink',
  'link': 'Link',
  'github-logo': 'Github',
  'github': 'Github',
  'twitter-logo': 'Twitter',
  'twitter': 'Twitter',

  // Finance & Business
  'wallet': 'Wallet',
  'trend-up': 'TrendingUp',
  'trending-up': 'TrendingUp',
  'trend-down': 'TrendingDown',
  'trending-down': 'TrendingDown',
  'chart-candlestick': 'ChartCandlestick',
  'chart-bar': 'BarChart',

  // Content & Media
  'book-open': 'BookOpen',
  'users': 'Users',
  'file-text': 'FileText',
  'file': 'File',
  'folder': 'Folder',
  'folder-open': 'FolderOpen',

  // Status & Feedback
  'circle-notch': 'Loader2',
  'loader': 'Loader2',
  'arrows-clockwise': 'RefreshCw',
  'refresh-cw': 'RefreshCw',

  // Auth & User
  'sign-out': 'LogOut',
  'log-out': 'LogOut',
  'sign-in': 'LogIn',
  'log-in': 'LogIn',
  'user': 'User',

  // Dev & Debug
  'bug': 'Bug',
  'robot': 'Bot',
  'bot': 'Bot',

  // Menu & Navigation
  'list': 'Menu',
  'menu': 'Menu',
  'bars-3': 'Menu',
  'dots-three-vertical': 'MoreVertical',
  'more-vertical': 'MoreVertical',
  'dots-three': 'MoreHorizontal',
  'more-horizontal': 'MoreHorizontal',

  // Additional common icons
  'target': 'Target',
  'crosshair': 'Crosshair',
  'palette': 'Palette',
  'globe': 'Globe',
  'star': 'Star',
  'package': 'Package',
  'arrows-left-right': 'ArrowLeftRight',
  'corners-out': 'Maximize2',
  'function': 'FunctionSquare',
  'box': 'Box',
  'clock': 'Clock',
  'calendar': 'Calendar',
  'image': 'Image',
  'play': 'Play',
  'pause': 'Pause',
  'stop': 'Square',
  'eye': 'Eye',
  'eye-slash': 'EyeOff',
  'eye-off': 'EyeOff',
  'lock': 'Lock',
  'unlock': 'Unlock',
  'key': 'Key',
  'shield': 'Shield',
  'heart': 'Heart',
  'bookmark': 'Bookmark',
  'tag': 'Tag',
  'hash': 'Hash',
  'at-sign': 'AtSign',
  'percent': 'Percent',
  'dollar-sign': 'DollarSign',
  'credit-card': 'CreditCard',
  'bar-chart': 'PieChart',
  'pie-chart': 'PieChart',
  'activity': 'Activity',
  'zap': 'Zap',
  'lightning': 'Zap',
  'flame': 'Flame',
  'fire': 'Flame',
  'sun': 'Sun',
  'moon': 'Moon',
  'cloud': 'Cloud',
  'droplet': 'Droplet',
  'thermometer': 'Thermometer',
  'map': 'Map',
  'map-pin': 'MapPin',
  'navigation': 'Navigation',
  'compass': 'Compass',
  'home': 'Home',
  'building': 'Building',
  'layers': 'Layers',
  'grid': 'Grid',
  'layout': 'Layout',
  'sidebar': 'Sidebar',
  'terminal': 'Terminal',
  'code': 'Code',
  'brackets': 'Braces',
  'database': 'Database',
  'server': 'Server',
  'cpu': 'Cpu',
  'hard-drive': 'HardDrive',
  'wifi': 'Wifi',
  'bluetooth': 'Bluetooth',
  'battery': 'Battery',
  'power': 'Power',
  'plug': 'Plug',
  'volume': 'Volume2',
  'volume-x': 'VolumeX',
  'mic': 'Mic',
  'mic-off': 'MicOff',
  'camera': 'Camera',
  'video': 'Video',
  'phone': 'Phone',
  'message-circle': 'MessageCircle',
  'message-square': 'MessageSquare',
  'share': 'Share2',
  'share-2': 'Share2',
  'repeat': 'Repeat',
  'shuffle': 'Shuffle',
  'skip-back': 'SkipBack',
  'skip-forward': 'SkipForward',
  'rewind': 'Rewind',
  'fast-forward': 'FastForward',
  'maximize': 'Maximize',
  'minimize': 'Minimize',
  'expand': 'Expand',
  'shrink': 'Shrink',
  'move': 'Move',
  'rotate-cw': 'RotateCw',
  'rotate-ccw': 'RotateCcw',
  'flip-horizontal': 'FlipHorizontal',
  'flip-vertical': 'FlipVertical',
  'crop': 'Crop',
  'scissors': 'Scissors',
  'clipboard': 'Clipboard',
  'printer': 'Printer',
  'paperclip': 'Paperclip',
  'link-2': 'Link2',
  'unlink': 'Unlink',
  'anchor': 'Anchor',
  'corner-down-left': 'CornerDownLeft',
  'corner-down-right': 'CornerDownRight',
  'corner-up-left': 'CornerUpLeft',
  'corner-up-right': 'CornerUpRight',
};

export interface IconProps extends Omit<JSX.SVGAttributes<SVGSVGElement>, 'size'> {
  /**
   * Icon name - supports both Lucide PascalCase and Phosphor kebab-case
   * Examples: 'ArrowLeft', 'arrow-left', 'Check', 'check', 'magnifying-glass'
   */
  name: string;
  /**
   * Icon size in pixels (default: 16)
   */
  size?: number | string;
  /**
   * Additional className for styling
   */
  className?: string;
}

/**
 * Resolve icon name to Lucide component name
 */
function resolveIconName(name: string): string {
  // Guard against empty/undefined names
  if (!name || name.length === 0) {
    return '';
  }

  // First, check if it's a direct Phosphor-to-Lucide mapping
  if (PHOSPHOR_TO_LUCIDE[name]) {
    return PHOSPHOR_TO_LUCIDE[name];
  }

  // If already PascalCase (starts with uppercase), use as-is
  if (name[0] === name[0].toUpperCase()) {
    return name;
  }

  // Convert kebab-case to PascalCase
  return name
    .split('-')
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');
}

/**
 * Icon component using lucide-preact icons
 * Automatically maps Phosphor-style names to Lucide equivalents
 *
 * @example
 * <Icon name="ArrowLeft" />
 * <Icon name="arrow-left" />
 * <Icon name="magnifying-glass" />  // Maps to Search
 * <Icon name="Check" size={20} className="text-primary" />
 */
export function Icon({ name, size = 16, className, ...props }: IconProps) {
  // Early return for empty names
  if (!name) return null;

  const lucideName = resolveIconName(name);
  const IconComponent = (LucideIcons as any)[lucideName];

  if (!IconComponent) {
    log.warn(`Icon "${name}" (resolved: "${lucideName}") not found in lucide-preact`);
    return null;
  }

  const sizeValue = typeof size === 'number' ? size : parseInt(size as string);

  return (
    <IconComponent
      size={sizeValue}
      className={cn(className)}
      {...props}
    />
  );
}

export type IconName = keyof typeof PHOSPHOR_TO_LUCIDE;
