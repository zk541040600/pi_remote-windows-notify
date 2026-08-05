using System.Text;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class RecoveryTicketTests
{
    private readonly FakeClock _clock = new(1_700_000_000_000);
    private readonly string _instance =
        "11111111-2222-3333-4444-555555555555";
    private readonly string _routing;

    public RecoveryTicketTests()
    {
        _routing = RoutingKey.Compute(
            _instance,
            "recovery-session-never-leaves-the-host");
    }

    [Fact]
    public async Task Owner_restore_resolves_one_ticket_to_one_snapshot_and_one_activation()
    {
        var dispatcher = CreateDispatcher();
        var pending = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-owner",
                _instance,
                _routing,
                "turn-complete",
                ProtocolConstants.DefaultRecoveryTicketTtlMs));

        Assert.Equal(RouteResults.Recovering, pending.Result);
        Assert.Equal(RouteResults.OwnerUnresolved, pending.Reason);
        Assert.Null(pending.SnapshotId);
        Assert.False(string.IsNullOrWhiteSpace(pending.RecoveryTicketId));

        var activationCount = 0;
        await RegisterOwnerAsync(
            dispatcher,
            "adapter-recovery-owner",
            "owner-recovery-owner",
            "page-recovery-owner",
            explicitOpen: true);
        dispatcher.TrySetActivator(
            "adapter-recovery-owner",
            new MockAdapterActivator((_, _) =>
            {
                Interlocked.Increment(ref activationCount);
                return Task.FromResult(new AdapterActivateResult
                {
                    Result = RouteResults.SessionUrlConfirmed,
                    ElapsedMs = 1,
                });
            }));

        var resolved = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-owner",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Ready, resolved.Result);
        Assert.False(string.IsNullOrWhiteSpace(resolved.SnapshotId));
        Assert.Equal(pending.RecoveryTicketId, resolved.RecoveryTicketId);

        var replay = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-owner",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Ready, replay.Result);
        Assert.Equal(resolved.SnapshotId, replay.SnapshotId);

        var first = await dispatcher.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-recovery-owner",
                resolved.SnapshotId!));
        var duplicate = await dispatcher.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-recovery-owner",
                resolved.SnapshotId!));

        Assert.Equal(RouteResults.SessionUrlConfirmed, first.Result);
        Assert.Equal(RouteResults.SessionUrlConfirmed, duplicate.Result);
        Assert.Equal(first.ActivationRequestId, duplicate.ActivationRequestId);
        Assert.Equal(1, Volatile.Read(ref activationCount));
    }

    [Fact]
    public async Task Completed_activation_retry_observes_original_result_after_owner_replacement()
    {
        var dispatcher = CreateDispatcher();
        const string adapterKey = "adapter-activation-retry-complete";
        const string oldOwnerKey = "owner-activation-retry-complete-old";
        await RegisterOwnerAsync(
            dispatcher,
            adapterKey,
            oldOwnerKey,
            "page-activation-retry-complete-old",
            explicitOpen: true);
        var callCount = 0;
        dispatcher.TrySetActivator(
            adapterKey,
            new MockAdapterActivator((_, _) =>
            {
                Interlocked.Increment(ref callCount);
                return Task.FromResult(new AdapterActivateResult
                {
                    Result = RouteResults.SessionUrlConfirmed,
                    ElapsedMs = 1,
                });
            }));

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-activation-retry-complete",
                _instance,
                _routing));
        var first = await dispatcher.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-activation-retry-complete",
                freeze.SnapshotId!));
        Assert.Equal(RouteResults.SessionUrlConfirmed, first.Result);

        Assert.Equal(
            RouteResults.Ok,
            (await dispatcher.DispatchAsync(
                MessageFactory.UnregisterOwner(
                    _clock,
                    adapterKey,
                    oldOwnerKey))).Result);
        await RegisterOwnerAsync(
            dispatcher,
            adapterKey,
            "owner-activation-retry-complete-new",
            "page-activation-retry-complete-new",
            explicitOpen: false);

        var retry = await dispatcher.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-activation-retry-complete",
                freeze.SnapshotId!));
        Assert.Equal(first.Result, retry.Result);
        Assert.Equal(first.ActivationRequestId, retry.ActivationRequestId);
        Assert.Equal(1, Volatile.Read(ref callCount));
    }

    [Fact]
    public async Task Pending_activation_retry_keeps_original_claim_when_owner_changes()
    {
        var dispatcher = CreateDispatcher();
        const string adapterKey = "adapter-activation-retry-pending";
        const string oldOwnerKey = "owner-activation-retry-pending-old";
        await RegisterOwnerAsync(
            dispatcher,
            adapterKey,
            oldOwnerKey,
            "page-activation-retry-pending-old",
            explicitOpen: true);
        var entered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var callCount = 0;
        dispatcher.TrySetActivator(
            adapterKey,
            new MockAdapterActivator(async (_, cancellationToken) =>
            {
                Interlocked.Increment(ref callCount);
                entered.TrySetResult(true);
                await release.Task.WaitAsync(cancellationToken);
                return new AdapterActivateResult
                {
                    Result = RouteResults.SessionUrlConfirmed,
                    ElapsedMs = 1,
                };
            }));

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-activation-retry-pending",
                _instance,
                _routing));
        var firstRequest = MessageFactory.Activate(
            _clock,
            "notif-activation-retry-pending",
            freeze.SnapshotId!);
        var firstTask = dispatcher.DispatchAsync(firstRequest);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        RouteResponse pendingRetry;
        try
        {
            Assert.Equal(
                RouteResults.Ok,
                (await dispatcher.DispatchAsync(
                    MessageFactory.UnregisterOwner(
                        _clock,
                        adapterKey,
                        oldOwnerKey))).Result);
            await RegisterOwnerAsync(
                dispatcher,
                adapterKey,
                "owner-activation-retry-pending-new",
                "page-activation-retry-pending-new",
                explicitOpen: false);

            pendingRetry = await dispatcher.DispatchAsync(
                MessageFactory.Activate(
                    _clock,
                    "notif-activation-retry-pending",
                    freeze.SnapshotId!));
            Assert.Equal(RouteResults.Pending, pendingRetry.Result);
            Assert.Equal(
                firstRequest.RequestId,
                pendingRetry.ActivationRequestId);
            Assert.Equal(1, Volatile.Read(ref callCount));
        }
        finally
        {
            release.TrySetResult(true);
        }

        var firstResult = await firstTask;
        Assert.Equal(RouteResults.Stale, firstResult.Result);
        Assert.Equal(firstRequest.RequestId, firstResult.ActivationRequestId);

        var finalRetry = await dispatcher.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-activation-retry-pending",
                freeze.SnapshotId!));
        Assert.Equal(firstResult.Result, finalRetry.Result);
        Assert.Equal(firstResult.Reason, finalRetry.Reason);
        Assert.Equal(firstRequest.RequestId, finalRetry.ActivationRequestId);
        Assert.Equal(1, Volatile.Read(ref callCount));
    }

    [Fact]
    public async Task Restore_only_owner_cannot_claim_an_unbound_ticket()
    {
        var dispatcher = CreateDispatcher();
        var pending = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-unbound",
                _instance,
                _routing,
                recoveryTtlMs: ProtocolConstants.DefaultRecoveryTicketTtlMs));

        await RegisterOwnerAsync(
            dispatcher,
            "adapter-recovery-unbound",
            "owner-recovery-unbound",
            "page-recovery-unbound",
            explicitOpen: false);
        var restoreOnly = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-unbound",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Recovering, restoreOnly.Result);
        Assert.Null(restoreOnly.SnapshotId);

        var openIntent = MessageFactory.RegisterOpenIntent(
            _clock,
            "adapter-recovery-unbound",
            "mock",
            _instance,
            _routing,
            "event-recovery-unbound",
            _clock.UtcNowMs);
        Assert.Equal(
            RouteResults.Ok,
            (await dispatcher.DispatchAsync(openIntent)).Result);

        var resolved = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-unbound",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Ready, resolved.Result);
        Assert.NotNull(resolved.SnapshotId);
    }

    [Fact]
    public async Task Pending_follows_authoritative_correction_but_resolved_snapshot_does_not_retarget()
    {
        var dispatcher = CreateDispatcher();
        await RegisterOwnerAsync(
            dispatcher,
            "adapter-bound-first",
            "owner-bound-first",
            "page-bound-first",
            explicitOpen: true,
            openedAtMs: _clock.UtcNowMs);
        Assert.Equal(
            RouteResults.Ok,
            (await dispatcher.DispatchAsync(
                MessageFactory.UnregisterOwner(
                    _clock,
                    "adapter-bound-first",
                    "owner-bound-first"))).Result);

        var pending = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-binding-change",
                _instance,
                _routing,
                recoveryTtlMs: ProtocolConstants.DefaultRecoveryTicketTtlMs));
        Assert.Equal(RouteResults.Recovering, pending.Result);

        await RegisterOwnerAsync(
            dispatcher,
            "adapter-bound-earlier",
            "owner-bound-earlier",
            "page-bound-earlier",
            explicitOpen: true,
            openedAtMs: _clock.UtcNowMs - 1000);

        var corrected = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-binding-change",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Ready, corrected.Result);
        Assert.Equal("mock", corrected.AdapterKind);
        Assert.NotNull(corrected.SnapshotId);

        await RegisterOwnerAsync(
            dispatcher,
            "adapter-bound-earliest",
            "owner-bound-earliest",
            "page-bound-earliest",
            explicitOpen: true,
            openedAtMs: _clock.UtcNowMs - 2000);

        var replay = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-binding-change",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Stale, replay.Result);
        Assert.Equal(RejectReasons.OwnerChanged, replay.Reason);
        Assert.Null(replay.SnapshotId);
    }

    [Fact]
    public async Task Expired_ticket_stays_terminal_after_an_owner_returns()
    {
        var dispatcher = CreateDispatcher();
        var pending = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-expired",
                _instance,
                _routing,
                recoveryTtlMs: ProtocolConstants.MinRecoveryTicketTtlMs));
        _clock.AdvanceMs(ProtocolConstants.MinRecoveryTicketTtlMs + 1);

        var expired = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-expired",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Expired, expired.Result);
        Assert.Equal(RejectReasons.RecoveryExpired, expired.Reason);

        await RegisterOwnerAsync(
            dispatcher,
            "adapter-recovery-expired",
            "owner-recovery-expired",
            "page-recovery-expired",
            explicitOpen: true);
        var stillExpired = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-expired",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Expired, stillExpired.Result);
        Assert.Null(stillExpired.SnapshotId);
    }

    [Fact]
    public async Task Expired_pending_burst_releases_capacity_and_evicted_ticket_keeps_expired_tombstone()
    {
        var dispatcher = CreateDispatcher();
        var tickets = new List<(string NotificationId, string TicketId)>();

        for (var index = 0;
             index < ProtocolConstants.MaxRecoveryTickets;
             index++)
        {
            var notificationId = $"notif-recovery-capacity-{index:D3}";
            var response = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(
                    _clock,
                    notificationId,
                    _instance,
                    _routing,
                    recoveryTtlMs:
                        ProtocolConstants.MinRecoveryTicketTtlMs));
            Assert.Equal(RouteResults.Recovering, response.Result);
            tickets.Add((notificationId, response.RecoveryTicketId!));
        }

        _clock.AdvanceMs(ProtocolConstants.MinRecoveryTicketTtlMs + 1);
        var replacement = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-capacity-replacement",
                _instance,
                _routing,
                recoveryTtlMs:
                    ProtocolConstants.MinRecoveryTicketTtlMs));

        Assert.Equal(RouteResults.Recovering, replacement.Result);
        Assert.NotEqual(RejectReasons.Capacity, replacement.Reason);

        // Capacity eviction may move one expired outcome into the bounded
        // tombstone table. Both retained terminals and that tombstone must
        // remain indistinguishable and fail closed as expired.
        foreach (var (notificationId, ticketId) in tickets)
        {
            var expired = await dispatcher.DispatchAsync(
                MessageFactory.ResolveRecovery(
                    _clock,
                    notificationId,
                    ticketId));
            Assert.Equal(RouteResults.Expired, expired.Result);
            Assert.Equal(RejectReasons.RecoveryExpired, expired.Reason);
            Assert.Equal(ticketId, expired.RecoveryTicketId);
        }
    }

    [Fact]
    public async Task Resolved_ticket_replays_its_snapshot_and_never_follows_a_new_page()
    {
        var dispatcher = CreateDispatcher();
        var pending = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-immutable",
                _instance,
                _routing,
                recoveryTtlMs: ProtocolConstants.DefaultRecoveryTicketTtlMs));
        await RegisterOwnerAsync(
            dispatcher,
            "adapter-recovery-immutable",
            "owner-recovery-old",
            "page-recovery-old",
            explicitOpen: true);
        var resolved = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-immutable",
                pending.RecoveryTicketId!));

        Assert.Equal(
            RouteResults.Ok,
            (await dispatcher.DispatchAsync(
                MessageFactory.UnregisterOwner(
                    _clock,
                    "adapter-recovery-immutable",
                    "owner-recovery-old"))).Result);
        await RegisterOwnerAsync(
            dispatcher,
            "adapter-recovery-immutable",
            "owner-recovery-new",
            "page-recovery-new",
            explicitOpen: false);

        var replay = await dispatcher.DispatchAsync(
            MessageFactory.ResolveRecovery(
                _clock,
                "notif-recovery-immutable",
                pending.RecoveryTicketId!));
        Assert.Equal(RouteResults.Ready, replay.Result);
        Assert.Equal(resolved.SnapshotId, replay.SnapshotId);

        var stale = await dispatcher.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-recovery-immutable",
                replay.SnapshotId!));
        Assert.Equal(RouteResults.Stale, stale.Result);
        Assert.Null(dispatcher.State.GetSnapshot(replay.SnapshotId!)?.LastActivateResult);
    }

    [Fact]
    public async Task Recovery_response_contains_only_opaque_handles_and_fingerprints()
    {
        var dispatcher = CreateDispatcher();
        var response = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-recovery-wire",
                _instance,
                _routing,
                recoveryTtlMs: ProtocolConstants.DefaultRecoveryTicketTtlMs));
        var json = Encoding.UTF8.GetString(response.ToUtf8Bytes());

        Assert.Contains("recoveryTicketId", json, StringComparison.Ordinal);
        Assert.DoesNotContain(_instance, json, StringComparison.Ordinal);
        Assert.DoesNotContain(_routing, json, StringComparison.Ordinal);
        Assert.DoesNotContain(
            "recovery-session-never-leaves-the-host",
            json,
            StringComparison.Ordinal);
        Assert.DoesNotContain("sessionId", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("url", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
    }

    private RouteDispatcher CreateDispatcher()
    {
        var state = new RouteStateMachine(
            _clock,
            "recovery-test-daemon",
            new MemoryRouteBindingStore());
        return new RouteDispatcher(state, _clock);
    }

    private async Task RegisterOwnerAsync(
        RouteDispatcher dispatcher,
        string adapterKey,
        string ownerKey,
        string pageKey,
        bool explicitOpen,
        long? openedAtMs = null)
    {
        if (dispatcher.State.GetAdapter(adapterKey) is null)
        {
            var adapter = await dispatcher.DispatchAsync(
                MessageFactory.RegisterAdapter(
                    _clock,
                    adapterKey,
                    "mock"));
            Assert.Equal(RouteResults.Ok, adapter.Result);
        }

        var owner = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "mock",
            ownerKey,
            pageKey,
            _instance,
            _routing,
            ownerEvent: explicitOpen
                ? OwnerEvents.ExplicitOpen
                : OwnerEvents.Restore,
            openEventId: explicitOpen
                ? "event-" + ownerKey
                : null,
            openedAtMs: explicitOpen
                ? openedAtMs ?? _clock.UtcNowMs
                : null);
        Assert.Equal(
            RouteResults.Ok,
            (await dispatcher.DispatchAsync(owner)).Result);
    }
}
