/**
 * Unified Settings Configuration
 * Single source of truth for settings structure, validation, and rendering
 */

// ─────────────────────────────────────────────────────────────
// Setting Types
// ─────────────────────────────────────────────────────────────

type IconValue = string | null | undefined;

export type SettingType =
  | { type: 'toggle' }
  | { type: 'number'; min: number; max: number; step: number }
  | { type: 'slider'; min: number; max: number; step: number; format?: (v: number) => string }
  | { type: 'select'; options: Array<{ value: string; label: string; icon?: IconValue }> }
  | { type: 'multiselect'; options: Array<{ value: string; label: string; icon?: IconValue }> };

export interface SettingDef {
  id: string;
  label: string;
  description: string;
  config: SettingType;
  keywords?: string[];
  showIf?: string; // ID of parent setting that must be true
}

export interface SettingCategory {
  id: string;
  label: string;
  icon: string;
  settings: SettingDef[];
}

// ─────────────────────────────────────────────────────────────
// Settings Schema
// ─────────────────────────────────────────────────────────────

export const SETTINGS_SCHEMA: SettingCategory[] = [
  {
    id: 'execution',
    label: 'Execution',
    icon: 'target',
    settings: [
      {
        id: 'maxSlippage',
        label: 'Max Slippage',
        description: 'Maximum slippage percentage for trades',
        config: { type: 'number', min: 0, max: 100, step: 0.1 },
        keywords: ['trade', 'swap', 'slippage']
      },
      {
        id: 'detailRoute',
        label: 'Detail Route',
        description: 'Show detailed routing information',
        config: { type: 'toggle' },
        keywords: ['route', 'routing']
      }
    ]
  },
  {
    id: 'interface',
    label: 'Interface',
    icon: 'palette',
    settings: [
      {
        id: 'theme',
        label: 'Theme',
        description: 'Color scheme preference',
        config: {
          type: 'select',
          options: [
            { value: 'dark', label: 'Dark' },
            { value: 'light', label: 'Light' }
          ]
        },
        keywords: ['dark', 'light', 'mode', 'appearance']
      },
      {
        id: 'hideSmallBalances',
        label: 'Hide Small Balances',
        description: 'Hide tokens with small amounts',
        config: { type: 'toggle' },
        keywords: ['balance', 'hide', 'display']
      },
      {
        id: 'hideUnsupportedTokens',
        label: 'Hide Unsupported Tokens',
        description: 'Hide unsupported tokens',
        config: { type: 'toggle' },
        keywords: ['tokens', 'unsupported']
      },
      {
        id: 'showTestNetworks',
        label: 'Show Test Networks',
        description: 'Display test and local networks in chain filters',
        config: { type: 'toggle' },
        keywords: ['testnet', 'test', 'networks', 'local', 'anvil', 'sepolia', 'development']
      },
      {
        id: 'animateBackground',
        label: 'Animate Background',
        description: 'Enable background animations',
        config: { type: 'toggle' },
        keywords: ['animation', 'effects']
      },
      {
        id: 'ringCount',
        label: 'Ring Count',
        description: 'Number of background rings',
        config: { type: 'slider', min: 4, max: 32, step: 1 },
        showIf: 'animateBackground'
      },
      {
        id: 'rotationSpeed',
        label: 'Rotation Speed',
        description: 'Background rotation speed',
        config: { type: 'slider', min: 5, max: 100, step: 5 },
        showIf: 'animateBackground'
      },
      {
        id: 'eyeSize',
        label: 'Eye Size',
        description: 'Central eye size percentage',
        config: { type: 'slider', min: 5, max: 30, step: 1, format: (v) => `${v}%` },
        showIf: 'animateBackground'
      }
    ]
  },
  {
    id: 'region',
    label: 'Region',
    icon: 'globe',
    settings: [
      {
        id: 'currency',
        label: 'Currency',
        description: 'Display currency preference',
        config: {
          type: 'select',
          options: [
            { value: 'USD', label: 'USD ($)' },
            { value: 'EUR', label: 'EUR (€)' },
            { value: 'GBP', label: 'GBP (£)' },
            { value: 'JPY', label: 'JPY (¥)' }
          ]
        },
        keywords: ['usd', 'eur', 'gbp', 'jpy']
      },
      {
        id: 'language',
        label: 'Language',
        description: 'Interface language',
        config: {
          type: 'select',
          options: [
            { value: 'en-US', label: 'English' },
            { value: 'es-ES', label: 'Español' },
            { value: 'fr-FR', label: 'Français' },
            { value: 'de-DE', label: 'Deutsch' },
            { value: 'zh-CN', label: '中文' },
            { value: 'ja-JP', label: '日本語' }
          ]
        },
        keywords: ['locale', 'i18n']
      }
    ]
  },
  {
    id: 'preferences',
    label: 'Preferences',
    icon: 'star',
    settings: [
      {
        id: 'swapTokenIn',
        label: 'Default Swap Input',
        description: 'Default token for swap input',
        config: { type: 'select', options: [] },
        keywords: ['swap', 'token', 'input', 'default']
      },
      {
        id: 'swapTokenOut',
        label: 'Default Swap Output',
        description: 'Default token for swap output',
        config: { type: 'select', options: [] },
        keywords: ['swap', 'token', 'output', 'default']
      },
      {
        id: 'chartBase',
        label: 'Chart Base Asset',
        description: 'Default base asset for price charts',
        config: { type: 'select', options: [] },
        keywords: ['chart', 'base', 'asset', 'pair']
      },
      {
        id: 'chartQuote',
        label: 'Chart Quote Asset',
        description: 'Default quote asset for price charts',
        config: { type: 'select', options: [] },
        keywords: ['chart', 'quote', 'asset', 'pair']
      }
    ]
  },
  {
    id: 'other',
    label: 'Other',
    icon: 'package',
    settings: [
      {
        id: 'exportFormat',
        label: 'Export Format',
        description: 'Data export format',
        config: {
          type: 'select',
          options: [
            { value: 'JSON', label: 'JSON' },
            { value: 'CSV', label: 'CSV' },
            { value: 'XML', label: 'XML' }
          ]
        },
        keywords: ['export', 'format', 'json', 'csv', 'xml']
      }
    ]
  }
];

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

export function getCategory(id: string): SettingCategory | undefined {
  return SETTINGS_SCHEMA.find(c => c.id === id);
}

export function getSetting(id: string): { setting: SettingDef; category: SettingCategory } | undefined {
  for (const cat of SETTINGS_SCHEMA) {
    const setting = cat.settings.find(s => s.id === id);
    if (setting) return { setting, category: cat };
  }
}

export interface AppSettings {
  // Execution
  maxSlippage: number;
  detailRoute: boolean;
  // Interface
  hideSmallBalances: boolean;
  hideUnsupportedTokens: boolean;
  showTestNetworks: boolean;
  animateBackground: boolean;
  ringCount: number;
  rotationSpeed: number;
  eyeSize: number;
  // Region
  currency: string;
  language: string;
  // Preferences
  swapTokenIn: string;
  swapTokenOut: string;
  chartBase: string;
  chartQuote: string;
  // Other
  exportFormat: string;
}

export function getDefaultSettings(): AppSettings {
  const defaults: any = {};
  for (const cat of SETTINGS_SCHEMA) {
    for (const setting of cat.settings) {
      const cfg = setting.config;
      if (cfg.type === 'toggle') defaults[setting.id] = false;
      else if (cfg.type === 'number' || cfg.type === 'slider') defaults[setting.id] = cfg.min;
      else if (cfg.type === 'select') defaults[setting.id] = cfg.options[0]?.value || '';
      else if (cfg.type === 'multiselect') defaults[setting.id] = [];
    }
  }
  return defaults as AppSettings;
}
