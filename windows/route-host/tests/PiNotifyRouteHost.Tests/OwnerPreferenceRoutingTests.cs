using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class OwnerPreferenceRoutingTests
{
    private readonly FakeClock _clock = new(1_700_000_000_000);
    private readonly string _instance = "11111111-2222-3333-4444-555555555555";
    private readonly string _routing;

    public OwnerPreferenceRoutingTests()
    {
        _routing = RoutingKey.Compute(_instance, "sensitive-session-never-persisted");
    }

    [Fact]
    public async Task Chrome_then_desktop_and_desktop_then_chrome_select_last_explicit_open()
    {
        var dispatcher = CreateDispatcher(new MemoryRoutePreferenceStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-0001");
        _clock.AdvanceMs(10);
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: true, eventId: "event-desktop-0001");

        var desktopWins = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-order-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, desktopWins.Result);
        Assert.Equal("pi-web-desktop", desktopWins.AdapterKind);

        _clock.AdvanceMs(10);
        await dispatcher.DispatchAsync(MessageFactory.UnregisterOwner(_clock, "owner-chrome"));
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome-2", "page-chrome-2",
            explicitOpen: true, eventId: "event-chrome-0002");
        var chromeWins = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-order-0002", _instance, _routing));
        Assert.Equal(RouteResults.Ready, chromeWins.Result);
        Assert.Equal("chrome", chromeWins.AdapterKind);
    }

    [Fact]
    public async Task Restore_heartbeat_and_reconnect_do_not_change_winner()
    {
        var dispatcher = CreateDispatcher(new MemoryRoutePreferenceStore());
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
                msg.OwnerKey = "owner-chrome";
                msg.LeaseTtlMs = ProtocolConstants.DefaultLeaseTtlMs;
            }));
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome-restored", "page-chrome-restored",
            explicitOpen: false);

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-restore-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ready, freeze.Result);
        Assert.Equal("pi-web-desktop", freeze.AdapterKind);
    }

    [Fact]
    public async Task Daemon_restart_preserves_winner_when_restore_order_reverses()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-preference-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var first = CreateDispatcher(new FileRoutePreferenceStore(path));
            await RegisterAsync(first, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
                explicitOpen: true, eventId: "event-chrome-0001");
            _clock.AdvanceMs(10);
            await RegisterAsync(first, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
                explicitOpen: true, eventId: "event-desktop-0001");

            var restarted = CreateDispatcher(new FileRoutePreferenceStore(path));
            await RegisterAsync(restarted, "adapter-desktop", "pi-web-desktop", "owner-desktop-new", "page-desktop-new",
                explicitOpen: false);
            await RegisterAsync(restarted, "adapter-chrome", "chrome", "owner-chrome-new", "page-chrome-new",
                explicitOpen: false);

            var freeze = await restarted.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-restart-0001", _instance, _routing));
            Assert.Equal(RouteResults.Ready, freeze.Result);
            Assert.Equal("pi-web-desktop", freeze.AdapterKind);

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
    public async Task Frozen_notification_keeps_old_owner_while_new_notification_uses_new_winner()
    {
        var dispatcher = CreateDispatcher(new MemoryRoutePreferenceStore());
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
        Assert.Equal("pi-web-desktop", newFreeze.AdapterKind);
        Assert.Equal(RouteResults.SessionUrlConfirmed,
            (await dispatcher.DispatchAsync(
                MessageFactory.Activate(_clock, "notif-frozen-0001", oldFreeze.SnapshotId!))).Result);
    }

    [Fact]
    public async Task Equal_timestamp_uses_persisted_receive_revision_and_is_idempotent()
    {
        var directory = Path.Combine(Path.GetTempPath(), "pi-route-tie-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var dispatcher = CreateDispatcher(new FileRoutePreferenceStore(path));
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
            Assert.Equal("pi-web-desktop", first.AdapterKind);

            // Revision survives daemon restart and reverse restoration order.
            var restarted = CreateDispatcher(new FileRoutePreferenceStore(path));
            await RegisterAsync(restarted, "adapter-aaaa", "pi-web-desktop", "owner-desktop-new", "page-desktop-new",
                explicitOpen: false);
            await RegisterAsync(restarted, "adapter-zzzz", "chrome", "owner-chrome-new", "page-chrome-new",
                explicitOpen: false);
            var afterRestart = await restarted.DispatchAsync(
                MessageFactory.Freeze(_clock, "notif-tie-0002", _instance, _routing));
            Assert.Equal("pi-web-desktop", afterRestart.AdapterKind);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Explicit_open_fails_closed_when_priority_cannot_be_persisted()
    {
        var dispatcher = CreateDispatcher(new FailingPreferenceStore());
        var adapter = await dispatcher.DispatchAsync(
            MessageFactory.RegisterAdapter(_clock, "adapter-chrome", "chrome"));
        Assert.Equal(RouteResults.Ok, adapter.Result);

        var registration = await dispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            _clock,
            "adapter-chrome",
            "owner-chrome",
            "page-chrome",
            _instance,
            _routing,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-chrome-0001",
            openedAtMs: _clock.UtcNowMs));

        Assert.Equal(RouteResults.Rejected, registration.Result);
        Assert.Equal(RejectReasons.PreferencePersistFailed, registration.Reason);
        Assert.Empty(dispatcher.State.ListOwners(_instance, _routing));
    }

    [Fact]
    public async Task One_ranked_and_one_unranked_live_owner_is_ambiguous()
    {
        var dispatcher = CreateDispatcher(new MemoryRoutePreferenceStore());
        await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
            explicitOpen: true, eventId: "event-chrome-ranked");
        await RegisterAsync(dispatcher, "adapter-desktop", "pi-web-desktop", "owner-desktop", "page-desktop",
            explicitOpen: false);

        var freeze = await dispatcher.DispatchAsync(
            MessageFactory.Freeze(_clock, "notif-partial-rank-0001", _instance, _routing));
        Assert.Equal(RouteResults.Ambiguous, freeze.Result);
        Assert.Equal(2, freeze.CandidateCount);
        Assert.Null(freeze.SnapshotId);
    }

    [Theory]
    [InlineData("")]
    [InlineData("{\"version\":1,\"nextRevision\":2,\"sessions\":{\"bad\":{\"adapters\":{}}}}")]
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

            var dispatcher = CreateDispatcher(new FileRoutePreferenceStore(path));
            await RegisterAsync(dispatcher, "adapter-chrome", "chrome", "owner-chrome", "page-chrome",
                explicitOpen: false);
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

    private RouteDispatcher CreateDispatcher(IRoutePreferenceStore preferences)
    {
        var state = new RouteStateMachine(_clock, "preference-test-daemon", preferences);
        return new RouteDispatcher(state, _clock);
    }

    private async Task RegisterAsync(
        RouteDispatcher dispatcher,
        string adapterKey,
        string adapterKind,
        string ownerKey,
        string pageKey,
        bool explicitOpen,
        string? eventId = null)
    {
        await dispatcher.DispatchAsync(MessageFactory.RegisterAdapter(
            _clock, adapterKey, adapterKind));
        dispatcher.TrySetActivator(adapterKey, MockAdapterActivator.ConfirmSessionUrl);
        var message = MessageFactory.RegisterOwner(
            _clock,
            adapterKey,
            ownerKey,
            pageKey,
            _instance,
            _routing,
            ownerEvent: explicitOpen ? OwnerEvents.ExplicitOpen : OwnerEvents.Restore,
            openEventId: explicitOpen ? eventId : null,
            openedAtMs: explicitOpen ? _clock.UtcNowMs : null);
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

internal sealed class FailingPreferenceStore : IRoutePreferenceStore
{
    public bool TryRecordExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        string openEventId,
        long openedAtMs,
        out OwnerPreference? preference)
    {
        _ = session;
        _ = adapterKey;
        _ = openEventId;
        _ = openedAtMs;
        preference = null;
        return false;
    }

    public OwnerPreference? GetPreference(SessionRouteKey session, string adapterKey)
    {
        _ = session;
        _ = adapterKey;
        return null;
    }
}
