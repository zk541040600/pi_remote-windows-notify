#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_RELATIVE = join("git", "github.com", "zk541040600", "pi_remote-windows-notify");
const PACKAGE_SOURCE_RELATIVES = [
  join("linux", "extensions", "remote-windows-notify.ts"),
  join("windows", "remote-windows-notify.ts"),
];
const MANAGED_SOURCE_NAME = "remote-windows-notify.ts";
const MANAGED_CONFIG_NAME = "remote-windows-notify.json";
const STATE_NAME = "pi-notify-install-state.json";

function readManagedFiles(managedDir) {
  const sourcePath = join(managedDir, MANAGED_SOURCE_NAME);
  const configPath = join(managedDir, MANAGED_CONFIG_NAME);
  if (!existsSync(sourcePath)) {
    throw new Error(`managed extension is missing: ${sourcePath}`);
  }
  if (!existsSync(configPath)) {
    throw new Error(`managed config is missing: ${configPath}`);
  }

  const source = readFileSync(sourcePath);
  const config = readFileSync(configPath);
  try {
    JSON.parse(config.toString("utf8"));
  } catch {
    throw new Error(`managed config is not valid JSON: ${configPath}`);
  }
  return { sourcePath, configPath, source, config };
}

function fileMatches(path, expected) {
  return existsSync(path) && readFileSync(path).equals(expected);
}

function atomicWrite(path, content, mode) {
  mkdirSync(dirname(path), { recursive: true });
  const temporaryPath = `${path}.tmp-${process.pid}-${randomUUID()}`;
  try {
    writeFileSync(temporaryPath, content, { mode });
    chmodSync(temporaryPath, mode);
    renameSync(temporaryPath, path);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function packageTargets(roots) {
  const targets = [];
  for (const root of roots) {
    for (const relative of PACKAGE_SOURCE_RELATIVES) {
      const target = join(root, relative);
      if (!existsSync(target) || !statSync(target).isFile()) {
        throw new Error(`installed package is incomplete: ${target}`);
      }
      targets.push(target);
    }
  }
  return targets;
}

function readState(managedDir) {
  const statePath = join(managedDir, STATE_NAME);
  let state;
  try {
    state = JSON.parse(readFileSync(statePath, "utf8"));
  } catch {
    throw new Error(`install state is missing or invalid: ${statePath}`);
  }
  if (state?.version !== 1 || typeof state.piDir !== "string" || !state.piDir.trim()) {
    throw new Error(`install state has an invalid Pi directory: ${statePath}`);
  }
  return { statePath, piDir: resolve(state.piDir) };
}

function resolveInstallPaths({ managedDir, piDir }) {
  const resolvedManagedDir = resolve(managedDir);
  const resolvedPiDir = piDir ? resolve(piDir) : readState(resolvedManagedDir).piDir;
  const packageRoot = join(resolvedPiDir, PACKAGE_RELATIVE);
  const roots = existsSync(packageRoot) && statSync(packageRoot).isDirectory() ? [packageRoot] : [];
  return {
    managedDir: resolvedManagedDir,
    piDir: resolvedPiDir,
    roots,
    targets: packageTargets(roots),
    legacyEntry: join(resolvedPiDir, "extensions", MANAGED_SOURCE_NAME),
    configTarget: join(resolvedPiDir, MANAGED_CONFIG_NAME),
    statePath: join(resolvedManagedDir, STATE_NAME),
  };
}

export function inspectInstallation(options) {
  const paths = resolveInstallPaths(options);
  const managed = readManagedFiles(paths.managedDir);
  const errors = [];
  const mode = paths.roots.length > 0 ? "package" : "standalone";

  if (mode === "package") {
    if (existsSync(paths.legacyEntry)) {
      errors.push(`duplicate legacy extension is still active: ${paths.legacyEntry}`);
    }
    for (const target of paths.targets) {
      if (!fileMatches(target, managed.source)) {
        errors.push(`package extension differs from managed source: ${target}`);
      }
    }
  } else if (!fileMatches(paths.legacyEntry, managed.source)) {
    errors.push(`standalone extension differs from managed source: ${paths.legacyEntry}`);
  }

  if (!fileMatches(paths.configTarget, managed.config)) {
    errors.push(`runtime config differs from managed config: ${paths.configTarget}`);
  }
  if (process.platform !== "win32" && existsSync(paths.configTarget) && (statSync(paths.configTarget).mode & 0o777) !== 0o600) {
    errors.push(`runtime config mode is not 0600: ${paths.configTarget}`);
  }

  try {
    const state = readState(paths.managedDir);
    if (state.piDir !== paths.piDir) {
      errors.push(`install state points at a different Pi directory: ${state.statePath}`);
    }
  } catch (error) {
    errors.push(error instanceof Error ? error.message : String(error));
  }

  return {
    mode,
    activePath: mode === "package" ? join(paths.roots[0], PACKAGE_SOURCE_RELATIVES[0]) : paths.legacyEntry,
    packageCopies: paths.targets.length,
    piDir: paths.piDir,
    errors,
  };
}

export function ensureInstallation(options) {
  const paths = resolveInstallPaths(options);
  const managed = readManagedFiles(paths.managedDir);
  const packageMode = paths.roots.length > 0;

  if (packageMode && existsSync(paths.legacyEntry) && !fileMatches(paths.legacyEntry, managed.source)) {
    throw new Error(`conflicting legacy extension must be reviewed before package mode can continue: ${paths.legacyEntry}`);
  }

  if (packageMode) {
    for (const target of paths.targets) {
      atomicWrite(target, managed.source, 0o644);
    }
    rmSync(paths.legacyEntry, { force: true });
  } else {
    atomicWrite(paths.legacyEntry, managed.source, 0o644);
  }

  atomicWrite(paths.configTarget, managed.config, 0o600);
  atomicWrite(
    paths.statePath,
    `${JSON.stringify({ version: 1, piDir: paths.piDir }, null, 2)}\n`,
    0o600,
  );
  if (process.platform !== "win32") {
    chmodSync(managed.sourcePath, 0o644);
    chmodSync(managed.configPath, 0o600);
  }

  const result = inspectInstallation({ managedDir: paths.managedDir, piDir: paths.piDir });
  if (result.errors.length > 0) {
    throw new Error(`post-install verification failed: ${result.errors.join("; ")}`);
  }
  return result;
}

function parseArguments(argv) {
  const result = { check: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--check") {
      result.check = true;
      continue;
    }
    if (argument === "--managed-dir" || argument === "--pi-dir") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error(`missing value for ${argument}`);
      }
      result[argument === "--managed-dir" ? "managedDir" : "piDir"] = value;
      index += 1;
      continue;
    }
    throw new Error(`unknown argument: ${argument}`);
  }
  return result;
}

function runCli() {
  const arguments_ = parseArguments(process.argv.slice(2));
  const managedDir = arguments_.managedDir ?? dirname(fileURLToPath(import.meta.url));
  const options = { managedDir, piDir: arguments_.piDir };
  const result = arguments_.check ? inspectInstallation(options) : ensureInstallation(options);
  if (result.errors.length > 0) {
    for (const error of result.errors) {
      console.error(`BAD ${error}`);
    }
    process.exitCode = 1;
    return;
  }
  console.log(
    `OK Pi notify bridge ${arguments_.check ? "verified" : "ensured"} mode=${result.mode} packageCopies=${result.packageCopies} active=${result.activePath}`,
  );
}

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && resolve(process.argv[1]) === resolve(currentFile)) {
  try {
    runCli();
  } catch (error) {
    console.error(`BAD ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
