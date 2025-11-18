export interface NavRoute {
  title: string
  path: string
  children?: NavRoute[]
}

export const navRoutes: NavRoute[] = [
  {
    title: 'Dashboard',
    path: '/'
  },
  {
    title: 'Swap',
    path: '/swap'
  },
  {
    title: 'Liquidity',
    path: '/liquidity'
  }
]

export const externalLinks: NavRoute[] = [
  { title: 'X', path: 'https://x.com/BTRSupply' },
  { title: 'Github', path: 'https://github.com/BTRSupply' },
  { title: 'Telegram', path: 'https://t.me/BTRSupply' }
]
