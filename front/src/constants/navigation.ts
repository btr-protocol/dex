// ============================================================================
// Navigation Types
// ============================================================================

export interface NavRoute {
  title: string
  path: string // local or external URL
  isExternal?: boolean
  description?: string
  icon?: string
  children?: NavRoute[]
}

// ============================================================================
// Page Routes
// ============================================================================

export const pageRoutes: NavRoute[] = [
  {
    title: 'Dashboard',
    path: '/',
    description: 'BTR - Decentralized Exchange',
    icon: '/icons/home.svg',
  },
  {
    title: 'Swap',
    path: '/swap',
    description: 'Trade at better rates',
    icon: '/icons/swap.svg',
  },
  {
    title: 'Earn',
    path: '/earn',
    description: 'Provide and stake liquidity',
    icon: '/icons/liquidity.svg',
  },
  {
    title: 'Vote',
    path: '/vote',
    description: 'Help steer the DAO',
    icon: '/icons/vote.svg',
  },
  {
    title: 'Metrics',
    path: '/metrics',
    description: 'Explore protocol metrics',
    icon: '/icons/metrics.svg',
  },
  {
    title: 'Docs',
    path: '/docs',
    description: 'Browse protocol docs',
    icon: '/icons/docs.svg',
  }
]

// ============================================================================
// Special Routes (not in main navigation)
// ============================================================================

export const specialRoutes = {
  addAsset: '/add-asset',
  chart: '/chart',
  settings: '/settings',
  archivist: '/archivist',
  admin: '/admin',
} as const

// ============================================================================
// Social Links
// ============================================================================

export const socialLinks: NavRoute[] = [
  {
    title: 'X (Twitter)',
    path: 'https://x.com/btr_supply',
    description: 'Follow us on X',
    icon: '/icons/x.svg',
    isExternal: true,
  },
  {
    title: 'Telegram',
    path: 'https://t.me/btrsupply',
    description: 'Chat with us on Telegram',
    icon: '/icons/telegram.svg',
    isExternal: true,
  },
  {
    title: 'GitHub',
    path: 'https://github.com/btr-supply',
    description: 'View source code on GitHub',
    icon: '/icons/github.svg',
    isExternal: true,
  },
  {
    title: 'Documentation',
    path: '/docs',
    description: 'Read the docs',
    icon: '/icons/docs.svg',
    isExternal: false,
  },
]

// ============================================================================
// Legal Routes
// ============================================================================

export const legalRoutes: NavRoute[] = [
  {
    title: 'ToS',
    path: '/legal/Terms of Service',
  },
  {
    title: 'Disclaimer',
    path: '/legal/Risk Disclaimer',
  },
  // {
  //   title: 'Privacy',
  //   path: '/legal/Privacy Policy',
  // },
]

// ============================================================================
// Header Navigation
// ============================================================================

export const headerNavigation: NavRoute[] = [
  {
    title: 'Swap',
    path: '/swap',
    description: 'Trade at better rates',
    icon: '/icons/swap.svg',
  },
  {
    title: 'Earn',
    path: '/earn',
    description: 'Provide and stake liquidity',
    icon: '/icons/liquidity.svg',
  },
  {
    title: 'Vote',
    path: '/vote',
    description: 'Help steer the DAO',
    icon: '/icons/vote.svg',
  },
  {
    title: 'Metrics',
    path: '/metrics',
    description: 'Explore protocol metrics',
    icon: '/icons/metrics.svg',
  },
  {
    title: 'Docs',
    path: '/docs',
    description: 'Browse protocol docs',
    icon: '/icons/docs.svg',
  }
]

// ============================================================================
// Footer Navigation
// ============================================================================

export const footerNavigation = {
  social: socialLinks,
  legal: legalRoutes,
}

// ============================================================================
// Helper Functions
// ============================================================================

// Get path by title (case-insensitive)
export function getPathByTitle(title: string): string | undefined {
  const route = pageRoutes.find(r => r.title.toLowerCase() === title.toLowerCase())
  return route?.path
}

// Get route by path
export function getRouteByPath(path: string): NavRoute | undefined {
  return pageRoutes.find(r => r.path === path)
}

// Route path constants (for type-safe imports)
export const ROUTES = {
  HOME: '/',
  SWAP: '/swap',
  EARN: '/earn',
  VOTE: '/vote',
  METRICS: '/metrics',
  DOCS: '/docs',
  ADD_ASSET: specialRoutes.addAsset,
  CHART: specialRoutes.chart,
  SETTINGS: specialRoutes.settings,
  ARCHIVIST: specialRoutes.archivist,
  ADMIN: specialRoutes.admin,
} as const

