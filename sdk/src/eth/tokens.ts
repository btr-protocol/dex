/**
 * ERC20 Token Configuration - Canonical Source of Truth
 *
 * This file is the single source of truth for token metadata.
 * The frontend imports from here - do not duplicate in front/.
 */

export interface TokenMetadata {
  symbol: string;
  name: string;
  decimals: number;
  addresses: Record<string, string>; // chainId -> address mapping
  wrapperOf?: string; // For wrapped tokens: WETH -> 'ETH', WBTC -> 'BTC'
  icon?: string; // Optional override. Default: /tokens/{symbol.toLowerCase()}.svg
}

// ─────────────────────────────────────────────────────────────
// Token Registry
// ─────────────────────────────────────────────────────────────

export const TOKENS: Record<string, TokenMetadata> = {
  // Base assets (canonical, non-wrapped)
  BTC: {
    symbol: 'BTC',
    name: 'Bitcoin',
    decimals: 8,
    addresses: {},
  },
  ETH: {
    symbol: 'ETH',
    name: 'Ethereum',
    decimals: 18,
    addresses: {},
  },
  BNB: {
    symbol: 'BNB',
    name: 'BNB',
    decimals: 18,
    addresses: {
      '1': '0xB8c77482e45F1F44dE1745F52C74426C631bDD52',
      '56': '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
    },
  },
  SOL: {
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    addresses: {
      '56': '0x570a5d26f7765ecb712c0924e4de545b89fd43df',
    },
  },
  ARB: {
    symbol: 'ARB',
    name: 'Arbitrum',
    decimals: 18,
    addresses: {
      '1': '0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1',
      '42161': '0x912CE59144191C1204E64559FE8253a0e49E6548',
    },
  },
  HYPE: {
    symbol: 'HYPE',
    name: 'Hyperliquid',
    decimals: 18,
    addresses: {
      '999': '0x5555555555555555555555555555555555555555',
    },
  },

  // Wrapped tokens
  WETH: {
    symbol: 'WETH',
    name: 'Wrapped Ether',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
      '56': '0x2170Ed0880ac9A755fd29B2688956BD959F933F8',
      '999': '0xBe6727B535545C67d5cAa73dEa54865B92CF7907',
      '8453': '0x4200000000000000000000000000000000000006',
      '42161': '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1',
    },
  },
  WBTC: {
    symbol: 'WBTC',
    name: 'Wrapped Bitcoin',
    decimals: 8,
    wrapperOf: 'BTC',
    addresses: {
      '1': '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
      '56': '0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c',
      '999': '0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463',
      '8453': '0x0555E30da8f98308EdB960aa94C0Db47230d2B9c',
      '42161': '0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f',
    },
  },
  CBBTC: {
    symbol: 'CBBTC',
    name: 'Coinbase Wrapped BTC',
    decimals: 8,
    wrapperOf: 'BTC',
    addresses: {
      '1': '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',
      '8453': '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',
      '42161': '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',
    },
  },
  TBTC: {
    symbol: 'TBTC',
    name: 'Threshold BTC',
    decimals: 18,
    wrapperOf: 'BTC',
    addresses: {
      '1': '0x18084fbA666a33d37592fA2633fD49a74DD93a88',
      '8453': '0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b',
      '42161': '0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40',
    },
  },

  // Stablecoins
  USDT: {
    symbol: 'USDT',
    name: 'Tether USD',
    decimals: 6,
    addresses: {
      '1': '0xdAC17F958D2ee523a2206206994597C13D831ec7',
      '56': '0x55d398326f99059fF775485246999027B3197955',
      '999': '0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb',
      '8453': '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2',
      '42161': '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
    },
  },
  USDC: {
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    addresses: {
      '1': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      '56': '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
      '999': '0xb88339CB7199b77E23DB6E890353E22632Ba630f',
      '8453': '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
      '42161': '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
    },
  },
  DAI: {
    symbol: 'DAI',
    name: 'Dai Stablecoin',
    decimals: 18,
    addresses: {
      '1': '0x6B175474E89094C44Da98b954EedeAC495271d0F',
      '56': '0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3',
      '8453': '0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb',
      '42161': '0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1',
    },
  },
  USDE: {
    symbol: 'USDE',
    name: 'USDe',
    decimals: 18,
    addresses: {
      '1': '0x4c9EDD5852cd905f086C759E8383e09bff1E68B3',
      '56': '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34',
      '999': '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34',
      '8453': '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34',
      '42161': '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34',
    },
  },
  TUSD: {
    symbol: 'TUSD',
    name: 'TrueUSD',
    decimals: 18,
    addresses: {
      '1': '0x0000000000085d4780B73119b644AE5ecd22b376',
      '56': '0x40af3827f39d0eacbf4a168f8d4ee67c121d11c9',
    },
  },
  FDUSD: {
    symbol: 'FDUSD',
    name: 'First Digital USD',
    decimals: 18,
    addresses: {
      '1': '0xc5f0f7b66764f6ec8c8dff7ba683102295e16409',
      '56': '0xc5f0f7b66764f6ec8c8dff7ba683102295e16409',
    },
  },
  USDD: {
    symbol: 'USDD',
    name: 'Decentralized USD',
    decimals: 18,
    addresses: {
      '56': '0xd17479997f34dd9156deef8f95a52d81d265be9c',
    },
  },
  USDP: {
    symbol: 'USDP',
    name: 'Pax Dollar',
    decimals: 18,
    addresses: {
      '1': '0x8e870d67f660d95d5be530380d0ec0bd388289e1',
      '56': '0xb3c11196a4f3b1da7c23d9fb0a3dde9c6340934f',
    },
  },
  crvUSD: {
    symbol: 'crvUSD',
    name: 'Curve USD',
    decimals: 18,
    addresses: {
      '1': '0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E',
      '56': '0xe2fb3F127f5450DeE44afe054385d74C392BdeF4',
    },
  },
  lisUSD: {
    symbol: 'lisUSD',
    name: 'Lista USD',
    decimals: 18,
    addresses: {
      '56': '0x0782b6d8c4551b9760e74c0545a9bcd90bdc41e5',
    },
  },
  AUSD: {
    symbol: 'AUSD',
    name: 'Agora Dollar',
    decimals: 18,
    addresses: {
      '1': '0x00000000efe302beaa2b3e6e1b18d08d69a9012a',
      '56': '0x00000000efe302beaa2b3e6e1b18d08d69a9012a',
    },
  },

  // ETH Liquid Staking Derivatives
  stETH: {
    symbol: 'stETH',
    name: 'Lido Staked ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84',
    },
  },
  wstETH: {
    symbol: 'wstETH',
    name: 'Wrapped stETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0',
      '8453': '0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452',
      '42161': '0x5979D7b546E38E414F7E9822514be443A4800529',
    },
  },
  rETH: {
    symbol: 'rETH',
    name: 'Rocket Pool ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xae78736Cd615f374D3085123A210448E74Fc6393',
      '8453': '0xB6fe221Fe9EeF5aBa221c348BA20A1Bf5e73624c',
      '42161': '0xEC70Dcb4A1EFa46b8F2D97C310C9c479018599ab',
    },
  },
  eETH: {
    symbol: 'eETH',
    name: 'ether.fi Staked ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0x35fA164735182de50811E8e2E824cfb9B6118ac2',
    },
  },
  weETH: {
    symbol: 'weETH',
    name: 'Wrapped eETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee',
      '56': '0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A',
      '8453': '0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A',
      '42161': '0x35751007a407ca6feffe80b3cb397736d2cf4dbe',
    },
  },
  wBETH: {
    symbol: 'wBETH',
    name: 'Wrapped Beacon ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xa2E3356610840701BDf5611a53974510Ae27E2e1',
      '56': '0xa2E3356610840701BDf5611a53974510Ae27E2e1',
    },
  },
  rsETH: {
    symbol: 'rsETH',
    name: 'Kelp DAO Restaked ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7',
      '42161': '0x4186BFC76E2E237523CBC30FD220FE055156b41F',
    },
  },
  lsETH: {
    symbol: 'lsETH',
    name: 'Liquid Staked ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0x8c1BEd5b9a0928467c9B1341Da1D7BD5e10b6549',
    },
  },
  ezETH: {
    symbol: 'ezETH',
    name: 'Renzo Restaked ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xbf5495Efe5DB9ce00f80364C8B423567e58d2110',
      '56': '0x2416092f143378750bb29b79eD961ab195CcEea5',
      '8453': '0x2416092f143378750bb29b79eD961ab195CcEea5',
      '42161': '0x2416092f143378750bb29b79eD961ab195CcEea5',
    },
  },
  osETH: {
    symbol: 'osETH',
    name: 'StakeWise OsTokenized ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38',
    },
  },
  ETHx: {
    symbol: 'ETHx',
    name: 'Stader ETHx',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xA35b1B31Ce002FBF2058D22F30f95D405200A15b',
    },
  },
  swETH: {
    symbol: 'swETH',
    name: 'Swell ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xf951E335afb289353dc249e82926178EaC7DEd78',
    },
  },
  cbETH: {
    symbol: 'cbETH',
    name: 'Coinbase Wrapped Staked ETH',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xbe9895146f7af43049ca1c1ae358b0541ea49704',
      '8453': '0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22',
    },
  },
  frxETH: {
    symbol: 'frxETH',
    name: 'Frax Ether',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0x5E8422345238F34275888049021821E8E08CAa1f',
      '56': '0x64048A7eEcF3a2F1BA9e144aAc3D7dB6e58F555e',
      '8453': '0xF010a7c8877043681D59AD125EbF575633505942',
      '42161': '0x178412e79c25968a32e89b11f63b33f733770c2a',
    },
  },
  frxUSD: {
    symbol: 'frxUSD',
    name: 'Frax USD',
    decimals: 18,
    addresses: {
      '56': '0x80Eede496655FB9047dd39d9f418d5483ED600df',
    },
  },
  sfrxETH: {
    symbol: 'sfrxETH',
    name: 'Staked Frax Ether',
    decimals: 18,
    wrapperOf: 'ETH',
    addresses: {
      '1': '0xac3E018457B222d93114458476f3E3416Abbe38F',
      '8453': '0x1f55a02A049033E3419a8E2975cF3F572F4e6E9A',
      '42161': '0x95ab45875cffdba1e5f451b950bc2e42c0053f39',
    },
  },

  // Commodities
  PAXG: {
    symbol: 'PAXG',
    name: 'Pax Gold',
    decimals: 18,
    addresses: {
      '1': '0x45804880De22913dAFE09f4980848ECE6EcbAf78',
      '56': '0x7950865a9140cB519342433146Ed5b40c6F210f7',
      '42161': '0xfEb4dfC8c4cF7eD305bB08065d08Ec6eE6728429',
    },
  },
  XAUT: {
    symbol: 'XAUT',
    name: 'Tether Gold',
    decimals: 6,
    addresses: {
      '1': '0x68749665FF8D2d112Fa859AA293F07A622782F38',
      '999': '0xf4D9235269A96aadaFc9aDAE454a0618EBe37949',
      '42161': '0x40461291347e1ecbB09499F3371D3F17F10D7159',
    },
  },

  // DeFi Tokens
  AAVE: {
    symbol: 'AAVE',
    name: 'Aave',
    decimals: 18,
    addresses: {
      '1': '0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9',
      '56': '0xfb6115445Bff7b52FeB98650C87f44907E58f802',
      '8453': '0x63706e401c06ac8513145b7687A14804d17f814b',
      '42161': '0xba5DdD1f9d7F570dc94a51479a000E3BCE967196',
    },
  },
  PENDLE: {
    symbol: 'PENDLE',
    name: 'Pendle',
    decimals: 18,
    addresses: {
      '1': '0x808507121B80c02388fAd14726482e061B8da827',
      '56': '0xb3Ed0A426155B79B898849803E3B36552f7ED507',
      '999': '0xD6Eb81136884713E843936843E286FD2a85A205A',
      '8453': '0xA99F6e6785Da0F5d6fB42495Fe424BCE029Eeb3E',
      '42161': '0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8',
    },
  },
  ENA: {
    symbol: 'ENA',
    name: 'Ethena',
    decimals: 18,
    addresses: {
      '1': '0x57e114B691Db790C35207b2e685D4A43181e6061',
      '56': '0x58538e6A46E07434d7E7375Bc268D3cb839C0133',
      '8453': '0x58538e6A46E07434d7E7375Bc268D3cb839C0133',
      '42161': '0x58538e6A46E07434d7E7375Bc268D3cb839C0133',
    },
  },
  UNI: {
    symbol: 'UNI',
    name: 'Uniswap',
    decimals: 18,
    addresses: {
      '1': '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984',
      '56': '0xBf5140A22578168FD562DCcF235E5D43A02ce9B1',
      '8453': '0xc3De830EA07524a0761646a6a4e4be0e114a3C83',
      '42161': '0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0',
    },
  },
  CAKE: {
    symbol: 'CAKE',
    name: 'PancakeSwap',
    decimals: 18,
    addresses: {
      '1': '0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898',
      '56': '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82',
      '8453': '0x3055913c90Fcc1A6CE9a358911721eEb942013A1',
      '42161': '0x1b896893dfc86bb67Cf57767298b9073D2c1bA2c',
    },
  },
  CRV: {
    symbol: 'CRV',
    name: 'Curve',
    decimals: 18,
    addresses: {
      '1': '0xD533a949740bb3306d119CC777fa900bA034cd52',
      '56': '0x9996D0276612d23b35f90C51EE935520B3d7355B',
      '8453': '0x8Ee73c484A26e0A5df2Ee2a4960B789967dd0415',
      '42161': '0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978',
    },
  },
  LINK: {
    symbol: 'LINK',
    name: 'Chainlink',
    decimals: 18,
    addresses: {
      '1': '0x514910771AF9Ca656af840dff83E8264EcF986CA',
      '56': '0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD',
      '8453': '0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196',
      '42161': '0xf97f4df75117a78c1A5a0DBb814Af92458539FB4',
    },
  },
  ZRO: {
    symbol: 'ZRO',
    name: 'LayerZero',
    decimals: 18,
    addresses: {
      '1': '0x6985884C4392D348587B19cb9eAAf157F13271cd',
      '56': '0x6985884C4392D348587B19cb9eAAf157F13271cd',
      '8453': '0x6985884C4392D348587B19cb9eAAf157F13271cd',
      '42161': '0x6985884C4392D348587B19cb9eAAf157F13271cd',
    },
  },
  AXL: {
    symbol: 'AXL',
    name: 'Axelar',
    decimals: 18,
    addresses: {
      '1': '0x467719aD09025FcC6cF6F8311755809d45a5E5f3',
      '56': '0x8b1f4432F943c465A973FeDC6d7aa50Fc96f1f65',
      '8453': '0x23ee2343B892b1BB63503a4FAbc840E0e2C6810f',
      '42161': '0x23ee2343B892b1BB63503a4FAbc840E0e2C6810f',
    },
  },
  MORPHO: {
    symbol: 'MORPHO',
    name: 'Morpho',
    decimals: 18,
    addresses: {},
  },
  SUI: {
    symbol: 'SUI',
    name: 'Sui',
    decimals: 9,
    addresses: {},
  },
  ZEC: {
    symbol: 'ZEC',
    name: 'Zcash',
    decimals: 8,
    addresses: {
      '56': '0x1ba42e5193dfa8b03d15dd1b86a3113bbbef8eeb',
    },
  },
};

// ─────────────────────────────────────────────────────────────
// Token Lists
// ─────────────────────────────────────────────────────────────

/** Canonical tokens (excludes wrappers) */
export const CANONICAL_TOKENS = Object.keys(TOKENS).filter(s => !TOKENS[s].wrapperOf);

/** All tokens including wrappers */
export const ALL_TOKENS = Object.keys(TOKENS);

/** Base tokens for pair generation */
export const BASE_TOKENS = [
  'BTC', 'ETH', 'SOL', 'BNB', 'AAVE', 'PENDLE', 'ENA', 'UNI',
  'CAKE', 'CRV', 'LINK', 'ZRO', 'AXL', 'MORPHO', 'HYPE', 'SUI', 'ZEC', 'ARB',
  'XAUT', 'PAXG'
];

/** Quote currencies for pair generation */
export const QUOTE_TOKENS = ['USDC', 'USDT', 'ETH', 'BTC', 'DAI', 'USDE'];

// ─────────────────────────────────────────────────────────────
// Helper Functions
// ─────────────────────────────────────────────────────────────

/**
 * Get token icon path (auto-computed or overridden)
 */
export function getTokenIcon(symbol: string): string {
  const token = TOKENS[symbol];
  return token?.icon || `/tokens/${symbol.toLowerCase()}.svg`;
}

/**
 * Get token address for a specific chain
 */
export function getTokenAddress(
  symbol: string,
  chainId: number | string
): string | undefined {
  return TOKENS[symbol]?.addresses[chainId.toString()];
}

/**
 * Get all tokens available on a chain
 */
export function getAllTokensForChain(chainId: number | string): Record<string, string> {
  const result: Record<string, string> = {};
  const chainIdStr = chainId.toString();

  for (const [symbol, token] of Object.entries(TOKENS)) {
    if (token.addresses[chainIdStr]) {
      result[symbol] = token.addresses[chainIdStr];
    }
  }

  return result;
}

/**
 * Resolve token to canonical symbol (unwraps if needed)
 * @param symbol Token symbol (may be wrapped)
 * @returns Canonical symbol (unwrapped)
 */
export function resolveTokenAlias(symbol: string): string {
  const symbolUpper = symbol.toUpperCase();
  const token = TOKENS[symbolUpper];
  return token?.wrapperOf || symbolUpper;
}

/**
 * Check if a search term matches a token (including wrappers)
 * @param symbol Canonical token symbol
 * @param searchTerm User search input
 * @returns true if search matches symbol or any wrapper of it
 */
export function tokenMatchesSearch(symbol: string, searchTerm: string): boolean {
  if (!searchTerm) return true;
  const searchLower = searchTerm.toLowerCase();
  const tokenInfo = TOKENS[symbol];
  if (!tokenInfo) return false;

  // Symbol match
  if (symbol.toLowerCase().includes(searchLower)) return true;

  // Name match
  if (tokenInfo.name.toLowerCase().includes(searchLower)) return true;

  // Address match (check all chain addresses)
  for (const address of Object.values(tokenInfo.addresses)) {
    if (address.toLowerCase().includes(searchLower)) return true;
  }

  // Check wrappers (e.g., searching "WETH" should find "ETH")
  for (const [wrapperSymbol, wrapper] of Object.entries(TOKENS)) {
    if (wrapper.wrapperOf === symbol) {
      if (wrapperSymbol.toLowerCase().includes(searchLower)) return true;
      if (wrapper.name.toLowerCase().includes(searchLower)) return true;
      for (const address of Object.values(wrapper.addresses)) {
        if (address.toLowerCase().includes(searchLower)) return true;
      }
    }
  }

  return false;
}
