/**
 * Node crypto hook for core modules under test.
 */
import { createHash, randomFillSync } from 'node:crypto';

globalThis.__piNotifyNodeCrypto = {
  createHash,
  randomFillSync: (buf) => {
    randomFillSync(buf);
    return buf;
  },
};
