import { createConfig, http } from 'wagmi'
import { mainnet, localhost } from 'wagmi/chains'
import { injected } from 'wagmi/connectors'
import { getRpcUrl } from './rpcs'

// Default to local Anvil for development
const isDev = import.meta.env.DEV
const defaultChain = isDev ? localhost : mainnet

// Configure chains with RPC fallbacks
export const config = createConfig({
  chains: [localhost, mainnet],
  connectors: [
    injected(),
    // walletConnect({ projectId: import.meta.env.VITE_WC_PROJECT_ID || '' })
  ],
  transports: {
    [localhost.id]: http('http://localhost:8545'),
    [mainnet.id]: http(getRpcUrl(1))
  }
})

// Anvil test accounts (for development)
export const ANVIL_ACCOUNTS = [
  {
    address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as `0x${string}`,
    label: 'Anvil #0',
    balance: 10000n * 10n ** 18n // 10,000 ETH
  },
  {
    address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as `0x${string}`,
    label: 'Anvil #1',
    balance: 10000n * 10n ** 18n
  },
  {
    address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as `0x${string}`,
    label: 'Anvil #2',
    balance: 10000n * 10n ** 18n
  }
] as const

export { defaultChain }
