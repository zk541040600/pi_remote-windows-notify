#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const child = join(root, "linux", "paseo-sender");
const gate = process.argv[2];
if (gate !== "test" && gate !== "check") {
  process.stderr.write("usage: node scripts/run-paseo-sender-gate.mjs <test|check>\n");
  process.exitCode = 2;
} else {
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  process.stdout.write(`\n[paseo-sender:${gate}] begin\n`);
  const result = spawnSync(npm, ["--prefix", child, "run", gate], {
    cwd: root,
    env: process.env,
    stdio: "inherit",
    shell: false,
  });
  if (result.error) {
    process.stderr.write(`[paseo-sender:${gate}] failed to launch: ${result.error.name}\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write(`[paseo-sender:${gate}] exit=${result.status ?? 1}\n\n`);
    process.exitCode = result.status ?? 1;
  }
}
