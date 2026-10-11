/*
 * Minimal QR encoder — byte mode, error-correction level M, versions 1..15.
 *
 * Needed because the TOTP setup stage hands us an `otpauth://` URI and nothing else: the
 * QR has to be produced in the browser. External scripts are not an option on the Authentik
 * origin, so this is deliberately dependency-free.
 *
 * Correctness is not self-evident for this algorithm, so it is checked against `qrencode`
 * and round-tripped through `zbarimg` in qr.test.mjs rather than eyeballed.
 */

// EC level M. Per version: [ecCodewordsPerBlock, group1Blocks, group1DataCw, group2Blocks, group2DataCw]
const EC_M = {
  1:  [10, 1, 16, 0, 0],
  2:  [16, 1, 28, 0, 0],
  3:  [26, 1, 44, 0, 0],
  4:  [18, 2, 32, 0, 0],
  5:  [24, 2, 43, 0, 0],
  6:  [16, 4, 27, 0, 0],
  7:  [18, 4, 31, 0, 0],
  8:  [22, 2, 38, 2, 39],
  9:  [22, 3, 36, 2, 37],
  10: [26, 4, 43, 1, 44],
  11: [30, 1, 50, 4, 51],
  12: [22, 6, 36, 2, 37],
  13: [22, 8, 37, 1, 38],
  14: [24, 4, 40, 5, 41],
  15: [24, 5, 41, 5, 42],
};

// Alignment pattern centre coordinates per version (version 1 has none).
const ALIGN = {
  1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
  7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
  11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62], 14: [6, 26, 46, 66],
  15: [6, 26, 48, 70],
};

// ---- GF(256) for Reed-Solomon, primitive polynomial 0x11d --------------------
const EXP = new Uint8Array(512), LOG = new Uint8Array(256);
(() => {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x; LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();
const mul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]];

function rsGenerator(degree) {
  let poly = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(poly.length + 1).fill(0);
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= mul(poly[j], EXP[i]);
      next[j + 1] ^= poly[j];
    }
    poly = next;
  }
  // Built in ascending powers, so the leading 1 ends up last. rsRemainder wants the leading
  // coefficient first — reverse before returning.
  return poly.reverse();
}

function rsRemainder(data, degree) {
  const gen = rsGenerator(degree);
  const rem = new Array(degree).fill(0);
  for (const byte of data) {
    const factor = byte ^ rem[0];
    rem.shift(); rem.push(0);
    for (let i = 0; i < degree; i++) rem[i] ^= mul(gen[i + 1], factor);
  }
  return rem;
}

// ---- Bit helpers -------------------------------------------------------------
class Bits {
  constructor() { this.bits = []; }
  push(value, length) {
    for (let i = length - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
  }
  get length() { return this.bits.length; }
}

const totalDataCodewords = (v) => {
  const [ec, b1, d1, b2, d2] = EC_M[v];
  return b1 * d1 + b2 * d2;
};

function chooseVersion(byteLen) {
  for (let v = 1; v <= 15; v++) {
    const countBits = v < 10 ? 8 : 16;
    const need = 4 + countBits + byteLen * 8;
    if (need <= totalDataCodewords(v) * 8) return v;
  }
  throw new Error('qr: payload too long for version 15 at EC level M');
}

// ---- Codeword assembly -------------------------------------------------------
function buildCodewords(bytes, version) {
  const [ecPerBlock, b1, d1, b2, d2] = EC_M[version];
  const capacity = totalDataCodewords(version) * 8;
  const bs = new Bits();
  bs.push(0b0100, 4);                                   // byte mode
  bs.push(bytes.length, version < 10 ? 8 : 16);         // character count
  for (const b of bytes) bs.push(b, 8);
  bs.push(0, Math.min(4, capacity - bs.length));        // terminator
  while (bs.length % 8) bs.bits.push(0);                // pad to a byte boundary

  const data = [];
  for (let i = 0; i < bs.length; i += 8) {
    let byte = 0;
    for (let j = 0; j < 8; j++) byte = (byte << 1) | bs.bits[i + j];
    data.push(byte);
  }
  const pads = [0xec, 0x11];
  for (let i = 0; data.length < capacity / 8; i++) data.push(pads[i % 2]);

  // Split into blocks, compute EC per block, then interleave both.
  const blocks = [], ecBlocks = [];
  let pos = 0;
  for (let i = 0; i < b1 + b2; i++) {
    const size = i < b1 ? d1 : d2;
    const block = data.slice(pos, pos + size);
    pos += size;
    blocks.push(block);
    ecBlocks.push(rsRemainder(block, ecPerBlock));
  }
  const out = [];
  const maxData = Math.max(d1, d2);
  for (let i = 0; i < maxData; i++) for (const b of blocks) if (i < b.length) out.push(b[i]);
  for (let i = 0; i < ecPerBlock; i++) for (const b of ecBlocks) out.push(b[i]);
  return out;
}

// ---- Matrix ------------------------------------------------------------------
function buildMatrix(version, codewords, mask) {
  const size = version * 4 + 17;
  const m = Array.from({ length: size }, () => new Array(size).fill(null));
  const reserved = Array.from({ length: size }, () => new Array(size).fill(false));

  const setF = (r, c, v) => { if (r >= 0 && r < size && c >= 0 && c < size) { m[r][c] = v; reserved[r][c] = true; } };

  // Finder patterns plus their separators.
  for (const [br, bc] of [[0, 0], [0, size - 7], [size - 7, 0]]) {
    for (let r = -1; r <= 7; r++) for (let c = -1; c <= 7; c++) {
      const inner = r >= 0 && r <= 6 && c >= 0 && c <= 6;
      const on = inner && (r === 0 || r === 6 || c === 0 || c === 6 || (r >= 2 && r <= 4 && c >= 2 && c <= 4));
      setF(br + r, bc + c, on ? 1 : 0);
    }
  }
  // Timing patterns.
  for (let i = 8; i < size - 8; i++) { setF(6, i, i % 2 === 0 ? 1 : 0); setF(i, 6, i % 2 === 0 ? 1 : 0); }
  // Alignment patterns, skipping those that collide with finders.
  const centers = ALIGN[version];
  for (const r of centers) for (const c of centers) {
    if ((r <= 8 && c <= 8) || (r <= 8 && c >= size - 9) || (r >= size - 9 && c <= 8)) continue;
    for (let dr = -2; dr <= 2; dr++) for (let dc = -2; dc <= 2; dc++) {
      const on = Math.max(Math.abs(dr), Math.abs(dc)) !== 1;
      setF(r + dr, c + dc, on ? 1 : 0);
    }
  }
  setF(size - 8, 8, 1);                                  // dark module
  // Reserve the format areas, which are written after masking. Mark them only — writing a
  // value here would clobber the timing modules at (6,8) and (8,6), which fall inside this
  // span and are not format positions, so nothing would put them back.
  const keep = (r, c) => { reserved[r][c] = true; };
  for (let i = 0; i < 9; i++) { keep(8, i); keep(i, 8); }
  for (let i = 0; i < 8; i++) { keep(8, size - 1 - i); keep(size - 1 - i, 8); }
  // Version information blocks, versions 7 and up.
  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const vbits = (version << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const bit = (vbits >>> i) & 1;
      setF(Math.floor(i / 3), size - 11 + (i % 3), bit);
      setF(size - 11 + (i % 3), Math.floor(i / 3), bit);
    }
  }

  // Data placement: two-column zigzag from the bottom right, skipping column 6.
  let bitIndex = 0, upward = true;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let step = 0; step < size; step++) {
      const r = upward ? size - 1 - step : step;
      for (const c of [right, right - 1]) {
        if (reserved[r][c]) continue;
        let bit = 0;
        if (bitIndex < codewords.length * 8) {
          bit = (codewords[bitIndex >>> 3] >>> (7 - (bitIndex & 7))) & 1;
        }
        bitIndex++;
        m[r][c] = bit ^ (maskBit(mask, r, c) ? 1 : 0);
      }
    }
    upward = !upward;
  }

  // Format information: EC level M is 0b00, combined with the mask, BCH(15,5) protected.
  const fmtData = (0b00 << 3) | mask;
  let rem = fmtData;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  const fmt = ((fmtData << 10) | rem) ^ 0x5412;
  // Copy 1 runs down column 8 then left along row 8; copy 2 runs right along row 8 and up
  // column 8. Note the spec is written in (x, y) — these are [row][col], so they look
  // transposed against it.
  for (let i = 0; i <= 5; i++) m[i][8] = (fmt >>> i) & 1;
  m[7][8] = (fmt >>> 6) & 1;
  m[8][8] = (fmt >>> 7) & 1;
  m[8][7] = (fmt >>> 8) & 1;
  for (let i = 9; i < 15; i++) m[8][14 - i] = (fmt >>> i) & 1;
  for (let i = 0; i < 8; i++) m[8][size - 1 - i] = (fmt >>> i) & 1;
  for (let i = 8; i < 15; i++) m[size - 15 + i][8] = (fmt >>> i) & 1;
  m[size - 8][8] = 1;

  return m;
}

function maskBit(mask, r, c) {
  switch (mask) {
    case 0: return (r + c) % 2 === 0;
    case 1: return r % 2 === 0;
    case 2: return c % 3 === 0;
    case 3: return (r + c) % 3 === 0;
    case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
    case 5: return ((r * c) % 2) + ((r * c) % 3) === 0;
    case 6: return (((r * c) % 2) + ((r * c) % 3)) % 2 === 0;
    case 7: return (((r + c) % 2) + ((r * c) % 3)) % 2 === 0;
  }
}

// ---- Mask penalty (ISO/IEC 18004 section 8.8.2) -------------------------------
function penalty(m) {
  const n = m.length;
  let score = 0;

  // Rule 1: runs of five or more same-coloured modules in a row or column.
  for (const transposed of [false, true]) {
    for (let a = 0; a < n; a++) {
      let run = 1;
      for (let b = 1; b < n; b++) {
        const cur = transposed ? m[b][a] : m[a][b];
        const prev = transposed ? m[b - 1][a] : m[a][b - 1];
        if (cur === prev) { run++; if (run === 5) score += 3; else if (run > 5) score++; }
        else run = 1;
      }
    }
  }
  // Rule 2: 2x2 blocks of one colour.
  for (let r = 0; r < n - 1; r++) for (let c = 0; c < n - 1; c++) {
    const v = m[r][c];
    if (v === m[r][c + 1] && v === m[r + 1][c] && v === m[r + 1][c + 1]) score += 3;
  }
  // Rule 3: the 1:1:3:1:1 finder-like pattern with four light modules either side.
  const A = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
  const B = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
  const matches = (get, i) => {
    let a = true, b = true;
    for (let k = 0; k < 11; k++) { const v = get(i + k); if (v !== A[k]) a = false; if (v !== B[k]) b = false; }
    return a || b;
  };
  for (let r = 0; r < n; r++) for (let c = 0; c + 11 <= n; c++) if (matches((i) => m[r][i], c)) score += 40;
  for (let c = 0; c < n; c++) for (let r = 0; r + 11 <= n; r++) if (matches((i) => m[i][c], r)) score += 40;
  // Rule 4: deviation of dark-module proportion from 50%.
  let dark = 0;
  for (const row of m) for (const v of row) dark += v;
  const pct = (dark * 100) / (n * n);
  score += Math.floor(Math.abs(pct - 50) / 5) * 10;
  return score;
}

/** Encode `text` and return the module matrix as an array of rows of 0/1. */
export function qrMatrix(text) {
  const bytes = Array.from(new TextEncoder().encode(text));
  const version = chooseVersion(bytes.length);
  const codewords = buildCodewords(bytes, version);
  let best = null, bestScore = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    const m = buildMatrix(version, codewords, mask);
    const s = penalty(m);
    if (s < bestScore) { bestScore = s; best = m; }
  }
  return best;
}
