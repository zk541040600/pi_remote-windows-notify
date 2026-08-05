using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class RegisterOwnerValidationTests
{
    private const string AdapterKey = "adapter-validation-0001";
    private const string OwnerKey = "owner-validation-0001";
    private const string PageKey = "page-validation-0001";
    private const string InstanceKey = "11111111-2222-3333-4444-555555555555";
    private static readonly string RoutingKeyValue = RoutingKey.Compute(InstanceKey, "validator-session");

    [Fact]
    public void Register_adapter_without_complete_surface_identity_is_rejected()
    {
        var clock = new FakeClock();
        var message = MessageFactory.RegisterAdapter(
            clock,
            AdapterKey,
            "chrome");
        message.BrowserKind = null;
        message.ProfileKey = null;

        var response = MessageValidator.ValidateRegisterAdapter(message);

        Assert.NotNull(response);
        Assert.Equal(RouteResults.Rejected, response!.Result);
        Assert.Equal(RejectReasons.MissingField, response.Reason);
    }

    [Fact]
    public void Register_adapter_with_mismatched_surface_kinds_is_rejected()
    {
        var clock = new FakeClock();
        var message = MessageFactory.RegisterAdapter(
            clock,
            AdapterKey,
            "chrome");
        message.BrowserKind = "edge";

        var response = MessageValidator.ValidateRegisterAdapter(message);

        Assert.NotNull(response);
        Assert.Equal(RouteResults.Rejected, response!.Result);
        Assert.Equal(RejectReasons.InvalidField, response.Reason);
    }

    [Fact]
    public void Non_surface_adapter_kind_cannot_register_as_notification_owner()
    {
        var clock = new FakeClock();
        var message = MessageFactory.RegisterAdapter(
            clock,
            AdapterKey,
            "client");

        var response = MessageValidator.ValidateRegisterAdapter(message);

        Assert.NotNull(response);
        Assert.Equal(RouteResults.Rejected, response!.Result);
        Assert.Equal(RejectReasons.InvalidField, response.Reason);
    }

    [Fact]
    public void Explicit_open_without_event_id_is_rejected_as_missing_field()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.ExplicitOpen, openedAtMs: clock.UtcNowMs);

        AssertRejected(message, RejectReasons.MissingField);
    }

    [Fact]
    public void Explicit_open_without_timestamp_is_rejected_as_missing_field()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.ExplicitOpen, openEventId: "open-event-0001");

        AssertRejected(message, RejectReasons.MissingField);
    }

    [Fact]
    public void Explicit_open_persisted_before_clock_rollback_is_valid()
    {
        var clock = new FakeClock();
        var message = Build(
            clock,
            OwnerEvents.ExplicitOpen,
            openEventId: "open-event-0001",
            openedAtMs: clock.UtcNowMs + 60_001);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    [Fact]
    public void Explicit_open_retry_has_no_past_age_limit()
    {
        var clock = new FakeClock();
        var message = Build(
            clock,
            OwnerEvents.ExplicitOpen,
            openEventId: "open-event-0001",
            openedAtMs: clock.UtcNowMs - 30 * 24 * 60 * 60_000L);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    [Fact]
    public void Restore_with_event_id_is_rejected_as_invalid_field()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.Restore, openEventId: "open-event-0001");

        AssertRejected(message, RejectReasons.InvalidField);
    }

    [Fact]
    public void Restore_with_timestamp_is_rejected_as_invalid_field()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.Restore, openedAtMs: clock.UtcNowMs);

        AssertRejected(message, RejectReasons.InvalidField);
    }

    [Fact]
    public void Explicit_open_with_complete_binding_candidate_metadata_is_valid()
    {
        var clock = new FakeClock();
        var message = Build(
            clock,
            OwnerEvents.ExplicitOpen,
            openEventId: "open-event-0001",
            openedAtMs: clock.UtcNowMs);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    [Fact]
    public void Restore_without_binding_candidate_metadata_is_valid()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.Restore);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    [Fact]
    public void Owner_without_complete_surface_identity_is_rejected()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.Restore);
        message.ProfileKey = null;

        AssertRejected(message, RejectReasons.MissingField);
    }

    [Fact]
    public void Legacy_owner_without_event_or_binding_candidate_metadata_is_valid()
    {
        var clock = new FakeClock();
        var message = Build(clock);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    [Theory]
    [InlineData("short")]
    [InlineData("bad/path")]
    [InlineData("bad=value")]
    public void Owner_with_non_portable_instance_key_is_rejected(string instanceKey)
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.Restore);
        message.InstanceKey = instanceKey;

        AssertRejected(message, RejectReasons.InvalidField);
    }

    [Fact]
    public void Freeze_with_non_portable_instance_key_is_rejected()
    {
        var clock = new FakeClock();
        var message = MessageFactory.Freeze(
            clock,
            "notification-validation-0001",
            "bad/path",
            RoutingKeyValue);

        var response = MessageValidator.ValidateFreeze(message);

        Assert.NotNull(response);
        Assert.Equal(RouteResults.Rejected, response!.Result);
        Assert.Equal(RejectReasons.InvalidField, response.Reason);
    }

    [Theory]
    [InlineData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    [InlineData("YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo0123456789_-opaque-key")]
    public void Owner_and_freeze_reject_non_sha256_routing_keys(string routingKey)
    {
        var clock = new FakeClock();
        var owner = Build(clock, OwnerEvents.Restore);
        owner.RoutingKey = routingKey;
        AssertRejected(owner, RejectReasons.InvalidField);

        var freeze = MessageFactory.Freeze(
            clock,
            "notification-invalid-routing-key",
            InstanceKey,
            routingKey);
        var freezeResponse = MessageValidator.ValidateFreeze(freeze);

        Assert.NotNull(freezeResponse);
        Assert.Equal(RouteResults.Rejected, freezeResponse!.Result);
        Assert.Equal(RejectReasons.InvalidField, freezeResponse.Reason);
    }

    private static RouteMessage Build(
        FakeClock clock,
        string? ownerEvent = null,
        string? openEventId = null,
        long? openedAtMs = null)
    {
        var message = MessageFactory.RegisterOwner(
            clock,
            AdapterKey,
            "chrome",
            OwnerKey,
            PageKey,
            InstanceKey,
            RoutingKeyValue,
            ownerEvent: ownerEvent,
            openEventId: openEventId,
            openedAtMs: openedAtMs);
        message.AdapterKind = "chrome";
        message.BrowserKind = "chrome";
        message.ProfileKey = "profile-validation-0001";
        return message;
    }

    private static void AssertRejected(RouteMessage message, string reason)
    {
        var response = MessageValidator.ValidateRegisterOwner(message);

        Assert.NotNull(response);
        Assert.Equal(RouteResults.Rejected, response!.Result);
        Assert.Equal(reason, response.Reason);
    }
}
