using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class RegisterOpenIntentTests
{
    private const string ChromeAdapter = "adapter-open-intent-chrome";
    private const string DesktopAdapter = "adapter-open-intent-desktop";
    private const string InstanceKey = "11111111-2222-3333-4444-555555555555";
    private static readonly string RoutingKeyValue =
        RoutingKey.Compute(InstanceKey, "register-open-intent-session");
    private readonly FakeClock _clock = new(1_700_000_000_000);

    [Fact]
    public void Open_intent_binds_without_creating_live_owner_snapshot_or_activation()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");

        var response = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-success",
            _clock.UtcNowMs));

        Assert.Equal(RouteResults.Ok, response.Result);
        Assert.Null(response.Reason);
        var binding = bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue));
        Assert.NotNull(binding);
        Assert.Equal(ChromeAdapter, binding!.AdapterKey);
        Assert.Equal("chrome", binding.AdapterIdentity.AdapterKind);
        Assert.Equal("chrome", binding.AdapterIdentity.BrowserKind);
        Assert.Equal(ChromeAdapter, binding.AdapterIdentity.ProfileKey);
        Assert.Equal("open-event-intent-success", binding.OpenEventId);
        Assert.Equal(_clock.UtcNowMs, binding.OpenedAtMs);
        Assert.Equal(1, state.LiveAdapterCount);
        Assert.Equal(0, state.LiveOwnerCount);
        Assert.Equal(0, state.SnapshotCount);
        Assert.Equal(0, state.PendingActivationCount);
    }

    [Fact]
    public void Open_intent_binding_survives_store_reload_without_an_owner()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-open-intent-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var state = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(state, ChromeAdapter, "chrome");

            var response = state.Handle(BuildOpenIntent(
                ChromeAdapter,
                "chrome",
                "open-event-intent-file-store",
                _clock.UtcNowMs));

            Assert.Equal(RouteResults.Ok, response.Result);
            Assert.Equal(0, state.LiveOwnerCount);
            var reloaded = new FileRouteBindingStore(path);
            var binding = reloaded.GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue));
            Assert.NotNull(binding);
            Assert.Equal(ChromeAdapter, binding!.AdapterKey);
            Assert.Equal(
                "open-event-intent-file-store",
                binding.OpenEventId);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Open_intent_succeeds_at_live_owner_capacity_without_consuming_owner_state()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        for (var index = 0; index < ProtocolConstants.MaxOwners; index++)
        {
            var owner = MessageFactory.RegisterOwner(
                _clock,
                ChromeAdapter,
                "chrome",
                $"owner-capacity-{index:D4}",
                $"page-capacity-{index:D4}",
                InstanceKey,
                RoutingKeyValue,
                ownerEvent: OwnerEvents.Restore);
            Assert.Equal(RouteResults.Ok, state.Handle(owner).Result);
        }
        Assert.Equal(ProtocolConstants.MaxOwners, state.LiveOwnerCount);

        var response = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-at-capacity",
            _clock.UtcNowMs));

        Assert.Equal(RouteResults.Ok, response.Result);
        Assert.Equal(ProtocolConstants.MaxOwners, state.LiveOwnerCount);
        Assert.NotNull(bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue)));
        Assert.Equal(0, state.SnapshotCount);
        Assert.Equal(0, state.PendingActivationCount);
    }

    [Fact]
    public void Later_and_identical_intents_are_idempotent_and_keep_the_first_binding()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        RegisterAdapter(state, DesktopAdapter, "pi-web-desktop");
        var openedAt = _clock.UtcNowMs;

        var first = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-first",
            openedAt));
        var firstBinding = bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue));

        _clock.AdvanceMs(10);
        var identical = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-first",
            openedAt));
        var sameEventChangedTimestamp = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-first",
            openedAt - 100));
        var later = state.Handle(BuildOpenIntent(
            DesktopAdapter,
            "pi-web-desktop",
            "open-event-intent-later",
            openedAt + 10));
        var binding = bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue));

        Assert.Equal(RouteResults.Ok, first.Result);
        Assert.Equal(RouteResults.Ok, identical.Result);
        Assert.Equal(RouteResults.Ok, sameEventChangedTimestamp.Result);
        Assert.Equal(RouteResults.Ok, later.Result);
        Assert.NotNull(firstBinding);
        Assert.NotNull(binding);
        Assert.Equal(ChromeAdapter, binding!.AdapterKey);
        Assert.Equal("open-event-intent-first", binding.OpenEventId);
        Assert.Equal(openedAt, binding.OpenedAtMs);
        Assert.Equal(firstBinding!.Revision, binding.Revision);
        Assert.Equal(0, state.LiveOwnerCount);
    }

    [Fact]
    public void Delayed_earlier_intent_corrects_a_later_provisional_binding()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        RegisterAdapter(state, DesktopAdapter, "pi-web-desktop");
        var earlier = _clock.UtcNowMs;

        Assert.Equal(
            RouteResults.Ok,
            state.Handle(BuildOpenIntent(
                DesktopAdapter,
                "pi-web-desktop",
                "open-event-intent-provisional",
                earlier + 20)).Result);
        _clock.AdvanceMs(30);
        Assert.Equal(
            RouteResults.Ok,
            state.Handle(BuildOpenIntent(
                ChromeAdapter,
                "chrome",
                "open-event-intent-delayed-earlier",
                earlier)).Result);

        var binding = bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue));
        Assert.NotNull(binding);
        Assert.Equal(ChromeAdapter, binding!.AdapterKey);
        Assert.Equal("open-event-intent-delayed-earlier", binding.OpenEventId);
        Assert.Equal(earlier, binding.OpenedAtMs);
        Assert.Equal(0, state.LiveOwnerCount);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(120_000)]
    public void Health_observed_clock_rollback_survives_reload_and_blocks_an_earlier_intent(
        long rollbackDistanceMs)
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-clock-rollback-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var originalNow = _clock.UtcNowMs;
            var state = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(state, ChromeAdapter, "chrome");
            RegisterAdapter(state, DesktopAdapter, "pi-web-desktop");
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(BuildOpenIntent(
                    DesktopAdapter,
                    "pi-web-desktop",
                    "open-event-before-clock-rollback",
                    originalNow + 20)).Result);

            _clock.SetMs(originalNow + rollbackDistanceMs);
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(MessageFactory.Health(_clock)).Result);
            _clock.SetMs(originalNow);
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(MessageFactory.Health(_clock)).Result);

            _clock.SetMs(originalNow + rollbackDistanceMs + 1);
            var restarted = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(restarted, ChromeAdapter, "chrome");
            RegisterAdapter(restarted, DesktopAdapter, "pi-web-desktop");
            Assert.Equal(
                RouteResults.Ok,
                restarted.Handle(BuildOpenIntent(
                    ChromeAdapter,
                    "chrome",
                    "open-event-after-clock-rollback",
                    originalNow)).Result);

            var binding = new FileRouteBindingStore(path).GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue));
            Assert.NotNull(binding);
            Assert.Equal(DesktopAdapter, binding!.AdapterKey);
            Assert.Equal(
                "open-event-before-clock-rollback",
                binding.OpenEventId);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Exact_request_replay_persists_a_clock_rollback_barrier_before_returning_ok()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-clock-replay-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var originalNow = _clock.UtcNowMs;
            var state = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(state, ChromeAdapter, "chrome");
            RegisterAdapter(state, DesktopAdapter, "pi-web-desktop");
            var provisional = BuildOpenIntent(
                DesktopAdapter,
                "pi-web-desktop",
                "open-event-replayed-across-clock-rollback",
                originalNow + 20);
            provisional.RequestId = "request-replayed-across-clock-rollback";
            Assert.Equal(RouteResults.Ok, state.Handle(provisional).Result);

            _clock.AdvanceMs(30);
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(MessageFactory.Health(_clock)).Result);
            _clock.SetMs(originalNow + 10);
            var replay = state.Handle(provisional);
            Assert.Equal(RouteResults.Ok, replay.Result);
            Assert.Equal(RejectReasons.Replay, replay.Reason);

            _clock.SetMs(originalNow + 40);
            var restarted = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(restarted, ChromeAdapter, "chrome");
            var delayedEarlier = restarted.Handle(BuildOpenIntent(
                ChromeAdapter,
                "chrome",
                "open-event-delayed-after-replayed-rollback",
                originalNow));
            Assert.Equal(RouteResults.Ok, delayedEarlier.Result);

            var binding = new FileRouteBindingStore(path).GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue));
            Assert.NotNull(binding);
            Assert.Equal(DesktopAdapter, binding!.AdapterKey);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Failed_clock_barrier_save_stays_pending_until_persisted_and_survives_reload()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-clock-save-failure-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var originalNow = _clock.UtcNowMs;
            var state = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(state, ChromeAdapter, "chrome");
            RegisterAdapter(state, DesktopAdapter, "pi-web-desktop");
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(BuildOpenIntent(
                    DesktopAdapter,
                    "pi-web-desktop",
                    "open-event-before-failed-clock-save",
                    originalNow + 20)).Result);

            _clock.SetMs(originalNow + 30);
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(MessageFactory.Health(_clock)).Result);

            using (new FileStream(
                       path,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.None))
            {
                _clock.SetMs(originalNow + 10);
                var rejected = state.Handle(MessageFactory.Health(_clock));
                Assert.Equal(RouteResults.Rejected, rejected.Result);
                Assert.Equal(
                    RejectReasons.PreferencePersistFailed,
                    rejected.Reason);
            }

            _clock.SetMs(originalNow + 40);
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(MessageFactory.Health(_clock)).Result);

            _clock.SetMs(originalNow + 41);
            var restarted = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(restarted, ChromeAdapter, "chrome");
            RegisterAdapter(restarted, DesktopAdapter, "pi-web-desktop");
            Assert.Equal(
                RouteResults.Ok,
                restarted.Handle(BuildOpenIntent(
                    ChromeAdapter,
                    "chrome",
                    "open-event-after-failed-clock-save",
                    originalNow)).Result);

            var binding = new FileRouteBindingStore(path).GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue));
            Assert.NotNull(binding);
            Assert.Equal(DesktopAdapter, binding!.AdapterKey);
            Assert.Equal(
                "open-event-before-failed-clock-save",
                binding.OpenEventId);
            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            Assert.Equal(
                2,
                saved.RootElement.GetProperty("clockEpoch").GetInt64());
            Assert.Equal(
                originalNow + 41,
                saved.RootElement
                    .GetProperty("clockHighWaterMs")
                    .GetInt64());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Version_three_binding_migrates_to_epoch_zero_and_cannot_be_corrected_across_upgrade()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-clock-v3-migration-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var originalNow = _clock.UtcNowMs;
            var sessionId = SessionId(InstanceKey, RoutingKeyValue);
            var legacy = new
            {
                version = 3,
                nextRevision = 1,
                sessions = new Dictionary<string, object>
                {
                    [sessionId] = new
                    {
                        adapterKey = DesktopAdapter,
                        adapterIdentity = new
                        {
                            adapterKind = "pi-web-desktop",
                            browserKind = "pi-web-desktop",
                            profileKey = DesktopAdapter,
                        },
                        openEventId = "open-event-before-v4-upgrade",
                        openedAtMs = originalNow + 20,
                        revision = 1,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(legacy));

            var state = CreateState(new FileRouteBindingStore(path));
            RegisterAdapter(state, ChromeAdapter, "chrome");
            RegisterAdapter(state, DesktopAdapter, "pi-web-desktop");
            Assert.Equal(
                RouteResults.Ok,
                state.Handle(BuildOpenIntent(
                    ChromeAdapter,
                    "chrome",
                    "open-event-after-v4-upgrade",
                    originalNow)).Result);

            var binding = new FileRouteBindingStore(path).GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue));
            Assert.NotNull(binding);
            Assert.Equal(DesktopAdapter, binding!.AdapterKey);
            Assert.Equal(0, binding.ReceiveClockEpoch);
            using var saved = JsonDocument.Parse(File.ReadAllBytes(path));
            Assert.Equal(
                4,
                saved.RootElement.GetProperty("version").GetInt32());
            Assert.Equal(
                1,
                saved.RootElement.GetProperty("clockEpoch").GetInt64());
            Assert.Equal(
                0,
                saved.RootElement
                    .GetProperty("sessions")
                    .GetProperty(sessionId)
                    .GetProperty("receiveClockEpoch")
                    .GetInt64());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Version_three_binding_rejects_smuggled_epoch_fields()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-clock-v3-smuggled-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var sessionId = SessionId(InstanceKey, RoutingKeyValue);
            var json = $$"""
                {
                  "version": 3,
                  "clockEpoch": 0,
                  "nextRevision": 1,
                  "sessions": {
                    "{{sessionId}}": {
                      "adapterKey": "{{DesktopAdapter}}",
                      "adapterIdentity": {
                        "adapterKind": "pi-web-desktop",
                        "browserKind": "pi-web-desktop",
                        "profileKey": "{{DesktopAdapter}}"
                      },
                      "openEventId": "open-event-smuggled-v3-clock",
                      "openedAtMs": 1700000000000,
                      "revision": 1
                    }
                  }
                }
                """;
            File.WriteAllText(path, json);

            var store = new FileRouteBindingStore(path);

            Assert.Null(store.GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Saturated_clock_epoch_rejects_rollback_without_wrapping_or_rewriting_state()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "pi-route-clock-overflow-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "route-preferences.json");
        try
        {
            var originalNow = _clock.UtcNowMs;
            var sessionId = SessionId(InstanceKey, RoutingKeyValue);
            var saturated = new
            {
                version = 4,
                clockEpoch = long.MaxValue,
                clockHighWaterMs = originalNow + 10,
                nextRevision = 1,
                sessions = new Dictionary<string, object>
                {
                    [sessionId] = new
                    {
                        adapterKey = DesktopAdapter,
                        adapterIdentity = new
                        {
                            adapterKind = "pi-web-desktop",
                            browserKind = "pi-web-desktop",
                            profileKey = DesktopAdapter,
                        },
                        openEventId = "open-event-saturated-clock",
                        openedAtMs = originalNow,
                        revision = 1,
                        receiveClockEpoch = long.MaxValue,
                    },
                },
            };
            File.WriteAllText(path, JsonSerializer.Serialize(saturated));
            var originalBytes = File.ReadAllBytes(path);

            var state = CreateState(new FileRouteBindingStore(path));
            var rejected = state.Handle(MessageFactory.Health(_clock));

            Assert.Equal(RouteResults.Rejected, rejected.Result);
            Assert.Equal(
                RejectReasons.PreferencePersistFailed,
                rejected.Reason);
            Assert.Equal(originalBytes, File.ReadAllBytes(path));
            var binding = new FileRouteBindingStore(path).GetBinding(
                new SessionRouteKey(InstanceKey, RoutingKeyValue));
            Assert.NotNull(binding);
            Assert.Equal(DesktopAdapter, binding!.AdapterKey);
            Assert.Equal(long.MaxValue, binding.ReceiveClockEpoch);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Stale_generation_and_mismatched_identity_fields_are_rejected_without_binding()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");

        var staleGeneration = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-stale",
            _clock.UtcNowMs);
        staleGeneration.AdapterGeneration = "generation-stale-open-intent";
        var staleResponse = state.Handle(staleGeneration);

        var wrongIdentity = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-wrong-identity",
            _clock.UtcNowMs);
        wrongIdentity.ProfileKey = "profile-open-intent-wrong";
        var wrongIdentityResponse = state.Handle(wrongIdentity);

        var wrongAdapterKind = BuildOpenIntent(
            ChromeAdapter,
            "edge",
            "open-event-intent-wrong-kind",
            _clock.UtcNowMs);
        var wrongAdapterKindResponse = state.Handle(wrongAdapterKind);

        Assert.Equal(RouteResults.AdapterUnavailable, staleResponse.Result);
        Assert.Equal(
            RejectReasons.AdapterGenerationChanged,
            staleResponse.Reason);
        Assert.Equal(RouteResults.Rejected, wrongIdentityResponse.Result);
        Assert.Equal(RejectReasons.InvalidField, wrongIdentityResponse.Reason);
        Assert.Equal(RouteResults.Rejected, wrongAdapterKindResponse.Result);
        Assert.Equal(
            RejectReasons.InvalidField,
            wrongAdapterKindResponse.Reason);
        Assert.Null(bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue)));
        Assert.Equal(0, state.LiveOwnerCount);
    }

    [Fact]
    public void Unregistered_adapter_is_rejected_without_binding_or_live_state()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);

        var response = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-unknown-adapter",
            _clock.UtcNowMs));

        Assert.Equal(RouteResults.AdapterUnavailable, response.Result);
        Assert.Equal(RejectReasons.AdapterUnknown, response.Reason);
        Assert.Null(bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue)));
        Assert.Equal(0, state.LiveAdapterCount);
        Assert.Equal(0, state.LiveOwnerCount);
        Assert.Equal(0, state.SnapshotCount);
        Assert.Equal(0, state.PendingActivationCount);
    }

    [Theory]
    [InlineData("owner-key")]
    [InlineData("replaces-owner-key")]
    [InlineData("page-key")]
    [InlineData("page-fingerprint")]
    [InlineData("owner-event")]
    [InlineData("lease-ttl")]
    [InlineData("adapter-started-at")]
    [InlineData("notification-id")]
    [InlineData("notification-kind")]
    [InlineData("snapshot-id")]
    [InlineData("activation-request-id")]
    [InlineData("result")]
    [InlineData("reason")]
    [InlineData("deadline")]
    [InlineData("elapsed")]
    public void Route_specific_pollution_is_rejected_as_invalid_field(
        string pollutedField)
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        var message = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-pollution",
            _clock.UtcNowMs);

        switch (pollutedField)
        {
            case "owner-key":
                message.OwnerKey = "owner-open-intent-pollution";
                break;
            case "replaces-owner-key":
                message.ReplacesOwnerKey = "owner-open-intent-replaced";
                break;
            case "page-key":
                message.PageKey = "page-open-intent-pollution";
                break;
            case "page-fingerprint":
                message.PageFingerprint = "page-fingerprint-pollution";
                break;
            case "owner-event":
                message.OwnerEvent = OwnerEvents.ExplicitOpen;
                break;
            case "lease-ttl":
                message.LeaseTtlMs = ProtocolConstants.DefaultLeaseTtlMs;
                break;
            case "adapter-started-at":
                message.AdapterStartedAtMs = _clock.UtcNowMs;
                break;
            case "notification-id":
                message.NotificationId = "notification-open-intent-pollution";
                break;
            case "notification-kind":
                message.NotificationKind = "ask-user";
                break;
            case "snapshot-id":
                message.SnapshotId = "snapshot-open-intent-pollution";
                break;
            case "activation-request-id":
                message.ActivationRequestId = "activation-open-intent-pollution";
                break;
            case "result":
                message.Result = RouteResults.Ok;
                break;
            case "reason":
                message.Reason = RejectReasons.Replay;
                break;
            case "deadline":
                message.DeadlineMs = _clock.UtcNowMs + 1_000;
                break;
            case "elapsed":
                message.ElapsedMs = 1;
                break;
            default:
                throw new ArgumentOutOfRangeException(
                    nameof(pollutedField),
                    pollutedField,
                    null);
        }

        var response = state.Handle(message);

        Assert.Equal(RouteResults.Rejected, response.Result);
        Assert.Equal(RejectReasons.InvalidField, response.Reason);
        Assert.Null(bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue)));
        Assert.Equal(0, state.LiveOwnerCount);
        Assert.Equal(0, state.SnapshotCount);
        Assert.Equal(0, state.PendingActivationCount);
    }

    [Theory]
    [InlineData("instance", "short")]
    [InlineData("routing", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("routing", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    [InlineData("event", "short")]
    [InlineData("event", "bad/open-event")]
    [InlineData("opened-at", "0")]
    public void Invalid_binding_candidate_fields_are_rejected(
        string field,
        string value)
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        var message = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-invalid-field",
            _clock.UtcNowMs);

        switch (field)
        {
            case "instance":
                message.InstanceKey = value;
                break;
            case "routing":
                message.RoutingKey = value;
                break;
            case "event":
                message.OpenEventId = value;
                break;
            case "opened-at":
                message.OpenedAtMs = long.Parse(value);
                break;
            default:
                throw new ArgumentOutOfRangeException(
                    nameof(field),
                    field,
                    null);
        }

        var response = state.Handle(message);

        Assert.Equal(RouteResults.Rejected, response.Result);
        Assert.Equal(RejectReasons.InvalidField, response.Reason);
        Assert.Null(bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue)));
    }

    [Fact]
    public void Missing_required_binding_candidate_field_is_rejected_as_missing_field()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        var message = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-missing-field",
            _clock.UtcNowMs);
        message.OpenEventId = null;

        var response = state.Handle(message);

        Assert.Equal(RouteResults.Rejected, response.Result);
        Assert.Equal(RejectReasons.MissingField, response.Reason);
        Assert.Null(bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue)));
    }

    [Fact]
    public void Persistence_failure_uses_existing_reason_and_leaves_no_live_state()
    {
        var bindings = new FailingBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");

        var response = state.Handle(BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-persist-failure",
            _clock.UtcNowMs));

        Assert.Equal(RouteResults.Rejected, response.Result);
        Assert.Equal(RejectReasons.PreferencePersistFailed, response.Reason);
        Assert.Equal(1, state.LiveAdapterCount);
        Assert.Equal(0, state.LiveOwnerCount);
        Assert.Equal(0, state.SnapshotCount);
        Assert.Equal(0, state.PendingActivationCount);
    }

    [Fact]
    public void Normal_request_replay_is_idempotent_and_conflicting_body_is_rejected()
    {
        var bindings = new MemoryRouteBindingStore();
        var state = CreateState(bindings);
        RegisterAdapter(state, ChromeAdapter, "chrome");
        var message = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-replay",
            _clock.UtcNowMs);
        message.RequestId = "request-open-intent-replay";

        var first = state.Handle(message);
        var replay = state.Handle(message);
        var conflict = BuildOpenIntent(
            ChromeAdapter,
            "chrome",
            "open-event-intent-conflict",
            _clock.UtcNowMs - 1);
        conflict.RequestId = message.RequestId;
        var conflictResponse = state.Handle(conflict);

        Assert.Equal(RouteResults.Ok, first.Result);
        Assert.Equal(RouteResults.Ok, replay.Result);
        Assert.Equal(RejectReasons.Replay, replay.Reason);
        Assert.Equal(RouteResults.Rejected, conflictResponse.Result);
        Assert.Equal(
            RejectReasons.RequestIdConflict,
            conflictResponse.Reason);
        var binding = bindings.GetBinding(
            new SessionRouteKey(InstanceKey, RoutingKeyValue));
        Assert.NotNull(binding);
        Assert.Equal("open-event-intent-replay", binding!.OpenEventId);
    }

    private RouteStateMachine CreateState(IRouteBindingStore bindings) =>
        new(_clock, "register-open-intent-test-daemon", bindings);

    private void RegisterAdapter(
        RouteStateMachine state,
        string adapterKey,
        string adapterKind)
    {
        var response = state.Handle(MessageFactory.RegisterAdapter(
            _clock,
            adapterKey,
            adapterKind));
        Assert.Equal(RouteResults.Ok, response.Result);
    }

    private RouteMessage BuildOpenIntent(
        string adapterKey,
        string adapterKind,
        string openEventId,
        long openedAtMs)
    {
        return MessageFactory.RegisterOpenIntent(
            _clock,
            adapterKey,
            adapterKind,
            InstanceKey,
            RoutingKeyValue,
            openEventId,
            openedAtMs);
    }

    private static string SessionId(string instanceKey, string routingKey)
    {
        var material = Encoding.UTF8.GetBytes(instanceKey + "\0" + routingKey);
        return Convert.ToHexString(SHA256.HashData(material)).ToLowerInvariant();
    }
}
