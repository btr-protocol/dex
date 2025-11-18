import { useReadContract } from 'wagmi';
import type { Address } from 'viem';
import ERC20_ABI from '@/contracts/abis/ERC20.json';

/**
 * Read token metadata (symbol, decimals, name)
 */
export function useTokenInfo(token: Address | undefined) {
  const { data: symbol } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'symbol',
    query: {
      enabled: !!token && token !== '0x0000000000000000000000000000000000000000',
    },
  });

  const { data: decimals } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'decimals',
    query: {
      enabled: !!token && token !== '0x0000000000000000000000000000000000000000',
    },
  });

  const { data: name } = useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'name',
    query: {
      enabled: !!token && token !== '0x0000000000000000000000000000000000000000',
    },
  });

  // Handle native ETH (address(0))
  if (token === '0x0000000000000000000000000000000000000000') {
    return {
      symbol: 'ETH',
      decimals: 18,
      name: 'Ethereum',
    };
  }

  return {
    symbol: symbol as string | undefined,
    decimals: decimals as number | undefined,
    name: name as string | undefined,
  };
}

/**
 * Read token balance for an account
 */
export function useTokenBalance(token: Address | undefined, account: Address | undefined) {
  return useReadContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: account ? [account] : undefined,
    query: {
      enabled: !!token && !!account && token !== '0x0000000000000000000000000000000000000000',
    },
  });
}
