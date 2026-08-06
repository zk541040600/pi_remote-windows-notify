import { randomUUID } from "node:crypto";
import {
  chmod,
  mkdir,
  open,
  rename,
  rm,
  stat,
} from "node:fs/promises";
import { dirname, join } from "node:path";

/**
 * Ensure directory exists with mode 0700.
 * @param {string} dir
 */
export async function ensurePrivateDir(dir) {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  try {
    await chmod(dir, 0o700);
  } catch {
    // best-effort on platforms that ignore mode
  }
}

/**
 * Atomic write: same-dir temp + write + fsync + rename + best-effort dir fsync.
 * File mode defaults to 0600.
 * @param {string} path
 * @param {string | Buffer} content
 * @param {{ mode?: number }} [options]
 */
export async function atomicWriteFile(path, content, options = {}) {
  const mode = options.mode ?? 0o600;
  const dir = dirname(path);
  await ensurePrivateDir(dir);
  const temporaryPath = join(dir, `.tmp-${process.pid}-${randomUUID()}`);
  let handle;
  try {
    handle = await open(temporaryPath, "w", mode);
    await handle.writeFile(content, { encoding: Buffer.isBuffer(content) ? undefined : "utf8" });
    await handle.sync();
    await handle.close();
    handle = undefined;
    try {
      await chmod(temporaryPath, mode);
    } catch {
      // ignore
    }
    await rename(temporaryPath, path);
    await fsyncDirectory(dir);
  } catch (error) {
    if (handle) {
      try {
        await handle.close();
      } catch {
        // ignore
      }
    }
    await rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

/**
 * Best-effort directory fsync. Some platforms/filesystems reject directory handles.
 * @param {string} dir
 */
export async function fsyncDirectory(dir) {
  try {
    const dirHandle = await open(dir, "r");
    try {
      await dirHandle.sync();
    } finally {
      await dirHandle.close();
    }
  } catch {
    // Atomic rename still applies where directory fsync is unavailable.
  }
}

/**
 * @param {string} path
 * @returns {Promise<number | null>} mode bits or null
 */
export async function readMode(path) {
  try {
    const info = await stat(path);
    return info.mode & 0o777;
  } catch {
    return null;
  }
}
