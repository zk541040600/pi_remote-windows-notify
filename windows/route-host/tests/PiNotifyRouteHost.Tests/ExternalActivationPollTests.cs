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
            _clock, adapterKey, "owner-ext-001", "page-ext-001", _instance, _routing, pageFingerprint: "fp-ext-1"));
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
    public async Task Wrong_adapter_poll_does_not_receive_command()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-02";
        const string otherAdapter = "adapter-edge-other-02";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, otherAdapter, "edge"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "owner-w-001", "page-w-001", _instance, _routing));

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
            _clock, adapterKey, "owner-c-001", "page-c-001", _instance, _routing));

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
    public async Task Activation_times_out_when_deadline_passes()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-04";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "owner-t-001", "page-t-001", _instance, _routing));

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
            _clock, adapterKey, "owner-s-001", "page-s-001", _instance, _routing, pageFingerprint: "fp-1"));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-s-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-s-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        // Owner navigates away before adapter polls.
        var re = await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "owner-s-001", "page-s-002", _instance, _routing, pageFingerprint: "fp-2"));
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
    public async Task Unregister_adapter_fails_open_activations()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-chrome-ext-06";

        await d.DispatchAsync(MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, adapterKey, "owner-u-001", "page-u-001", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-u-0001", _instance, _routing));
        var activate = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-u-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activate.Result);

        var unreg = MessageFactory.Create(MessageTypes.UnregisterAdapter, _clock);
        unreg.AdapterKey = adapterKey;
        await d.DispatchAsync(unreg);

        var status = await d.DispatchAsync(MessageFactory.ActivationStatus(_clock, activate.ActivationRequestId!));
        Assert.Equal(RouteResults.AdapterUnavailable, status.Result);
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
            _clock, adapterKey, "owner-m-001", "page-m-001", _instance, _routing));

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
