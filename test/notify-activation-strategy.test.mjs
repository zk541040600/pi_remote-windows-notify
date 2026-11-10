import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const windowsRoot = new URL("../windows/", import.meta.url);

function readWindows(name) {
  return readFileSync(new URL(name, windowsRoot), "utf8");
}

// Pure ports of terminal-route selection/post-check for offline contract coverage.
function testAuthorityMatch({ tabName = "", windowTitle = "", tabTitle = "", cwdBase = "" } = {}) {
  const tab = String(tabName || "").trim();
  const window = String(windowTitle || "").trim();
  const requiredTitle = String(tabTitle || "").trim();
  const requiredCwd = String(cwdBase || "").trim();

  if (requiredTitle) {
    if (!tab) return false;
    if (tab.toLowerCase().indexOf(requiredTitle.toLowerCase()) < 0) return false;
    if (requiredCwd) {
      const haystack = [tab, window].filter(Boolean);
      if (!haystack.some((value) => value.toLowerCase().includes(requiredCwd.toLowerCase()))) {
        return false;
      }
    }
    return true;
  }

  if (!requiredCwd) return false;
  return [tab, window].filter(Boolean).some((value) => value.toLowerCase().includes(requiredCwd.toLowerCase()));
}

function selectTerminalCandidates({ tabTitle = "", cwdBase = "", windows = [], cachedCandidate = null } = {}) {
  const requiredTitle = String(tabTitle || "").trim();
  const requiredCwd = String(cwdBase || "").trim();
  if (!requiredTitle && !requiredCwd) {
    return { result: "missing-target-metadata", retryable: false, candidates: [], selected: null };
  }

  const candidates = [];
  for (const window of windows) {
    const processName = String(window.processName || "");
    if (!/WindowsTerminal|Terminal/.test(processName)) continue;
    for (const tab of window.tabs || []) {
      if (
        !testAuthorityMatch({
          tabName: tab.name,
          windowTitle: window.title,
          tabTitle: requiredTitle,
          cwdBase: requiredCwd,
        })
      ) {
        continue;
      }
      candidates.push({
        windowHandle: window.handle,
        windowTitle: window.title,
        tabName: tab.name,
        tabIndex: tab.index ?? -1,
      });
    }
  }

  if (candidates.length === 0) {
    return { result: "target-missing", retryable: true, candidates, selected: null };
  }
  if (candidates.length > 1) {
    return { result: "ambiguous", retryable: true, candidates, selected: null };
  }

  const selected = candidates[0];
  if (cachedCandidate) {
    // Cache may only reaffirm the unique candidate; it cannot hide a second match.
    void cachedCandidate;
  }
  return { result: "unique", retryable: false, candidates, selected };
}

function testActivationProof({
  tabTitle = "",
  cwdBase = "",
  targetHandle = null,
  foregroundHandle = null,
  selectedTabs = [],
} = {}) {
  if (targetHandle == null || targetHandle === 0) {
    return { ok: false, result: "foreground-proof-failed", reason: "missing-target-handle" };
  }
  if (foregroundHandle == null || foregroundHandle === 0 || foregroundHandle !== targetHandle) {
    return { ok: false, result: "foreground-proof-failed", reason: "foreground-mismatch" };
  }
  if (selectedTabs.length === 0) {
    return { ok: false, result: "selected-tab-proof-failed", reason: "no-selected-tab" };
  }
  if (selectedTabs.length > 1) {
    return { ok: false, result: "selected-tab-proof-failed", reason: "multiple-selected-tabs" };
  }
  const tab = selectedTabs[0];
  if (
    !testAuthorityMatch({
      tabName: tab.name,
      windowTitle: tab.windowTitle || "",
      tabTitle,
      cwdBase,
    })
  ) {
    return { ok: false, result: "selected-tab-proof-failed", reason: "selected-tab-mismatch" };
  }
  return { ok: true, result: "activated", reason: "" };
}

function normalizeOrigin(originKind) {
  if (originKind == null || String(originKind).trim() === "") {
    return { ok: true, originKind: "terminal" };
  }
  const kind = String(originKind).trim();
  if (kind === "terminal" || kind === "paseo" || kind === "pi-web") {
    return { ok: true, originKind: kind };
  }
  return { ok: false, originKind: "" };
}

function mapUiOutcome(outcome, hasDeferredActivateIntent = false) {
  const decision = String(outcome?.Decision || "");
  if (!["ready", "handled", "focused", "fail-closed"].includes(decision)) {
    return { action: "show-unavailable", claimFinalActivation: false };
  }
  if (decision === "ready") {
    return {
      action: "store-ready",
      startActivate: Boolean(hasDeferredActivateIntent),
      claimFinalActivation: false,
    };
  }
  if (decision === "handled") {
    return { action: "close-handled", claimFinalActivation: true };
  }
  if (decision === "focused") {
    // Focused/pending is NON-terminal: the card must stay open in bounded
    // pending feedback; only a final result (or the original deadline) closes it.
    return { action: "keep-focused", claimFinalActivation: false };
  }
  if (outcome?.Retryable) {
    return { action: "restore-retryable", claimFinalActivation: false };
  }
  return { action: "show-unavailable", claimFinalActivation: false };
}

test("origin normalization accepts blank/terminal/paseo/pi-web and rejects unknown", () => {
  assert.deepEqual(normalizeOrigin(""), { ok: true, originKind: "terminal" });
  assert.deepEqual(normalizeOrigin("   "), { ok: true, originKind: "terminal" });
  assert.deepEqual(normalizeOrigin("terminal"), { ok: true, originKind: "terminal" });
  assert.deepEqual(normalizeOrigin("paseo"), { ok: true, originKind: "paseo" });
  assert.deepEqual(normalizeOrigin("pi-web"), { ok: true, originKind: "pi-web" });
  assert.equal(normalizeOrigin("pi-web-desktop").ok, false);
  assert.equal(normalizeOrigin("chrome").ok, false);
  assert.equal(normalizeOrigin("Paseo").ok, false);

  const activation = readWindows("NotifyBridge.Activation.ps1");
  assert.match(activation, /function Normalize-NotifyActivationOriginKind/);
  assert.match(activation, /unsupported-origin/);
  assert.match(activation, /isUnsupportedOrigin/);
  assert.match(activation, /Result\.Result -eq 'unsupported-origin'/);
  assert.match(activation, /elseif \(-not \[string\]::IsNullOrWhiteSpace\(\$OriginKind\)\) \{\s*''/);
  assert.match(activation, /legacy-blank-origin|IsNullOrWhiteSpace\(\$OriginKind\)/);
  assert.doesNotMatch(activation, /originKind\s*=\s*'pi-web-desktop'/);
});

test("UI lifecycle mapping keeps focused pending non-terminal", () => {
  assert.equal(mapUiOutcome({ Decision: "ready", Result: "ready" }, false).action, "store-ready");
  assert.equal(mapUiOutcome({ Decision: "ready", Result: "ready" }, true).startActivate, true);
  assert.equal(mapUiOutcome({ Decision: "handled", Result: "activated", ProofState: "final" }).action, "close-handled");
  assert.equal(mapUiOutcome({ Decision: "handled", Result: "activated", ProofState: "final" }).claimFinalActivation, true);
  assert.equal(
    mapUiOutcome({ Decision: "focused", Result: "pending", ProofState: "pending" }).action,
    "keep-focused",
  );
  assert.equal(
    mapUiOutcome({ Decision: "focused", Result: "pending", ProofState: "pending" }).claimFinalActivation,
    false,
  );
  assert.equal(
    mapUiOutcome({ Decision: "fail-closed", Result: "target-missing", Retryable: true }).action,
    "restore-retryable",
  );
  assert.equal(
    mapUiOutcome({ Decision: "fail-closed", Result: "expired", Retryable: false }).action,
    "show-unavailable",
  );

  const activation = readWindows("NotifyBridge.Activation.ps1");
  assert.match(activation, /function ConvertTo-NotifyActivationUiOutcome/);
  assert.match(activation, /store-ready|close-handled|keep-focused|restore-retryable|show-unavailable/);
  assert.doesNotMatch(activation, /close-focused/, "focused must never map to a close action");
  assert.match(activation, /ClaimFinalActivation/);
});

test("WT pure candidate selection covers unique/miss/ambiguous/title authority/cwd legacy/cache", () => {
  const titleA = "π - work · #aaaaaaaaaaaa";
  const titleB = "π - work · #bbbbbbbbbbbb";

  const unique = selectTerminalCandidates({
    tabTitle: titleA,
    cwdBase: "work",
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [
          { name: titleA, index: 0 },
          { name: titleB, index: 1 },
        ],
      },
    ],
  });
  assert.equal(unique.result, "unique");
  assert.equal(unique.selected.tabName, titleA);

  const sameCwdDifferentHash = selectTerminalCandidates({
    tabTitle: titleA,
    cwdBase: "work",
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [
          { name: titleA, index: 0 },
          { name: titleB, index: 1 },
        ],
      },
    ],
  });
  assert.equal(sameCwdDifferentHash.candidates.length, 1);

  const missing = selectTerminalCandidates({
    tabTitle: titleA,
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [{ name: titleB, index: 0 }],
      },
    ],
  });
  assert.equal(missing.result, "target-missing");

  const ambiguous = selectTerminalCandidates({
    tabTitle: titleA,
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [
          { name: titleA, index: 0 },
          { name: `prefix ${titleA}`, index: 1 },
        ],
      },
    ],
  });
  assert.equal(ambiguous.result, "ambiguous");

  const titleBlocksCwdFallback = selectTerminalCandidates({
    tabTitle: titleA,
    cwdBase: "work",
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [{ name: "π - work · #cccccccccccc", index: 0 }],
      },
    ],
  });
  assert.equal(titleBlocksCwdFallback.result, "target-missing");

  const cwdOnly = selectTerminalCandidates({
    cwdBase: "work",
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [{ name: "π - work · #dddddddddddd", index: 0 }],
      },
    ],
  });
  assert.equal(cwdOnly.result, "unique");

  const cacheCannotHideDuplicate = selectTerminalCandidates({
    tabTitle: titleA,
    windows: [
      {
        handle: 1,
        title: "Windows Terminal",
        processName: "WindowsTerminal",
        tabs: [
          { name: titleA, index: 0 },
          { name: titleA, index: 1 },
        ],
      },
    ],
    cachedCandidate: { windowHandle: 1, tabName: titleA },
  });
  assert.equal(cacheCannotHideDuplicate.result, "ambiguous");

  const terminalRoute = readWindows("terminal-route.ps1");
  assert.match(terminalRoute, /function Select-NotifyTerminalCandidates/);
  assert.match(terminalRoute, /missing-target-metadata/);
  assert.match(terminalRoute, /target-missing/);
  assert.match(terminalRoute, /ambiguous/);
  assert.match(terminalRoute, /CachedCandidate/);
});

test("WT post-check requires foreground HWND and exact selected tab", () => {
  const title = "π - work · #aaaaaaaaaaaa";
  assert.equal(
    testActivationProof({
      tabTitle: title,
      targetHandle: 11,
      foregroundHandle: 22,
      selectedTabs: [{ name: title }],
    }).result,
    "foreground-proof-failed",
  );
  assert.equal(
    testActivationProof({
      tabTitle: title,
      targetHandle: 11,
      foregroundHandle: 11,
      selectedTabs: [],
    }).result,
    "selected-tab-proof-failed",
  );
  assert.equal(
    testActivationProof({
      tabTitle: title,
      targetHandle: 11,
      foregroundHandle: 11,
      selectedTabs: [{ name: title }, { name: title }],
    }).result,
    "selected-tab-proof-failed",
  );
  assert.equal(
    testActivationProof({
      tabTitle: title,
      targetHandle: 11,
      foregroundHandle: 11,
      selectedTabs: [{ name: "π - work · #bbbbbbbbbbbb" }],
    }).result,
    "selected-tab-proof-failed",
  );
  assert.equal(
    testActivationProof({
      tabTitle: title,
      targetHandle: 11,
      foregroundHandle: 11,
      selectedTabs: [{ name: title }],
    }).ok,
    true,
  );

  const terminalRoute = readWindows("terminal-route.ps1");
  assert.match(terminalRoute, /function Test-NotifyTerminalActivationProof/);
  assert.match(terminalRoute, /foreground-proof-failed/);
  assert.match(terminalRoute, /selected-tab-proof-failed/);
  assert.match(terminalRoute, /GetForegroundWindow\(\)/);
});

test("all click entry points use the coordinator and never fall through across origins", () => {
  const broker = readWindows("pi-notify-broker.ps1");
  const popup = readWindows("pi-notify-popup.ps1");
  const activate = readWindows("pi-notify-activate.ps1");
  const activation = readWindows("NotifyBridge.Activation.ps1");

  for (const source of [broker, popup, activate]) {
    assert.match(source, /terminal-route\.ps1/);
    assert.match(source, /NotifyBridge\.Activation\.ps1/);
  }

  assert.match(broker, /Get-NotifyActivationWorkerScript|Invoke-NotifyActivationStrategy/);
  assert.match(popup, /Get-NotifyActivationWorkerScript|Invoke-NotifyActivationStrategy/);
  assert.match(activate, /Invoke-NotifyActivationStrategy/);
  assert.match(activation, /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs \$ActivationRecoveryWaitMs/);
  assert.match(activation, /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-ActivateWaitMs 45000 -ActivateTimeoutMs 48000/);
  assert.match(activation, /Wait-NotifyExactRouteRecovery[^\r\n]*-WaitMs 125000/);
  assert.doesNotMatch(activation, /Invoke-NotifyExactRouteRecoveryAndActivate[^\r\n]*-RecoveryWaitMs 125000/);

  assert.doesNotMatch(broker, /legacy-activation-complete/);
  assert.doesNotMatch(popup, /legacy-activation-queued/);
  assert.doesNotMatch(activate, /function Focus-NotifyWindow/);

  const piWebFail = activate.slice(activate.indexOf("if ($originKind -eq 'pi-web')"));
  assert.match(piWebFail, /activate-route-fail-closed[\s\S]*exit 1/);
  assert.doesNotMatch(piWebFail, /Invoke-NotifyTerminalRouteActivate/);

  assert.match(activation, /origin -eq 'paseo'/);
  assert.match(activation, /origin -eq 'pi-web'/);
  assert.match(activation, /Invoke-NotifyTerminalActivationStrategy|Invoke-NotifyTerminalRouteActivate/);
});

test("runtime inventories and offline check include both new modules", () => {
  for (const name of [
    "install-remote-windows-notify.ps1",
    "install-windows-autostart.ps1",
    "pi-notify-refresh.ps1",
    "pi-notify-restart-listener.ps1",
  ]) {
    const source = readWindows(name);
    assert.match(source, /terminal-route\.ps1/, `${name} must copy terminal-route.ps1`);
    assert.match(source, /NotifyBridge\.Activation\.ps1/, `${name} must copy NotifyBridge.Activation.ps1`);
  }

  const check = readWindows("pi-notify-check.ps1");
  assert.match(check, /terminal-route\.ps1/);
  assert.match(check, /NotifyBridge\.Activation\.ps1/);
  assert.match(check, /Invoke-NotifyActivationStrategy/);
  assert.match(check, /legacy-activation-complete|legacy-activation-queued/);
});

test("offline self-check follows shared activation ownership", () => {
  const check = readWindows("pi-notify-check.ps1");

  assert.match(check, /\$terminalRouteText -notmatch 'Cache cannot skip full uniqueness enumeration'/);
  assert.match(check, /Shared Terminal route must require the full title/);
  assert.match(check, /function Invoke-NotifyPaseoActivationStrategy/);
  assert.match(check, /Activate script must resolve nonce-only toast state and delegate/);
  assert.doesNotMatch(
    check,
    /broker-focus-ambiguous|popup-focus-ambiguous|broker-paseo-retry-ready|popup-paseo-retry-ready|paseoOutcome\.Result|Get-NotifyActivateFingerprint/,
  );
});

test("real Pi Web runtime config is derived from the Desktop route authority", () => {
  const common = readWindows("NotifyBridge.Common.ps1");
  const installer = readWindows("install-remote-windows-notify.ps1");
  const check = readWindows("pi-notify-check.ps1");

  assert.match(common, /function Resolve-NotifyBridgePiWebInstanceKey/);
  assert.match(common, /function New-NotifyBridgeRemoteConfig/);
  assert.match(
    installer,
    /Resolve-NotifyBridgePiWebInstanceKey[\s\S]*New-NotifyBridgeRemoteConfig/,
  );
  assert.match(installer, /-PiWebInstanceKey \$resolvedPiWebInstanceKey/);
  assert.doesNotMatch(installer, /\$remoteConfig\s*=\s*@\{/);
  assert.match(check, /expectedPiWebInstanceKey/);
  assert.match(check, /OK pi web route enabled=/);
  assert.match(check, /remoteRouteSuccess/);
});

test("immutable popup expiry is absolute and retry timers use only remaining lifetime", () => {
  const activation = readWindows("NotifyBridge.Activation.ps1");
  const broker = readWindows("pi-notify-broker.ps1");
  const popup = readWindows("pi-notify-popup.ps1");

  assert.match(activation, /function Get-NotifyActivationRemainingMs/);
  assert.match(activation, /ExpiresAtUtc\.ToUniversalTime\(\) - \$NowUtc\.ToUniversalTime\(\)/);

  assert.match(broker, /ExpiresAtUtc\s*=\s*\$popupExpiresAtUtc/);
  assert.match(broker, /Get-NotifyActivationRemainingMs -ExpiresAtUtc \(\[DateTime\]\$Tag\.ExpiresAtUtc\)/);
  assert.match(broker, /\$Tag\.Timer\.Interval = \$remainingMs/);
  assert.match(broker, /broker-popup-expired[\s\S]*ignoredOutcome/);
  assert.doesNotMatch(broker, /restore clickable retry UI[\s\S]{0,500}\$Tag\.Timer\.Interval\s*=\s*\$popupLifetimeMs/);

  assert.match(popup, /NotifyPopupExpiresAtUtc\s*=\s*\[DateTime\]::UtcNow\.AddMilliseconds\(\$popupLifetimeMs\)/);
  assert.match(popup, /Get-NotifyActivationRemainingMs -ExpiresAtUtc \$script:NotifyPopupExpiresAtUtc/);
  assert.match(popup, /\$script:NotifyPopupTimer\.Interval = \$remainingMs/);
  assert.match(popup, /popup-expired ignoredOutcome/);
  assert.doesNotMatch(popup, /popup-retry-ready[\s\S]{0,300}NotifyPopupTimer\.Interval\s*=\s*\$popupLifetimeMs/);
});

test("worker output cardinality and every synthetic fallback use the complete outcome contract", () => {
  const activation = readWindows("NotifyBridge.Activation.ps1");
  const broker = readWindows("pi-notify-broker.ps1");
  const popup = readWindows("pi-notify-popup.ps1");
  const requiredFields = [
    "Version",
    "Operation",
    "OriginKind",
    "Decision",
    "Result",
    "Reason",
    "Retryable",
    "ProofState",
    "SnapshotId",
    "RecoveryTicketId",
    "ScrollAttempted",
    "ScrolledToBottom",
    "ElapsedMs",
  ];

  for (const field of requiredFields) {
    assert.match(activation, new RegExp(`['\"]?${field}['\"]?`), `shared worker contract must include ${field}`);
  }
  assert.match(activation, /function Resolve-NotifyActivationWorkerOutput/);
  assert.match(activation, /items\.Count -ne 1/);
  assert.match(activation, /worker-empty/);
  assert.match(activation, /worker-output-count/);
  assert.match(activation, /worker-malformed/);
  assert.match(activation, /worker-module-missing/);
  assert.match(activation, /worker-exception/);

  for (const source of [broker, popup]) {
    assert.match(source, /Resolve-NotifyActivationWorkerOutput -Rows \$rows/);
    assert.match(source, /New-NotifyActivationWorkerFailureOutcome[\s\S]{0,180}worker-(endinvoke-error|cancelled)/);
    assert.doesNotMatch(source, /\$rows\[-1\]/);
    assert.doesNotMatch(source, /\[pscustomobject\]@\{ Decision = 'fail-closed'; Result = 'adapter-unavailable'/);
  }
});

test("WT live route reacquires authority and final proof reads a fresh window title", () => {
  const terminalRoute = readWindows("terminal-route.ps1");
  assert.match(terminalRoute, /function Get-NotifyTerminalWindowTitle/);
  assert.match(terminalRoute, /Discovery objects are hints only[\s\S]*Get-NotifyTerminalWindowSnapshots/);
  assert.match(terminalRoute, /Reacquire the live element by authority/);
  assert.match(terminalRoute, /Test-NotifyTerminalAuthorityMatch -TabName \(\[string\]\$_\.Name\)/);
  assert.doesNotMatch(terminalRoute, /\(\[string\]\$_\.Name -eq \[string\]\$best\.TabName\) -or \(\[int\]\$_\.Index/);
  assert.match(
    terminalRoute,
    /do \{[\s\S]*GetForegroundWindow\(\)[\s\S]*Get-NotifyTerminalWindowTitle -Handle \$handle[\s\S]*Get-NotifyTerminalSelectedTabs -Handle \$handle -WindowTitle \$currentWindowTitle/,
  );
});

test("WT route owns best-effort scroll and all activation surfaces log its result", () => {
  const terminalRoute = readWindows("terminal-route.ps1");
  const activation = readWindows("NotifyBridge.Activation.ps1");
  const broker = readWindows("pi-notify-broker.ps1");
  const popup = readWindows("pi-notify-popup.ps1");
  const activate = readWindows("pi-notify-activate.ps1");

  assert.match(terminalRoute, /\$scrollAttempted\s*=\s*\$true/);
  assert.match(
    terminalRoute,
    /\$scrolledToBottom\s*=\s*\[bool\]\(Set-NotifyBridgeTerminalScrollToBottom/,
  );
  assert.match(activation, /ScrollAttempted/);
  assert.match(activation, /ScrolledToBottom/);
  for (const source of [broker, popup, activate]) {
    assert.match(source, /scrollAttempted=/);
    assert.match(source, /scrolledToBottom=/);
    assert.doesNotMatch(source, /Set-NotifyBridgeTerminalScrollToBottom/);
  }
});

test("safe Windows route suite directly invokes the real PowerShell pure contracts", () => {
  const routeTests = readWindows("test-route.ps1");
  assert.match(routeTests, /\. \(Join-Path \$scriptDir 'terminal-route\.ps1'\)/);
  assert.match(routeTests, /\. \(Join-Path \$scriptDir 'NotifyBridge\.Activation\.ps1'\)/);
  assert.match(routeTests, /Select-NotifyTerminalCandidates -TabTitle/);
  assert.match(routeTests, /Test-NotifyTerminalActivationProof -TabTitle/);
  assert.match(routeTests, /Resolve-NotifyActivationWorkerOutput -Rows/);
  assert.match(routeTests, /Get-NotifyActivationRemainingMs -ExpiresAtUtc/);
  assert.doesNotMatch(routeTests, /Invoke-NotifyTerminalRouteActivate/);
});

test("focused progress stays non-terminal and cannot be claimed as final activation success", () => {
  const activation = readWindows("NotifyBridge.Activation.ps1");
  assert.match(activation, /decisionName -eq 'focused'|\$decision -eq 'focused'/);
  assert.match(activation, /ProofState 'pending'|ProofState = 'pending'/);
  assert.match(activation, /Action\s+=\s+'keep-focused'/);
  assert.doesNotMatch(activation, /close-focused/);
  assert.match(activation, /ClaimFinalActivation = \$false/);

  const mapper = mapUiOutcome({ Decision: "focused", Result: "pending", ProofState: "pending" });
  assert.equal(mapper.action, "keep-focused");
  assert.equal(mapper.claimFinalActivation, false);
});
