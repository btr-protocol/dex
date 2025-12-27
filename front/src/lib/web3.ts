import { getRpcUrl, type Address } from '@sdk/eth/chains'

// Chain configurations
export const CHAINS = {
  mainnet: { id: 1, name: 'Ethereum', rpc: getRpcUrl(1) },
  bsc: { id: 56, name: 'BSC', rpc: getRpcUrl(56) },
  localhost: { id: 31337, name: 'Localhost', rpc: 'http://localhost:8545' },
} as const

// Default to local Anvil for development
const isDev = import.meta.env.DEV
export const defaultChainId = isDev ? 31337 : 1

// Anvil test accounts (for development)
export const ANVIL_ACCOUNTS = [
  {
    address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address,
    label: 'Anvil #0',
    balance: 10000n * 10n ** 18n // 10,000 ETH
  },
  {
    address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address,
    label: 'Anvil #1',
    balance: 10000n * 10n ** 18n
  },
  {
    address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address,
    label: 'Anvil #2',
    balance: 10000n * 10n ** 18n
  }
] as const
