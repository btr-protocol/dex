/**
 * Ultra-Compact ABI Coder
 * Supports: All standard Solidity types (recursive arrays, tuples, dynamic types)
 */

import type { Hex } from './types';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export type AbiFunction = {
  type: 'function';
  name: string;
  inputs?: any[];
  outputs?: any[];
  stateMutability?: 'pure' | 'view' | 'nonpayable' | 'payable';
};

export type Abi = readonly any[];

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

export const getSelector = (sig: string) => 
  `0x${SELECTORS[sig] || (() => { throw new Error(`Missing selector: ${sig}`) })()}`;

// ─────────────────────────────────────────────────────────────
// Encoder
// ─────────────────────────────────────────────────────────────

const TYPE_RX = /^([a-z]+)(\d+)?(\[\])?$/;

export function encode(type: string, val: any, components?: any[]): { h: string; t: string } {
  // 1. Handle Arrays ([])
  if (type.endsWith('[]')) {
    const base = type.slice(0, -2);
    const arr = val as any[];
    return processList(arr.map(v => encode(base, v, components)), true);
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
const processList = (items: { h: string; t: string }[], isArray: boolean) => {
  let head = '', tail = '', offset = items.length * 32;
  const result = { h: '', t: '' };
  
  // If array, prefix with length
  if (isArray) result.t += pad(numToHex(items.length));

  for (const item of items) {
    if (item.t) { // Is Dynamic
      head += pad(numToHex(offset));
      tail += item.h + item.t; // Dynamic item content goes to tail
      offset += (item.h + item.t).length / 2;
    } else { // Is Static
      head += item.h;
    }
  }
  
  if (isArray) result.t += head + tail;
  else Object.assign(result, { h: head + tail }); // Tuples inline content
  
  return result;
};

// ─────────────────────────────────────────────────────────────
// Decoder
// ─────────────────────────────────────────────────────────────

export function decode(type: string, data: string, offset = 0, components?: any[]): { val: any; read: number } {
  const d = clean(data);
  const readWord = (off: number) => d.slice(off, off + 64);
  const readInt = (off: number) => BN('0x' + readWord(off));

  // 1. Arrays
  if (type.endsWith('[]')) {
    const base = type.slice(0, -2);
    const ptr = Number(readInt(offset)) * 2; // Pointer to data start
    const len = Number(readInt(ptr));       // Array length
    const arr = [];
    let childOff = ptr + 64;
    
    for (let i = 0; i < len; i++) {
      // If dynamic child, read pointer. Else read data directly.
      const isDyn = base === 'string' || base === 'bytes' || base.endsWith('[]');
      const start = isDyn ? ptr + 64 + (Number(readInt(childOff)) * 2) : childOff;
      const res = decode(base, d, start, components);
      arr.push(res.val);
      childOff += isDyn ? 64 : res.read;
    }
    return { val: arr, read: 64 };
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
