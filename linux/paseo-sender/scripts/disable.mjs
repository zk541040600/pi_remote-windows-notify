#!/usr/bin/env node
/**
 * Disable paseo-sender user service. Never calls systemctl unless --apply.
 */
import { unlinkSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolvePaths } from "./install.mjs";

/**
 * @param {string[]} argv
 * @param {{ env?: NodeJS.ProcessEnv, spawn?: typeof spawnSync }} [options]
 */
export function disableMain(argv = process.argv.slice(2), options = {}) {
  const env = options.env || process.env;
  const apply = argv.includes("--apply");
  const paths = resolvePaths(env);
  const commands = apply
    ? ["systemctl --user disable --now paseo-sender.service", "systemctl --user daemon-reload"]
    : [];

  const plan = {
    apply,
    unitPath: paths.unitPath,
    systemctlCommands: commands,
    removeUnit: apply,
  };

  if (!apply) {
    process.stdout.write(`${JSON.stringify({ dryRun: true, plan }, null, 2)}\n`);
    return 0;
  }

  const spawn = options.spawn || spawnSync;
  const disable = spawn("systemctl", ["--user", "disable", "--now", "paseo-sender.service"], {
    env,
    encoding: "utf8",
  });
  if (disable.status !== 0) {
    process.stderr.write("command failed: systemctl --user disable --now paseo-sender.service\n");
    return 1;
  }
  if (existsSync(paths.unitPath)) unlinkSync(paths.unitPath);
  const reload = spawn("systemctl", ["--user", "daemon-reload"], { env, encoding: "utf8" });
  if (reload.status !== 0) {
    process.stderr.write("command failed: systemctl --user daemon-reload\n");
    return 1;
  }
  process.stdout.write(`${JSON.stringify({ ok: true, plan }, null, 2)}\n`);
  return 0;
}

const isDirect = process.argv[1] && process.argv[1].endsWith("disable.mjs");
if (isDirect) {
  process.exitCode = disableMain();
}
