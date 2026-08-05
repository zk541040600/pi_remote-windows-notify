using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class OwnerBindingRoutingTests
{
    private readonly FakeClock _clock = new(1_700_000_000_000);
    private readonly string _instance = "11111111-2222-3333-4444-555555555555";
    private readonly string _routing;
    private readonly HashSet<(RouteDispatcher Dispatcher, string AdapterKey)>
        _registeredAdapters = [];

    public OwnerBindingRoutingTests()
    {
        _routing = RoutingKey.Compute(_instance, "sensitive-session-never-persisted");
    }

    [Fact]
    public async Task Chrome_then_desktop_and_desktop_then_chrome_bind_first_explicit_open_per_session()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-0001");
        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-0001");

        var chromeRemainsBound = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-order-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, chromeRemainsBound.Result);
        Assert.Equal("chrome", chromeRemainsBound.AdapterKind);

        var desktopFirstRouting = RoutingKey.Compute(_instance, "desktop-first-session");
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop",
            "owner-desktop-first", "page-desktop-first",
            explicitOpen: true, eventId: "event-desktop-first", routingKey: desktopFirstRouting);
        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
            "owner-chrome-later", "page-chrome-later",
            explicitOpen: true, eventId: "event-chrome-later", routingKey: desktopFirstRouting);

        var desktopRemainsBound = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-order-0002", _instance, desktopFirstRouting));
        Assert.Equal(RouteResults.Ready, desktopRemainsBound.Result);
        Assert.Equal("pi-web-desktop", desktopRemainsBound.AdapterKind);
    }

    [Fact]
    public async Task Restore_heartbeat_and_reconnect_do_not_change_winner()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-0001");
        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-0001");

        _clock.AdvanceMs(10);
        await dispatcher.DispatchAsync(MessageFactory.Create(MessageTypes.Heartbeat, _clock, nonce: "nonce-heartbeat-1")
            .Also(msg =>
            {
                msg.AdapterKey = "adapter-chrome";
                msg.AdapterGeneration =
                    MessageFactory.DefaultAdapterGeneration("adapter-chrome");
                msg.OwnerKey = "owner-chrome";
                msg.LeaseTtlMs = ProtocolConstants.DefaultLeaseTtlMs;
            }));
        await dispatcher.DispatchAsync(MessageFactory.UnregisterOwner(
            _clock,
            "adapter-chrome",
            "owner-chrome"));
        Assert.Equal(
            RouteResults.Ok,
            (await dispatcher.DispatchAsync(
                MessageFactory.RegisterAdapter(
                    _clock,
                    "adapter-chrome",
                    "chrome"))).Result);
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome-restored", "page-chrome-restored",
            explicitOpen: false);

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-restore-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal("chrome", freeze.AdapterKind);
    }

    [Fact]
    public async Task Daemon_restart_preserves_first_binding_when_restore_order_reverses()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-preference-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var first = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(first, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
                explicitOpen: true, eventId: "event-chrome-0001");
            _clock.AdvanceMs(10);
            await RegisterAsync(first, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
                explicitOpen: true, eventId: "event-desktop-0001");

            var restarted = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(restarted, "adapter-desktop", "pi-web-desktop", "owner-desktop-new", "page-desktop-new",
                explicitOpen: false);
            await RegisterAsync(restarted, "adapter-chrome", "chrome", "owner-chrome-new", "page-chrome-new",
                explicitOpen: false);

            var freeze = await restarted.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-restart-0001", _instance, _routing));
            Assert.Equal(RouteResults.Ready, freeze.Result);
            Assert.Equal("chrome", freeze.AdapterKind);

            var stateJson = File.ReadAllText(path);
            Assert.DoesNotContain("sensitive-session-never-persisted", stateJson, StringComparison.Ordinal);
            Assert.DoesNotContain("http://", stateJson, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("https://", stateJson, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Transient_binding_file_lock_recovers_the_original_document()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-locked-preference-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        var session = new SessionRouteKey(_instance, _routing);
        var identity = new AdapterBindingIdentity
        {
            AdapterKind = "chrome",
            BrowserKind = "chrome",
            ProfileKey = "profile-locked-original",
        };
        try
        {
            var original = new FileRouteBindingStore(path);
            Assert.True(original.TryBindFirstExplicitOpen(
                session,
                "adapter-locked-original",
                identity,
                "event-locked-original",
                _clock.UtcNowMs,
                out _));
            var originalBytes = File.ReadAllBytes(path);

            FileRouteBindingStore unavailable;
            using (var lockStream = new FileStream(
                       path,
                       FileMode.Open,
                       FileAccess.ReadWrite,
                       FileShare.None))
            {
                unavailable = new FileRouteBindingStore(path);
                Assert.False(unavailable.TryBindFirstExplicitOpen(
                    new SessionRouteKey(
                        _instance,
                        RoutingKey.Compute(_instance, "locked-new-session")),
                    "adapter-locked-new",
                    identity,
                    "event-locked-new",
                    _clock.UtcNowMs + 1,
                    out _));
            }

            var recovered = unavailable.GetBinding(session);
            Assert.NotNull(recovered);
            Assert.Equal("adapter-locked-original", recovered.AdapterKey);
            Assert.Equal("event-locked-original", recovered.OpenEventId);
            Assert.Equal(originalBytes, File.ReadAllBytes(path));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Daemon_restart_does_not_let_another_surface_inherit_a_persisted_adapter_key()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-restart-identity-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        const string sharedAdapterKey = "adapter-restart-collision";
        try
        {
            var first = CreateDispatcher(new FileRouteBindingStore(path));
            var chromeAdapter = MessageFactory.RegisterAdapter(
                _clock,
                sharedAdapterKey,
                "chrome");
            chromeAdapter.BrowserKind = "chrome";
            chromeAdapter.ProfileKey = "profile-chrome-original";
            Assert.Equal(
                RouteResults.Ok,
                (await first.DispatchAsync(chromeAdapter)).Result);

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
                (await first.DispatchAsync(chromeOwner)).Result);

            var restarted = CreateDispatcher(new FileRouteBindingStore(path));
            var desktopAdapter = MessageFactory.RegisterAdapter(
                _clock,
                sharedAdapterKey,
                "pi-web-desktop");
            desktopAdapter.BrowserKind = "pi-web-desktop";
            desktopAdapter.ProfileKey = "profile-desktop-collision";
            var adapterRejected = await restarted.DispatchAsync(desktopAdapter);
            Assert.Equal(RouteResults.Rejected, adapterRejected.Result);
            Assert.Equal(RejectReasons.InvalidField, adapterRejected.Reason);

            var desktopRestore = MessageFactory.RegisterOwner(
                _clock,
                sharedAdapterKey,
                "pi-web-desktop",
                "owner-desktop-collision",
                "page-desktop-collision",
                _instance,
                _routing,
                ownerEvent: OwnerEvents.Restore);
            desktopRestore.AdapterKind = "pi-web-desktop";
            desktopRestore.BrowserKind = "pi-web-desktop";
            desktopRestore.ProfileKey = "profile-desktop-collision";
            var rejected = await restarted.DispatchAsync(desktopRestore);

            Assert.Equal(RouteResults.AdapterUnavailable, rejected.Result);
            Assert.Equal(RejectReasons.AdapterUnknown, rejected.Reason);
            Assert.Empty(restarted.State.ListOwners(_instance, _routing));

            var freeze = await restarted.DispatchAsync(
                MessageFactory.Freeze(
                    _clock,
                    "notif-restart-identity-collision",
                    _instance,
                    _routing));
            Assert.Equal(RouteResults.Miss, freeze.Result);
            Assert.Null(freeze.SnapshotId);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Later_explicit_open_does_not_rewrite_the_binding_document()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-sticky-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
                "owner-chrome", "page-chrome",
                explicitOpen: true, eventId: "event-chrome-first");
            using var firstDocument = JsonDocument.Parse(
                File.ReadAllBytes(path));

            _clock.AdvanceMs(10);
            await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop",
                "owner-desktop", "page-desktop",
                explicitOpen: true, eventId: "event-desktop-later");
            using var afterLaterOpen = JsonDocument.Parse(
                File.ReadAllBytes(path));

            Assert.Equal(
                firstDocument.RootElement.GetProperty("sessions").GetRawText(),
                afterLaterOpen.RootElement.GetProperty("sessions").GetRawText());
            Assert.Equal(
                firstDocument.RootElement.GetProperty("nextRevision").GetInt64(),
                afterLaterOpen.RootElement.GetProperty("nextRevision").GetInt64());
            Assert.Equal(
                firstDocument.RootElement.GetProperty("clockEpoch").GetInt64(),
                afterLaterOpen.RootElement.GetProperty("clockEpoch").GetInt64());
            Assert.True(
                afterLaterOpen.RootElement
                    .GetProperty("clockHighWaterMs")
                    .GetInt64() >
                firstDocument.RootElement
                    .GetProperty("clockHighWaterMs")
                    .GetInt64());
            Assert.Equal(
                4,
                afterLaterOpen.RootElement.GetProperty("version").GetInt32());
            Assert.DoesNotContain(
                "adapter-desktop",
                afterLaterOpen.RootElement.GetRawText(),
                StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Frozen_and_new_notifications_keep_the_first_bound_adapter()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-0001");

        var oldFreeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-frozen-0001", _instance, _routing));
        var oldSnapshot = dispatcher.State.GetSnapshot(oldFreeze.SnapshotId!);
        Assert.Equal("owner-chrome", oldSnapshot!.OwnerKey);

        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-0001");
        var newFreeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-frozen-0002", _instance, _routing));

        Assert.Equal("owner-chrome", dispatcher.State.GetSnapshot(oldFreeze.SnapshotId!)!.OwnerKey);
        Assert.Equal("chrome", newFreeze.AdapterKind);
        Assert.Equal(RouteResults.SessionUrlConfirmed,
            (await dispatcher.DispatchAsync(
                MessageFactory.Activate(_clock, "notif-frozen-0001", oldFreeze.SnapshotId!))).Result);
    }

    [Fact]
    public async Task Equal_timestamp_keeps_first_received_binding_and_is_idempotent()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-tie-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            // Lexical adapter order is deliberately opposite the desired winner.
            await RegisterAsync(dispatcher, "adapter-zzzz", "chrome", "owner-chrome", "page-chrome",
                explicitOpen: true, eventId: "event-chrome-0001");
            await RegisterAsync(dispatcher, "adapter-aaaa", "pi-web-desktop", "owner-desktop", "page-desktop",
                explicitOpen: true, eventId: "event-desktop-0001");

            // Replaying Chrome's same event cannot turn it into the later event.
            await RegisterAsync(dispatcher, "adapter-zzzz", "chrome", "owner-chrome", "page-chrome",
                explicitOpen: true, eventId: "event-chrome-0001");
            var first = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-tie-0001", _instance, _routing));
            Assert.Equal("chrome", first.AdapterKind);

            // Revision survives daemon restart and reverse restoration order.
            var restarted = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(restarted, "adapter-aaaa", "pi-web-desktop", "owner-desktop-new", "page-desktop-new",
                explicitOpen: false);
            await RegisterAsync(restarted, "adapter-zzzz", "chrome", "owner-chrome-new", "page-chrome-new",
                explicitOpen: false);
            var afterRestart = await restarted.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-tie-0002", _instance, _routing));
            Assert.Equal("chrome", afterRestart.AdapterKind);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Delayed_earlier_open_corrects_a_later_provisional_binding()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-delayed-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            var earlier = _clock.UtcNowMs;

            _clock.AdvanceMs(20);
            await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop",
                "owner-desktop", "page-desktop",
                explicitOpen: true, eventId: "event-desktop-later",
                openedAtMs: earlier + 10);

            _clock.AdvanceMs(1);
            await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
                "owner-chrome", "page-chrome",
                explicitOpen: true, eventId: "event-chrome-earlier",
                openedAtMs: earlier);

            var restarted = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(restarted, "adapter-desktop", "pi-web-desktop",
                "owner-desktop-restored", "page-desktop-restored", explicitOpen: false);
            await RegisterAsync(restarted, "adapter-chrome", "chrome",
                "owner-chrome-restored", "page-chrome-restored", explicitOpen: false);

            var freeze = await restarted.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-delayed-earlier-0001", _instance, _routing));
            Assert.Equal(RouteResults.Ready, freeze.Result);
            Assert.Equal("chrome", freeze.AdapterKind);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Freeze_replay_rejects_snapshot_after_delayed_earlier_binding_correction()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var earlier = _clock.UtcNowMs;

        _clock.AdvanceMs(20);
        await RegisterAsync(
            dispatcher,
            "adapter-desktop",
            "pi-web-desktop",
            "owner-desktop-provisional",
            "page-desktop-provisional",
            explicitOpen: true,
            eventId: "event-desktop-provisional",
            openedAtMs: earlier + 10);
        var frozen = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-provisional-replay",
                _instance,
                _routing));
        Assert.Equal(RouteResults.Ready, frozen.Result);
        Assert.Equal("pi-web-desktop", frozen.AdapterKind);

        await RegisterAsync(
            dispatcher,
            "adapter-chrome",
            "chrome",
            "owner-chrome-earlier",
            "page-chrome-earlier",
            explicitOpen: true,
            eventId: "event-chrome-earlier",
            openedAtMs: earlier);

        var replay = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-provisional-replay",
                _instance,
                _routing));
        Assert.Equal(RouteResults.Stale, replay.Result);
        Assert.Equal(RejectReasons.OwnerChanged, replay.Reason);
        Assert.Equal(frozen.SnapshotId, replay.SnapshotId);
    }

    [Fact]
    public async Task Begin_activate_rejects_snapshot_after_delayed_earlier_binding_correction()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var earlier = _clock.UtcNowMs;

        _clock.AdvanceMs(20);
        await RegisterAsync(
            dispatcher,
            "adapter-desktop",
            "pi-web-desktop",
            "owner-desktop-begin",
            "page-desktop-begin",
            explicitOpen: true,
            eventId: "event-desktop-begin",
            openedAtMs: earlier + 10);
        var frozen = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-provisional-begin",
                _instance,
                _routing));

        await RegisterAsync(
            dispatcher,
            "adapter-chrome",
            "chrome",
            "owner-chrome-begin",
            "page-chrome-begin",
            explicitOpen: true,
            eventId: "event-chrome-begin",
            openedAtMs: earlier);

        var activate = MessageFactory.Activate(
            _clock,
            "notif-provisional-begin",
            frozen.SnapshotId!);
        var (early, snapshot, adapter) =
            dispatcher.State.BeginActivate(activate);
        Assert.NotNull(early);
        Assert.Equal(RouteResults.Stale, early.Result);
        Assert.Equal(RejectReasons.OwnerChanged, early.Reason);
        Assert.Null(snapshot);
        Assert.Null(adapter);
    }

    [Fact]
    public async Task Enqueue_commit_rejects_correction_between_begin_and_commit()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var earlier = _clock.UtcNowMs;

        _clock.AdvanceMs(20);
        await RegisterExternalAsync(
            dispatcher,
            "adapter-desktop",
            "pi-web-desktop",
            "owner-desktop-enqueue",
            "page-desktop-enqueue",
            explicitOpen: true,
            eventId: "event-desktop-enqueue",
            openedAtMs: earlier + 10);
        var frozen = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-provisional-enqueue",
                _instance,
                _routing));
        var activate = MessageFactory.Activate(
            _clock,
            "notif-provisional-enqueue",
            frozen.SnapshotId!);
        var (early, snapshot, adapter) =
            dispatcher.State.BeginActivate(activate);
        Assert.Null(early);
        Assert.NotNull(snapshot);
        Assert.NotNull(adapter);

        await RegisterExternalAsync(
            dispatcher,
            "adapter-chrome",
            "chrome",
            "owner-chrome-enqueue",
            "page-chrome-enqueue",
            explicitOpen: true,
            eventId: "event-chrome-enqueue",
            openedAtMs: earlier);

        var committed = dispatcher.State.EnqueuePendingActivation(
            activate,
            snapshot!,
            adapter!);
        Assert.Equal(RouteResults.Stale, committed.Result);
        Assert.Equal(RejectReasons.OwnerChanged, committed.Reason);
        Assert.Equal(0, dispatcher.State.PendingActivationCount);
    }

    [Fact]
    public async Task Pending_activation_is_not_delivered_after_binding_correction()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var earlier = _clock.UtcNowMs;

        _clock.AdvanceMs(20);
        await RegisterExternalAsync(
            dispatcher,
            "adapter-desktop",
            "pi-web-desktop",
            "owner-desktop-pending",
            "page-desktop-pending",
            explicitOpen: true,
            eventId: "event-desktop-pending",
            openedAtMs: earlier + 10);
        var frozen = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-provisional-pending",
                _instance,
                _routing));
        var activate = MessageFactory.Activate(
            _clock,
            "notif-provisional-pending",
            frozen.SnapshotId!);
        var accepted = await dispatcher.DispatchAsync(activate);
        Assert.Equal(RouteResults.Accepted, accepted.Result);

        await RegisterExternalAsync(
            dispatcher,
            "adapter-chrome",
            "chrome",
            "owner-chrome-pending",
            "page-chrome-pending",
            explicitOpen: true,
            eventId: "event-chrome-pending",
            openedAtMs: earlier);

        var poll = await dispatcher.DispatchAsync(
            MessageFactory.PollActivation(
                _clock,
                "adapter-desktop"));
        Assert.Equal(RouteResults.Ok, poll.Result);
        Assert.Equal(RejectReasons.NoPending, poll.Reason);

        var status = await dispatcher.DispatchAsync(
            MessageFactory.ActivationStatus(
                _clock,
                activate.RequestId));
        Assert.Equal(RouteResults.Stale, status.Result);
        Assert.Equal(RejectReasons.OwnerChanged, status.Reason);
    }

    [Fact]
    public async Task Complete_activate_reports_stale_after_binding_correction()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var earlier = _clock.UtcNowMs;

        _clock.AdvanceMs(20);
        await RegisterAsync(
            dispatcher,
            "adapter-desktop",
            "pi-web-desktop",
            "owner-desktop-complete",
            "page-desktop-complete",
            explicitOpen: true,
            eventId: "event-desktop-complete",
            openedAtMs: earlier + 10);
        var frozen = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(
                _clock,
                "notif-provisional-complete",
                _instance,
                _routing));

        await RegisterAsync(
            dispatcher,
            "adapter-chrome",
            "chrome",
            "owner-chrome-complete",
            "page-chrome-complete",
            explicitOpen: true,
            eventId: "event-chrome-complete",
            openedAtMs: earlier);

        var completed = dispatcher.State.CompleteActivate(
            "activate-provisional-complete",
            "notif-provisional-complete",
            frozen.SnapshotId!,
            new AdapterActivateResult
            {
                Result = RouteResults.SessionUrlConfirmed,
                ElapsedMs = 1,
            });
        Assert.Equal(RouteResults.Stale, completed.Result);
        Assert.Equal(RejectReasons.OwnerChanged, completed.Reason);
    }

    [Fact]
    public async Task Delayed_first_open_survives_more_than_twenty_four_hours_of_host_unavailability()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var chromeOpenedAt = _clock.UtcNowMs - 7 * 24 * 60 * 60_000L;

        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop",
            "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-later",
            openedAtMs: _clock.UtcNowMs);

        // Chrome captured the real user-open while Route Host was unavailable and retries
        // after recovery. Transport delay must not erase the first-opener event.
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
            "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-seven-days-earlier",
            openedAtMs: chromeOpenedAt);

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-delayed-week-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal("chrome", freeze.AdapterKind);
    }

    [Fact]
    public async Task Explicit_open_fails_closed_when_priority_cannot_be_persisted()
    {
        var dispatcher = CreateDispatcher(new FailingBindingStore());
        var adapter = await dispatcher.DispatchAsync(
            MessageFactory.RegisterAdapter(_clock, "adapter-chrome", "chrome"));
        Assert.Equal(RouteResults.Ok, adapter.Result);

        var registration = await dispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            "adapter-chrome",
            "chrome",
            "owner-chrome",
            "page-chrome",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-chrome-0001",
            openedAtMs: _clock.UtcNowMs));

        Assert.Equal(RouteResults.Rejected, registration.Result);
        Assert.Equal(RejectReasons.BindingPersistFailed, registration.Reason);
        Assert.Empty(dispatcher.State.ListOwners(_instance, _routing));
    }

    [Fact]
    public async Task First_binding_selects_its_adapter_even_when_another_owner_is_restore_only()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-ranked");
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: false);

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-partial-rank-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal("chrome", freeze.AdapterKind);
        Assert.NotNull(freeze.SnapshotId);
    }

    [Fact]
    public async Task Bound_adapter_offline_does_not_fall_back_and_reopening_it_resumes_routing()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-first");
        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-later");

        var unregister = await dispatcher.DispatchAsync(
            MessageFactory.UnregisterOwner(
                _clock,
                "adapter-chrome",
                "owner-chrome"));
        Assert.Equal(RouteResults.Ok, unregister.Result);

        var offline = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-bound-offline-0001", _instance, _routing));
        Assert.Equal(RouteResults.Miss, offline.Result);
        Assert.Equal(RouteResults.OwnerUnresolved, offline.Reason);
        Assert.Null(offline.SnapshotId);

        await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
            "owner-chrome-restored", "page-chrome-restored", explicitOpen: false);
        var resumed = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-bound-resumed-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, resumed.Result);
        Assert.Equal("chrome", resumed.AdapterKind);
    }

    [Fact]
    public async Task Capacity_rejection_does_not_persist_a_phantom_explicit_open()
    {
        var dispatcher = CreateDispatcher(new MemoryRouteBindingStore());
        var firstOpenedAt = _clock.UtcNowMs + 10;
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-before-capacity",
            openedAtMs: firstOpenedAt);
        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-before-capacity");
        var edgeAdapter = await dispatcher.DispatchAsync(
            MessageFactory.RegisterAdapter(_clock, "adapter-edge", "edge"));
        Assert.Equal(RouteResults.Ok, edgeAdapter.Result);

        for (var index = 0; index < ProtocolConstants.MaxOwners - 2; index++)
        {
            var filler = MessageFactory.RegisterOwner(
                _clock,
                "adapter-chrome",
                "chrome",
                $"owner-fill-{index:D4}",
                $"page-fill-{index:D4}",
                _instance,
                RoutingKey.Compute(_instance, $"capacity-session-{index:D4}"),
                ownerEvent: OwnerEvents.Restore);
            var fillerResponse = await dispatcher.DispatchAsync(filler);
            Assert.Equal(RouteResults.Ok, fillerResponse.Result);
        }

        _clock.AdvanceMs(10);
        var rejected = await dispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            "adapter-edge",
            "edge",
            "owner-edge-over-capacity",
            "page-edge-over-capacity",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-edge-over-capacity",
            openedAtMs: firstOpenedAt - 1));
        Assert.Equal(RouteResults.Rejected, rejected.Result);
        Assert.Equal(RejectReasons.Capacity, rejected.Reason);

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-capacity-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal("chrome", freeze.AdapterKind);
    }

    [Fact]
    public async Task Max_revision_state_compacts_atomically_instead_of_crashing_registration()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-revision-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var existingSessionId = SessionId(_instance, _routing);
            var saturated = new
            {
                version = 3,
                nextRevision = long.MaxValue,
                sessions = new Dictionary<string, object>
                {
                    [existingSessionId] = new
                    {
                        adapterKey = "adapter-chrome",
                        adapterIdentity = new
                        {
                            adapterKind = "chrome",
                            browserKind = "chrome",
                            profileKey = "profile-chrome-saturated",
                        },
                        openEventId = "event-chrome-saturated",
                        openedAtMs = _clock.UtcNowMs,
                        revision = long.MaxValue,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(saturated));

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            var secondRouting = RoutingKey.Compute(_instance, "revision-rollover-session");
            await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop",
                "owner-desktop-rollover", "page-desktop-rollover",
                explicitOpen: true, eventId: "event-desktop-rollover",
                routingKey: secondRouting);

            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            Assert.Equal(2, saved.RootElement.GetProperty("nextRevision").GetInt64());
            Assert.Equal(2, saved.RootElement.GetProperty("sessions").EnumerateObject().Count());
            Assert.Equal(
                new long[] { 1, 2 },
                saved.RootElement.GetProperty("sessions")
                    .EnumerateObject()
                    .Select(item => item.Value.GetProperty("revision").GetInt64())
                    .Order()
                    .ToArray());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Capacity_evicts_oldest_persisted_revision_not_client_open_timestamp()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-capacity-order-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var sessions = new Dictionary<string, object>();
            string? oldestRevisionSessionId = null;
            string? oldestTimestampSessionId = null;
            for (var index = 0; index < 2_048; index++)
            {
                var routingKey = RoutingKey.Compute(
                    _instance,
                    $"persisted-capacity-session-{index:D4}");
                var sessionId = SessionId(_instance, routingKey);
                if (index == 0)
                {
                    oldestRevisionSessionId = sessionId;
                }
                else if (index == 1)
                {
                    oldestTimestampSessionId = sessionId;
                }

                sessions[sessionId] = new
                {
                    adapterKey = "adapter-chrome-capacity",
                    adapterIdentity = new
                    {
                        adapterKind = "chrome",
                        browserKind = "chrome",
                        profileKey = "profile-chrome-capacity",
                    },
                    openEventId = $"event-capacity-{index:D4}",
                    openedAtMs = index switch
                    {
                        0 => _clock.UtcNowMs + 1_000_000,
                        1 => _clock.UtcNowMs - 1_000_000,
                        _ => _clock.UtcNowMs + index,
                    },
                    revision = index + 1L,
                };
            }

            File.WriteAllText(
                path,
                JsonSerializer.Serialize(new
                {
                    version = 3,
                    nextRevision = 2_048,
                    sessions,
                }));

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            var delayedRouting = RoutingKey.Compute(
                _instance,
                "delayed-event-admitted-at-capacity");
            var adapter = MessageFactory.RegisterAdapter(
                _clock,
                "adapter-chrome-capacity",
                "chrome");
            adapter.BrowserKind = "chrome";
            adapter.ProfileKey = "profile-chrome-capacity";
            Assert.Equal(
                RouteResults.Ok,
                (await dispatcher.DispatchAsync(adapter)).Result);

            var delayedOwner = MessageFactory.RegisterOwner(
                _clock,
                "adapter-chrome-capacity",
                "chrome",
                "owner-delayed-capacity",
                "page-delayed-capacity",
                _instance,
                delayedRouting,
                ownerEvent: OwnerEvents.ExplicitOpen,
                openEventId: "event-delayed-capacity",
                openedAtMs: _clock.UtcNowMs - 2_000_000);
            delayedOwner.AdapterKind = "chrome";
            delayedOwner.BrowserKind = "chrome";
            delayedOwner.ProfileKey = "profile-chrome-capacity";
            Assert.Equal(
                RouteResults.Ok,
                (await dispatcher.DispatchAsync(delayedOwner)).Result);

            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            var savedSessions = saved.RootElement.GetProperty("sessions");
            Assert.Equal(2_048, savedSessions.EnumerateObject().Count());
            Assert.False(savedSessions.TryGetProperty(oldestRevisionSessionId!, out _));
            Assert.True(savedSessions.TryGetProperty(oldestTimestampSessionId!, out _));
            Assert.True(
                savedSessions.TryGetProperty(
                    SessionId(_instance, delayedRouting),
                    out _));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Valid_version_one_last_open_metadata_is_not_migrated_as_a_first_binding()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-v1-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var sessionMaterial = Encoding.UTF8.GetBytes(_instance + "\0" + _routing);
            var sessionId = Convert.ToHexString(SHA256.HashData(sessionMaterial)).ToLowerInvariant();
            var legacy = new
            {
                version = 1,
                nextRevision = 2,
                sessions = new Dictionary<string, object>
                {
                    [sessionId] = new
                    {
                        adapters = new Dictionary<string, object>
                        {
                            ["adapter-chrome"] = new
                            {
                                openEventId = "event-chrome-v1",
                                openedAtMs = _clock.UtcNowMs,
                                revision = 1,
                            },
                            ["adapter-desktop"] = new
                            {
                                openEventId = "event-desktop-v1",
                                openedAtMs = _clock.UtcNowMs + 10,
                                revision = 2,
                            },
                        },
                        updatedAtMs = _clock.UtcNowMs + 10,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(legacy));

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
                "owner-chrome", "page-chrome", explicitOpen: false);
            await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop",
                "owner-desktop", "page-desktop", explicitOpen: false);

            var freeze = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-v1-reset-0001", _instance, _routing));
            Assert.Equal(RouteResults.Ambiguous, freeze.Result);
            Assert.Null(freeze.SnapshotId);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Valid_version_two_key_only_metadata_is_not_migrated_without_surface_identity()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-v2-key-only-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var keyOnly = new
            {
                version = 2,
                nextRevision = 1,
                sessions = new Dictionary<string, object>
                {
                    [SessionId(_instance, _routing)] = new
                    {
                        adapterKey = "adapter-chrome-v2",
                        openEventId = "event-chrome-v2",
                        openedAtMs = _clock.UtcNowMs,
                        revision = 1,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(keyOnly));

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(
                dispatcher,
                "adapter-chrome-v2",
                "chrome",
                "owner-chrome-v2",
                "page-chrome-v2",
                explicitOpen: false);

            var restoreOnly = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(
                    _clock,
                    "notif-v2-key-only-restore",
                    _instance,
                    _routing));
            Assert.Equal(RouteResults.Miss, restoreOnly.Result);
            Assert.Equal(RouteResults.OwnerUnresolved, restoreOnly.Reason);

            await RegisterAsync(
                dispatcher,
                "adapter-chrome-v2",
                "chrome",
                "owner-chrome-v2",
                "page-chrome-v2",
                explicitOpen: true,
                eventId: "event-chrome-v3-real-open");
            var rebound = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(
                    _clock,
                    "notif-v2-key-only-rebound",
                    _instance,
                    _routing));
            Assert.Equal(RouteResults.Ready, rebound.Result);
            Assert.Equal("chrome", rebound.AdapterKind);

            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            Assert.Equal(4, saved.RootElement.GetProperty("version").GetInt32());
            Assert.True(
                saved.RootElement.GetProperty("sessions")
                    .GetProperty(SessionId(_instance, _routing))
                    .TryGetProperty("adapterIdentity", out _));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData("")]
    [InlineData("{\"version\":1,\"nextRevision\":2,\"sessions\":{\"bad\":{\"adapters\":{}}}}")]
    [InlineData("{\"version\":1,\"nextRevision\":2,\"sessions\":{\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\":{\"adapters\":{\"adapter-chrome\":{\"openEventId\":\"event-chrome-old\",\"openedAtMs\":1700000000000,\"revision\":1},\"adapter-desktop\":{\"openEventId\":\"event-desktop-old\",\"openedAtMs\":1700000000010,\"revision\":2}},\"updatedAtMs\":1700000000010}}}")]
    [InlineData("{\"version\":2,\"nextRevision\":0,\"sessions\":null}")]
    [InlineData("{not-json")]
    public async Task Missing_or_corrupt_metadata_is_deterministically_fail_closed(string contents)
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-corrupt-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            if (contents.Length > 0)
            {
                File.WriteAllText(path, contents);
            }

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
                explicitOpen: false);

            var singleRestore = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(
                    _clock,
                    "notif-corrupt-single-restore",
                    _instance,
                    _routing));
            Assert.Equal(RouteResults.Miss, singleRestore.Result);
            Assert.Equal(RouteResults.OwnerUnresolved, singleRestore.Reason);
            Assert.Null(singleRestore.SnapshotId);

            await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
                explicitOpen: false);

            var first = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-corrupt-0001", _instance, _routing));
            var second = await dispatcher.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-corrupt-0002", _instance, _routing));
            Assert.Equal(RouteResults.Ambiguous, first.Result);
            Assert.Equal(RouteResults.Ambiguous, second.Result);
            Assert.Equal(2, first.CandidateCount);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Version_three_state_rejects_non_sha256_session_keys()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-nonhex-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var invalidSessionId = new string('z', 64);
            var invalid = new
            {
                version = 3,
                nextRevision = 1,
                sessions = new Dictionary<string, object>
                {
                    [invalidSessionId] = new
                    {
                        adapterKey = "adapter-unreachable",
                        adapterIdentity = new
                        {
                            adapterKind = "chrome",
                            browserKind = "chrome",
                            profileKey = "profile-unreachable-state",
                        },
                        openEventId = "event-unreachable-state",
                        openedAtMs = _clock.UtcNowMs,
                        revision = 1,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(invalid));

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            await RegisterAsync(dispatcher, "adapter-chrome", "chrome",
                "owner-chrome-after-corrupt", "page-chrome-after-corrupt",
                explicitOpen: true, eventId: "event-chrome-after-corrupt");

            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            var sessions = saved.RootElement.GetProperty("sessions");
            Assert.Single(sessions.EnumerateObject());
            Assert.True(sessions.TryGetProperty(SessionId(_instance, _routing), out _));
            Assert.False(sessions.TryGetProperty(invalidSessionId, out _));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Version_three_state_rejects_conflicting_identity_for_one_adapter_key()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-conflicting-adapter-identity-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            const string adapterKey = "adapter-conflicting-state";
            var otherRouting = RoutingKey.Compute(
                _instance,
                "conflicting-adapter-identity-session");
            var invalid = new
            {
                version = 3,
                nextRevision = 2,
                sessions = new Dictionary<string, object>
                {
                    [SessionId(_instance, _routing)] = new
                    {
                        adapterKey,
                        adapterIdentity = new
                        {
                            adapterKind = "chrome",
                            browserKind = "chrome",
                            profileKey = "profile-conflicting-state-a",
                        },
                        openEventId = "event-conflicting-state-a",
                        openedAtMs = _clock.UtcNowMs,
                        revision = 1,
                    },
                    [SessionId(_instance, otherRouting)] = new
                    {
                        adapterKey,
                        adapterIdentity = new
                        {
                            adapterKind = "chrome",
                            browserKind = "chrome",
                            profileKey = "profile-conflicting-state-b",
                        },
                        openEventId = "event-conflicting-state-b",
                        openedAtMs = _clock.UtcNowMs + 1,
                        revision = 2,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(invalid));

            var dispatcher = CreateDispatcher(new FileRouteBindingStore(path));
            var adapter = await dispatcher.DispatchAsync(
                MessageFactory.RegisterAdapter(_clock, adapterKey, "chrome"));
            Assert.Equal(RouteResults.Ok, adapter.Result);

            var owner = await dispatcher.DispatchAsync(MessageFactory.RegisterOwner(
                _clock,
                adapterKey,
                "chrome",
                "owner-after-conflicting-state",
                "page-after-conflicting-state",
                _instance,
                _routing,
                ownerEvent: OwnerEvents.ExplicitOpen,
                openEventId: "event-after-conflicting-state",
                openedAtMs: _clock.UtcNowMs + 2));
            Assert.Equal(RouteResults.Ok, owner.Result);

            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            var sessions = saved.RootElement.GetProperty("sessions");
            Assert.Single(sessions.EnumerateObject());
            Assert.True(sessions.TryGetProperty(SessionId(_instance, _routing), out _));
            Assert.False(sessions.TryGetProperty(SessionId(_instance, otherRouting), out _));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Version_three_state_rejects_duplicate_properties_before_deserialization()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-duplicate-session-property-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var sessionId = SessionId(_instance, _routing);
            var json = $$"""
                {
                  "version": 3,
                  "nextRevision": 2,
                  "sessions": {
                    "{{sessionId}}": {
                      "adapterKey": "adapter-duplicate-state",
                      "adapterIdentity": {
                        "adapterKind": "chrome",
                        "browserKind": "chrome",
                        "profileKey": "profile-duplicate-state-a"
                      },
                      "openEventId": "event-duplicate-state-a",
                      "openedAtMs": 1700000000000,
                      "revision": 1
                    },
                    "{{sessionId}}": {
                      "adapterKey": "adapter-duplicate-state",
                      "adapterIdentity": {
                        "adapterKind": "chrome",
                        "browserKind": "chrome",
                        "profileKey": "profile-duplicate-state-b"
                      },
                      "openEventId": "event-duplicate-state-b",
                      "openedAtMs": 1700000000001,
                      "revision": 2
                    }
                  }
                }
                """;
            File.WriteAllText(path, json);

            var store = new FileRouteBindingStore(path);

            Assert.Null(store.GetBinding(new SessionRouteKey(_instance, _routing)));

            var caseAliasJson = $$"""
                {
                  "version": 3,
                  "Version": 3,
                  "nextRevision": 1,
                  "sessions": {
                    "{{sessionId}}": {
                      "adapterKey": "adapter-duplicate-alias",
                      "adapterIdentity": {
                        "adapterKind": "chrome",
                        "browserKind": "chrome",
                        "profileKey": "profile-duplicate-alias"
                      },
                      "openEventId": "event-duplicate-alias",
                      "openedAtMs": 1700000000000,
                      "revision": 1
                    }
                  }
                }
                """;
            File.WriteAllText(path, caseAliasJson);

            var aliasStore = new FileRouteBindingStore(path);

            Assert.Null(aliasStore.GetBinding(new SessionRouteKey(_instance, _routing)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Version_three_state_rejects_incomplete_surface_identity()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-incomplete-identity-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var invalid = new
            {
                version = 3,
                nextRevision = 1,
                sessions = new Dictionary<string, object>
                {
                    [SessionId(_instance, _routing)] = new
                    {
                        adapterKey = "adapter-incomplete-identity",
                        adapterIdentity = new
                        {
                            adapterKind = "chrome",
                            browserKind = "chrome",
                        },
                        openEventId = "event-incomplete-identity",
                        openedAtMs = _clock.UtcNowMs,
                        revision = 1,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(invalid));

            var store = new FileRouteBindingStore(path);

            Assert.Null(store.GetBinding(new SessionRouteKey(_instance, _routing)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData("adapterKey")]
    [InlineData("openEventId")]
    public void Version_three_state_rejects_explicit_null_identity_without_throwing(string field)
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-null-binding-field-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var valid = new
            {
                version = 3,
                nextRevision = 1,
                sessions = new Dictionary<string, object>
                {
                    [SessionId(_instance, _routing)] = new
                    {
                        adapterKey = "adapter-null-binding-field",
                        adapterIdentity = new
                        {
                            adapterKind = "chrome",
                            browserKind = "chrome",
                            profileKey = "profile-null-binding-field",
                        },
                        openEventId = "event-null-binding-field",
                        openedAtMs = _clock.UtcNowMs,
                        revision = 1,
                    },
                },
            };
            var json = JsonSerializer.Serialize(valid);
            json = field switch
            {
                "adapterKey" => json.Replace(
                    "\"adapterKey\":\"adapter-null-binding-field\"",
                    "\"adapterKey\":null",
                    StringComparison.Ordinal),
                "openEventId" => json.Replace(
                    "\"openEventId\":\"event-null-binding-field\"",
                    "\"openEventId\":null",
                    StringComparison.Ordinal),
                _ => throw new ArgumentOutOfRangeException(nameof(field)),
            };
            File.WriteAllText(path, json);

            var store = new FileRouteBindingStore(path);

            Assert.Null(store.GetBinding(new SessionRouteKey(_instance, _routing)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Oversized_binding_state_is_rejected_without_allocating_a_file_sized_buffer()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-oversized-binding-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            const long oversizedLength = 16L * 1024 * 1024;
            using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.SetLength(oversizedLength);
            }

            _ = new FileRouteBindingStore(Path.Combine(directory, "missing-warmup.json"));
            var allocatedBefore = GC.GetAllocatedBytesForCurrentThread();
            var store = new FileRouteBindingStore(path);
            var allocated = GC.GetAllocatedBytesForCurrentThread() - allocatedBefore;

            Assert.True(
                allocated < 8L * 1024 * 1024,
                $"Oversized binding load allocated {allocated} bytes.");
            Assert.Null(store.GetBinding(new SessionRouteKey(_instance, _routing)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string SessionId(string instanceKey, string routingKey)
    {
        var material = Encoding.UTF8.GetBytes(instanceKey + "\0" + routingKey);
        return Convert.ToHexString(SHA256.HashData(material)).ToLowerInvariant();
    }

    private RouteDispatcher CreateDispatcher(IRouteBindingStore bindings)
    {
        var state = new RouteStateMachine(_clock, "binding-test-daemon", bindings);
        return new RouteDispatcher(state, _clock);
    }

    private async Task RegisterAsync(
        RouteDispatcher dispatcher,
        string adapterKey,
        string adapterKind,
        string ownerKey,
        string pageKey,
        bool explicitOpen,
        string? eventId = null,
        long? openedAtMs = null,
        string? routingKey = null)
    {
        if (_registeredAdapters.Add((dispatcher, adapterKey)))
        {
            await dispatcher.DispatchAsync(MessageFactory.RegisterAdapter(
                _clock, adapterKey, adapterKind));
            dispatcher.TrySetActivator(adapterKey, MockAdapterActivator.ConfirmSessionUrl);
        }
        var message = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            adapterKind,
            ownerKey,
            pageKey,
            _instance,
            routingKey ?? _routing,
            ownerEvent: explicitOpen ? OwnerEvents.ExplicitOpen : OwnerEvents.Restore,
            openEventId: explicitOpen ? eventId : null,
            openedAtMs: explicitOpen ? openedAtMs ?? _clock.UtcNowMs : null);
        var response = await dispatcher.DispatchAsync(message);
        Assert.Equal(RouteResults.Ok, response.Result);
    }

    private async Task RegisterExternalAsync(
        RouteDispatcher dispatcher,
        string adapterKey,
        string adapterKind,
        string ownerKey,
        string pageKey,
        bool explicitOpen,
        string? eventId = null,
        long? openedAtMs = null)
    {
        if (_registeredAdapters.Add((dispatcher, adapterKey)))
        {
            var registered = await dispatcher.DispatchAsync(
                MessageFactory.RegisterAdapter(
                    _clock,
                    adapterKey,
                    adapterKind));
            Assert.Equal(RouteResults.Ok, registered.Result);
        }

        var message = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            adapterKind,
            ownerKey,
            pageKey,
            _instance,
            _routing,
            ownerEvent: explicitOpen
                ? OwnerEvents.ExplicitOpen
                : OwnerEvents.Restore,
            openEventId: explicitOpen ? eventId : null,
            openedAtMs: explicitOpen
                ? openedAtMs ?? _clock.UtcNowMs
                : null);
        var response = await dispatcher.DispatchAsync(message);
        Assert.Equal(RouteResults.Ok, response.Result);
    }
}

internal static class RouteMessageTestExtensions
{
    public static RouteMessage Also(this RouteMessage message, Action<RouteMessage> configure)
    {
        configure(message);
        return message;
    }
}

internal sealed class FailingBindingStore : IRouteBindingStore
{
    public bool AllowsUnboundSingleOwnerRouting => false;

    public bool TryObserveReceiveClock(long receivedAtMs) =>
        receivedAtMs > 0;

    public bool IsAdapterIdentityCompatible(
        string adapterKey,
        AdapterBindingIdentity adapterIdentity)
    {
        _ = adapterKey;
        _ = adapterIdentity;
        return true;
    }

    public bool TryBindFirstExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        AdapterBindingIdentity adapterIdentity,
        string openEventId,
        long openedAtMs,
        long receivedAtMs,
        out SessionOwnerBinding? binding)
    {
        _ = session;
        _ = adapterKey;
        _ = adapterIdentity;
        _ = openEventId;
        _ = openedAtMs;
        _ = receivedAtMs;
        binding = null;
        return false;
    }

    public SessionOwnerBinding? GetBinding(SessionRouteKey session)
    {
        _ = session;
        return null;
    }
}
