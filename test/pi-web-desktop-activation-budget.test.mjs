import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const windowsRoot = new URL("../windows/", import.meta.url);
const popupActivationEntryPoints = ["pi-notify-broker.ps1", "pi-notify-popup.ps1"];

test("Pi Web popup clicks use short reconnect and bounded background-proof budgets", () => {
  for (const name of popupActivationEntryPoints) {
    const source = readFileSync(new URL(name, windowsRoot), "utf8");
    assert.match(source, /ActivationRecoveryWaitMs = 10000/);
    assert.match(
      source,
      /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs \$ActivationRecoveryWaitMs -ActivateWaitMs 45000 -ActivateTimeoutMs 48000/,
      `${name} must bound reconnect while leaving enough time for background proof`,
    );
    assert.doesNotMatch(
      source,
      /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs 125000/,
      `${name} must not make a user wait for the passive 125-second recovery budget`,
    );
  }
});

test("non-popup activation retains the long recovery budget", () => {
  const source = readFileSync(
    new URL("pi-notify-activate.ps1", windowsRoot),
    "utf8",
  );
  assert.match(
    source,
    /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs 125000 -ActivateWaitMs 45000 -ActivateTimeoutMs 48000/,
  );
});
