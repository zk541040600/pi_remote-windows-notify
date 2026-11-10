import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
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
const programmaticNavigationPath = new URL(
  "../../IggToolsL2/tools/pi-web-desktop/ProgrammaticSessionNavigationTransaction.cs",
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

test("PiWebDesktop notification routing keeps strict same-document proof and one controlled unbound navigation", () => {
  const source = readFileSync(mainFormPath, "utf8");
  const transaction = readFileSync(rowActivationPath, "utf8");
  assert.equal(
    existsSync(programmaticNavigationPath),
    true,
    "the shipped Desktop source must retain the bounded controlled-navigation transaction",
  );
  const navigationTransaction = readFileSync(programmaticNavigationPath, "utf8");

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
  assert.doesNotMatch(
    source,
    /nativeTraverseTo|activation\.navigationInfo|beginHistoryEntryRebind|finishHistoryEntryRebind|emitDeferredHistoryApiProof|activation\.navigateSeen|activation\.committed|activation\.entryEventSeen/,
    "dead history/current activation machinery must stay removed",
  );
  assert.match(source, /beginProvisionalHistoryEntryRebind\(target,effectiveMethod\)/);
  assert.match(source, /finishProvisionalHistoryEntryRebind\(/);
  assert.match(source, /currentProvisionalHistoryEntry\(/);
  assert.match(source, /proof\.requestGestureSeq===lastCommittedUserGestureSeq/);
  assert.match(source, /proof\.requestGestureSeq===gestureSequence/);
  assert.doesNotMatch(source, /traverse-correlation-timeout/);
  assert.match(source, /RowActivationHistoryBudgetMs/);
  assert.match(transaction, /IsUnavailableWithoutMutation/);
  assert.doesNotMatch(transaction, /CanFallback/);
  assert.match(
    source,
    /rowActivationOutcome\s*!=\s*SessionRowActivationOutcome\.Unavailable[\s\S]{0,120}return false/,
  );
  assert.match(
    source,
    /_documentGeneration != activationStartDocumentGeneration[\s\S]{0,260}_pendingDocumentNavigationId != activationStartNavigationId[\s\S]{0,200}_activeDocumentNonce,[\s\S]{0,100}activationStartDocumentNonce/,
  );
  assert.match(source, /route-row-activation-fallback/);
  assert.match(source, /row-unavailable-source-unchanged/);
  const fallbackFenceStart = source.indexOf(
    "var activationStartUserSelectionEpoch = _trustedUserSelectionEpoch;",
  );
  const fallbackFenceGuard = source.indexOf(
    "_trustedUserSelectionEpoch !=",
    fallbackFenceStart,
  );
  const controlledNavigation = source.indexOf(
    "core.Navigate(targetUrl)",
    fallbackFenceStart,
  );
  assert.ok(
    fallbackFenceStart >= 0 &&
      fallbackFenceGuard > fallbackFenceStart &&
      controlledNavigation > fallbackFenceGuard,
    "a trusted user selection processed during row activation must fence controlled navigation",
  );
  assert.match(
    source,
    /private void SupersedeProgrammaticSessionSelection[\s\S]{0,220}_trustedUserSelectionEpoch\+\+;/,
  );
  assert.match(
    source,
    /const historyRecord=verifiedHistoryEntries\.get\(data\.sessionId\);[\s\S]{0,180}removeHistorySession\(data\.sessionId\)[\s\S]{0,220}status:'unavailable'/,
    "a disconnected row or retained history is only a zero-mutation unavailable signal, never a selector",
  );
  assert.match(source, /route-activation-navigation-issued/);
  assert.match(source, /new ProgrammaticSessionNavigationTransaction/);
  assert.match(source, /core\.Navigate\(targetUrl\)/);
  assert.match(
    source,
    /rowActivationOutcome\s*!=\s*SessionRowActivationOutcome\.Unavailable[\s\S]{0,900}return false/,
    "partial, no-proof, ambiguous, and superseded activation must fail closed before navigation",
  );
  assert.match(navigationTransaction, /NavigationId/);
  assert.match(navigationTransaction, /ExpectedDocumentGeneration/);
  assert.match(navigationTransaction, /DocumentNonce/);
  assert.match(navigationTransaction, /TrySignalNavigationReady/);
  assert.match(navigationTransaction, /TryMarkSessionLoaded/);
  assert.match(navigationTransaction, /TryCommitObservation/);
  assert.match(navigationTransaction, /TryBeginProvisionalFocus/);
  assert.match(navigationTransaction, /TryReleaseMask/);
  assert.match(navigationTransaction, /FailAndReleaseMask/);
  assert.match(
    source,
    /var ownsMask = ReferenceEquals\(_loadingMaskOwner, navigation\);[\s\S]{0,180}navigation\.FailAndReleaseMask\(\)[\s\S]{0,180}if \(!ownsMask \|\| !released\)/,
    "failure cleanup must not unlock a newer transaction's mask owner",
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
  assert.match(source, /const deferredUserApiProofs=new Map\(\)/);
  assert.match(source, /const maxDeferredUserApiProofs=16/);
  assert.match(source, /const deferUserApiProof=\(proof\)=>/);
  assert.match(
    source,
    /deferredUserApiProofs\.get\(proof\.sessionId\)!==proof/,
  );
  assert.match(
    source,
    /deferredUserApiProofs\.size>=maxDeferredUserApiProofs/,
  );
  assert.match(source, /deferredProof\.requestGesture===gesture/);
  assert.match(source, /emitSessionApiProof\(deferredProof,false\)/);
  assert.match(source, /rejectDeferredUserApiProof\(proof,'deferred-expired'\)/);
  assert.match(source, /let deferredProgrammaticApiProof=null/);
  assert.match(source, /const deferProgrammaticApiProof=\(proof\)=>/);
  assert.match(
    source,
    /activation\.kind!=='row'[\s\S]{0,180}pendingRowActivation!==activation[\s\S]{0,180}activation\.sessionId!==proof\.sessionId/,
  );
  assert.match(
    source,
    /const deferredApiProofExpired=\(proof\)=>\{[\s\S]{0,220}Date\.now\(\)>=proof\.deferredExpiresAtMs/,
  );
  assert.match(source, /proof\.deferredExpiresAtMs=deferredAtMs\+5000/);
  assert.match(
    source,
    /Math\.max\(0,proof\.deferredExpiresAtMs-Date\.now\(\)\)/,
  );
  assert.match(
    source,
    /const expireDeferredApiProof=\(proof\)=>\{[\s\S]{0,500}clearDeferredApiProof\(proof\)[\s\S]{0,500}outcome:'deferred-expired'/,
  );
  assert.match(
    source,
    /const emitSessionApiProof=\(proof,allowDefer\)=>\{try\{[\s\S]{0,120}expireDeferredApiProof\(proof\)/,
  );
  assert.match(
    source,
    /activation\.historyAcked=true;[\s\S]{0,420}programmaticProof\.activation===activation[\s\S]{0,220}emitSessionApiProof\(programmaticProof,false\)[\s\S]{0,120}maybeClearPendingActivation\(activation\)/,
  );
  assert.match(source, /pendingLaggingUserSessionProof/);
  assert.match(source, /ShouldPromoteLaggingUserSessionProof/);
  assert.match(
    source,
    /ConsumeLaggingUserSessionProof[\s\S]*candidateSlot = null;[\s\S]*ShouldPromoteLaggingUserSessionProof/,
  );
  assert.match(
    source,
    /candidateDocumentGeneration == currentDocumentGeneration[\s\S]*candidateDocumentNonce,[\s\S]*activeDocumentNonce[\s\S]*IsFreshRouteIntent[\s\S]*candidateRoutingKey,[\s\S]*observedRoutingKey/,
  );
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
  const commandHandler = source.slice(commandStart, syntheticClick);
  assert.match(
    commandHandler,
    /clearProgrammaticProofForActivation\([\s\S]{0,160}pendingRowActivation,'proof-superseded'/,
  );
  const trustedClickStart = source.indexOf(
    "document.addEventListener('click'",
  );
  const historyHookStart = source.indexOf(
    "for(const method of ['pushState','replaceState'])",
    trustedClickStart,
  );
  assert.ok(
    trustedClickStart >= 0 && historyHookStart > trustedClickStart,
    "missing trusted click proof ownership window",
  );
  assert.match(
    source.slice(trustedClickStart, historyHookStart),
    /clearProgrammaticProofForActivation\([\s\S]{0,160}pendingRowActivation,'proof-superseded'/,
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
  assert.match(
    adapter,
    /if \(!retainTerminalFence\)[\s\S]{0,220}RemoveActivationFinalizer\([\s\S]{0,120}rejectPending: true\)[\s\S]{0,120}ReleaseActivationTerminalFence\(\)/,
    "exception/cancellation before durable terminal admission must reject fresh-navigation finalization",
  );
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
  assert.match(
    source,
    /'api-response-confirmed',[\s\S]*'api-response-confirmed-source-promoted'/,
  );
  const captureStart = source.indexOf(
    "function Get-CapturedRowRoutingFingerprints",
  );
  const captureEnd = source.indexOf("\nfunction ", captureStart + 1);
  const captureContract = source.slice(
    captureStart,
    captureEnd > captureStart ? captureEnd : undefined,
  );
  assert.ok(captureStart >= 0, "missing captured-row proof contract");
  assert.match(captureContract, /processId -eq \$script:DesktopPid/);
  assert.match(captureContract, /runId -eq \$script:DesktopRunId/);
  assert.match(
    captureContract,
    /Get-EventDocumentGeneration[\s\S]*-eq \$DocumentGeneration/,
  );
  assert.match(captureContract, /intentKind' 'sidebar'/);
  assert.match(
    captureContract,
    /Test-EventField \$_ 'routingFp' \$routingFp/,
  );
  assert.match(
    captureContract,
    /ConvertTo-EventUtc -EventRecord \$_\) -ge \$intentUtc/,
  );
  assert.match(
    source,
    /\$readyUtc -le \$issuedUtc[\s\S]*\$issuedUtc -le \$historyUtc[\s\S]*\$historyUtc -le \$proofUtc[\s\S]*\$proofUtc -le \$committedUtc[\s\S]*\$committedUtc -le \$confirmedUtc[\s\S]*\$confirmedUtc -le \$acknowledgedUtc[\s\S]*\$acknowledgedUtc -le \$completedUtc/,
  );
  assert.match(source, /ACTIVATION_EVENT_ORDER_INVALID/);
  assert.match(source, /CONTROLLED_NAVIGATION_EVENT_ORDER_INVALID/);
  assert.match(source, /PHYSICAL_POPUP_CLICK_MISSING/);
  assert.match(source, /broker-popup-click\\s\+popupId/);
  const activationStart = source.indexOf("function Invoke-LiveExactActivation");
  const activationEnd = source.indexOf("\nfunction ", activationStart + 1);
  const activationContract = source.slice(
    activationStart,
    activationEnd > activationStart ? activationEnd : undefined,
  );
  assert.ok(activationStart >= 0, "missing live exact activation contract");
  assert.doesNotMatch(activationContract, /Test-CapturedRowEvidence/);
  assert.doesNotMatch(
    activationContract,
    /Invoke-BrokerRequest\s+-Method POST\s+-Path '\/close'[\s\S]{0,160}activate\s*=\s*\$true/,
  );
  assert.match(source, /ACTIVATION_BINDING_SNAPSHOT_INVALID/);
  assert.match(source, /targetRowState' 'verified'/);
  assert.match(source, /targetHistoryState' 'retained'/);
  assert.match(source, /TWO_ACCEPTED_ACTIVATION_ROUNDS_REQUIRED/);
  assert.match(source, /CONTROLLED_NAVIGATION_ROUND_MISSING/);
  assert.match(source, /SAME_DOCUMENT_ROUND_MISSING/);
  assert.match(source, /route-row-activation-fail-closed-check/);
  assert.match(source, /unavailableWithoutMutation' \$true/);
  assert.match(source, /route-activation-navigation-mask/);
  assert.match(source, /route-activation-observation-committed/);
  assert.match(source, /\$navigationIssued\.Count -eq 1/);
  assert.match(source, /\$navigationStarts\.Count -eq 1/);
  assert.match(source, /\$afterGeneration -eq \(\$beforeGeneration \+ 1\)/);
  assert.match(source, /BROKER_HANDLED_FINAL_COUNT_INVALID/);
  assert.match(source, /BROKER_HANDLED_TERMINAL_COUNT_INVALID/);
  assert.match(source, /BROKER_FOCUSED_TERMINAL_OBSERVED/);
  assert.match(source, /ACTIVATION_SELECTION_PATH_INVALID/);
  assert.match(source, /FreshFallbackCount\s*=\s*\$fallbacks\.Count/);
  assert.match(source, /'route-row-binding-diagnostic'/);
});
