/**
 * Encoding utilities: Hex and Compact Formats
 * Keccak256 is exported from @sdk/eth (uses @noble/hashes)
 */

// ─────────────────────────────────────────────────────────────
// B64 Encoding/Decoding (52/5/7 format)
// ─────────────────────────────────────────────────────────────

/**
 * Custom encoding used for compact amount representation
 */

const B64_MANTISSA_BITS = 52n;
const B64_MAX_MANTISSA = (1n << B64_MANTISSA_BITS) - 1n;
const EXPONENT_BIAS = 64n;

/**
 * Encode amount to B64 format (52-bit mantissa, 5-bit decimals, 7-bit exponent)
 * @param amount - Raw token amount as bigint
 * @param decimals - Token decimals (0-31)
 * @returns B64 encoded value as bigint (fits in uint64)
 */
export function encodeB64(amount: bigint, decimals: number): bigint {
  if (amount === 0n) throw new Error('Cannot encode zero');
  if (decimals > 31) throw new Error('Decimals must be <= 31');

  let mant = amount;
  let exponent = 0n;

  // Normalize mantissa to fit in 52 bits
  while (mant > B64_MAX_MANTISSA) {
    mant = (mant + 5n) / 10n; // Round
    exponent++;
  }

  // Scale up if too small
  const minMantissa = B64_MAX_MANTISSA / 10n;
  while (mant < minMantissa && exponent > -64n) {
    mant *= 10n;
    exponent--;
  }

  if (exponent < -64n || exponent > 63n) throw new Error('Exponent overflow');

  // Pack: mantissa(52) | decimals(5) | biasedExp(7)
  const biasedExp = exponent + EXPONENT_BIAS;
  return (mant << 12n) | (BigInt(decimals) << 7n) | biasedExp;
}

/**
 * Decode B64 to raw amount
 * @param packed - B64 encoded value
 * @param targetDecimals - Target decimal precision
 * @returns Decoded amount as bigint
 */
export function decodeB64(packed: bigint, targetDecimals: number): bigint {
  if (packed === 0n) throw new Error('Cannot decode zero');

  const mant = packed >> 12n;
  const storedDecimals = Number((packed >> 7n) & 0x1fn);
  const exponent = (packed & 0x7fn) - EXPONENT_BIAS;

  const totalShift = exponent + BigInt(targetDecimals - storedDecimals);

  if (totalShift >= 0n) {
    return mant * 10n ** totalShift;
  } else {
    return mant / 10n ** -totalShift;
  }
}

// ─────────────────────────────────────────────────────────────
// Hex Encoding/Decoding
// ─────────────────────────────────────────────────────────────

export function hexToNumber(hex: string): number {
  return parseInt(hex, 16);
}

export function numberToHex(num: number | bigint): `0x${string}` {
  return `0x${num.toString(16)}`;
}

export function hexToBigInt(hex: string): bigint {
  return BigInt(hex);
}

export function bigIntToHex(num: bigint): `0x${string}` {
  return `0x${num.toString(16)}`;
}

/**
 * Convert various types to hex string
 */
export function toHex(
  value: string | number | bigint | boolean | Uint8Array,
): `0x${string}` {
  if (typeof value === 'string') {
    // Already hex
    if (value.startsWith('0x')) return value as `0x${string}`;
    // UTF-8 string to hex
    return `0x${Array.from(new TextEncoder().encode(value))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')}`;
  }
  if (typeof value === 'number' || typeof value === 'bigint') {
    return numberToHex(value);
  }
  if (typeof value === 'boolean') {
    return value ? '0x1' : '0x0';
  }
  if (value instanceof Uint8Array) {
    return `0x${Array.from(value)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')}`;
  }
  throw new Error(`Cannot convert ${typeof value} to hex`);
}

/**
 * Concatenate hex strings or byte arrays
 */
export function concat(values: (`0x${string}` | Uint8Array)[]): `0x${string}` {
  let result = '';
  for (const val of values) {
    if (typeof val === 'string') {
      result += val.slice(2); // Remove 0x prefix
    } else {
      result += Array.from(val)
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('');
    }
  }
  return `0x${result}`;
}

/**
 * Pad hex string to specified byte length
 * @param hex - Hex string to pad
 * @param size - Target byte length (default: 32)
 * @param dir - Padding direction: 'left' (default) or 'right'
 */
export function pad(
  hex: `0x${string}`,
  size = 32,
  dir: 'left' | 'right' = 'left',
): `0x${string}` {
  const stripped = hex.slice(2);
  const targetLength = size * 2; // 2 hex chars per byte

  if (stripped.length >= targetLength) {
    return hex;
  }

  const padding = '0'.repeat(targetLength - stripped.length);
  return dir === 'left'
    ? `0x${padding}${stripped}`
    : `0x${stripped}${padding}`;
}

