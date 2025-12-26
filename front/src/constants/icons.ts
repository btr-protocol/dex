/**
 * Icon mappings - single source of truth
 * Centralizes all icon lookups used across the application
 * Uses UnoCSS Phosphor icons (i-ph-*)
 */

// ============================================================================
// Feature Icons (Phosphor icon classes)
// ============================================================================

export const FEATURE_ICONS = {
  'Swap': 'ph-arrow-left-right',
  'Liquidity': 'ph-lightning-bold',
  'Stake': 'ph-trend-up',
  'Metrics': 'ph-text-outline',
  'Add Asset': 'ph-plus',
  'Documentation': 'ph-text-outline',
} as const;

export type FeatureName = keyof typeof FEATURE_ICONS;

// ============================================================================
// Settings Category Icons (Phosphor icon classes)
// ============================================================================

export const SETTINGS_CATEGORY_ICONS = {
  'execution': 'ph-target',
  'interface': 'ph-palette',
  'region': 'ph-globe',
  'other': 'ph-package',
} as const;

export type SettingsCategoryId = keyof typeof SETTINGS_CATEGORY_ICONS;

// ============================================================================
// Settings Field Icons (by field title)
// ============================================================================

export const SETTINGS_FIELD_ICONS = {
  'Max Slippage': 'slippage',
  'Detail Route': 'slippage',
  'Theme': 'theme',
  'Hide Small Balances': 'interface',
  'Hide Unsupported Tokens': 'interface',
  'Show Test Networks': 'interface',
  'Animate Background': 'interface',
  'Ring Count': 'interface',
  'Rotation Speed': 'interface',
  'Eye Size': 'interface',
  'Currency': 'region',
  'Language': 'region',
  'Export Format': 'other',
} as const;

export type SettingsFieldName = keyof typeof SETTINGS_FIELD_ICONS;

// ============================================================================
// Social/External Link Icons
// ============================================================================

export const SOCIAL_ICONS = {
  'Telegram': '/icons/telegram.svg',
  'Github': '/icons/github.svg',
  'GitHub': '/icons/github.svg',
  'X': '/icons/x.svg',
  'X (Twitter)': '/icons/x.svg',
  'Twitter': '/icons/x.svg',
  'Docs': '/icons/docs.svg',
  'Documentation': '/icons/docs.svg',
} as const;

export type SocialPlatform = keyof typeof SOCIAL_ICONS;

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Get feature icon component by title
 */
export function getFeatureIcon(title: string) {
  return FEATURE_ICONS[title as FeatureName] ?? null;
}

/**
 * Get settings category icon by category ID
 */
export function getSettingsCategoryIcon(categoryId: string) {
  return SETTINGS_CATEGORY_ICONS[categoryId as SettingsCategoryId] ?? 'ph-package';
}

/**
 * Get settings field icon identifier by field title
 */
export function getSettingsFieldIcon(title: string): string {
  return SETTINGS_FIELD_ICONS[title as SettingsFieldName] ?? 'settings';
}

/**
 * Get social/external link icon path by title
 */
export function getSocialIcon(title: string): string | null {
  return SOCIAL_ICONS[title as SocialPlatform] ?? null;
}
