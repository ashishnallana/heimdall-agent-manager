/*
 * Proves the QR encoder produces codes that genuinely scan.
 *
 * Two independent checks per input:
 *   1. the module matrix matches `qrencode`, the reference C implementation;
 *   2. a PNG rendered from our matrix decodes back to the original text via `zbarimg`.
 *
 * Check 2 is the one that matters — it is end-to-end and does not care how we got there.
 *
 * Run inside a nix shell providing qrencode and zbar:
 *   nix shell nixpkgs#qrencode nixpkgs#zbar --command node qr.test.mjs
 */
import { execFileSync } from 'node:child_process';
import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';
import { qrMatrix } from './qr.js';

const CASES = [
  'otpauth://totp/heimdall%3Ademo-user?secret=MZXW6YTBOI5DCMRTGQZTENBVGY3TIMZU&algorithm=SHA1&digits=6&period=30&issuer=heimdall',
  'otpauth://totp/heimdall%3Aa?secret=JBSWY3DPEHPK3PXP&algorithm=SHA1&digits=6&period=30&issuer=heimdall',
  'otpauth://totp/heimdall%3Asomebody-with-a-really-rather-long-username-indeed?secret=MZXW6YTBOI5DCMRTGQZTENBVGY3TIMZU&algorithm=SHA1&digits=6&period=30&issuer=heimdall',
  'HELLO',
];

const dir = mkdtempSync(join(tmpdir(), 'qrtest-'));

/** Reference matrix from qrencode, as rows of 0/1. */
function reference(text) {
  const out = execFileSync('qrencode', ['-l', 'M', '-t', 'ASCII', '-m', '0', '-o', '-', text],
    { input: '', encoding: 'latin1' });
  // ASCII output uses two characters per module: '##' is dark, '  ' is light.
  return out.split('\n').filter((l) => l.length > 1).map((line) => {
    const row = [];
    for (let i = 0; i < line.length; i += 2) row.push(line[i] === '#' ? 1 : 0);
    return row;
  });
}

/** Render a matrix to a minimal greyscale PNG so zbarimg can read it. */
function writePng(matrix, path, scale = 8, quiet = 4) {
  const n = matrix.length, size = (n + quiet * 2) * scale;
  const raw = Buffer.alloc((size + 1) * size, 0xff);
  for (let y = 0; y < size; y++) {
    raw[y * (size + 1)] = 0;                       // per-scanline filter byte
    const my = Math.floor(y / scale) - quiet;
    if (my < 0 || my >= n) continue;
    for (let x = 0; x < size; x++) {
      const mx = Math.floor(x / scale) - quiet;
      if (mx < 0 || mx >= n) continue;
      raw[y * (size + 1) + 1 + x] = matrix[my][mx] ? 0x00 : 0xff;
    }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
    const crcBuf = Buffer.alloc(4); crcBuf.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crcBuf]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 0;                        // 8-bit greyscale
  writeFileSync(path, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]));
}

let CRC_TABLE = null;
function crc32(buf) {
  if (!CRC_TABLE) {
    CRC_TABLE = new Int32Array(256);
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      CRC_TABLE[i] = c;
    }
  }
  let c = -1;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return c ^ -1;
}

let pass = 0, fail = 0;
for (const text of CASES) {
  const label = text.length > 54 ? text.slice(0, 51) + '...' : text;
  const mine = qrMatrix(text);

  const ref = reference(text);
  const sameSize = ref.length === mine.length;
  const identical = sameSize && mine.every((row, r) => row.every((v, c) => v === ref[r][c]));

  const png = join(dir, 'q.png');
  writePng(mine, png);
  let decoded = '';
  try {
    decoded = execFileSync('zbarimg', ['-q', '--raw', png], { encoding: 'utf8' }).trim();
  } catch (e) { decoded = `<zbarimg failed: ${e.status}>`; }
  const scans = decoded === text;

  // Decoding is the criterion. Matching qrencode byte-for-byte is NOT required and is only
  // reported: it may pick a different mask, and it performs optimal MODE SEGMENTATION —
  // splitting a string into alphanumeric and byte runs — where we always emit one byte-mode
  // segment. That legitimately lets it reach a smaller version for the same text.
  //
  // So the structural assertion is one-sided: our code may be the same size or LARGER than
  // the reference, never smaller. Smaller would mean we had claimed a capacity we do not
  // have, which is a real bug and the kind that still scans right up until the payload grows.
  const notUndersized = mine.length >= ref.length;
  const ok = scans && notUndersized;
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${mine.length}x${mine.length}  scans=${scans}  `
    + `ref=${ref.length}x${ref.length}  not-undersized=${notUndersized}  identical=${identical}  ${label}`);
  if (!scans) console.log(`      decoded: ${JSON.stringify(decoded.slice(0, 80))}`);
}
try { unlinkSync(join(dir, 'q.png')); } catch {}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
