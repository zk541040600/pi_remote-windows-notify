using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

/// <summary>
/// Integration coverage for the external-adapter polling protocol:
/// register adapter+owner → freeze → activate(accepted) → poll-activation → activate-result → activation-status.
/// </summary>
public class ExternalActivationPollTests
{
    private readonly FakeClock _clock = new(1_700_000_000_000);
    private readonly string _instance = "11111111-2222-3333-4444-555555555555";
    private readonly string _routing;

    public ExternalActivationPollTests()
    {
        _routing = RoutingKey.Compute(_instance, "session-external-poll");
    }

    [Fact]
    public async Task External_adapter_happy_path_poll_result_and_status()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-01";

        // External adapter: register without in-process activator.
        var regA = await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        Assert.Equal(RouteResults.Ok, regA.Result);

        var regO = await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-ext-001", "page-ext-001", _instance, _routing, pageFingerprint: "fp-ext-1"));
        Assert.Equal(RouteResults.Ok, regO.Result);

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock, "notif-ext-0001", _instance, _routing, "turn-complete"));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.False(string.IsNullOrEmpty(freeze.SnapshotId));

        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock, "notif-ext-0001", freeze.SnapshotId!, deadlineMs: _clock.UtcNowMs + 5_000));
        Assert.Equal(RouteResults.Accepted, activate.Result);
        Assert.Equal(RejectReasons.PendingAdapterDelivery, activate.Reason);
        Assert.False(string.IsNullOrEmpty(activate.ActivationRequestId));
        var activationRequestId = activate.ActivationRequestId!;

        // Status is pending before poll.
        var status1 = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activationRequestId));
        Assert.Equal(RouteResults.Pending, status1.Result);

        // Poll delivers the exact command once.
        var poll = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ready, poll.Result);
        Assert.Equal(activationRequestId, poll.ActivationRequestId);
        Assert.Equal(freeze.SnapshotId, poll.SnapshotId);
        Assert.Equal("owner-ext-001", poll.OwnerKey);
        Assert.Equal("page-ext-001", poll.PageKey);
        Assert.Equal(_instance, poll.InstanceKey);
        Assert.Equal(_routing, poll.RoutingKey);
        Assert.Equal("fp-ext-1", poll.PageFingerprint);
        Assert.Equal("notif-ext-0001", poll.NotificationId);

        // Second poll does not redeliver.
        var poll2 = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ok, poll2.Result);
        Assert.Equal(RejectReasons.NoPending, poll2.Reason);

        // Status still pending (delivered, awaiting result).
        var status2 = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activationRequestId));
        Assert.Equal(RouteResults.Pending, status2.Result);
        Assert.Equal("delivered-awaiting-result", status2.Reason);

        // Adapter completes with session-url-confirmed.
        var result = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activationRequestId,
            RouteResults.SessionUrlConfirmed,
            snapshotId: freeze.SnapshotId,
            adapterKey: adapterKey,
            elapsedMs: 12));
        Assert.Equal(RouteResults.SessionUrlConfirmed, result.Result);
        Assert.Equal(activationRequestId, result.ActivationRequestId);

        // Final status is terminal.
        var status3 = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activationRequestId));
        Assert.Equal(RouteResults.SessionUrlConfirmed, status3.Result);
        Assert.Equal(freeze.SnapshotId, status3.SnapshotId);

        // Idempotent activate-result replay.
        var result2 = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activationRequestId,
            RouteResults.SessionUrlConfirmed,
            adapterKey: adapterKey));
        Assert.Equal(RouteResults.SessionUrlConfirmed, result2.Result);
    }

    [Fact]
    public async Task Desktop_focus_progress_is_pending_idempotent_and_keeps_work_queued()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-desktop-progress";
        await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "pi-web-desktop"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "pi-web-desktop",
            "owner-desktop-progress",
            "page-desktop-progress",
            _instance,
            _routing,
            pageFingerprint: "fp-desktop-progress"));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-desktop-progress",
            _instance,
            _routing));
        var activationDeadline = _clock.UtcNowMs + 45_000;
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-desktop-progress",
            freeze.SnapshotId!,
            deadlineMs: activationDeadline));
        var poll = await d.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            adapterKey));
        Assert.Equal(RouteResults.Ready, poll.Result);
        Assert.Equal(activationDeadline, poll.DeadlineMs);

        var progressMessage = MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-desktop-progress",
            freeze.SnapshotId!,
            adapterKey,
            elapsedMs: 17);
        progressMessage.OwnerKey = poll.OwnerKey;
        progressMessage.PageKey = poll.PageKey;
        progressMessage.InstanceKey = poll.InstanceKey;
        progressMessage.RoutingKey = poll.RoutingKey;
        progressMessage.PageFingerprint = poll.PageFingerprint;
        progressMessage.AdapterKind = "pi-web-desktop";

        var progress = await d.DispatchAsync(progressMessage);
        Assert.Equal(RouteResults.Pending, progress.Result);
        Assert.Equal("delivered-awaiting-result", progress.Reason);
        Assert.Equal(
            ActivationPhases.DesktopRowFocusedAwaitingProof,
            progress.ActivationPhase);
        Assert.Equal(activate.ActivationRequestId, progress.ActivationRequestId);
        Assert.Equal(freeze.SnapshotId, progress.SnapshotId);

        var duplicate = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-desktop-progress",
            freeze.SnapshotId!,
            adapterKey,
            elapsedMs: 23));
        Assert.Equal(RouteResults.Pending, duplicate.Result);
        Assert.Equal(progress.ActivationPhase, duplicate.ActivationPhase);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Pending, status.Result);
        Assert.Equal("delivered-awaiting-result", status.Reason);
        Assert.Equal(progress.ActivationPhase, status.ActivationPhase);

        var snapshot = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(snapshot);
        Assert.Null(snapshot!.LastActivateResult);
        Assert.Null(snapshot.LastActivateReason);

        // Progress neither dequeues the command nor extends its delivery
        // lease; the immutable command remains eligible for normal redelivery.
        _clock.AdvanceMs(ProtocolConstants.ActivationDeliveryRetryMs + 1);
        var redelivered = await d.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            adapterKey));
        Assert.Equal(RouteResults.Ready, redelivered.Result);
        Assert.Equal(activate.ActivationRequestId, redelivered.ActivationRequestId);

        var final = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activate.ActivationRequestId!,
            RouteResults.SessionUrlConfirmed,
            snapshotId: freeze.SnapshotId,
            adapterKey: adapterKey));
        Assert.Equal(RouteResults.SessionUrlConfirmed, final.Result);

        var finalStatus = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.SessionUrlConfirmed, finalStatus.Result);
        Assert.Null(finalStatus.ActivationPhase);
    }

    [Fact]
    public async Task Focus_progress_requires_exact_desktop_delivery_correlation()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-desktop-progress-correlation";
        await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "pi-web-desktop"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "pi-web-desktop",
            "owner-progress-correlation",
            "page-progress-correlation",
            _instance,
            _routing));
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-progress-correlation",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-progress-correlation",
            freeze.SnapshotId!));

        var beforeDelivery = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-progress-correlation",
            freeze.SnapshotId!,
            adapterKey));
        Assert.Equal(RouteResults.Rejected, beforeDelivery.Result);
        Assert.Equal(RejectReasons.PendingAdapterDelivery, beforeDelivery.Reason);

        await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));

        var wrongSnapshot = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-progress-correlation",
            "snapshot-progress-wrong",
            adapterKey));
        Assert.Equal(RouteResults.Rejected, wrongSnapshot.Result);
        Assert.Equal(RejectReasons.SnapshotMismatch, wrongSnapshot.Reason);

        var wrongNotification = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-progress-wrong",
            freeze.SnapshotId!,
            adapterKey));
        Assert.Equal(RouteResults.Rejected, wrongNotification.Result);
        Assert.Equal(RejectReasons.SnapshotMismatch, wrongNotification.Reason);

        var wrongGeneration = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-progress-correlation",
            freeze.SnapshotId!,
            adapterKey,
            adapterGeneration: "generation-progress-wrong"));
        Assert.Equal(RouteResults.AdapterUnavailable, wrongGeneration.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, wrongGeneration.Reason);

        var invalidPhase = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-progress-correlation",
            freeze.SnapshotId!,
            adapterKey,
            activationPhase: "desktop-window-seen"));
        Assert.Equal(RouteResults.Rejected, invalidPhase.Result);
        Assert.Equal(RejectReasons.InvalidField, invalidPhase.Reason);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Pending, status.Result);
        Assert.Null(status.ActivationPhase);
        var snapshot = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(snapshot);
        Assert.Null(snapshot!.LastActivateResult);
    }

    [Fact]
    public async Task Focus_progress_is_desktop_only_and_stale_observation_is_non_terminal()
    {
        var chromeDispatcher = CreateDispatcher();
        const string chromeAdapter = "adapter-chrome-progress-denied";
        await chromeDispatcher.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            chromeAdapter,
            "chrome"));
        await chromeDispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            chromeAdapter,
            "chrome",
            "owner-chrome-progress-denied",
            "page-chrome-progress-denied",
            _instance,
            _routing));
        var chromeFreeze = await chromeDispatcher.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-chrome-progress-denied",
            _instance,
            _routing));
        var chromeActivate = await chromeDispatcher.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-chrome-progress-denied",
            chromeFreeze.SnapshotId!));
        await chromeDispatcher.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            chromeAdapter));
        var chromeProgress = await chromeDispatcher.DispatchAsync(
            MessageFactory.ActivateProgress(
                _clock,
                chromeActivate.ActivationRequestId!,
                "notif-chrome-progress-denied",
                chromeFreeze.SnapshotId!,
                chromeAdapter));
        Assert.Equal(RouteResults.Rejected, chromeProgress.Result);
        Assert.Equal(RejectReasons.WrongAdapter, chromeProgress.Reason);

        var desktopDispatcher = CreateDispatcher();
        const string desktopAdapter = "adapter-desktop-progress-stale";
        const string desktopOwner = "owner-desktop-progress-stale";
        await desktopDispatcher.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            desktopAdapter,
            "pi-web-desktop"));
        await desktopDispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            desktopAdapter,
            "pi-web-desktop",
            desktopOwner,
            "page-desktop-progress-stale",
            _instance,
            _routing));
        var desktopFreeze = await desktopDispatcher.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-desktop-progress-stale",
            _instance,
            _routing));
        var desktopActivate = await desktopDispatcher.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-desktop-progress-stale",
            desktopFreeze.SnapshotId!));
        await desktopDispatcher.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            desktopAdapter));
        await desktopDispatcher.DispatchAsync(MessageFactory.UnregisterOwner(
            _clock,
            desktopAdapter,
            desktopOwner));

        var staleProgress = await desktopDispatcher.DispatchAsync(
            MessageFactory.ActivateProgress(
                _clock,
                desktopActivate.ActivationRequestId!,
                "notif-desktop-progress-stale",
                desktopFreeze.SnapshotId!,
                desktopAdapter));
        Assert.Equal(RouteResults.Stale, staleProgress.Result);
        Assert.Equal(RejectReasons.LeaseExpired, staleProgress.Reason);

        var desktopSnapshot = desktopDispatcher.State.GetSnapshot(
            desktopFreeze.SnapshotId!);
        Assert.NotNull(desktopSnapshot);
        Assert.Null(desktopSnapshot!.LastActivateResult);

        // Normal status owns the terminal transition after progress merely
        // observed the stale target.
        var terminalStatus = await desktopDispatcher.DispatchAsync(
            MessageFactory.ActivationStatus(
                _clock,
                desktopActivate.ActivationRequestId!));
        Assert.Equal(RouteResults.Stale, terminalStatus.Result);
        Assert.Equal(RejectReasons.LeaseExpired, terminalStatus.Reason);
    }

    [Fact]
    public async Task Expired_focus_progress_reports_timeout_without_owning_completion()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-desktop-progress-expired";
        await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "pi-web-desktop"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "pi-web-desktop",
            "owner-desktop-progress-expired",
            "page-desktop-progress-expired",
            _instance,
            _routing));
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-desktop-progress-expired",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-desktop-progress-expired",
            freeze.SnapshotId!,
            deadlineMs: _clock.UtcNowMs + 1_000));
        var frozenSnapshot = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(frozenSnapshot);
        await d.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            adapterKey));
        _clock.AdvanceMs(1_001);

        var progress = await d.DispatchAsync(MessageFactory.ActivateProgress(
            _clock,
            activate.ActivationRequestId!,
            "notif-desktop-progress-expired",
            freeze.SnapshotId!,
            adapterKey));
        Assert.Equal(RouteResults.Timeout, progress.Result);
        Assert.Equal(RejectReasons.Expired, progress.Reason);

        Assert.Null(frozenSnapshot!.LastActivateResult);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Timeout, status.Result);
        Assert.Equal(RejectReasons.Expired, status.Reason);
        Assert.Equal(
            RouteResults.Timeout,
            d.State.GetSnapshot(freeze.SnapshotId!)!.LastActivateResult);
    }

    [Fact]
    public async Task Lost_poll_response_is_redelivered_after_delivery_retry_lease()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-lost-poll";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-lost-poll",
            "page-lost-poll",
            _instance,
            _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-lost-poll",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-lost-poll",
            freeze.SnapshotId!,
            deadlineMs: _clock.UtcNowMs + 5_000));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        // Simulate a daemon/native response lost after Route Host selected the
        // command but before the adapter received it.
        var lost = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ready, lost.Result);

        var immediate = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ok, immediate.Result);
        Assert.Equal(RejectReasons.NoPending, immediate.Reason);

        _clock.AdvanceMs(1_001);

        var retried = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ready, retried.Result);
        Assert.Equal(lost.ActivationRequestId, retried.ActivationRequestId);
        Assert.Equal(lost.NotificationId, retried.NotificationId);
        Assert.Equal(lost.SnapshotId, retried.SnapshotId);
        Assert.Equal(lost.OwnerKey, retried.OwnerKey);
        Assert.Equal(lost.PageKey, retried.PageKey);

        var result = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            retried.ActivationRequestId!,
            RouteResults.SessionUrlConfirmed,
            snapshotId: retried.SnapshotId,
            adapterKey: adapterKey));
        Assert.Equal(RouteResults.SessionUrlConfirmed, result.Result);

        var afterAck = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ok, afterAck.Result);
        Assert.Equal(RejectReasons.NoPending, afterAck.Reason);
    }

    [Fact]
    public async Task Lost_poll_response_is_redelivered_after_small_clock_rollback()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-rollback-poll";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-rollback-poll",
            "page-rollback-poll",
            _instance,
            _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-rollback-poll",
            _instance,
            _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.NotNull(freeze.SnapshotId);
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-rollback-poll",
            freeze.SnapshotId,
            deadlineMs: _clock.UtcNowMs + 5_000));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        var lost = await d.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            adapterKey));
        Assert.Equal(RouteResults.Ready, lost.Result);

        // A sub-skew wall-clock rollback retains runtime state. It must not
        // turn the delivery retry lease into a multi-second suppression window.
        _clock.SetMs(_clock.UtcNowMs - 30_000);

        var retried = await d.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            adapterKey));
        Assert.Equal(RouteResults.Ready, retried.Result);
        Assert.Equal(lost.ActivationRequestId, retried.ActivationRequestId);
        Assert.Equal(lost.NotificationId, retried.NotificationId);
        Assert.Equal(lost.SnapshotId, retried.SnapshotId);
        Assert.Equal(lost.OwnerKey, retried.OwnerKey);
        Assert.Equal(lost.PageKey, retried.PageKey);
    }

    [Fact]
    public async Task Wrong_adapter_poll_does_not_receive_command()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-02";
        const string otherAdapter = "adapter-edge-other-02";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, otherAdapter, "edge"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-w-001", "page-w-001", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-wrong-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);

        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-wrong-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        // Wrong adapter polls: no command.
        var pollWrong = await d.DispatchAsync(MessageFactory.PollActivation(_clock, otherAdapter));
        Assert.Equal(RouteResults.Ok, pollWrong.Result);
        Assert.Equal(RejectReasons.NoPending, pollWrong.Reason);

        // Correct adapter still receives it.
        var pollRight = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ready, pollRight.Result);
        Assert.Equal(activate.ActivationRequestId, pollRight.ActivationRequestId);
    }

    [Fact]
    public async Task Wrong_adapter_cannot_complete_activate_result()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-03";
        const string otherAdapter = "adapter-edge-other-03";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, otherAdapter, "edge"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-c-001", "page-c-001", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-c-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-c-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        var poll = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ready, poll.Result);

        var bad = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activate.ActivationRequestId!,
            RouteResults.SessionUrlConfirmed,
            adapterKey: otherAdapter));
        Assert.Equal(RouteResults.Rejected, bad.Result);
        Assert.Equal(RejectReasons.WrongAdapter, bad.Reason);

        // Still pending for the real adapter.
        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Pending, status.Result);
    }

    [Fact]
    public async Task Invalid_terminal_result_cannot_complete_an_activation()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-invalid-terminal-result";
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-invalid-terminal",
            "page-invalid-terminal",
            _instance,
            _routing));
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-invalid-terminal",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-invalid-terminal",
            freeze.SnapshotId!));
        await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));

        var invalid = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activate.ActivationRequestId!,
            RouteResults.Ready,
            snapshotId: freeze.SnapshotId,
            adapterKey: adapterKey));
        Assert.Equal(RouteResults.Rejected, invalid.Result);
        Assert.Equal(RejectReasons.InvalidField, invalid.Reason);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Pending, status.Result);
    }

    [Fact]
    public async Task Snapshot_mismatch_is_checked_before_stale_target_mutation()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-result-correlation-order";
        const string ownerKey = "owner-result-correlation-order";
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            ownerKey,
            "page-result-correlation-order",
            _instance,
            _routing));
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-result-correlation-order",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-result-correlation-order",
            freeze.SnapshotId!));
        await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        await d.DispatchAsync(MessageFactory.UnregisterOwner(
            _clock,
            adapterKey,
            ownerKey));

        var mismatched = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activate.ActivationRequestId!,
            RouteResults.SessionUrlConfirmed,
            snapshotId: "snapshot-result-correlation-wrong",
            adapterKey: adapterKey));
        Assert.Equal(RouteResults.Rejected, mismatched.Result);
        Assert.Equal(RejectReasons.SnapshotMismatch, mismatched.Reason);

        var snapshotAfterMismatch = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(snapshotAfterMismatch);
        Assert.Null(snapshotAfterMismatch!.LastActivateResult);

        // A later status query may independently revalidate the now-missing
        // owner and complete stale; that transition is not authority granted
        // by the mismatched result.
        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Stale, status.Result);
    }

    [Fact]
    public async Task Unknown_activation_result_cannot_mutate_a_known_snapshot()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-orphan-result";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-orphan-result",
            "page-orphan-result",
            _instance,
            _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-orphan-result",
            _instance,
            _routing));
        var before = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(before);
        Assert.Null(before!.LastActivateResult);

        var orphan = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            "activation-never-enqueued",
            RouteResults.SessionUrlConfirmed,
            snapshotId: freeze.SnapshotId,
            adapterKey: adapterKey));

        Assert.Equal(RouteResults.Stale, orphan.Result);
        Assert.Equal(RejectReasons.ActivationUnknown, orphan.Reason);
        var after = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(after);
        Assert.Null(after!.LastActivateResult);
        Assert.Null(after.LastActivateReason);
    }

    [Fact]
    public async Task Activation_times_out_when_deadline_passes()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-04";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-t-001", "page-t-001", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-t-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock, "notif-t-0001", freeze.SnapshotId!, deadlineMs: _clock.UtcNowMs + 1_000));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        _clock.AdvanceMs(2_000);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Timeout, status.Result);
        Assert.Equal(RejectReasons.Expired, status.Reason);

        // Poll after timeout yields nothing.
        var poll = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ok, poll.Result);
        Assert.Equal(RejectReasons.NoPending, poll.Reason);
    }

    [Fact]
    public async Task Poll_returns_stale_when_owner_page_changed_before_delivery()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-05";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-s-001", "page-s-001", _instance, _routing, pageFingerprint: "fp-1"));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-s-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-s-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        // Owner navigates away before adapter polls.
        var re = await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-s-001", "page-s-002", _instance, _routing, pageFingerprint: "fp-2"));
        Assert.Equal(RouteResults.Ok, re.Result);

        // Poll revalidates and completes as stale (command not delivered).
        var poll = await d.DispatchAsync(MessageFactory.PollActivation(_clock, adapterKey));
        Assert.Equal(RouteResults.Ok, poll.Result);
        Assert.Equal(RejectReasons.NoPending, poll.Reason);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activate.ActivationRequestId!));
        Assert.Equal(RouteResults.Stale, status.Result);
        Assert.Equal(RejectReasons.OwnerChanged, status.Reason);
    }

    [Fact]
    public async Task Snapshot_capacity_does_not_evict_an_in_flight_activation_target()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-capacity";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-snapshot-capacity",
            "page-snapshot-capacity",
            _instance,
            _routing));

        var protectedFreeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-protected-snapshot",
            _instance,
            _routing));
        var activation = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-protected-snapshot",
            protectedFreeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activation.Result);

        for (var index = 1; index < ProtocolConstants.MaxSnapshots; index++)
        {
            var freeze = await d.DispatchAsync(MessageFactory.Freeze(
                _clock,
                $"notif-capacity-{index:D4}",
                _instance,
                _routing));
            Assert.Equal(RouteResults.Ready, freeze.Result);
        }

        var overflow = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-capacity-overflow",
            _instance,
            _routing));
        Assert.Equal(RouteResults.Ready, overflow.Result);
        Assert.NotNull(d.State.GetSnapshot(protectedFreeze.SnapshotId!));

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activation.ActivationRequestId!));
        Assert.Equal(RouteResults.Pending, status.Result);
    }

    [Fact]
    public async Task Activation_capacity_rejects_overflow_without_evicting_in_flight_work()
    {
        var d = CreateDispatcher();
        string? oldestActivationRequestId = null;

        for (var adapterIndex = 0; adapterIndex < 8; adapterIndex++)
        {
            var adapterKey = $"adapter-capacity-{adapterIndex:D2}";
            var sessionId = $"session-capacity-{adapterIndex:D2}";
            var routing = RoutingKey.Compute(_instance, sessionId);
            await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome"));
            await d.DispatchAsync(MessageFactory.RegisterOwner(
                _clock,
                adapterKey,
                "chrome",
                $"owner-capacity-{adapterIndex:D2}",
                $"page-capacity-{adapterIndex:D2}",
                _instance,
                routing));

            for (var itemIndex = 0; itemIndex < ProtocolConstants.MaxPendingPerAdapter; itemIndex++)
            {
                var notificationId = $"notif-capacity-{adapterIndex:D2}-{itemIndex:D2}";
                var freeze = await d.DispatchAsync(MessageFactory.Freeze(
                    _clock,
                    notificationId,
                    _instance,
                    routing));
                var activation = await d.DispatchAsync(MessageFactory.Activate(
                    _clock,
                    notificationId,
                    freeze.SnapshotId!,
                    deadlineMs: _clock.UtcNowMs + ProtocolConstants.MaxRequestTtlMs));
                Assert.Equal(RouteResults.Accepted, activation.Result);
                oldestActivationRequestId ??= activation.ActivationRequestId;
            }
        }

        Assert.Equal(ProtocolConstants.MaxPendingActivations, d.State.PendingActivationCount);

        const string overflowAdapter = "adapter-capacity-overflow";
        const string overflowSession = "session-capacity-overflow";
        var overflowRouting = RoutingKey.Compute(_instance, overflowSession);
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, overflowAdapter, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            overflowAdapter,
            "chrome",
            "owner-capacity-overflow",
            "page-capacity-overflow",
            _instance,
            overflowRouting));
        var overflowFreeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-capacity-overflow",
            _instance,
            overflowRouting));
        var overflow = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-capacity-overflow",
            overflowFreeze.SnapshotId!,
            deadlineMs: _clock.UtcNowMs + ProtocolConstants.MaxRequestTtlMs));

        Assert.Equal(RouteResults.Rejected, overflow.Result);
        Assert.Equal(RejectReasons.Capacity, overflow.Reason);
        Assert.Equal(ProtocolConstants.MaxPendingActivations, d.State.PendingActivationCount);

        var oldestStatus = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            oldestActivationRequestId!));
        Assert.Equal(RouteResults.Pending, oldestStatus.Result);
    }

    [Fact]
    public async Task Unregister_adapter_fails_open_activations()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-06";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "chrome", "owner-u-001", "page-u-001", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-u-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-u-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        var unreg = MessageFactory.Create(MessageTypes.UnregisterAdapter, _clock);
        unreg.AdapterKey = adapterKey;
        unreg.AdapterGeneration =
            MessageFactory.DefaultAdapterGeneration(adapterKey);
        await d.DispatchAsync(unreg);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activate.ActivationRequestId!));
        Assert.Equal(RouteResults.AdapterUnavailable, status.Result);
    }

    [Fact]
    public async Task Register_adapter_fails_old_generation_activations()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-generation-07";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-generation-001",
            "page-generation-001",
            _instance,
            _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-generation-001",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-generation-001",
            freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        var restarted = await d.DispatchAsync(
            MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: "generation-chrome-restarted-08",
                adapterStartedAtMs: _clock.UtcNowMs + 1));
        Assert.Equal(RouteResults.Ok, restarted.Result);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activate.ActivationRequestId!));
        Assert.Equal(RouteResults.AdapterUnavailable, status.Result);
        Assert.Equal(RejectReasons.AdapterUnknown, status.Reason);
        Assert.Empty(d.State.ListOwners(_instance, _routing));
    }

    [Fact]
    public async Task Restarted_adapter_acknowledges_the_old_generations_durable_result()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-generation-outbox";
        var oldGeneration = MessageFactory.DefaultAdapterGeneration(adapterKey);
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-generation-outbox-old",
            "page-generation-outbox-old",
            _instance,
            _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-generation-outbox",
            _instance,
            _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-generation-outbox",
            freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);
        Assert.Equal(
            RouteResults.Ready,
            (await d.DispatchAsync(
                MessageFactory.PollActivation(
                    _clock,
                    adapterKey,
                    adapterGeneration: oldGeneration))).Result);

        _clock.AdvanceMs(10);
        const string newGeneration = "generation-outbox-restarted";
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: newGeneration,
                adapterStartedAtMs: _clock.UtcNowMs))).Result);

        var durableOldResult = await d.DispatchAsync(MessageFactory.ActivateResult(
            _clock,
            activate.ActivationRequestId!,
            RouteResults.SessionUrlConfirmed,
            snapshotId: freeze.SnapshotId,
            adapterKey: adapterKey,
            adapterGeneration: oldGeneration));
        Assert.Equal(RouteResults.AdapterUnavailable, durableOldResult.Result);
        Assert.Equal(RejectReasons.AdapterUnknown, durableOldResult.Reason);
        Assert.Equal(activate.ActivationRequestId, durableOldResult.ActivationRequestId);

        var stalePoll = await d.DispatchAsync(MessageFactory.PollActivation(
            _clock,
            adapterKey,
            adapterGeneration: oldGeneration));
        Assert.Equal(RouteResults.AdapterUnavailable, stalePoll.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, stalePoll.Reason);
    }

    [Fact]
    public async Task In_process_mock_activator_still_returns_final_ack_without_poll()
    {
        // Regression: mock path must not require poll-activation.
        var d = CreateDispatcher();
        const string adapterKey = "adapter-mock-poll-01";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "mock"));
        d.TrySetActivator(adapterKey, MockAdapterActivator.ConfirmSessionUrl);
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "mock", "owner-m-001", "page-m-001", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-m-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-m-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.SessionUrlConfirmed, activate.Result);

        // No pending external activation.
        Assert.Equal(0, d.State.PendingActivationCount);
    }

    private RouteDispatcher CreateDispatcher()
    {
        var state = new RouteStateMachine(_clock, daemonId: "test-poll-daemon");
        return new RouteDispatcher(state, _clock);
    }
}
