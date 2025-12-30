import { defineConfig, presetWind } from 'unocss'
import presetIcons from '@unocss/preset-icons'

export default defineConfig({
  presets: [
    presetWind({
      preflight: true, // Enable Tailwind-style reset
    }),
    presetIcons({
      extraProperties: {
        display: 'inline-block',
        'vertical-align': 'middle',
      },
    }),
  ],
  safelist: [
    // Rounded utilities
    'rounded', 'rounded-none', 'rounded-sm', 'rounded-md', 'rounded-lg', 'rounded-xl', 'rounded-2xl', 'rounded-full',
    'rounded-t-lg', 'rounded-b-lg', 'rounded-l-sm', 'rounded-r-sm', 'rounded-xs',
    // Common spacing/sizing
    'gap-1', 'gap-1.5', 'gap-2', 'gap-2.5', 'gap-3', 'gap-4',
    'px-2', 'px-3', 'px-4', 'py-1', 'py-1.5', 'py-2', 'py-2.5',
    'h-8', 'h-10', 'h-12', 'w-full',
    // Transitions
    'transition-colors', 'duration-150',
    // Display/flex
    'inline-flex', 'flex', 'items-center', 'justify-center',
  ],
  content: {
    pipeline: {
      include: [
        /\.(vue|svelte|[jt]sx|mdx?|astro|html)($|\?)/,
        'src/**/*.{js,ts,jsx,tsx}',
      ],
    },
  },
  rules: [
    // Custom z-index utilities
    [/^z-tooltip$/, () => ({ 'z-index': 'var(--z-index-tooltip)' })],

    // Custom font family utilities
    [/^font-numbers$/, () => ({ 'font-family': 'var(--font-numbers)' })],
    [/^font-title$/, () => ({ 'font-family': 'var(--font-title)' })],

    // Custom background color utilities for hyphenated colors
    [/^bg-bg-(\d+)$/, ([, n]) => ({ 'background-color': `var(--bg-${n})` })],
    [/^bg-bg-primary$/, () => ({ 'background-color': 'var(--bg-primary)' })],

    // Semantic background colors
    [/^bg-background$/, () => ({ 'background-color': 'var(--bg-0)' })],
    [/^bg-foreground$/, () => ({ 'background-color': 'var(--fg-0)' })],
    [/^bg-primary$/, () => ({ 'background-color': 'var(--primary)' })],
    [/^bg-accent$/, () => ({ 'background-color': 'var(--bg-3)' })],
    [/^bg-muted$/, () => ({ 'background-color': 'var(--bg-2)' })],
    [/^bg-popover$/, () => ({ 'background-color': 'var(--bg-1)' })],
    [/^bg-card$/, () => ({ 'background-color': 'var(--bg-1)' })],
    [/^bg-destructive$/, () => ({ 'background-color': 'var(--red)' })],
    [/^bg-ring$/, () => ({ 'background-color': 'var(--primary)' })],
    [/^bg-border$/, () => ({ 'background-color': 'var(--border-color)' })],
    [/^bg-input$/, () => ({ 'background-color': 'var(--bg-2)' })],

    // Custom text color utilities
    [/^text-fg-(\d+)$/, ([, n]) => ({ color: `var(--fg-${n})` })],
    [/^text-primary$/, () => ({ color: 'var(--primary)' })],

    // Semantic text colors
    [/^text-background$/, () => ({ color: 'var(--bg-0)' })],
    [/^text-foreground$/, () => ({ color: 'var(--fg-0)' })],
    [/^text-accent-foreground$/, () => ({ color: 'var(--fg-0)' })],
    [/^text-muted-foreground$/, () => ({ color: 'var(--fg-2)' })],
    [/^text-popover-foreground$/, () => ({ color: 'var(--fg-0)' })],
    [/^text-card-foreground$/, () => ({ color: 'var(--fg-0)' })],
    [/^text-destructive-foreground$/, () => ({ color: 'var(--white)' })],
    [/^text-accent$/, () => ({ color: 'var(--fg-0)' })],
    [/^text-muted$/, () => ({ color: 'var(--fg-2)' })],

    // Border width utilities - ensure solid style and default color
    [/^border$/, () => ({ 'border-width': '1px', 'border-style': 'solid', 'border-color': 'var(--border-color)' })],
    [/^border-(\d+)$/, ([, width]) => ({ 'border-width': `${width}px`, 'border-style': 'solid' })],
    [/^border-([tblr])$/, ([, side]) => {
      const sides = { t: 'top', b: 'bottom', l: 'left', r: 'right' };
      return {
        [`border-${sides[side]}-width`]: '1px',
        [`border-${sides[side]}-style`]: 'solid'
      };
    }],
    [/^border-([tblr])-(\d+)$/, ([, side, width]) => {
      const sides = { t: 'top', b: 'bottom', l: 'left', r: 'right' };
      return {
        [`border-${sides[side]}-width`]: `${width}px`,
        [`border-${sides[side]}-style`]: 'solid'
      };
    }],

    // Custom border utilities
    [/^border-border$/, () => ({ 'border-color': 'var(--border-color)' })],
    [/^border-input$/, () => ({ 'border-color': 'var(--bg-2)' })],
    [/^border-ring$/, () => ({ 'border-color': 'var(--primary)' })],
    [/^border-primary$/, () => ({ 'border-color': 'var(--border-color-primary)' })],

    // Hover variants for custom utilities
    [/^hover:bg-bg-(\d+)$/, ([, n]) => ({
      '&:hover': { 'background-color': `var(--bg-${n})` }
    })],
    [/^hover:text-fg-(\d+)$/, ([, n]) => ({
      '&:hover': { color: `var(--fg-${n})` }
    })],
    // Hover variants for semantic colors
    [/^hover:bg-primary\/(\d+)$/, ([, n]) => ({
      '&:hover': { 'background-color': `rgba(var(--primary-rgb), ${parseInt(n) / 100})` }
    })],
    [/^hover:bg-accent$/, () => ({
      '&:hover': { 'background-color': 'var(--bg-3)' }
    })],
    [/^hover:text-accent-foreground$/, () => ({
      '&:hover': { color: 'var(--fg-0)' }
    })],

    // Border radius utilities - override presetWind defaults
    [/^rounded-none$/, () => ({ 'border-radius': '0' })],
    [/^rounded-xs$/, () => ({ 'border-radius': '5px' })],
    [/^rounded-sm$/, () => ({ 'border-radius': '8px' })],
    [/^rounded-md$/, () => ({ 'border-radius': '12px' })],
    [/^rounded-lg$/, () => ({ 'border-radius': '16px' })],
    [/^rounded-xl$/, () => ({ 'border-radius': '16px' })],
    [/^rounded-2xl$/, () => ({ 'border-radius': '16px' })],
    [/^rounded-full$/, () => ({ 'border-radius': '9999px' })],
    [/^rounded$/, () => ({ 'border-radius': '12px' })],
    // Directional rounded
    [/^rounded-t-lg$/, () => ({ 'border-top-left-radius': '16px', 'border-top-right-radius': '16px' })],
    [/^rounded-b-lg$/, () => ({ 'border-bottom-left-radius': '16px', 'border-bottom-right-radius': '16px' })],
    [/^rounded-l-sm$/, () => ({ 'border-top-left-radius': '8px', 'border-bottom-left-radius': '8px' })],
    [/^rounded-r-sm$/, () => ({ 'border-top-right-radius': '8px', 'border-bottom-right-radius': '8px' })],

    // Ring utilities
    [/^focus-visible:ring-(\d+)$/, ([, n]) => ({
      '&:focus-visible': {
        '--un-ring-width': `${n}px`,
        '--un-ring-offset-shadow': 'var(--un-ring-inset) 0 0 0 var(--un-ring-offset-width) var(--un-ring-offset-color)',
        '--un-ring-shadow': 'var(--un-ring-inset) 0 0 0 calc(var(--un-ring-width) + var(--un-ring-offset-width)) var(--un-ring-color)',
        'box-shadow': 'var(--un-ring-offset-shadow), var(--un-ring-shadow), var(--un-shadow)',
      }
    })],
    [/^ring-ring$/, () => ({ '--un-ring-color': 'var(--primary)' })],
  ],
  darkMode: 'class',
  theme: {
    extend: {
      spacing: {
        // Custom named spacing (doesn't override numeric defaults)
        'unit-o': 'var(--unit-o)',
        'unit-h': 'var(--unit-h)',
        'unit-1': 'var(--unit-1)',
        'unit-2': 'var(--unit-2)',
        'unit-3': 'var(--unit-3)',
        'unit-4': 'var(--unit-4)',
        'unit-5': 'var(--unit-5)',
        'unit-6': 'var(--unit-6)',
        'unit-7': 'var(--unit-7)',
        'unit-8': 'var(--unit-8)',
        'unit-9': 'var(--unit-9)',
        'unit-10': 'var(--unit-10)',
        'unit-11': 'var(--unit-11)',
        'unit-12': 'var(--unit-12)',
        'unit-13': 'var(--unit-13)',
        'unit-14': 'var(--unit-14)',
        'xxxxs': 'var(--xxxxs)',
        'xxxs': 'var(--xxxs)',
        'xxs': 'var(--xxs)',
        'xs': 'var(--xs)',
        's': 'var(--s)',
        'ssm': 'var(--ssm)',
        'sm': 'var(--sm)',
        'smm': 'var(--smm)',
        'mss': 'var(--mss)',
        'ms': 'var(--ms)',
        'mms': 'var(--mms)',
        'mmms': 'var(--mmms)',
        'm': 'var(--m)',
        'ml': 'var(--ml)',
        'mll': 'var(--mll)',
        'lmm': 'var(--lmm)',
        'lm': 'var(--lm)',
        'l': 'var(--l)',
        'xl': 'var(--xl)',
        'xxl': 'var(--xxl)',
        'xxxl': 'var(--xxxl)',
      },
      borderRadius: {
        'none': '0',
        'xs': '5px',     /* checkboxes, badges, tags, kbd - matches --radius-xs */
        'sm': '8px',     /* buttons, inputs - matches --radius-sm */
        'md': '12px',    /* cards, forms - matches --radius-md */
        'lg': '16px',    /* modals, containers - matches --radius-lg */
        'xl': '16px',    /* alias for lg */
        '2xl': '16px',   /* alias for lg */
        'full': '9999px',
        DEFAULT: '12px', /* matches --radius-md */
      },
      boxShadow: {
        'chain-badge': '0 0 0 1px var(--border-color)',
      },
      fontSize: {
        // Don't override xs, sm, etc - use unique names
        'fs-xs': 'var(--font-size-xs)',
        'fs-s': 'var(--font-size-s)',
        'fs-m': 'var(--font-size-m)',
        'fs-ml': 'var(--font-size-ml)',
        'fs-l': 'var(--font-size-l)',
        'fs-xl': 'var(--font-size-xl)',
        'fs-xxl': 'var(--font-size-xxl)',
        'fs-xxxl': 'var(--font-size-xxxl)',
        'fs-xxxxl': 'var(--font-size-xxxxl)',
        'title': 'var(--font-size-title)',
        'subtitle': 'var(--font-size-subtitle)',
      },
      zIndex: {
        'footer': 'var(--z-index-footer)',
        'dropdown': 'var(--z-index-dropdown)',
        'modal': 'var(--z-index-modal)',
        'tooltip': 'var(--z-index-tooltip)',
        'toast': 'var(--z-index-toast)',
      },
      gridTemplateColumns: {
        '14': 'repeat(14, minmax(0, 1fr))',
      },
      borderWidth: {
        DEFAULT: 'var(--border-width)',
      },
      fontFamily: {
        'title': 'var(--font-title)',
        'body': 'var(--font-body)',
        'mono': 'var(--font-mono)',
        'numbers': 'var(--font-numbers)',
      },
      borderColor: {
        DEFAULT: 'var(--border-color)',
        'primary': 'var(--border-color-primary)',
      },
      colors: {
        // Brand Colors (from constants.css)
        'primary': {
          DEFAULT: 'var(--primary)',
          foreground: 'var(--white)',
        },
        'secondary': 'var(--secondary)',
        'black': 'var(--black)',
        'white': 'var(--white)',

        // Sentiment Colors (from constants.css)
        'green': 'var(--green)',
        'red': 'var(--red)',
        'yellow': 'var(--yellow)',
        'cyan': 'var(--cyan)',
        'pink': 'var(--pink)',
        'violet': 'var(--violet)',

        // Semantic Aliases (from constants.css)
        'active': 'var(--active)',
        'success': 'var(--success)',
        'error': 'var(--error)',
        'warning': 'var(--warning)',
        'info': 'var(--info)',

        // Semantic Colors
        'border': 'var(--border-color)',
        'input': 'var(--bg-2)',
        'ring': 'var(--primary)',
        'background': 'var(--bg-0)',
        'foreground': 'var(--fg-0)',
        'muted': {
          DEFAULT: 'var(--bg-2)',
          foreground: 'var(--fg-2)',
        },
        'accent': {
          DEFAULT: 'var(--bg-3)',
          foreground: 'var(--fg-0)',
        },
        'popover': {
          DEFAULT: 'var(--bg-1)',
          foreground: 'var(--fg-0)',
        },
        'card': {
          DEFAULT: 'var(--bg-1)',
          foreground: 'var(--fg-0)',
        },
        'destructive': {
          DEFAULT: 'var(--red)',
          foreground: 'var(--white)',
        },

        // Extended Palette
        'bg-0': 'var(--bg-0)',
        'bg-1': 'var(--bg-1)',
        'bg-2': 'var(--bg-2)',
        'bg-3': 'var(--bg-3)',
        'bg-4': 'var(--bg-4)',
        'bg-5': 'var(--bg-5)',
        'bg-6': 'var(--bg-6)',
        'bg-7': 'var(--bg-7)',
        'bg-primary': 'var(--bg-primary)',
        'bg-secondary': 'var(--bg-secondary)',
        'bg-success': 'var(--bg-success)',
        'bg-error': 'var(--bg-error)',
        'bg-warning': 'var(--bg-warning)',
        'bg-info': 'var(--bg-info)',
        'bg-positive': 'var(--bg-positive)',
        'bg-negative': 'var(--bg-negative)',
        'bg-green': 'var(--bg-green)',
        'bg-red': 'var(--bg-red)',
        'bg-yellow': 'var(--bg-yellow)',
        'bg-orange': 'var(--bg-orange)',
        'bg-blue': 'var(--bg-blue)',

        'fg-0': 'var(--fg-0)',
        'fg-1': 'var(--fg-1)',
        'fg-2': 'var(--fg-2)',
        'fg-3': 'var(--fg-3)',
      },
    },
  },
  shortcuts: {
    // Core flex layouts - reduce inline complexity
    'flex-v': 'flex flex-col',
    'flex-h': 'flex flex-row',
    'flex-between': 'flex items-center justify-between',
    'flex-center': 'flex items-center justify-center',
    'flex-start': 'flex items-center justify-start',
    'flex-end': 'flex items-center justify-end',
    'h-start': 'flex flex-row justify-start items-center',
    'h-center': 'flex flex-row justify-center items-center',
    'v-start': 'flex flex-col items-center justify-start',
    'v-center': 'flex flex-col items-center justify-center',

    // Flex with gaps
    'flex-center-gap-1': 'flex items-center gap-1',
    'flex-center-gap-1.5': 'flex items-center gap-1.5',
    'flex-center-gap-2': 'flex items-center gap-2',
    'flex-between-gap-4': 'flex items-center justify-between gap-4',

    // Card & panel patterns - eliminate bg-bg-1 border border-border repetition
    'card-base': 'bg-bg-1 border border-border rounded-md',
    'card-lg': 'bg-bg-1 border border-border rounded-lg',
    'card-xl': 'bg-bg-1 border border-border rounded-xl',
    'card-glass': 'bg-white/5 border border-white/10 rounded-md',
    'card-glass-lg': 'bg-white/5 border border-white/10 rounded-lg',
    'card-hover': 'bg-bg-1 border border-border rounded-md hover:bg-bg-2/50 transition-colors cursor-pointer',

    // Toolbar items
    'toolbar-btn': 'h-8 px-2 flex items-center cursor-pointer text-fg-2 font-title font-medium transition-colors duration-150 hover:text-fg-1 hover:bg-bg-2',
    'toolbar-btn-active': 'bg-bg-primary text-primary',
    'toolbar-item': 'h-8 px-2 flex items-center gap-1.5 text-xs font-title font-medium text-fg-1 border-r border-border transition-colors duration-150 hover:bg-bg-2',

    // Floating panels (tooltips, popovers, dropdowns)
    'floating-panel': 'fixed z-tooltip px-3 py-2 text-xs font-title font-medium text-fg-1 bg-bg-1 border border-border rounded-sm shadow-lg',

    // Typography
    'font-numeric': 'font-numbers tabular-nums',
    'text-caption': 'text-xs text-muted-foreground',
    'text-label': 'text-sm font-semibold text-foreground',

    // Badges
    'badge-chain': 'rounded-xs bg-bg-1 border border-border',

    // Button states
    'btn-selected': 'bg-bg-primary text-primary',
    'btn-unselected': 'text-fg-2',

    // Common content layouts
    'section-padding': 'px-4 py-3',
    'page-padding': 'px-6 py-4',
  },
})
