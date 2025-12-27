/**
 * Ultra-Compact ABI Coder
 * Supports: All standard Solidity types (static/dynamic arrays, tuples, events, errors)
 */

import type { Hex } from './types';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export type AbiFunction = {
  type: 'function';
  name: string;
  inputs?: AbiParameter[];
  outputs?: AbiParameter[];
  stateMutability?: 'pure' | 'view' | 'nonpayable' | 'payable';
};

export type AbiEvent = {
  type: 'event';
  name: string;
  inputs?: AbiParameter[];
  anonymous?: boolean;
};

export type AbiError = {
  type: 'error';
  name: string;
  inputs?: AbiParameter[];
};

export type AbiParameter = {
  name?: string;
  type: string;
  components?: AbiParameter[];
  indexed?: boolean;
};

export type Abi = readonly (AbiFunction | AbiEvent | AbiError | any)[];

// ─────────────────────────────────────────────────────────────
// Utils & Constants
// ─────────────────────────────────────────────────────────────

const BN = BigInt;
const clean = (s: string) => s.startsWith('0x') ? s.slice(2) : s;
const pad = (s: string, len = 64) => s.padStart(len, '0');
const numToHex = (n: bigint | number | boolean) => BN(n).toString(16);
const utf8 = new TextEncoder();
const decUtf8 = new TextDecoder();

// Common selectors
const SELECTORS: Record<string, string> = {
  'balanceOf(address)': '70a08231', 'allowance(address,address)': 'dd62ed3e', 
  'approve(address,uint256)': '095ea7b3', 'transfer(address,uint256)': 'a9059cbb',
  'transferFrom(address,address,uint256)': '23b872dd', 'name()': '06fdde03', 
  'symbol()': '95d89b41', 'decimals()': '313ce567', 'totalSupply()': '18160ddd',
  'aggregate3((address,bool,bytes)[])': '82ad56cb', 'aggregate((address,bytes)[])': '252dba42'
};

export const getSelector = (sig: string): Hex =>
  `0x${SELECTORS[sig] || (() => { throw new Error(`Missing selector: ${sig}`) })()}` as Hex;

// ─────────────────────────────────────────────────────────────
// Encoder
// ─────────────────────────────────────────────────────────────

const TYPE_RX = /^([a-z]+)(\d+)?(\[\d*\])?$/;

export function encode(type: string, val: any, components?: any[]): { h: string; t: string } {
  // 1. Handle Arrays ([] or [N])
  const arrayMatch = type.match(/(\[\d*\])$/);
  if (arrayMatch) {
    const base = type.slice(0, -arrayMatch[1].length);
    const arr = val as any[];
    const isStatic = arrayMatch[1] !== '[]'; // [N] is static, [] is dynamic
    return processList(arr.map(v => encode(base, v, components)), !isStatic, isStatic ? arr.length : undefined);
  }

  // 2. Handle Tuples (tuple)
  if (type === 'tuple' && components) {
    return processList(components.map((c, i) => 
      encode(c.type, (val as any)[c.name || i] ?? (Array.isArray(val) ? val[i] : undefined), c.components)
    ), false);
  }

  // 3. Handle Primitives
  const [, base, sizeStr] = type.match(TYPE_RX) || [];
  
  // 3a. Dynamic Bytes/String
  if (base === 'bytes' && !sizeStr) {
    const hex = typeof val === 'string' ? clean(val) : val; 
    const len = Math.ceil(hex.length / 2);
    return { h: '', t: pad(numToHex(len)) + hex.padEnd(Math.ceil(len / 32) * 64, '0') };
  }
  if (base === 'string') {
    return encode('bytes', Array.from(utf8.encode(val)).map(b => b.toString(16).padStart(2,'0')).join(''));
  }

  // 3b. Static Types
  let hex = '';
  if (base === 'address') hex = clean(val);
  else if (base === 'bool') hex = val ? '1' : '0';
  else if (base === 'bytes') hex = clean(val).padEnd(64, '0'); // bytesN
  else { // uint/int
    const n = BN(val);
    hex = numToHex(n < 0n ? n + (1n << BN(sizeStr || 256)) : n);
  }
  
  return { h: pad(hex), t: '' };
}

// Helper to join list of encoded items (Used by Arrays & Tuples)
const processList = (items: { h: string; t: string }[], isDynamic: boolean, _staticLen?: number) => {
  let head = '', tail = '', offset = items.length * 32;
  const result = { h: '', t: '' };

  // If dynamic array, prefix with length. Static arrays don't include length.
  if (isDynamic) result.t += pad(numToHex(items.length));

  for (const item of items) {
    if (item.t) { // Is Dynamic
      head += pad(numToHex(offset));
      tail += item.h + item.t; // Dynamic item content goes to tail
      offset += (item.h + item.t).length / 2;
    } else { // Is Static
      head += item.h;
    }
  }

  if (isDynamic) result.t += head + tail;
  else Object.assign(result, { h: head + tail }); // Tuples & static arrays inline content

  return result;
};

// ─────────────────────────────────────────────────────────────
// Decoder
// ─────────────────────────────────────────────────────────────

export function decode(type: string, data: string, offset = 0, components?: any[]): { val: any; read: number } {
  const d = clean(data);
  const readWord = (off: number) => d.slice(off, off + 64);
  const readInt = (off: number) => BN('0x' + readWord(off));

  // 1. Arrays ([] or [N])
  const arrayMatch = type.match(/(\[\d*\])$/);
  if (arrayMatch) {
    const base = type.slice(0, -arrayMatch[1].length);
    const isDynamic = arrayMatch[1] === '[]';
    const staticLen = !isDynamic ? Number(arrayMatch[1].slice(1, -1)) : 0;

    let ptr = offset;
    let len = staticLen;

    // For dynamic arrays, read pointer and then length
    if (isDynamic) {
      ptr = Number(readInt(offset)) * 2;
      len = Number(readInt(ptr));
      ptr += 64;
    }

    const arr = [];
    let childOff = ptr;

    for (let i = 0; i < len; i++) {
      // If dynamic child, read pointer. Else read data directly.
      const isDyn = base === 'string' || base === 'bytes' || base.endsWith(']');
      const start = isDyn ? ptr + (Number(readInt(childOff)) * 2) : childOff;
      const res = decode(base, d, start, components);
      arr.push(res.val);
      childOff += isDyn ? 64 : res.read;
    }

    return { val: arr, read: isDynamic ? 64 : staticLen * 32 };
  }

  // 2. Tuples
  if (type === 'tuple' && components) {
    const obj: any = Array.isArray(components) ? {} : [];
    let curr = offset;
    components.forEach((c, i) => {
      const isDyn = c.type === 'string' || c.type === 'bytes' || c.type.endsWith('[]');
      const start = isDyn ? offset + (Number(readInt(curr)) * 2) : curr;
      const res = decode(c.type, d, start, c.components);
      obj[c.name || i] = res.val;
      curr += 64;
    });
    return { val: obj, read: curr - offset };
  }

  // 3. Primitives
  const [, base, sizeStr] = type.match(TYPE_RX) || [];

  if (base === 'bytes' && !sizeStr) { // Dynamic bytes
    const ptr = Number(readInt(offset)) * 2;
    const len = Number(readInt(ptr));
    return { val: `0x${d.slice(ptr + 64, ptr + 64 + len * 2)}`, read: 64 };
  }
  
  if (base === 'string') {
    const b = decode('bytes', d, offset);
    const bytes = new Uint8Array(b.val.slice(2).match(/.{1,2}/g)!.map((b: string) => parseInt(b, 16)));
    return { val: decUtf8.decode(bytes), read: 64 };
  }

  // Static Primitives
  const val = readInt(offset);
  if (base === 'address') return { val: `0x${readWord(offset).slice(24)}`, read: 64 };
  if (base === 'bool') return { val: val !== 0n, read: 64 };
  if (base === 'int') {
    const bits = BN(sizeStr || 256);
    const mask = 1n << (bits - 1n);
    return { val: val >= mask ? val - (1n << bits) : val, read: 64 };
  }
  if (base === 'bytes') return { val: `0x${readWord(offset).slice(0, parseInt(sizeStr!) * 2)}`, read: 64 };

  return { val, read: 64 }; // uint
}

// ─────────────────────────────────────────────────────────────
// High Level API
// ─────────────────────────────────────────────────────────────

export function encodeFn({ abi, functionName, args = [] }: any): Hex {
  const fn = abi.find((i: any) => i.name === functionName);
  if (!fn) throw new Error('Fn not found');
  const argsEncoded = processList(fn.inputs.map((i: any, idx: number) => encode(i.type, args[idx], i.components)), false);
  const sig = `${fn.name}(${fn.inputs.map((i: any) => i.type).join(',')})`;
  return `${getSelector(sig)}${argsEncoded.h}${argsEncoded.t}`;
}

export function decodeFn({ abi, functionName, data }: any): any {
  const fn = abi.find((i: any) => i.name === functionName);
  if (!fn || !fn.outputs.length) return undefined;
  const res = decode(fn.outputs.length > 1 ? 'tuple' : fn.outputs[0].type, data, 0, fn.outputs);
  return res.val;
}

// ─────────────────────────────────────────────────────────────
// Viem-Compatible ABI Parameter Encoding/Decoding
// ─────────────────────────────────────────────────────────────

/**
 * Encode parameters to hex string (viem-compatible)
 * @example encodeAbiParameters([{type: 'address'}, {type: 'uint256'}], ['0x...', 123n])
 */
export function encodeAbiParameters(params: AbiParameter[], values: any[]): Hex {
  const encoded = processList(
    params.map((p, i) => encode(p.type, values[i], p.components)),
    false
  );
  return `0x${encoded.h}${encoded.t}` as Hex;
}

/**
 * Decode parameters from hex string (viem-compatible)
 * @example decodeAbiParameters([{type: 'address'}, {type: 'uint256'}], '0x...')
 */
export function decodeAbiParameters(params: AbiParameter[], data: string): any[] {
  const d = clean(data);
  const result: any[] = [];
  let offset = 0;

  for (const param of params) {
    const decoded = decode(param.type, d, offset, param.components);
    result.push(decoded.val);
    offset += decoded.read;
  }

  return result;
}

/**
 * Get event signature hash (topic 0) - requires external keccak256
 * @note: This returns the signature string. Use external keccak256 lib for actual topic hash.
 * @example const topicHash = keccak256(toBytes(getEventSignature(event)))
 */
export function getEventSignature(event: AbiEvent): string {
  return `${event.name}(${(event.inputs || []).map(i => i.type).join(',')})`;
}

/**
 * Encode event indexed parameters (for log filtering with external keccak256)
 * @note: Topic[0] is the event signature hash - compute it separately with keccak256(toBytes(getEventSignature(event)))
 */
export function encodeEventTopics(event: AbiEvent, args: Record<string, any>): (Hex | null)[] {
  const topics: (Hex | null)[] = [];

  for (const input of event.inputs || []) {
    if (!input.indexed) continue;

    const value = args[input.name || ''];
    if (value === undefined || value === null) {
      topics.push(null);
    } else {
      const encoded = encode(input.type, value, input.components);
      topics.push(`0x${pad(encoded.h)}` as Hex);
    }
  }

  return topics;
}

/**
 * Get error signature (used in error decoding)
 */
export function getErrorSignature(error: AbiError): string {
  return `${error.name}(${(error.inputs || []).map(i => i.type).join(',')})`;
}

/**
 * Encode error parameters (for custom errors)
 */
export function encodeErrorResult(error: AbiError, args: any[]): Hex {
  const sig = getErrorSignature(error);
  const selector = getSelector(sig);
  const encoded = processList(
    (error.inputs || []).map((input, i) => encode(input.type, args[i], input.components)),
    false
  );
  return `${selector}${encoded.h}${encoded.t}` as Hex;
}

/**
 * Decode error result (for custom errors in revert reasons)
 */
export function decodeErrorResult(abi: Abi, data: string): { name: string; args: any[] } | undefined {
  if (!data.startsWith('0x') || data.length < 10) return undefined;

  const selector = data.slice(0, 10);
  const error = abi.find((item: any) => item.type === 'error' && getSelector(getErrorSignature(item)) === selector);

  if (!error) return undefined;

  const args = decodeAbiParameters(error.inputs || [], data.slice(10));
  return { name: error.name, args };
}
