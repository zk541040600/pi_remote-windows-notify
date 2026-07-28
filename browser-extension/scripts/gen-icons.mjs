#!/usr/bin/env node
/**
 * Generate minimal solid PNG icons (no external deps).
 */

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = join(__dirname, '..', 'icons');
mkdirSync(outDir, { recursive: true });

/**
 * @param {number} size
 * @param {[number, number, number]} rgb
 */
function pngRgb(size, rgb) {
  const { 0: r, 1: g, 2: b } = rgb;
  const row = Buffer.alloc(1 + size * 4);
  const raw = Buffer.alloc((1 + size * 4) * size);
  for (let y = 0; y < size; y++) {
    row[0] = 0; // filter none
    for (let x = 0; x < size; x++) {
      const cx = x - size / 2;
      const cy = y - size / 2;
      const rad = size * 0.38;
      const inCircle = cx * cx + cy * cy <= rad * rad;
      const o = 1 + x * 4;
      if (inCircle) {
        row[o] = r;
        row[o + 1] = g;
        row[o + 2] = b;
        row[o + 3] = 255;
      } else {
        row[o] = 15;
        row[o + 1] = 20;
        row[o + 2] = 28;
        row[o + 3] = 255;
      }
    }
    row.copy(raw, y * row.length);
  }

  const compressed = deflateSync(raw);

  function chunk(/** @type {string} */ type, /** @type {Buffer} */ data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const typeBuf = Buffer.from(type, 'ascii');
    const crcSrc = Buffer.concat([typeBuf, data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(crcSrc) >>> 0);
    return Buffer.concat([len, typeBuf, data, crc]);
  }

  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  return Buffer.concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', compressed),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function crc32(/** @type {Buffer} */ buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? (0xedb88320 ^ (c >>> 1)) : c >>> 1;
    }
  }
  return ~c;
}

const color = [61, 139, 253];
for (const size of [16, 48, 128]) {
  const file = join(outDir, `icon${size}.png`);
  writeFileSync(file, pngRgb(size, color));
  console.log('wrote', file);
}
