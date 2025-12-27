/**
 * Mock Data for Development and Testing
 *
 * Used when no deployed contract is available or for testing scenarios
 */

/**
 * Mock token prices for development/testing
 * Used to generate estimated swap quotes when no actual contract is deployed
 */
export const MOCK_PRICES: Record<string, number> = {
  ETH: 3500,
  WETH: 3500,
  BTC: 100000,
  WBTC: 100000,
  BNB: 600,
  WBNB: 600,
  SOL: 200,
  USDC: 1,
  USDT: 1,
  DAI: 1,
  PAXG: 2650,
};

/**
 * Get mock price for a token symbol
 */
export function getMockPrice(symbol: string): number {
  return MOCK_PRICES[symbol.toUpperCase()] || 1;
}
