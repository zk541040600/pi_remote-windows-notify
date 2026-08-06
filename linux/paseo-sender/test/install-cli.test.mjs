import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

import { installMain, resolvePaths, renderUnit } from "../scripts/install.mjs";
import { disableMain } from "../scripts/disable.mjs";
import { main as cliMain } from "../src/cli.mjs";
import {
  applyDaemonUrlPolicy,
  loadSenderConfig,
  publicConfigStatus,
} from "../src/config.mjs";

function tempHome(prefix = "paseo-sender-home-") {
  return mkdtempSync(join(tmpdir(), prefix));
}

function envFor(home) {
  return { HOME: home, XDG_CONFIG_HOME: join(home, ".config"), XDG_STATE_HOME: join(home, ".local", "state") };
}

test("install dry-run never spawns or writes", () => {
  const home = tempHome();
  try {
    let spawned = 0;
    const code = installMain([], { env: envFor(home), spawn: () => { spawned += 1; return { status: 0 }; } });
    assert.equal(code, 0);
    assert.equal(spawned, 0);
    assert.equal(existsSync(resolvePaths(envFor(home)).unitPath), false);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("install apply handles paths with spaces, writes private config, and does not enable by default", () => {
  const base = tempHome();
  const home = join(base, "home with spaces");
  mkdirSync(home, { recursive: true });
  try {
    const commands = [];
    const env = envFor(home);
    const code = installMain(["--apply"], {
      env,
      execPath: process.execPath,
      spawn(cmd, args) { commands.push([cmd, ...args]); return { status: 0, stdout: "", stderr: "" }; },
    });
    assert.equal(code, 0);
    const paths = resolvePaths(env);
    const unit = readFileSync(paths.unitPath, "utf8");
    assert.match(unit, /ExecStart="[^"]+node" "[^"]+cli\.mjs" run --config "[^"]+home with spaces/u);
    assert.match(unit, /Environment="PASEO_SENDER_STATE_DIR=[^"]+home with spaces/u);
    assert.equal(/password|windowsToken|daemonPassword|X-Pi-Notify-Token/iu.test(unit), false);
    assert.equal(commands.some((command) => command.includes("enable")), false);
    assert.equal(commands.some((command) => command.includes("daemon-reload")), true);
    assert.equal(statSync(paths.configPath).mode & 0o777, 0o600);
  } finally { rmSync(base, { recursive: true, force: true }); }
});

test("disable apply reports systemctl failure and preserves unit", () => {
  const home = tempHome();
  try {
    const env = envFor(home);
    const paths = resolvePaths(env);
    mkdirSync(dirname(paths.unitPath), { recursive: true });
    writeFileSync(paths.unitPath, "unit");
    const code = disableMain(["--apply"], {
      env,
      spawn: () => ({ status: 1, stdout: "", stderr: "failed" }),
    });
    assert.equal(code, 1);
    assert.equal(existsSync(paths.unitPath), true);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("rendered unit is accepted by systemd-analyze when available", (t) => {
  if (spawnSync("systemd-analyze", ["--version"], { encoding: "utf8" }).status !== 0) {
    t.skip("systemd-analyze unavailable");
    return;
  }
  const base = tempHome("paseo sender verify ");
  try {
    const unitPath = join(base, "paseo-sender.service");
    writeFileSync(unitPath, renderUnit({
      nodePath: process.execPath,
      cliPath: join(dirname(new URL(import.meta.url).pathname), "..", "src", "cli.mjs"),
      stateDir: join(base, "state with spaces"),
      configPath: join(base, "config with spaces.json"),
    }));
    const result = spawnSync("systemd-analyze", ["verify", unitPath], { encoding: "utf8" });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  } finally { rmSync(base, { recursive: true, force: true }); }
});

test("secret-bearing config requires 0600 and status redacts values", async () => {
  const home = tempHome();
  try {
    const configPath = join(home, "config.json");
    writeFileSync(configPath, JSON.stringify({
      deliveryMode: "shadow",
      windowsToken: "super-secret",
      daemonPassword: "daemon-secret",
    }), { mode: 0o644 });
    if (process.platform !== "win32") {
      await assert.rejects(loadSenderConfig({ configPath }), /0600/u);
      chmodSync(configPath, 0o600);
    }
    const config = await loadSenderConfig({ configPath, overrides: { stateDir: join(home, "state") } });
    const status = publicConfigStatus(config);
    assert.equal(status.hasWindowsToken, true);
    assert.equal(status.hasDaemonPassword, true);
    assert.equal(JSON.stringify(status).includes("super-secret"), false);
    assert.equal(JSON.stringify(status).includes("daemon-secret"), false);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("daemon URL rejects credentials, unsafe protocol, and remote plaintext", () => {
  assert.equal(applyDaemonUrlPolicy("ws://127.0.0.1:8787").allowed, true);
  assert.equal(applyDaemonUrlPolicy("ws://user:pass@127.0.0.1:8787").allowed, false);
  assert.equal(applyDaemonUrlPolicy("http://127.0.0.1:8787").allowed, false);
  assert.equal(applyDaemonUrlPolicy("ws://example.com:8787").allowed, false);
});

test("root package gates explicitly execute child gate runner", () => {
  const packageRoot = join(dirname(new URL(import.meta.url).pathname), "..", "..", "..");
  const pkg = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
  assert.match(pkg.scripts.test, /run-paseo-sender-gate\.mjs test/u);
  assert.match(pkg.scripts.check, /run-paseo-sender-gate\.mjs check/u);
  const runner = readFileSync(join(packageRoot, "scripts", "run-paseo-sender-gate.mjs"), "utf8");
  assert.match(runner, /spawnSync/u);
  assert.match(runner, /shell: false/u);
});

test("cli dry-run and status stay offline", async () => {
  const home = tempHome();
  try {
    process.env.PASEO_SENDER_STATE_DIR = join(home, "state");
    assert.equal(await cliMain(["dry-run"]), 0);
    assert.equal(await cliMain(["status"]), 0);
  } finally {
    delete process.env.PASEO_SENDER_STATE_DIR;
    rmSync(home, { recursive: true, force: true });
  }
});
