/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{vue,js,ts,jsx,tsx}'],
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
        'smm': 'var(--smm)',
        'mss': 'var(--mss)',
        'mms': 'var(--mms)',
        'mmms': 'var(--mmms)',
        'm': 'var(--m)',
        'mll': 'var(--mll)',
        'lmm': 'var(--lmm)',
        'lm': 'var(--lm)',
        'l': 'var(--l)',
      },
      borderRadius: {
        'none': '0',
        'xs': 'var(--radius-xs)',    /* 5px - checkboxes, badges, tags, kbd */
        'sm': 'var(--radius-sm)',    /* 8px - buttons, inputs */
        'md': 'var(--radius-md)',    /* 12px - cards, forms */
        'lg': 'var(--radius-lg)',    /* 16px - modals, containers */
        'xl': 'var(--radius-lg)',    /* alias */
        '2xl': 'var(--radius-lg)',   /* alias */
        'full': '9999px',
        DEFAULT: 'var(--radius-md)',
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
      borderColor: theme => ({
        ...theme('colors'),
        DEFAULT: 'var(--border-color)',
        'primary': 'var(--border-color-primary)',
      }),
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
  plugins: [
    function ({ addUtilities }) {
      const customUtilities = {
        '.flex-v': {
          display: 'flex',
          'flex-direction': 'column',
        },
        '.flex-h': {
          display: 'flex',
          'flex-direction': 'row',
        },
        '.h-start': {
          display: 'flex',
          'flex-direction': 'row',
          'justify-content': 'flex-start',
          'align-items': 'center',
        },
        '.h-center': {
          display: 'flex',
          'flex-direction': 'row',
          'justify-content': 'center',
          'align-items': 'center',
        },
        '.v-start': {
          display: 'flex',
          'flex-direction': 'column',
          'align-items': 'center',
          'justify-content': 'flex-start',
        },
        '.v-center': {
          display: 'flex',
          'flex-direction': 'column',
          'align-items': 'center',
          'justify-content': 'center',
        },
        '.font-numeric': {
          'font-family': 'var(--font-numbers)',
          'font-variant-numeric': 'tabular-nums',
        },
        '.badge-chain': {
          'border-radius': 'var(--radius-xs)',
          'background-color': 'var(--bg-1)',
          'border': '1px solid var(--border-color)',
        },
      };
      addUtilities(customUtilities, ['responsive']);
    }
  ]
}
