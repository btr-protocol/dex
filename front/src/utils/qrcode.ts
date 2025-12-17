/**
 * Ultra-Minimal QR Code Generator
 * Fixed: Version 6 (41x41), Level L, Byte Mode, Mask 0
 * Capacity: ~134 characters (ASCII/UTF-8)
 */

// ─────────────────────────────────────────────────────────────
// 1. GF(256) Math & Polynomials
// ─────────────────────────────────────────────────────────────

const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);

// Precompute Galois Field tables
(function initGF() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d; // Primitive polynomial
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const gfMul = (a: number, b: number) => (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]];

function getPoly(degree: number): Uint8Array {
  const poly = new Uint8Array(degree + 1);
  poly[0] = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = i + 1; j >= 1; j--) {
      poly[j] = poly[j] ^ gfMul(poly[j - 1], EXP[i]);
    }
    poly[0] = gfMul(poly[0], EXP[i]);
  }
  return poly;
}

function getECC(data: Uint8Array, degree: number): Uint8Array {
  const poly = getPoly(degree);
  const ecc = new Uint8Array(degree);
  for (let i = 0; i < data.length; i++) {
    const inv = ecc[0] ^ data[i];
    for (let j = 0; j < degree - 1; j++) ecc[j] = ecc[j + 1] ^ gfMul(inv, poly[degree - 1 - j]);
    ecc[degree - 1] = gfMul(inv, poly[0]);
  }
  return ecc;
}

// ─────────────────────────────────────────────────────────────
// 2. Bit Buffer & Data Encoding
// ─────────────────────────────────────────────────────────────

class BitStream {
  data: number[] = [];
  length = 0;

  put(num: number, len: number) {
    for (let i = 0; i < len; i++) {
      this.putBit(((num >>> (len - i - 1)) & 1) === 1);
    }
  }

  putBit(bit: boolean) {
    if (this.length === this.data.length * 8) this.data.push(0);
    if (bit) this.data[this.length >>> 3] |= (0x80 >>> (this.length & 7));
    this.length++;
  }

  // Interleave blocks (V6-L specific: 2 blocks, 68 data, 18 ECC)
  getBytes(): Uint8Array {
    const dataLen = 68; // V6-L data per block
    const eccLen = 18;  // V6-L ECC per block

    // Prepare blocks
    const d1 = new Uint8Array(this.data.slice(0, dataLen));
    const d2 = new Uint8Array(this.data.slice(dataLen, dataLen * 2));
    const e1 = getECC(d1, eccLen);
    const e2 = getECC(d2, eccLen);

    // Interleave
    const final = new Uint8Array(172);
    let k = 0;

    // Interleave Data
    for (let i = 0; i < dataLen; i++) { final[k++] = d1[i]; final[k++] = d2[i]; }
    // Interleave ECC
    for (let i = 0; i < eccLen; i++) { final[k++] = e1[i]; final[k++] = e2[i]; }

    return final;
  }
}

// ─────────────────────────────────────────────────────────────
// 3. QR Matrix Construction (Fixed V6)
// ─────────────────────────────────────────────────────────────

const SIZE = 41; // Version 6
// const ALIGN = [6, 34]; // Alignment coords
const FORMAT_INFO = 0x77c4; // Level L, Mask 0 (Precomputed BCH)

export function createQR(text: string, options?: { logo?: boolean }): string {
  // 1. Encode Data (Byte Mode)
  const stream = new BitStream();
  const utf8 = new TextEncoder().encode(text);

  if (utf8.length > 134) throw new Error('Text too long for QR V6');

  stream.put(0x4, 4); // Mode: Byte
  stream.put(utf8.length, 8); // Length header
  utf8.forEach(b => stream.put(b, 8));

  // Terminator & Padding
  const totalDataBits = 136 * 8; // 136 bytes * 8
  if (stream.length + 4 <= totalDataBits) stream.put(0, 4);
  while (stream.length % 8 !== 0) stream.putBit(false);

  // Pad bytes (0xEC, 0x11)
  while (stream.length < totalDataBits) {
    stream.put(0xEC, 8);
    if (stream.length < totalDataBits) stream.put(0x11, 8);
  }

  const data = stream.getBytes();

  // 2. Init Matrix
  const mod = Array(SIZE).fill(null).map(() => Array(SIZE).fill(null));
  const set = (x: number, y: number, v: boolean) => mod[y][x] = v;

  // Function Patterns (Finder, Timing, Alignment)
  const fillRect = (x: number, y: number, w: number, h: number) => {
    for (let r = y; r < y + h; r++)
      for (let c = x; c < x + w; c++) set(c, r, true);
  };
  const box = (x: number, y: number) => {
    fillRect(x, y, 7, 7);
    for(let i=2; i<5; i++) for(let j=2; j<5; j++) set(x+j, y+i, true); // inner
    for(let i=1; i<6; i++) { set(x+i, y+1, false); set(x+i, y+5, false); set(x+1, y+i, false); set(x+5, y+i, false); } // ring
  };

  // Finders
  box(0, 0); box(SIZE - 7, 0); box(0, SIZE - 7);

  // Separators
  const hLine = (x: number, y: number, l: number) => { for(let i=0; i<l; i++) set(x+i, y, false); };
  const vLine = (x: number, y: number, l: number) => { for(let i=0; i<l; i++) set(x, y+i, false); };
  hLine(0, 7, 8); hLine(SIZE-8, 7, 8); hLine(0, SIZE-8, 8);
  vLine(7, 0, 8); vLine(SIZE-8, 0, 8); vLine(7, SIZE-8, 8);

  // Alignment (V6: at 6, 34)
  const alignPoints = [[6,34], [34,6], [34,34]];
  // Note: (6,6) is finder, excluded.
  alignPoints.forEach(([c, r]) => {
    // 5x5 box centered
    for(let y=r-2; y<=r+2; y++) for(let x=c-2; x<=c+2; x++) set(x, y,
      y===r-2 || y===r+2 || x===c-2 || x===c+2 || (x===c && y===r)
    );
  });

  // Timing
  for (let i = 8; i < SIZE - 8; i++) {
    if (mod[6][i] === null) set(i, 6, i % 2 === 0);
    if (mod[i][6] === null) set(6, i, i % 2 === 0);
  }

  // 3. Place Data (Zig-Zag)
  let idx = 0;
  for (let right = SIZE - 1; right > 0; right -= 2) {
    if (right === 6) right--;
    for (let vert = 0; vert < SIZE; vert++) {
      const y = ((right + 1) & 2) ? SIZE - 1 - vert : vert;
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        if (mod[y][x] === null) {
          // Get bit
          let bit = false;
          if (idx < data.length * 8) {
            bit = ((data[idx >>> 3] >>> (7 - (idx & 7))) & 1) === 1;
          }
          // Apply Mask 0: (x + y) % 2 === 0
          if ((x + y) % 2 === 0) bit = !bit;
          set(x, y, bit);
          idx++;
        }
      }
    }
  }

  // 4. Place Format Info (L, Mask 0)
  const bits = FORMAT_INFO;
  for (let i = 0; i < 15; i++) {
    const v = ((bits >>> i) & 1) === 1;
    // Vert
    if (i < 6) set(8, i, v);
    else if (i < 8) set(8, i + 1, v);
    else set(8, SIZE - 15 + i, v);
    // Horz
    if (i < 8) set(SIZE - 1 - i, 8, v);
    else if (i < 9) set(15 - i, 8, v);
    else set(15 - i - 1, 8, v);
  }
  set(8, SIZE - 8, true); // Always black module

  // 5. Render SVG
  let path = '';
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      if (mod[y][x]) path += `M${x} ${y}h1v1h-1z`;
    }
  }

  // Add logo if requested (centered 7x7 square with white background)
  let logoSvg = '';
  if (options?.logo) {
    const logoSize = 7;
    const logoPos = (SIZE - logoSize) / 2;
    // White background for logo
    logoSvg = `<rect x="${logoPos}" y="${logoPos}" width="${logoSize}" height="${logoSize}" fill="white"/>`;
    logoSvg += `<image x="${logoPos}" y="${logoPos}" width="${logoSize}" height="${logoSize}" href="/brand/logo-b.svg"/>`;
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" shape-rendering="crispEdges"><path d="${path}"/>${logoSvg}</svg>`;
}
