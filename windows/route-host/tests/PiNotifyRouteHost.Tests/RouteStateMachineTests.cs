using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class RouteStateMachineTests
{
    private readonly FakeClock _clock = new(1_700_000_000_000);
    private readonly string _instance = "11111111-2222-3333-4444-555555555555";
    private readonly string _routing;

    public RouteStateMachineTests()
    {
        _routing = RoutingKey.Compute(_instance, "session-under-test");
    }

    [Fact]
    public async Task Freeze_with_zero_owners_returns_miss()
    {
        var d = CreateDispatcher();
        var r = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-miss-0001", _instance, _routing));
        Assert.Equal(RouteResults.Miss, r.Result);
        Assert.Equal(0, r.CandidateCount);
        Assert.Equal(RouteResults.OwnerUnresolved, r.Reason);
    }

    [Fact]
    public async Task Freeze_with_unique_owner_returns_ready_and_activate_confirms()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-u-0001", _instance, _routing, "ask-user"));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.False(string.IsNullOrEmpty(freeze.SnapshotId));
        Assert.Equal(1, freeze.CandidateCount);

        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-u-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.SessionUrlConfirmed, act.Result);
        Assert.Equal(freeze.SnapshotId, act.SnapshotId);
    }

    [Fact]
    public async Task Freeze_with_two_owners_returns_ambiguous_without_snapshot()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-002", "page-002");

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-a-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ambiguous, freeze.Result);
        Assert.Equal(2, freeze.CandidateCount);
        Assert.Null(freeze.SnapshotId);
    }

    [Fact]
    public async Task Snapshot_is_immutable_when_new_owner_appears()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-imm-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        var snapId = freeze.SnapshotId!;

        // New owner for same session after freeze must not retarget old snapshot.
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-002", "page-002");

        var snap = d.State.GetSnapshot(snapId);
        Assert.NotNull(snap);
        Assert.Equal("owner-001", snap!.OwnerKey);
        Assert.Equal("page-001", snap.PageKey);

        // New freeze is ambiguous; old snapshot still activates owner-1 if still live.
        var freeze2 = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-imm-0002", _instance, _routing));
        Assert.Equal(RouteResults.Ambiguous, freeze2.Result);

        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-imm-0001", snapId));
        Assert.Equal(RouteResults.SessionUrlConfirmed, act.Result);
    }

    [Fact]
    public async Task Activate_returns_stale_when_owner_page_changes()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001", pageFingerprint: "fp-1");

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-stale-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);

        // Same ownerKey re-registers with a different pageKey (navigated away).
        var re = MessageFactory.RegisterOwner(
            _clock, "adapter-1", "owner-001", "page-002", _instance, _routing, pageFingerprint: "fp-2");
        var reg = await d.DispatchAsync(re);
        Assert.Equal(RouteResults.Ok, reg.Result);

        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-stale-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Stale, act.Result);
        Assert.Equal(RejectReasons.OwnerChanged, act.Reason);
    }

    [Fact]
    public async Task Activate_returns_stale_when_owner_unregistered()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-gone-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);

        await d.DispatchAsync(MessageFactory.UnregisterOwner(_clock, "owner-001"));
        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-gone-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Stale, act.Result);
    }

    [Fact]
    public async Task Activate_returns_adapter_unavailable_when_adapter_lease_expires()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001", leaseTtlMs: 5_000);
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-lease-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);

        _clock.AdvanceMs(10_000);

        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-lease-0001", freeze.SnapshotId!));
        Assert.True(act.Result is RouteResults.Stale or RouteResults.AdapterUnavailable);
    }

    [Fact]
    public async Task Replay_requestId_is_idempotent()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");

        var msg = MessageFactory.Freeze(_clock, "notif-rpl-0001", _instance, _routing);
        var first = await d.DispatchAsync(msg);
        Assert.Equal(RouteResults.Ready, first.Result);

        var second = await d.DispatchAsync(msg);
        Assert.Equal(RouteResults.Ready, second.Result);
        Assert.Equal(first.SnapshotId, second.SnapshotId);
        Assert.Equal(RejectReasons.Replay, second.Reason);
    }

    [Fact]
    public async Task Expired_message_is_rejected()
    {
        var d = CreateDispatcher();
        var msg = MessageFactory.Freeze(_clock, "notif-exp-0001", _instance, _routing);
        msg.ExpiresAtMs = msg.IssuedAtMs + 1_000;
        _clock.AdvanceMs(2_000);

        var r = await d.DispatchAsync(msg);
        Assert.Equal(RouteResults.Expired, r.Result);
    }

    [Fact]
    public async Task Wrong_protocol_version_is_rejected()
    {
        var d = CreateDispatcher();
        var msg = MessageFactory.Health(_clock);
        msg.ProtocolVersion = 99;
        var r = await d.DispatchAsync(msg);
        Assert.Equal(RouteResults.ProtocolMismatch, r.Result);
    }

    [Fact]
    public async Task Daemon_restart_drops_runtime_handles()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-rst-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);

        d.State.ResetForRestart();
        Assert.Equal(0, d.State.LiveOwnerCount);
        Assert.Equal(0, d.State.LiveAdapterCount);
        Assert.Equal(0, d.State.SnapshotCount);

        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-rst-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Stale, act.Result);
    }

    [Fact]
    public async Task Freeze_does_not_log_or_store_raw_session_in_snapshot()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-priv-0001", _instance, _routing));
        var snap = d.State.GetSnapshot(freeze.SnapshotId!);
        Assert.NotNull(snap);
        // Snapshot holds routingKey (opaque) and instanceKey UUID, never raw session id field.
        Assert.Equal(_routing, snap!.RoutingKey);
        Assert.DoesNotContain("session-under-test", snap.RoutingKey);
        Assert.Null(snap.GetType().GetProperty("RawSessionId"));
    }

    [Fact]
    public async Task Chrome_and_edge_owners_same_session_are_ambiguous()
    {
        var d = CreateDispatcher();
        var a1 = MessageFactory.RegisterAdapter(_clock, "adapter-chrome", "chrome");
        await d.DispatchAsync(a1);
        d.TrySetActivator("adapter-chrome", MockAdapterActivator.ConfirmSessionUrl);
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, "adapter-chrome", "owner-chrome-1", "page-chrome-1", _instance, _routing));

        var a2 = MessageFactory.RegisterAdapter(_clock, "adapter-edge", "edge");
        await d.DispatchAsync(a2);
        d.TrySetActivator("adapter-edge", MockAdapterActivator.ConfirmSessionUrl);
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, "adapter-edge", "owner-edge-1", "page-edge-1", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-x-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ambiguous, freeze.Result);
        Assert.Equal(2, freeze.CandidateCount);
    }

    [Fact]
    public async Task Health_reports_daemon_and_counts()
    {
        var d = CreateDispatcher();
        var r = await d.DispatchAsync(MessageFactory.Health(_clock));
        Assert.Equal(RouteResults.Ok, r.Result);
        Assert.False(string.IsNullOrEmpty(r.DaemonId));
        Assert.Equal(0, r.LiveOwners);
        Assert.Null(r.RoutingFingerprint);
    }

    [Fact]
    public async Task Health_reports_only_fingerprints_for_a_unique_owner()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-health", "owner-health", "page-health");

        var r = await d.DispatchAsync(MessageFactory.Health(_clock));
        Assert.Equal(1, r.LiveOwners);
        Assert.Equal("mock", r.AdapterKind);
        Assert.Equal(RoutingKey.Fingerprint(_routing), r.RoutingFingerprint);
        Assert.Equal(RoutingKey.FingerprintInstance(_instance), r.InstanceFingerprint);
        Assert.NotEqual(_routing, r.RoutingFingerprint);
        Assert.NotEqual(_instance, r.InstanceFingerprint);
    }

    private RouteDispatcher CreateDispatcher()
    {
        var state = new RouteStateMachine(_clock, daemonId: "test-daemon");
        return new RouteDispatcher(state, _clock);
    }

    private async Task RegisterMockOwnerAsync(
        RouteDispatcher d,
        string adapterKey,
        string ownerKey,
        string pageKey,
        string? pageFingerprint = null,
        int? leaseTtlMs = null)
    {
        var regA = MessageFactory.RegisterAdapter(_clock, adapterKey, "mock", leaseTtlMs);
        var ra = await d.DispatchAsync(regA);
        Assert.Equal(RouteResults.Ok, ra.Result);
        d.TrySetActivator(adapterKey, MockAdapterActivator.ConfirmSessionUrl);

        var regO = MessageFactory.RegisterOwner(
            _clock, adapterKey, ownerKey, pageKey, _instance, _routing, pageFingerprint, leaseTtlMs);
        var ro = await d.DispatchAsync(regO);
        Assert.Equal(RouteResults.Ok, ro.Result);
    }
}
