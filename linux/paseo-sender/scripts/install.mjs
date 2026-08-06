#!/usr/bin/env node
/**
 * Install systemd --user unit template for paseo-sender.
 * Default is dry-run / temp HOME; never calls real systemctl unless --apply.
 * enable --now requires additional --enable-now (still needs --apply).
 */
import { chmodSync, mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(__dirname, "..");
const unitTemplatePath = join(packageRoot, "systemd", "paseo-sender.service");
const cliPath = join(packageRoot, "src", "cli.mjs");

export function renderUnit({ nodePath, cliPath: cli, stateDir, configPath, description }) {
  return `[Unit]
Description=${description || "Paseo unified Windows notify sender"}
After=default.target

[Service]
Type=simple
ExecStart=${systemdQuote(nodePath)} ${systemdQuote(cli)} run --config ${systemdQuote(configPath)}
Restart=on-failure
RestartSec=5
Environment=${systemdQuote(`PASEO_SENDER_STATE_DIR=${stateDir}`)}
# Secrets must come from the config file (mode 0600), never from unit Environment=.
NoNewPrivileges=true

[Install]
WantedBy=default.target
`;
}

function systemdQuote(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export function resolvePaths(env = process.env) {
  const home = env.HOME || homedir();
  const xdgConfig = env.XDG_CONFIG_HOME || join(home, ".config");
  const xdgState = env.XDG_STATE_HOME || join(home, ".local", "state");
  const unitDir = join(xdgConfig, "systemd", "user");
  const unitPath = join(unitDir, "paseo-sender.service");
  const configDir = join(xdgConfig, "paseo-sender");
  const configPath = join(configDir, "config.json");
  const stateDir = join(xdgState, "paseo-sender");
  return { home, unitDir, unitPath, configDir, configPath, stateDir };
}

/**
 * @param {string[]} argv
 * @param {{ env?: NodeJS.ProcessEnv, execPath?: string, spawn?: typeof spawnSync }} [options]
 */
export function installMain(argv = process.argv.slice(2), options = {}) {
  const env = options.env || process.env;
  const apply = argv.includes("--apply");
  const enableNow = argv.includes("--enable-now");
  const nodePath = options.execPath || process.execPath;
  const paths = resolvePaths(env);

  const unitBody = renderUnit({
    nodePath,
    cliPath,
    stateDir: paths.stateDir,
    configPath: paths.configPath,
  });

  const plan = {
    apply,
    enableNow: apply && enableNow,
    unitPath: paths.unitPath,
    configPath: paths.configPath,
    stateDir: paths.stateDir,
    systemctlCommands: apply
      ? [
          "systemctl --user daemon-reload",
          ...(enableNow ? ["systemctl --user enable --now paseo-sender.service"] : []),
        ]
      : [],
  };

  if (!apply) {
    process.stdout.write(
      `${JSON.stringify({ dryRun: true, plan, unitPreview: unitBody }, null, 2)}\n`,
    );
    return 0;
  }

  mkdirSync(paths.unitDir, { recursive: true, mode: 0o755 });
  mkdirSync(paths.configDir, { recursive: true, mode: 0o700 });
  mkdirSync(paths.stateDir, { recursive: true, mode: 0o700 });

  writeFileSync(paths.unitPath, unitBody, { mode: 0o644 });
  if (!existsSync(paths.configPath)) {
    const example = {
      enabled: true,
      deliveryMode: "shadow",
      daemonUrl: "ws://127.0.0.1:8787",
      clientId: "paseo-sender",
      windowsEndpoint: "http://127.0.0.1:23118/notify",
      windowsToken: "",
      detailedSummary: false,
    };
    writeFileSync(paths.configPath, `${JSON.stringify(example, null, 2)}\n`, { mode: 0o600 });
  }
  try {
    chmodSync(paths.configPath, 0o600);
  } catch {
    // Mode enforcement is rechecked by runtime config loading.
  }

  const spawn = options.spawn || spawnSync;
  for (const command of plan.systemctlCommands) {
    const parts = command.split(" ");
    const result = spawn(parts[0], parts.slice(1), {
      env,
      encoding: "utf8",
    });
    if (result.status !== 0) {
      process.stderr.write(`command failed: ${command}\n${result.stderr || ""}\n`);
      return 1;
    }
  }

  process.stdout.write(`${JSON.stringify({ ok: true, plan }, null, 2)}\n`);
  return 0;
}

export function readUnitTemplate() {
  if (existsSync(unitTemplatePath)) {
    return readFileSync(unitTemplatePath, "utf8");
  }
  return null;
}

const isDirect = process.argv[1] && process.argv[1].endsWith("install.mjs");
if (isDirect) {
  process.exitCode = installMain();
}
