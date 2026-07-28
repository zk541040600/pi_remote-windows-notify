/**
 * Minimal SHA-256 + random for MV3 service worker (no node:crypto).
 * Used by core modules via globalThis.__piNotifyNodeCrypto.
 */

// Pure JS SHA-256 (compact, public-domain style implementation).
function rotr(n, x) {
  return (x >>> n) | (x << (32 - n));
}

function sha256Bytes(/** @type {Uint8Array} */ message) {
  const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);

  const bitLen = message.length * 8;
  const withPad = message.length + 1 + 8;
  const padLen = (64 - (withPad % 64)) % 64;
  const total = message.length + 1 + padLen + 8;
  const buf = new Uint8Array(total);
  buf.set(message);
  buf[message.length] = 0x80;
  const view = new DataView(buf.buffer);
  // length as 64-bit big-endian (high 32 always 0 for our sizes)
  view.setUint32(total - 4, bitLen >>> 0, false);

  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  const w = new Uint32Array(64);

  for (let i = 0; i < total; i += 64) {
    for (let j = 0; j < 16; j++) {
      w[j] = view.getUint32(i + j * 4, false);
    }
    for (let j = 16; j < 64; j++) {
      const s0 = rotr(7, w[j - 15]) ^ rotr(18, w[j - 15]) ^ (w[j - 15] >>> 3);
      const s1 = rotr(17, w[j - 2]) ^ rotr(19, w[j - 2]) ^ (w[j - 2] >>> 10);
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) >>> 0;
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let j = 0; j < 64; j++) {
      const S1 = rotr(6, e) ^ rotr(11, e) ^ rotr(25, e);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + K[j] + w[j]) >>> 0;
      const S0 = rotr(2, a) ^ rotr(13, a) ^ rotr(22, a);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }

  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  outView.setUint32(0, h0, false);
  outView.setUint32(4, h1, false);
  outView.setUint32(8, h2, false);
  outView.setUint32(12, h3, false);
  outView.setUint32(16, h4, false);
  outView.setUint32(20, h5, false);
  outView.setUint32(24, h6, false);
  outView.setUint32(28, h7, false);
  return out;
}

function toHex(/** @type {Uint8Array} */ bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, '0');
  return s;
}

/**
 * node:crypto-like createHash('sha256')
 * @param {string} alg
 */
export function createHash(alg) {
  if (String(alg).toLowerCase() !== 'sha256') {
    throw new Error(`unsupported hash: ${alg}`);
  }
  /** @type {Uint8Array[]} */
  const chunks = [];
  return {
    /**
     * @param {Uint8Array|ArrayBuffer|string} data
     * @param {string} [encoding]
     */
    update(data, encoding) {
      if (typeof data === 'string') {
        chunks.push(new TextEncoder().encode(data));
      } else if (data instanceof ArrayBuffer) {
        chunks.push(new Uint8Array(data));
      } else if (ArrayBuffer.isView(data)) {
        chunks.push(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
      } else {
        chunks.push(new Uint8Array(data));
      }
      return this;
    },
    digest(encoding) {
      let total = 0;
      for (const c of chunks) total += c.length;
      const msg = new Uint8Array(total);
      let off = 0;
      for (const c of chunks) {
        msg.set(c, off);
        off += c.length;
      }
      const hash = sha256Bytes(msg);
      if (encoding === 'hex' || encoding == null) return toHex(hash);
      return hash;
    },
  };
}

/**
 * @param {Uint8Array} buf
 */
export function randomFillSync(buf) {
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(buf);
    return buf;
  }
  for (let i = 0; i < buf.length; i++) buf[i] = Math.floor(Math.random() * 256);
  return buf;
}
