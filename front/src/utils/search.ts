/**
 * Search utilities and icon mapping for SearchModal
 */

import { getFeatureIcon as getFeatureIconFromConst, getSettingsFieldIcon, getSocialIcon } from '@/constants/icons';

/**
 * Get icon name for search result based on title
 */
export const getFeatureIcon = (title: string): string => {
  // Check if it's a token swap (e.g., "Swap ETH")
  if (title.startsWith('Swap ')) {
    return 'arrows-left-right';
  }
  const icon = getFeatureIconFromConst(title);
  // Strip 'ph-' prefix if present, as Icon component adds 'i-ph-'
  return typeof icon === 'string' ? icon.replace(/^ph-/, '') : 'circles-three-plus';
};

/**
 * Extract token symbol from "Swap TOKEN" title
 */
export const getTokenFromTitle = (title: string): string | null => {
  if (title.startsWith('Swap ')) {
    return title.replace('Swap ', '').toLowerCase();
  }
  return null;
};

/**
 * Get settings icon type
 */
export const getSettingsIcon = getSettingsFieldIcon;

/**
 * Get social/link icon path
 */
export const getLinkIcon = getSocialIcon;

/**
 * Get icon path for settings based on type
 */
export const getSettingsIconPath = (type: string): string => {
  switch (type) {
    case 'slippage':
      return '/icons/slippage.svg';
    case 'theme':
      return '/icons/settings.svg';
    case 'interface':
      return '/icons/settings.svg';
    default:
      return '/icons/settings.svg';
  }
};
