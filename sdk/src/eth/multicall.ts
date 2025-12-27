/**
 * Multicall3 helper
 * Zero dependencies, works with optimized ABI coder
 */

import { ethCall } from './rpc';
import { encodeFn, decodeFn } from './abi';
import { getMulticall3 } from './chains';
import type { Address, Eip1193Provider } from './types';

export const MC3_ADDR = '0xcA11bde05977b3631167028862bE2a173976CA11';

// Minimal ABI definition with short keys to save space
const MC3_ABI = [{
  name: 'aggregate3',
  inputs: [{ type: 'tuple[]', components: [
    { name: 't', type: 'address' }, // target
    { name: 'f', type: 'bool' },    // failureAllowed
    { name: 'd', type: 'bytes' }    // callData
  ]}],
  outputs: [{ type: 'tuple[]', components: [
    { name: 's', type: 'bool' },    // success
    { name: 'r', type: 'bytes' }    // returnData
  ]}]
}];

export interface Call {
  address: Address;
  abi: any;
  functionName: string;
  args?: any[];
  allowFailure?: boolean;
}

export async function multicall(
  p: Eip1193Provider,
  calls: Call[],
  opt: { addr?: Address; chainId?: number; block?: string } = {}
) {
  // 1. Encode all calls
  const inputs = calls.map(c => ({
    t: c.address,
    f: c.allowFailure ?? true,
    d: encodeFn(c) // Re-uses Call interface directly for encodeFn
  }));

  // 2. Execute aggregate3
  const data = encodeFn({ abi: MC3_ABI, functionName: 'aggregate3', args: [inputs] });
  // Use explicit addr > chainId override > default
  const multicallAddr = opt.addr || (opt.chainId !== undefined ? getMulticall3(opt.chainId) : MC3_ADDR);
  const raw = await ethCall(p, multicallAddr, data, opt.block);

  // 3. Decode results
  // The decoder returns an array of objects based on component names: [{s: bool, r: bytes}]
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [results] = decodeFn({ abi: MC3_ABI, functionName: 'aggregate3', data: raw }) as any[];

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return results.map((res: any, i: number): any => {
    if (!res.s) return { success: false, error: new Error('Call failed') };
    try {
      return { success: true, result: decodeFn({ ...calls[i], data: res.r }) };
    } catch (e) {
      return { success: false, error: e };
    }
  });
}

export async function multicallStrict<T = any>(
  p: Eip1193Provider,
  calls: Call[],
  opt?: { addr?: Address; chainId?: number; block?: string }
): Promise<T[]> {
  const res = await multicall(p, calls.map(c => ({ ...c, allowFailure: false })), opt);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const err = res.find((r: any) => !r.success);
  if (err) throw new Error(`Multicall error: ${(err as any).error}`);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return res.map((r: any) => r.result);
}
