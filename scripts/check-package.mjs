#!/usr/bin/env node

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const linuxSourcePath = join(root, "linux", "extensions", "remote-windows-notify.ts");
const windowsSourcePath = join(root, "windows", "remote-windows-notify.ts");
const ensurePath = join(root, "windows", "pi-notify-ensure.mjs");

function read(relative) {
  return readFileSync(join(root, relative), "utf8");
}

function checkNodeSyntax(path, transformTypes = false) {
  const arguments_ = transformTypes
    ? ["--experimental-transform-types", "--check", path]
    : ["--check", path];
  const result = spawnSync(process.execPath, arguments_, { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout || `syntax check failed: ${path}`);
}

function requirePattern(source, pattern, message) {
  if (!pattern.test(source)) {
    throw new Error(message);
  }
}

function forbidPattern(source, pattern, message) {
  if (pattern.test(source)) {
    throw new Error(message);
  }
}

const packageJson = JSON.parse(read("package.json"));
assert.deepEqual(
  packageJson.pi?.extensions,
  ["./linux/extensions/remote-windows-notify.ts"],
  "package manifest must expose exactly one canonical Pi entry",
);
assert.equal(
  readFileSync(linuxSourcePath).equals(readFileSync(windowsSourcePath)),
  true,
  "Linux package entry and Windows distribution template must be byte-identical",
);
checkNodeSyntax(linuxSourcePath, true);
checkNodeSyntax(windowsSourcePath, true);
checkNodeSyntax(ensurePath);

const runtimeConsumers = [
  "windows/install-remote-windows-notify.ps1",
  "windows/install-windows-autostart.ps1",
  "windows/pi-notify-refresh.ps1",
  "windows/pi-notify-restart-listener.ps1",
];
for (const relative of runtimeConsumers) {
  requirePattern(read(relative), /['"]pi-notify-ensure\.mjs['"]/, `${relative} must distribute pi-notify-ensure.mjs`);
  requirePattern(read(relative), /['"]pi-notify-qq-sender\.ps1['"]/, `${relative} must distribute pi-notify-qq-sender.ps1`);
}

const linuxAutostart = read("windows/install-linux-autostart.ps1");
requirePattern(linuxAutostart, /pi-notify-ensure\.mjs/, "Linux autostart must call pi-notify-ensure.mjs");
forbidPattern(
  linuxAutostart,
  /install -m 0644 "\$managed_dir\/remote-windows-notify\.ts" "\$pi_dir\/extensions\/remote-windows-notify\.ts"/,
  "autostart must not recreate a duplicate global entry when package mode is active",
);

const remoteInstall = read("windows/install-remote-windows-notify.ps1");
requirePattern(remoteInstall, /--pi-dir/, "remote installer must pass the selected Pi directory to the ensure owner");
forbidPattern(
  remoteInstall,
  /-RemotePath \$remoteExtensionPath/,
  "remote installer must delegate active-entry ownership to pi-notify-ensure.mjs",
);

const windowsCheck = read("windows/pi-notify-check.ps1");
requirePattern(windowsCheck, /pi-notify-ensure\.mjs["']?\s+--check/, "Windows check must invoke read-only ownership verification");
requirePattern(windowsCheck, /__piRemoteWindowsNotifyActiveToken/, "Windows check must require the active-token lifecycle marker");
requirePattern(windowsCheck, /pi-notify-qq-sender\.ps1/, "Windows check must cover the QQ worker runtime file");

const common = read("windows/NotifyBridge.Common.ps1");
for (const field of ["qqNotifyEnabled", "qqNodeExecutable", "qqSenderScript", "qqSendTimeoutSeconds", "qqMaxConcurrent"]) {
  requirePattern(common, new RegExp(`\\b${field}\\b`), `NotifyBridge config must include ${field}`);
}
requirePattern(common, /finalQqNotifyEnabled[\s\S]*?else \{\s*\$false\s*\}/, "QQ notifications must default to disabled");
forbidPattern(common, /qq(?:Account|Openid|Token|Secret|Recipient|Receiver)/i, "NotifyBridge config must not own QQ identity or credentials");

const listener = read("windows/notify-listener.ps1");
const noTargetIndex = listener.lastIndexOf("-Body 'no-target'");
const dedupIndex = listener.lastIndexOf("-Body 'dedup'");
const desktopIndex = listener.lastIndexOf("Show-Toast -Title $title");
const qqIndex = listener.lastIndexOf("Start-NotifyQqDispatch -Title $title -Body $body");
const okIndex = listener.lastIndexOf("-Body 'ok'");
assert.ok(noTargetIndex >= 0 && noTargetIndex < dedupIndex && dedupIndex < desktopIndex && desktopIndex < qqIndex && qqIndex < okIndex, "QQ dispatch must occur once after target/dedupe/desktop gates and before the unchanged ok response");
assert.equal((listener.match(/^\s*Start-NotifyQqDispatch -Title \$title -Body \$body\s*$/gm) ?? []).length, 1, "the accepted listener path must start exactly one QQ worker");
requirePattern(listener, /qq-send-drop reason=capacity/, "listener must enforce a QQ worker concurrency limit");
requirePattern(listener, /SetAccessRuleProtection\(\$true, \$false\)/, "listener must protect its QQ pending directory");

const windowsReadme = read("windows/README.md");
requirePattern(windowsReadme, /qqNotifyEnabled`? \(default `false`\)/, "Windows README must document QQ as default-disabled");
requirePattern(windowsReadme, /--dry-run/, "Windows README must require dry-run or fake-sender validation before real QQ sends");
requirePattern(windowsReadme, /qq-sender\.log/, "Windows README must document redacted QQ sender log evidence");
forbidPattern(windowsReadme, /qq(?:Account|Openid|Token|Secret|Recipient|Receiver)/i, "Windows README must not document QQ identity or credentials as bridge-owned config");

const qqWorker = read("windows/pi-notify-qq-sender.ps1");
requirePattern(qqWorker, /WaitForExit\(\$timeoutSeconds \* 1000\)/, "QQ worker must bound the Node process timeout");
requirePattern(qqWorker, /\$process\.Kill\(\)/, "QQ worker must terminate Node on timeout");
requirePattern(qqWorker, /RedirectStandardOutput = \$true[\s\S]*RedirectStandardError = \$true/, "QQ worker must capture and discard sender output");
requirePattern(qqWorker, /finally \{[\s\S]*Remove-Item -LiteralPath \$TextFile/, "QQ worker must always clean its message file");
forbidPattern(qqWorker, /\b(?:retry|Start-Sleep)\b/i, "QQ worker must not retry");
forbidPattern(qqWorker, /Write-NotifyQqSenderLog[^\r\n]*(?:stdout|stderr|senderScript|TextFile)/i, "QQ worker logs must not expose sender output, paths, or message files");

const broker = read("windows/pi-notify-broker.ps1");
forbidPattern(broker, /\bAdd-Content\b/, "broker logging must not use PowerShell Add-Content");
assert.ok((broker.match(/Monitor\]::Enter/g) ?? []).length >= 2, "both broker runspaces need shared Monitor locking");
assert.ok((broker.match(/Monitor\]::Exit/g) ?? []).length >= 2, "both broker runspaces must release the shared lock");
assert.ok((broker.match(/File\]::AppendAllText/g) ?? []).length >= 2, "both broker runspaces need short-lived appends");
requirePattern(broker, /AddParameter\('LogLock'/, "the background runspace must receive the shared log lock");

for (const name of readdirSync(join(root, "windows"))) {
  if (!name.endsWith(".ps1")) {
    continue;
  }
  const source = read(`windows/${name}`);
  forbidPattern(source, /[^\x00-\x7f]/, `${name} must remain Windows PowerShell 5.1 ASCII source`);
  forbidPattern(source, /foreach\s*\(\s*\$pid\b/i, `${name} must not shadow PowerShell's automatic PID variable`);
}

console.log("pi-remote-windows-notify package check passed");
