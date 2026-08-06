import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createHash } from "node:crypto";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixturePath = join(root, "test/fixtures/windows-paseo-v1-contract.json");
const senderFixturePath = join(root, "linux/paseo-sender/fixtures/windows-paseo-v1-contract.json");

function read(rel) {
  return readFileSync(join(root, rel), "utf8");
}

test("shared Windows Paseo v1 contract fixtures are byte-identical", () => {
  assert.equal(existsSync(fixturePath), true);
  assert.equal(existsSync(senderFixturePath), true);
  const a = readFileSync(fixturePath);
  const b = readFileSync(senderFixturePath);
  assert.equal(a.equals(b), true);
});

test("Windows listener implements authenticated health and close contracts", () => {
  const listener = read("windows/notify-listener.ps1");
  const common = read("windows/NotifyBridge.Common.ps1");
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));

  assert.match(listener, /\/paseo\/health/);
  assert.match(listener, /\/paseo\/close/);
  assert.match(listener, /Get-NotifyPaseoHealthSnapshot/);
  assert.match(listener, /Invoke-NotifyPaseoCloseByNotificationId/);
  assert.match(common, /function Get-NotifyPaseoHealthSnapshot/);
  assert.match(common, /function Resolve-NotifyPaseoCloseRequest/);
  assert.match(common, /notifyV1\s*=\s*\$true/);
  assert.match(common, /closeV1\s*=\s*\$true/);
  assert.match(common, /existingClickEventV1\s*=\s*\$true/);

  // Close allowed fields exactness
  for (const field of fixture.close.allowedFields) {
    assert.match(common, new RegExp(`'${field}'`));
  }

  // Must not treat unauthenticated GET /health as capability probe for sender
  assert.match(listener, /GET.*\/health[\s\S]*?\{\\"ok\\":true\}|path -eq '\/health'/);
});

test("sender package pins @getpaseo/client 0.3.0-beta.2 and does not import from Pi extension", () => {
  const pkg = JSON.parse(read("linux/paseo-sender/package.json"));
  assert.equal(pkg.dependencies["@getpaseo/client"], "0.3.0-beta.2");
  assert.equal(existsSync(join(root, "linux/paseo-sender/package-lock.json")), true);
  const lock = JSON.parse(read("linux/paseo-sender/package-lock.json"));
  const client = lock.packages?.["node_modules/@getpaseo/client"];
  assert.equal(client?.version, "0.3.0-beta.2");

  const extension = read("linux/extensions/remote-windows-notify.ts");
  // Pi extension must not import the Paseo SDK (path name for health lease is OK).
  assert.equal(extension.includes("@getpaseo/client"), false);
  assert.equal(/from\s+["']@getpaseo\//.test(extension), false);
  assert.equal(/require\(["']@getpaseo\//.test(extension), false);
});

test("sender source has no provider notification branch and uses onAgentAttentionRequired", () => {
  const files = [
    "linux/paseo-sender/src/service.mjs",
    "linux/paseo-sender/src/normalize.mjs",
    "linux/paseo-sender/src/reconcile.mjs",
    "linux/paseo-sender/src/daemon.mjs",
  ];
  const src = files.map(read).join("\n");
  assert.match(src, /onAgentAttentionRequired/);
  assert.equal(/provider\s*===\s*['"]pi['"]/.test(src), false);
  assert.equal(/provider\s*===\s*['"]codex['"]/.test(src), false);
  assert.equal(/switch\s*\(\s*provider/.test(src), false);
});

test("install helpers default to dry-run and never mention crontab", () => {
  const install = read("linux/paseo-sender/scripts/install.mjs");
  const disable = read("linux/paseo-sender/scripts/disable.mjs");
  assert.match(install, /--apply/);
  assert.match(install, /enable-now/);
  assert.equal(/crontab/i.test(install), false);
  assert.equal(/crontab/i.test(disable), false);
});

test("Pi extension lease gate is opt-in and templates stay in sync", () => {
  const linux = readFileSync(join(root, "linux/extensions/remote-windows-notify.ts"));
  const windows = readFileSync(join(root, "windows/remote-windows-notify.ts"));
  assert.equal(
    createHash("sha256").update(linux).digest("hex"),
    createHash("sha256").update(windows).digest("hex"),
  );
  const text = linux.toString("utf8");
  // Gate symbols once implemented
  if (text.includes("paseoLeaseGateEnabled") || text.includes("PI_NOTIFY_PASEO_LEASE_GATE")) {
    assert.match(text, /PASEO_AGENT_ID/);
    assert.match(text, /PI_NOTIFY_ALLOW_PASEO/);
    assert.equal(/if\s*\(\s*process\.env\.PASEO_AGENT_ID[\s\S]{0,80}return;/.test(text), false);
  }
});
