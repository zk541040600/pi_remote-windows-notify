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
    private readonly HashSet<string> _registeredMockAdapters = new(StringComparer.Ordinal);

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
    public async Task Frozen_owner_key_cannot_be_reparented_to_a_reconnecting_adapter()
    {
        var d = CreateDispatcher();
        await d.DispatchAsync(
            MessageFactory.RegisterAdapter(_clock, "adapter-chrome-owner", "chrome"));
        d.TrySetActivator("adapter-chrome-owner", MockAdapterActivator.ConfirmSessionUrl);
        var chromeOwner = MessageFactory.RegisterOwner(
            _clock,
            "adapter-chrome-owner",
            "chrome",
            "owner-frozen-identity",
            "page-frozen-chrome",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-frozen-chrome",
            openedAtMs: _clock.UtcNowMs);
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(chromeOwner)).Result);

        var frozen = await d.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-owner-reparent", _instance, _routing));
        Assert.Equal(RouteResults.Ready, frozen.Result);
        Assert.Equal("chrome", frozen.AdapterKind);

        await d.DispatchAsync(
            MessageFactory.RegisterAdapter(_clock, "adapter-desktop-owner", "pi-web-desktop"));
        var reparent = MessageFactory.RegisterOwner(
            _clock,
            "adapter-desktop-owner",
            "pi-web-desktop",
            "owner-frozen-identity",
            "page-frozen-desktop",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.Restore);
        var rejected = await d.DispatchAsync(reparent);
        Assert.Equal(RouteResults.Rejected, rejected.Result);
        Assert.Equal(RejectReasons.OwnerChanged, rejected.Reason);

        var activation = await d.DispatchAsync(
            MessageFactory.Activate(_clock, "notif-owner-reparent", frozen.SnapshotId!));
        Assert.Equal(RouteResults.SessionUrlConfirmed, activation.Result);

        var nextFreeze = await d.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-owner-reparent-next", _instance, _routing));
        Assert.Equal(RouteResults.Ready, nextFreeze.Result);
        Assert.Equal("chrome", nextFreeze.AdapterKind);
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
            _clock, "adapter-1", "mock", "owner-001", "page-002", _instance, _routing, pageFingerprint: "fp-2");
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

        await d.DispatchAsync(MessageFactory.UnregisterOwner(
            _clock,
            "adapter-1",
            "owner-001"));
        var act = await d.DispatchAsync(MessageFactory.Activate(_clock, "notif-gone-0001", freeze.SnapshotId!));
        Assert.Equal(RouteResults.Stale, act.Result);
    }

    [Fact]
    public async Task Register_adapter_is_a_restart_barrier_for_old_owners()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-restart-barrier";
        await RegisterMockOwnerAsync(
            d,
            adapterKey,
            "owner-before-restart",
            "page-before-restart");

        var frozen = await d.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-adapter-restart",
                _instance,
                _routing));
        Assert.Equal(RouteResults.Ready, frozen.Result);

        var restarted = await d.DispatchAsync(
            MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "mock",
                adapterGeneration: "generation-after-restart-barrier",
                adapterStartedAtMs: _clock.UtcNowMs + 1));
        Assert.Equal(RouteResults.Ok, restarted.Result);
        Assert.Empty(d.State.ListOwners(_instance, _routing));

        var stale = await d.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-adapter-restart",
                frozen.SnapshotId!));
        Assert.Equal(RouteResults.Stale, stale.Result);
        Assert.Equal(RejectReasons.LeaseExpired, stale.Reason);

        var restored = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "mock",
            "owner-after-restart",
            "page-after-restart",
            _instance,
            _routing,
            adapterGeneration: "generation-after-restart-barrier");
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(restored)).Result);

        var next = await d.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-adapter-restart-next",
                _instance,
                _routing));
        Assert.Equal(RouteResults.Ready, next.Result);
        Assert.Equal(1, next.CandidateCount);
    }

    [Fact]
    public async Task Adapter_generation_rejects_stale_runtime_messages_and_retry_is_not_a_barrier()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-generation-proof";
        const string oldGeneration = "generation-old-runtime-001";
        const string newGeneration = "generation-new-runtime-002";
        var oldStartedAtMs = _clock.UtcNowMs;

        var first = MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs);
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(first)).Result);
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterOwner(
                _clock,
                adapterKey,
                "chrome",
                "owner-generation-proof-old",
                "page-generation-proof-old",
                _instance,
                _routing,
                adapterGeneration: oldGeneration))).Result);

        // Lost-ack retry from the same runtime refreshes the lease; it must not
        // destroy owners that this exact runtime already published.
        var sameGenerationRetry = MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs);
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(sameGenerationRetry)).Result);
        Assert.Single(d.State.ListOwners(_instance, _routing));

        _clock.AdvanceMs(10);
        var newStartedAtMs = _clock.UtcNowMs;
        var replacement = MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: newGeneration,
            adapterStartedAtMs: newStartedAtMs);
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(replacement)).Result);
        Assert.Empty(d.State.ListOwners(_instance, _routing));
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterOwner(
                _clock,
                adapterKey,
                "chrome",
                "owner-generation-proof-new",
                "page-generation-proof-new",
                _instance,
                _routing,
                adapterGeneration: newGeneration))).Result);

        var staleHeartbeat = MessageFactory.Create(MessageTypes.Heartbeat, _clock);
        staleHeartbeat.AdapterKey = adapterKey;
        staleHeartbeat.AdapterGeneration = oldGeneration;
        staleHeartbeat.LeaseTtlMs = ProtocolConstants.DefaultLeaseTtlMs;
        var staleHeartbeatResult = await d.DispatchAsync(staleHeartbeat);
        Assert.Equal(RouteResults.AdapterUnavailable, staleHeartbeatResult.Result);
        Assert.Equal(
            RejectReasons.AdapterGenerationChanged,
            staleHeartbeatResult.Reason);

        var staleUnregister = MessageFactory.UnregisterOwner(
            _clock,
            adapterKey,
            "owner-generation-proof-new",
            adapterGeneration: oldGeneration);
        var staleUnregisterResult = await d.DispatchAsync(staleUnregister);
        Assert.Equal(RouteResults.AdapterUnavailable, staleUnregisterResult.Result);
        Assert.Single(d.State.ListOwners(_instance, _routing));

        var staleOwner = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-generation-proof-stale",
            "page-generation-proof-stale",
            _instance,
            _routing,
            adapterGeneration: oldGeneration);
        var staleOwnerResult = await d.DispatchAsync(staleOwner);
        Assert.Equal(RouteResults.AdapterUnavailable, staleOwnerResult.Result);
        Assert.Single(d.State.ListOwners(_instance, _routing));

        // An older runtime whose register frame arrives late cannot take the
        // adapter back from the newer process generation.
        var lateOldRegister = MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs);
        var lateOldResult = await d.DispatchAsync(lateOldRegister);
        Assert.Equal(RouteResults.AdapterUnavailable, lateOldResult.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, lateOldResult.Reason);
        Assert.Single(d.State.ListOwners(_instance, _routing));
    }

    [Fact]
    public async Task Adapter_generation_high_water_rejects_stale_register_after_successor_unregisters()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-generation-unregister-fence";
        const string oldGeneration = "generation-unregister-old-001";
        const string newGeneration = "generation-unregister-new-002";
        var oldStartedAtMs = _clock.UtcNowMs;
        var newStartedAtMs = oldStartedAtMs + 1;

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: oldGeneration,
                adapterStartedAtMs: oldStartedAtMs))).Result);
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: newGeneration,
                adapterStartedAtMs: newStartedAtMs))).Result);

        var unregister = MessageFactory.Create(MessageTypes.UnregisterAdapter, _clock);
        unregister.AdapterKey = adapterKey;
        unregister.AdapterGeneration = newGeneration;
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(unregister)).Result);

        var stale = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs));

        Assert.Equal(RouteResults.AdapterUnavailable, stale.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, stale.Reason);
        Assert.Equal(0, d.State.LiveAdapterCount);
    }

    [Fact]
    public async Task Adapter_generation_high_water_survives_lease_expiry_and_clock_rollback()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-generation-expiry-fence";
        const string oldGeneration = "generation-expiry-old-001";
        const string newGeneration = "generation-expiry-new-002";
        var oldStartedAtMs = _clock.UtcNowMs;
        var newStartedAtMs = oldStartedAtMs + 1;

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                leaseTtlMs: ProtocolConstants.MinLeaseTtlMs,
                adapterGeneration: oldGeneration,
                adapterStartedAtMs: oldStartedAtMs))).Result);
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                leaseTtlMs: ProtocolConstants.MinLeaseTtlMs,
                adapterGeneration: newGeneration,
                adapterStartedAtMs: newStartedAtMs))).Result);

        _clock.AdvanceMs(ProtocolConstants.MinLeaseTtlMs + 1);
        Assert.Equal(0, d.State.LiveAdapterCount);

        var staleAfterExpiry = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs));
        Assert.Equal(RouteResults.AdapterUnavailable, staleAfterExpiry.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, staleAfterExpiry.Reason);

        _clock.SetMs(oldStartedAtMs - 60 * 60_000);
        var staleAfterRollback = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs));
        Assert.Equal(RouteResults.AdapterUnavailable, staleAfterRollback.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, staleAfterRollback.Reason);

        var sameSuccessor = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: newGeneration,
            adapterStartedAtMs: newStartedAtMs));
        Assert.Equal(RouteResults.Ok, sameSuccessor.Result);
    }

    [Fact]
    public async Task Adapter_generation_high_water_is_cleared_by_daemon_restart()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-generation-restart-fence";
        const string oldGeneration = "generation-restart-old-001";
        const string newGeneration = "generation-restart-new-002";
        var oldStartedAtMs = _clock.UtcNowMs;

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: oldGeneration,
                adapterStartedAtMs: oldStartedAtMs))).Result);
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: newGeneration,
                adapterStartedAtMs: oldStartedAtMs + 1))).Result);

        d.State.ResetForRestart();

        var restored = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: oldGeneration,
            adapterStartedAtMs: oldStartedAtMs));
        Assert.Equal(RouteResults.Ok, restored.Result);
    }

    [Fact]
    public async Task Adapter_generation_high_water_rejects_new_keys_at_a_bounded_capacity()
    {
        var d = CreateDispatcher();
        const int expectedFenceCapacity =
            ProtocolConstants.MaxAdapterGenerationFences;
        var firstStartedAtMs = _clock.UtcNowMs;

        for (var index = 0; index < expectedFenceCapacity; index++)
        {
            var adapterKey = $"adapter-fence-capacity-{index:D4}";
            var generation = $"generation-fence-current-{index:D4}";
            if (index == 0)
            {
                Assert.Equal(
                    RouteResults.Ok,
                    (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                        _clock,
                        adapterKey,
                        "chrome",
                        adapterGeneration: "generation-fence-stale-0000",
                        adapterStartedAtMs: firstStartedAtMs))).Result);
            }

            Assert.Equal(
                RouteResults.Ok,
                (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                    _clock,
                    adapterKey,
                    "chrome",
                    adapterGeneration: generation,
                    adapterStartedAtMs: firstStartedAtMs + index + 1))).Result);

            var unregister = MessageFactory.Create(
                MessageTypes.UnregisterAdapter,
                _clock);
            unregister.AdapterKey = adapterKey;
            unregister.AdapterGeneration = generation;
            Assert.Equal(
                RouteResults.Ok,
                (await d.DispatchAsync(unregister)).Result);
        }

        Assert.Equal(0, d.State.LiveAdapterCount);
        var overflow = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            "adapter-fence-capacity-overflow",
            "chrome",
            adapterGeneration: "generation-fence-overflow-0001",
            adapterStartedAtMs: firstStartedAtMs + expectedFenceCapacity + 1));
        Assert.Equal(RouteResults.Rejected, overflow.Result);
        Assert.Equal(RejectReasons.Capacity, overflow.Reason);
        Assert.Equal(0, d.State.LiveAdapterCount);

        var stale = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            "adapter-fence-capacity-0000",
            "chrome",
            adapterGeneration: "generation-fence-stale-0000",
            adapterStartedAtMs: firstStartedAtMs));
        Assert.Equal(RouteResults.AdapterUnavailable, stale.Result);
        Assert.Equal(RejectReasons.AdapterGenerationChanged, stale.Reason);
    }

    [Fact]
    public async Task Clock_rollback_invalidates_runtime_state_and_allows_same_generation_to_reregister()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-generation-clock-rollback";
        const string generation = "generation-clock-rollback-001";
        var startedAtMs = _clock.UtcNowMs;

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome",
                adapterGeneration: generation,
                adapterStartedAtMs: startedAtMs))).Result);
        var explicitOwner = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "chrome",
            "owner-generation-clock-rollback",
            "page-generation-clock-rollback",
            _instance,
            _routing,
            adapterGeneration: generation);
        explicitOwner.OwnerEvent = OwnerEvents.ExplicitOpen;
        explicitOwner.OpenEventId = "event-generation-clock-rollback";
        explicitOwner.OpenedAtMs = startedAtMs;
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(explicitOwner)).Result);
        var frozen = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-generation-clock-rollback",
            _instance,
            _routing));
        Assert.Equal(RouteResults.Ready, frozen.Result);
        var activation = await d.DispatchAsync(MessageFactory.Activate(
            _clock,
            "notif-generation-clock-rollback",
            frozen.SnapshotId!));
        Assert.Equal(RouteResults.Accepted, activation.Result);

        _clock.SetMs(startedAtMs - 60 * 60_000);
        var retry = await d.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            "chrome",
            adapterGeneration: generation,
            adapterStartedAtMs: startedAtMs));

        Assert.Equal(RouteResults.Ok, retry.Result);
        Assert.Empty(d.State.ListOwners(_instance, _routing));
        Assert.Equal(0, d.State.SnapshotCount);
        var oldStatus = await d.DispatchAsync(MessageFactory.ActivationStatus(
            _clock,
            activation.ActivationRequestId!));
        Assert.Equal(RouteResults.Miss, oldStatus.Result);
        Assert.Equal(RejectReasons.ActivationUnknown, oldStatus.Reason);

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterOwner(
                _clock,
                adapterKey,
                "chrome",
                "owner-generation-clock-restored",
                "page-generation-clock-restored",
                _instance,
                _routing,
                adapterGeneration: generation))).Result);
        var restored = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-generation-clock-restored",
            _instance,
            _routing));
        Assert.Equal(RouteResults.Ready, restored.Result);
    }

    [Fact]
    public void Handle_uses_one_clock_observation_for_validation_sweep_and_mutation()
    {
        const long now = 1_700_000_000_000;
        var clock = new CountingClock(now);
        var state = new RouteStateMachine(clock, daemonId: "clock-observation");
        var message = MessageFactory.Health(new FakeClock(now));
        var readsBeforeHandle = clock.ReadCount;

        var response = state.Handle(message);

        Assert.Equal(RouteResults.Ok, response.Result);
        Assert.Equal(readsBeforeHandle + 1, clock.ReadCount);
    }

    [Fact]
    public async Task Register_owner_atomically_replaces_an_unacknowledged_predecessor()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-owner-replacement";
        const string oldOwnerKey = "owner-replacement-old";
        const string newOwnerKey = "owner-replacement-new";
        await RegisterMockOwnerAsync(
            d,
            adapterKey,
            oldOwnerKey,
            "page-replacement-old");

        // Model a lost unregister-owner request/ack: the predecessor remains in
        // Route Host when the client publishes the new document owner.
        var replacement = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "mock",
            newOwnerKey,
            "page-replacement-new",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.Restore,
            replacesOwnerKey: oldOwnerKey);
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(replacement)).Result);

        var owners = d.State.ListOwners(_instance, _routing);
        Assert.Single(owners);
        Assert.Equal(newOwnerKey, owners[0].OwnerKey);

        var freeze = await d.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-owner-replacement",
                _instance,
                _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal(1, freeze.CandidateCount);

        // A lost register-owner acknowledgement can retry the same atomic swap
        // after the predecessor has already gone.
        var retry = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            "mock",
            newOwnerKey,
            "page-replacement-new",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.Restore,
            replacesOwnerKey: oldOwnerKey);
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(retry)).Result);
        Assert.Single(d.State.ListOwners(_instance, _routing));
    }

    [Fact]
    public async Task Heartbeat_reports_missing_adapter_and_owner_instead_of_false_refresh()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-heartbeat-proof";

        var missingAdapter = MessageFactory.Create(MessageTypes.Heartbeat, _clock);
        missingAdapter.AdapterKey = adapterKey;
        missingAdapter.AdapterGeneration =
            MessageFactory.DefaultAdapterGeneration(adapterKey);
        missingAdapter.LeaseTtlMs = ProtocolConstants.DefaultLeaseTtlMs;
        var adapterResult = await d.DispatchAsync(missingAdapter);
        Assert.Equal(RouteResults.AdapterUnavailable, adapterResult.Result);
        Assert.Equal(RejectReasons.AdapterUnknown, adapterResult.Reason);

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(
                MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"))).Result);
        var missingOwner = MessageFactory.Create(MessageTypes.Heartbeat, _clock);
        missingOwner.AdapterKey = adapterKey;
        missingOwner.AdapterGeneration =
            MessageFactory.DefaultAdapterGeneration(adapterKey);
        missingOwner.OwnerKey = "owner-heartbeat-proof";
        missingOwner.LeaseTtlMs = ProtocolConstants.DefaultLeaseTtlMs;
        var ownerResult = await d.DispatchAsync(missingOwner);
        Assert.Equal(RouteResults.Stale, ownerResult.Result);
        Assert.Equal(RejectReasons.OwnerChanged, ownerResult.Reason);
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
    public async Task Reused_requestId_with_different_message_is_rejected()
    {
        var d = CreateDispatcher();
        var first = MessageFactory.Create(
            MessageTypes.Health,
            _clock,
            requestId: "request-body-conflict");
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(first)).Result);

        var conflicting = MessageFactory.RegisterAdapter(
            _clock,
            "adapter-request-body-conflict",
            "chrome");
        conflicting.RequestId = first.RequestId;
        var result = await d.DispatchAsync(conflicting);

        Assert.Equal(RouteResults.Rejected, result.Result);
        Assert.Equal(RejectReasons.RequestIdConflict, result.Reason);
        Assert.Equal(0, d.State.LiveAdapterCount);
    }

    [Fact]
    public async Task Concurrent_identical_activate_invokes_in_process_adapter_once()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-concurrent-activate";
        await RegisterMockOwnerAsync(
            d,
            adapterKey,
            "owner-concurrent-activate",
            "page-concurrent-activate");
        var entered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var callCount = 0;
        d.TrySetActivator(
            adapterKey,
            new MockAdapterActivator(async (_, cancellationToken) =>
            {
                Interlocked.Increment(ref callCount);
                entered.TrySetResult(true);
                await release.Task.WaitAsync(cancellationToken);
                return new AdapterActivateResult
                {
                    Result = RouteResults.SessionUrlConfirmed,
                    ElapsedMs = 1
                };
            }));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-concurrent-activate",
            _instance,
            _routing));
        var activate = MessageFactory.Activate(
            _clock,
            "notif-concurrent-activate",
            freeze.SnapshotId!);
        var firstTask = d.DispatchAsync(activate);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var duplicateTask = d.DispatchAsync(activate);

        Assert.Equal(1, Volatile.Read(ref callCount));
        release.TrySetResult(true);
        var firstResult = await firstTask;
        var duplicateResult = await duplicateTask;
        Assert.Equal(RouteResults.SessionUrlConfirmed, firstResult.Result);
        Assert.Equal(RouteResults.Pending, duplicateResult.Result);
        Assert.Equal(RejectReasons.Replay, duplicateResult.Reason);
    }

    [Fact]
    public async Task External_activate_revalidates_the_target_at_queue_commit()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-queue-commit";
        const string ownerKey = "owner-queue-commit";
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock,
                adapterKey,
                "chrome"))).Result);
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.RegisterOwner(
                _clock,
                adapterKey,
                "chrome",
                ownerKey,
                "page-queue-commit",
                _instance,
                _routing))).Result);
        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-queue-commit",
            _instance,
            _routing));
        var activate = MessageFactory.Activate(
            _clock,
            "notif-queue-commit",
            freeze.SnapshotId!);
        var (early, snapshot, adapter) = d.State.BeginActivate(activate);
        Assert.Null(early);
        Assert.NotNull(snapshot);
        Assert.NotNull(adapter);

        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(MessageFactory.UnregisterOwner(
                _clock,
                adapterKey,
                ownerKey))).Result);
        var result = d.State.EnqueuePendingActivation(
            activate,
            snapshot!,
            adapter!);

        Assert.Equal(RouteResults.Stale, result.Result);
        Assert.Equal(0, d.State.PendingActivationCount);
    }

    [Fact]
    public async Task Reused_activate_nonce_with_a_new_requestId_does_not_repeat_the_side_effect()
    {
        var d = CreateDispatcher();
        const string adapterKey = "adapter-activate-nonce";
        await RegisterMockOwnerAsync(
            d,
            adapterKey,
            "owner-activate-nonce",
            "page-activate-nonce");
        var callCount = 0;
        d.TrySetActivator(
            adapterKey,
            new MockAdapterActivator((_, _) =>
            {
                Interlocked.Increment(ref callCount);
                return Task.FromResult(new AdapterActivateResult
                {
                    Result = RouteResults.SessionUrlConfirmed,
                    ElapsedMs = 1
                });
            }));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(
            _clock,
            "notif-activate-nonce",
            _instance,
            _routing));
        var first = MessageFactory.Activate(
            _clock,
            "notif-activate-nonce",
            freeze.SnapshotId!);
        first.Nonce = "nonce-activate-side-effect";
        var firstResult = await d.DispatchAsync(first);

        var duplicate = MessageFactory.Activate(
            _clock,
            "notif-activate-nonce",
            freeze.SnapshotId!);
        duplicate.Nonce = first.Nonce;
        var duplicateResult = await d.DispatchAsync(duplicate);

        Assert.Equal(RouteResults.SessionUrlConfirmed, firstResult.Result);
        Assert.Equal(RouteResults.Replay, duplicateResult.Result);
        Assert.Equal(RejectReasons.Replay, duplicateResult.Reason);
        Assert.Equal(1, Volatile.Read(ref callCount));
    }

    [Fact]
    public async Task Replay_cache_never_exceeds_its_entry_limit_when_requests_include_nonces()
    {
        var d = CreateDispatcher();

        for (var index = 0; index <= ProtocolConstants.MaxReplayEntries / 2; index++)
        {
            var message = MessageFactory.Create(
                MessageTypes.Health,
                _clock,
                requestId: $"request-{index:D4}",
                nonce: $"nonce-{index:D4}");
            var response = await d.DispatchAsync(message);
            Assert.Equal(RouteResults.Ok, response.Result);
        }

        var replayField = typeof(RouteStateMachine).GetField(
            "_replay",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        var replayEntries = Assert.IsAssignableFrom<System.Collections.IDictionary>(
            replayField!.GetValue(d.State));

        Assert.True(
            replayEntries.Count <= ProtocolConstants.MaxReplayEntries,
            $"Replay cache contained {replayEntries.Count} entries.");
    }

    [Fact]
    public async Task Reused_nonce_does_not_overwrite_the_original_replay_record()
    {
        var d = CreateDispatcher();
        var first = MessageFactory.Create(
            MessageTypes.Health,
            _clock,
            requestId: "request-original-nonce-record",
            nonce: "nonce-original-record");
        Assert.Equal(RouteResults.Ok, (await d.DispatchAsync(first)).Result);

        var collision = MessageFactory.Create(
            MessageTypes.Health,
            _clock,
            requestId: "request-colliding-nonce-record",
            nonce: first.Nonce);
        var collisionResult = await d.DispatchAsync(collision);
        Assert.Equal(RouteResults.Replay, collisionResult.Result);

        var replayField = typeof(RouteStateMachine).GetField(
            "_replay",
            System.Reflection.BindingFlags.Instance |
            System.Reflection.BindingFlags.NonPublic);
        var replayEntries = Assert.IsAssignableFrom<System.Collections.IDictionary>(
            replayField!.GetValue(d.State));
        replayEntries.Remove(first.RequestId);

        var recovered = await d.DispatchAsync(first);
        Assert.Equal(RouteResults.Ok, recovered.Result);
        Assert.Equal(RejectReasons.Replay, recovered.Reason);
    }

    [Fact]
    public async Task Notification_id_cannot_replay_a_snapshot_with_a_different_kind()
    {
        var d = CreateDispatcher();
        await RegisterMockOwnerAsync(d, "adapter-1", "owner-001", "page-001");

        var first = await d.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-kind-immutable",
                _instance,
                _routing,
                "ask-user"));
        Assert.Equal(RouteResults.Ready, first.Result);

        var conflicting = await d.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-kind-immutable",
                _instance,
                _routing,
                "turn-complete"));
        Assert.Equal(RouteResults.Rejected, conflicting.Result);
        Assert.Equal(RejectReasons.SnapshotMismatch, conflicting.Reason);
        Assert.Null(conflicting.SnapshotId);

        var activation = await d.DispatchAsync(
            MessageFactory.Activate(
                _clock,
                "notif-kind-immutable",
                first.SnapshotId!));
        Assert.Equal(RouteResults.SessionUrlConfirmed, activation.Result);
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
            _clock, "adapter-chrome", "chrome", "owner-chrome-1", "page-chrome-1", _instance, _routing));

        var a2 = MessageFactory.RegisterAdapter(_clock, "adapter-edge", "edge");
        await d.DispatchAsync(a2);
        d.TrySetActivator("adapter-edge", MockAdapterActivator.ConfirmSessionUrl);
        await d.DispatchAsync(MessageFactory.RegisterOwner(
            _clock, "adapter-edge", "edge", "owner-edge-1", "page-edge-1", _instance, _routing));

        var freeze = await d.DispatchAsync(MessageFactory.Freeze(_clock, "notif-x-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ambiguous, freeze.Result);
        Assert.Equal(2, freeze.CandidateCount);
    }

    [Fact]
    public async Task Live_adapter_key_cannot_be_reused_by_another_surface_identity()
    {
        var d = CreateDispatcher();
        const string sharedAdapterKey = "adapter-shared-collision";

        var chromeAdapter = MessageFactory.RegisterAdapter(
            _clock, sharedAdapterKey, "chrome");
        chromeAdapter.BrowserKind = "chrome";
        chromeAdapter.ProfileKey = "profile-chrome-original";
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(chromeAdapter)).Result);

        var chromeOwner = MessageFactory.RegisterOwner(
            _clock,
            sharedAdapterKey,
            "chrome",
            "owner-chrome-original",
            "page-chrome-original",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-chrome-original",
            openedAtMs: _clock.UtcNowMs);
        chromeOwner.AdapterKind = "chrome";
        chromeOwner.BrowserKind = "chrome";
        chromeOwner.ProfileKey = "profile-chrome-original";
        Assert.Equal(
            RouteResults.Ok,
            (await d.DispatchAsync(chromeOwner)).Result);

        var desktopCollision = MessageFactory.RegisterAdapter(
            _clock, sharedAdapterKey, "pi-web-desktop");
        desktopCollision.BrowserKind = "pi-web-desktop";
        desktopCollision.ProfileKey = "profile-desktop-collision";
        var adapterRejected = await d.DispatchAsync(desktopCollision);
        Assert.Equal(RouteResults.Rejected, adapterRejected.Result);
        Assert.Equal(RejectReasons.InvalidField, adapterRejected.Reason);

        var desktopOwner = MessageFactory.RegisterOwner(
            _clock,
            sharedAdapterKey,
            "pi-web-desktop",
            "owner-desktop-collision",
            "page-desktop-collision",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-desktop-collision",
            openedAtMs: _clock.UtcNowMs - 1);
        desktopOwner.AdapterKind = "pi-web-desktop";
        desktopOwner.BrowserKind = "pi-web-desktop";
        desktopOwner.ProfileKey = "profile-desktop-collision";
        var ownerRejected = await d.DispatchAsync(desktopOwner);
        Assert.Equal(RouteResults.Rejected, ownerRejected.Result);
        Assert.Equal(RejectReasons.InvalidField, ownerRejected.Reason);

        var freeze = await d.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-adapter-collision", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal("chrome", freeze.AdapterKind);
        Assert.Equal(1, freeze.CandidateCount);
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
        if (_registeredMockAdapters.Add(adapterKey))
        {
            var regA = MessageFactory.RegisterAdapter(_clock, adapterKey, "mock", leaseTtlMs);
            var ra = await d.DispatchAsync(regA);
            Assert.Equal(RouteResults.Ok, ra.Result);
            d.TrySetActivator(adapterKey, MockAdapterActivator.ConfirmSessionUrl);
        }

        var regO = MessageFactory.RegisterOwner(
            _clock, adapterKey, "mock", ownerKey, pageKey, _instance, _routing, pageFingerprint, leaseTtlMs);
        var ro = await d.DispatchAsync(regO);
        Assert.Equal(RouteResults.Ok, ro.Result);
    }

    private sealed class CountingClock(long utcNowMs) : IClock
    {
        public int ReadCount { get; private set; }

        public long UtcNowMs
        {
            get
            {
                ReadCount++;
                return utcNowMs;
            }
        }
    }
}
