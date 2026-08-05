import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const windowsRoot = new URL("../windows/", import.meta.url);
const activationEntryPoints = [
  "pi-notify-broker.ps1",
  "pi-notify-popup.ps1",
  "pi-notify-activate.ps1",
];

test("Pi Web popup activation allows bounded fresh-document proof", () => {
  for (const name of activationEntryPoints) {
    const source = readFileSync(new URL(name, windowsRoot), "utf8");
    assert.match(
      source,
      /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs 125000 -ActivateWaitMs 15000 -ActivateTimeoutMs 18000/,
      `${name} must preserve both reconnect and fresh-document proof budgets`,
    );
    assert.doesNotMatch(
      source,
      /Invoke-NotifyExactRouteActivate[^\r\n]*-WaitMs 5000 -TimeoutMs 8000/,
      `${name} still has the too-short legacy budget`,
    );
  }
});
