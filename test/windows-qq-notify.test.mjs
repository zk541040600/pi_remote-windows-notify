import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const read = (relative) => readFileSync(new URL(`../${relative}`, import.meta.url), "utf8");

const common = read("windows/NotifyBridge.Common.ps1");
const listener = read("windows/notify-listener.ps1");
const worker = read("windows/pi-notify-qq-sender.ps1");
const fakeIntegration = read("windows/test-qq-notify.ps1");
const windowsReadme = read("windows/README.md");

const runtimeConsumers = [
  "windows/install-remote-windows-notify.ps1",
  "windows/install-windows-autostart.ps1",
  "windows/pi-notify-refresh.ps1",
  "windows/pi-notify-restart-listener.ps1",
];

test("QQ bridge config stays flat, bounded, non-sensitive, and disabled by default", () => {
  for (const field of [
    "qqNotifyEnabled",
    "qqNodeExecutable",
    "qqSenderScript",
    "qqSendTimeoutSeconds",
    "qqMaxConcurrent",
  ]) {
    assert.match(common, new RegExp(`\\b${field}\\b`));
  }
  assert.match(common, /finalQqNotifyEnabled[\s\S]*?else \{\s*\$false\s*\}/);
  assert.match(common, /finalQqSendTimeoutSeconds[\s\S]*?\[Math\]::Min\(120/);
  assert.match(common, /finalQqMaxConcurrent[\s\S]*?\[Math\]::Min\(8/);
  assert.match(common, /foreach \(\$key in \$existing\.Keys\)[\s\S]*?if \(-not \$config\.ContainsKey\(\$key\)\)/);
  assert.doesNotMatch(common, /qq(?:Account|Openid|Token|Secret|Recipient|Receiver)/i);
});

test("listener dispatches QQ exactly once after target, dedupe, and desktop gates", () => {
  const noTarget = listener.lastIndexOf("-Body 'no-target'");
  const dedup = listener.lastIndexOf("-Body 'dedup'");
  const desktop = listener.lastIndexOf("Show-Toast -Title $title");
  const dispatch = listener.lastIndexOf("Start-NotifyQqDispatch -Title $title -Body $body");
  const ok = listener.lastIndexOf("-Body 'ok'");
  assert.ok(noTarget >= 0 && noTarget < dedup);
  assert.ok(dedup < desktop && desktop < dispatch && dispatch < ok);
  assert.equal(
    (listener.match(/^\s*Start-NotifyQqDispatch -Title \$title -Body \$body\s*$/gm) ?? []).length,
    1,
  );
  assert.match(listener, /qq-pending/);
  assert.match(listener, /Guid\]::NewGuid\(\)\.ToString\('N'\)/);
  assert.match(listener, /UTF8Encoding\]::new\(\$false\)/);
  assert.match(listener, /qq-send-drop reason=capacity/);
  assert.match(listener, /NotifyQqWorkers\.Count -ge \$script:NotifyQqMaxConcurrent/);
  assert.match(listener, /SetAccessRuleProtection\(\$true, \$false\)/);
  assert.doesNotMatch(listener, /Write-NotifyListenerLog[^\r\n]*(?:\$Title|\$Body|\$qqText|\$textFile)/);
});

test("QQ worker is one-shot, bounded, redacted, and always cleans its text file", () => {
  assert.equal((worker.match(/\[System\.Diagnostics\.Process\]::Start/g) ?? []).length, 1);
  assert.match(worker, /'--text-file', \$TextFile/);
  assert.match(worker, /WaitForExit\(\$timeoutSeconds \* 1000\)/);
  assert.match(worker, /if \(-not \$process\.WaitForExit[\s\S]*?\$process\.Kill\(\)/);
  assert.match(worker, /RedirectStandardOutput = \$true/);
  assert.match(worker, /RedirectStandardError = \$true/);
  assert.match(worker, /qq-send-ok/);
  assert.match(worker, /qq-send-failed exitCode=/);
  assert.match(worker, /qq-send-timeout/);
  assert.match(worker, /qq-send-unavailable reason=/);
  assert.match(worker, /finally \{[\s\S]*?Remove-Item -LiteralPath \$TextFile/);
  assert.doesNotMatch(worker, /\b(?:retry|Start-Sleep)\b/i);
  assert.doesNotMatch(worker, /Write-NotifyQqSenderLog[^\r\n]*(?:stdout|stderr|senderScript|TextFile)/i);
  assert.doesNotMatch(worker, /\b(?:account|openid|recipient|receiver|clientSecret)\b/i);
});

test("all Windows runtime sync paths, checks, and docs include the QQ worker contract", () => {
  for (const relative of runtimeConsumers) {
    assert.match(read(relative), /['"]pi-notify-qq-sender\.ps1['"]/, relative);
  }
  assert.match(read("windows/pi-notify-check.ps1"), /pi-notify-qq-sender\.ps1/);
  assert.match(read("scripts/check-package.mjs"), /pi-notify-qq-sender\\\.ps1/);
  assert.match(windowsReadme, /qqNotifyEnabled`? \(default `false`\)/);
  assert.match(windowsReadme, /--dry-run/);
  assert.match(windowsReadme, /qq-sender\.log/);
  assert.doesNotMatch(windowsReadme, /qq(?:Account|Openid|Token|Secret|Recipient|Receiver)/i);
});

test("fake integration crosses HTTP listener to real worker without the real QQ sender", () => {
  assert.match(fakeIntegration, /Start-NotifyQqTestListener/);
  assert.match(fakeIntegration, /Invoke-NotifyQqTestRequest/);
  assert.match(fakeIntegration, /pi-notify-qq-sender\.ps1/);
  assert.match(fakeIntegration, /fake-qq-sender\.mjs/);
  assert.match(fakeIntegration, /notificationKind = 'ask-user'/);
  assert.match(fakeIntegration, /notificationKind = 'turn-complete'/);
  assert.match(fakeIntegration, /originKind = 'pi-web'/);
  assert.match(fakeIntegration, /qq-send-drop reason=capacity/);
  assert.match(fakeIntegration, /qq-send-unavailable reason=sender/);
  assert.match(fakeIntegration, /qq-send-timeout/);
  assert.match(fakeIntegration, /RAW-PRIVATE-DIAGNOSTIC/);
  assert.doesNotMatch(fakeIntegration, /send-qq-message\.mjs/);
});

test(
  "Windows fake QQ integration passes",
  { skip: process.platform !== "win32" },
  () => {
    const result = spawnSync(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", fileURLToPath(new URL("../windows/test-qq-notify.ps1", import.meta.url))],
      { encoding: "utf8", timeout: 120_000 },
    );
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /QQ notify fake integration passed/);
  },
);
