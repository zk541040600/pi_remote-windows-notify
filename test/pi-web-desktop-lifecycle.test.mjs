import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const mainFormPath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/MainForm.cs",
  import.meta.url,
);
const singleInstancePath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/SingleInstanceCoordinator.cs",
  import.meta.url,
);
const appPathsPath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/AppPaths.cs",
  import.meta.url,
);
const rowActivationPath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/SessionRowActivationTransaction.cs",
  import.meta.url,
);
const routeAdapterPath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/RouteAdapter.cs",
  import.meta.url,
);
const routeProtocolPath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/RouteProtocol.cs",
  import.meta.url,
);
const liveActivationTestPath = new URL(
  "../windows/test-pi-web-dest-activation-live.ps1",
  import.meta.url,
);

test("PiWebDesktop awaits route cleanup before allowing the form to close", () => {
  const source = readFileSync(mainFormPath, "utf8");
  assert.match(source, /FormClosing\s*\+=\s*OnFormClosing/);

  const start = source.indexOf("private async void OnFormClosing");
  assert.ok(start >= 0, "missing asynchronous close handler");
  const end = source.indexOf("\n    private ", start + 1);
  const method = source.slice(start, end > start ? end : undefined);

  assert.match(method, /eventArgs\.Cancel\s*=\s*true/);
  assert.match(method, /await adapter\.DisposeAsync\(\)/);
  assert.match(method, /_routeShutdownComplete\s*=\s*true/);
  assert.doesNotMatch(method, /Task\.Run/);
});

test("PiWebDesktop secondary-launch pipe is Windows login-session local", () => {
  const source = readFileSync(singleInstancePath, "utf8");
  assert.match(
    source,
    /ActivationPipeName\s*=\s*@"LOCAL\\PiWebDesktop\.Activate"/,
  );
});

test("PiWebDesktop durable route outboxes are Windows login-session local", () => {
  const source = readFileSync(appPathsPath, "utf8");
  assert.match(source, /SessionRouteDataDirectory/);
  assert.match(
    source,
    /ActivationResultOutboxFilePath\s*=>\s*Path\.Combine\(\s*SessionRouteDataDirectory,/,
  );
  assert.match(
    source,
    /ExplicitOpenOutboxFilePath\s*=>\s*Path\.Combine\(\s*SessionRouteDataDirectory,/,
  );
});

test("PiWebDesktop notification routing reuses a verified live sidebar row", () => {
  const source = readFileSync(mainFormPath, "utf8");
  const transaction = readFileSync(rowActivationPath, "utf8");

  assert.match(source, /const verifiedRows=new Map\(\)/);
  assert.match(source, /const verifiedHistoryEntries=new Map\(\)/);
  assert.match(source, /const historyEntryOwners=new Map\(\)/);
  assert.match(source, /const rowMarker=Symbol\('pi-web-desktop-row'\)/);
  assert.match(source, /const sessionRowMarkers=new Map\(\)/);
  assert.match(source, /new WeakRef\(row\)/);
  assert.match(source, /if\(!event\.isTrusted\|\|event\.button!==0\)\{return;\}/);
  assert.match(source, /handledGestureSeq = _lastHandledSidebarGestureSequence/);
  assert.match(source, /data\.handledGestureSeq<lastCommittedUserGestureSeq/);
  assert.match(source, /pendingRowActivation=activation;try\{row\.click\(\)/);
  assert.match(source, /const supersededRowActivations=new Map\(\)/);
  assert.match(source, /rememberSupersededRowActivation\(pendingRowActivation\)/);
  assert.match(source, /rowRef:activation\.rowRef/);
  assert.match(source, /marker:activation\.marker/);
  assert.match(source, /entry\.rowRef&&entry\.rowRef\.deref\(\)===gesture\.row/);
  assert.match(source, /gesture\.row&&gesture\.row\[rowMarker\]===entry\.marker/);
  assert.match(source, /classifySupersededRowActivation\(targetSession,gesture\)/);
  assert.match(source, /if\(gesture&&!supersededHistory\)/);
  assert.match(source, /stageHistoryEntry\(targetSession,gesture\)/);
  assert.match(source, /confirmHistoryEntry\(proof\.sessionId,historyBinding\)/);
  assert.match(source, /navigationApi\.entries\(\)/);
  assert.match(source, /nativeTraverseTo\(historyRecord\.key/);
  assert.match(source, /info===activation\.navigationInfo/);
  assert.match(source, /beginProvisionalHistoryEntryRebind\(target,method\)/);
  assert.match(source, /finishProvisionalHistoryEntryRebind\(/);
  assert.match(source, /currentProvisionalHistoryEntry\(/);
  assert.match(source, /proof\.requestGestureSeq===lastCommittedUserGestureSeq/);
  assert.match(source, /proof\.requestGestureSeq===gestureSequence/);
  assert.match(source, /beginHistoryEntryRebind\(activation,target,method\)/);
  assert.match(source, /finishHistoryEntryRebind\(activation\)/);
  assert.match(source, /activation\.finished=true;emitDeferredHistoryApiProof/);
  assert.match(source, /traverse-correlation-timeout/);
  assert.match(source, /RowActivationHistoryBudgetMs/);
  assert.match(source, /reason = "current-source-is-target"/);
  assert.match(
    source,
    /activation\.navigateSeen[\s\S]*activation\.committed[\s\S]*activation\.entryEventSeen/,
  );
  assert.match(source, /pendingRowActivation===activation/);
  assert.match(source, /const rowLineageObserver=new MutationObserver/);
  assert.match(source, /const lineageFromMutationBatch=\(records\)=>/);
  assert.match(source, /removeRecord\.target!==addRecord\.target/);
  assert.match(
    source,
    /removeRecord\.previousSibling!==addRecord\.previousSibling/,
  );
  assert.match(source, /addRecord\.removedNodes\.length!==0/);
  assert.match(
    source,
    /record\.removedNodes\.length!==1\|\|[\s\S]*record\.addedNodes\.length!==1/,
  );
  assert.match(source, /newRow\.previousSibling!==record\.previousSibling/);
  assert.match(source, /newRow\.nextSibling!==record\.nextSibling/);
  assert.match(source, /!isRow\(newRow,sidebar\)/);
  assert.match(
    source,
    /latestLoadedSession=\{sessionId:proof\.sessionId,url:currentUrl\.href\}/,
  );
  assert.match(source, /pendingLaggingUserSessionProof/);
  assert.match(source, /api-response-confirmed-source-promoted/);
  assert.match(source, /result = "trusted-user-intent-pending"/);
  assert.match(
    transaction,
    /CanCorrelateLaggingApiProof[\s\S]*ClickIssued[\s\S]*TargetHistorySeen[\s\S]*InitialSource/,
  );

  const commandStart = source.indexOf(
    "if(data.kind!==rowActivationCommandKind",
  );
  const userPriorityGuard = source.indexOf(
    "data.handledGestureSeq<lastCommittedUserGestureSeq",
    commandStart,
  );
  const syntheticClick = source.indexOf(
    "pendingRowActivation=activation;try{row.click()",
    commandStart,
  );
  assert.ok(commandStart >= 0, "missing attested row command handler");
  assert.ok(
    userPriorityGuard > commandStart && userPriorityGuard < syntheticClick,
    "a committed real sidebar click must beat a queued native row command",
  );
  const commandSupersede = source.indexOf(
    "rememberSupersededRowActivation(pendingRowActivation)",
    commandStart,
  );
  assert.ok(
    commandSupersede > userPriorityGuard,
    "checking real-user priority must not discard an older synthetic tombstone",
  );

  const userRouteStart = source.indexOf("private void HandleUserRouteMessage");
  const userRouteEnd = source.indexOf(
    "private void HandleSessionCreatedMessage",
    userRouteStart,
  );
  const userRoute = source.slice(userRouteStart, userRouteEnd);
  assert.ok(
    userRoute.indexOf("SupersedeProgrammaticSessionSelection") <
      userRoute.indexOf("AcceptRouteIntent"),
    "a valid real sidebar route must supersede notification routing before admission",
  );

  const firstProgress = source.indexOf(
    "activation.FirstProgress.Task.WaitAsync",
  );
  const finalCompletion = source.indexOf(
    "activation.Completion.Task.WaitAsync(ct)",
    firstProgress,
  );
  assert.ok(
    firstProgress >= 0 && finalCompletion > firstProgress,
    "the short no-progress budget must hand off to the caller's full deadline",
  );

  assert.match(
    transaction,
    /!NavigationAttempted\s*&&\s*!ClickIssued\s*&&\s*!HistoryChanged/,
  );
  assert.match(transaction, /TargetHistorySeen/);
  assert.match(transaction, /TargetHistoryProgress/);
  assert.match(transaction, /ExactApiProofSeen/);
  assert.match(transaction, /TryBeginProvisionalFocus/);
  assert.match(
    transaction,
    /!ClickIssued\s*\|\|\s*!TargetHistorySeen[\s\S]*currentRoutingKey,[\s\S]*Owner\.RoutingKey/,
  );
  assert.match(source, /route-row-activation-provisional-focus/);
  assert.ok(
    source.indexOf("TryBeginProvisionalFocus") <
      source.indexOf('LogRouteEvent("route-row-activation-provisional-focus"'),
    "provisional focus must pass the exact transaction gate before Win32 focus",
  );
  assert.doesNotMatch(source, /__reactFiber|__reactProps|_reactInternals/);
});

test("PiWebDesktop reports focused row progress without weakening final proof", () => {
  const source = readFileSync(mainFormPath, "utf8");
  const transaction = readFileSync(rowActivationPath, "utf8");
  const adapter = readFileSync(routeAdapterPath, "utf8");
  const protocol = readFileSync(routeProtocolPath, "utf8");

  assert.match(
    protocol,
    /DesktopRowFocusedAwaitingProof\s*=\s*[\s\S]*"desktop-row-focused-awaiting-proof"/,
  );
  assert.match(source, /activateOwnerWithProgress:\s*ActivateSessionWindowAsync/);
  assert.match(
    source,
    /if \(focused\)[\s\S]*ReportProgrammaticSessionRowProgressAsync\(activation\)/,
  );
  assert.match(
    source,
    /await reporter\([\s\S]*DesktopRowFocusedAwaitingProof/,
  );
  assert.match(adapter, /BuildActivateProgress\([\s\S]*ReportProgressAsync/);
  assert.match(adapter, /response\.Result,[\s\S]*RouteResults\.Pending/);
  assert.match(adapter, /response\.ActivationRequestId,[\s\S]*command\.ActivationRequestId/);
  assert.match(
    transaction,
    /TryComplete\([\s\S]*!ExactApiProofSeen[\s\S]*ObservationCommitted/,
  );
  assert.match(
    source,
    /rowActivation\.Outcome\s*==\s*SessionRowActivationOutcome\.Pending/,
  );
  assert.doesNotMatch(
    source,
    /rowActivation\.Outcome\s+is\s+SessionRowActivationOutcome\.Pending\s+or\s+SessionRowActivationOutcome\.Succeeded/,
  );
  assert.match(source, /new UiDispatchStartGate\(\)/);
  assert.match(
    source,
    /catch \(OperationCanceledException\)[\s\S]*dispatchGate\.TryCancelBeforeStart\(\)[\s\S]*return await completion\.Task\.ConfigureAwait\(false\)/,
  );
});

test("live Dest activation evidence strips PowerShell provider metadata", () => {
  const source = readFileSync(liveActivationTestPath, "utf8");
  assert.match(
    source,
    /Get-Content -LiteralPath \$script:BrokerLog -Tail \$Tail \|[\s\S]*ForEach-Object \{ \[string\]\$_ \}/,
  );
  assert.match(source, /\[int\]\$ActivationTimeoutSeconds\s*=\s*55/);
  assert.match(
    source,
    /if \(\$closedObserved -and \$adapterCompleteObserved\) \{ break \}/,
  );
  assert.match(source, /FOCUSED_POPUP_CLOSE_EXCEEDED_2S/);
});
