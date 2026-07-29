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

    [Theory]
    [InlineData(60_001)]
    [InlineData(-86_400_001)]
    public void Explicit_open_with_out_of_bounds_timestamp_is_rejected_as_invalid_field(long offsetMs)
    {
        var clock = new FakeClock();
        var message = Build(
            clock,
            OwnerEvents.ExplicitOpen,
            openEventId: "open-event-0001",
            openedAtMs: clock.UtcNowMs + offsetMs);

        AssertRejected(message, RejectReasons.InvalidField);
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
    public void Explicit_open_with_complete_ordering_metadata_is_valid()
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
    public void Restore_without_ordering_metadata_is_valid()
    {
        var clock = new FakeClock();
        var message = Build(clock, OwnerEvents.Restore);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    [Fact]
    public void Legacy_owner_without_event_or_ordering_metadata_is_valid()
    {
        var clock = new FakeClock();
        var message = Build(clock);

        Assert.Null(MessageValidator.ValidateRegisterOwner(message));
    }

    private static RouteMessage Build(
        FakeClock clock,
        string? ownerEvent = null,
        string? openEventId = null,
        long? openedAtMs = null) =>
        MessageFactory.RegisterOwner(
            clock,
            AdapterKey,
            OwnerKey,
            PageKey,
            InstanceKey,
            RoutingKeyValue,
            ownerEvent: ownerEvent,
            openEventId: openEventId,
            openedAtMs: openedAtMs);

    private static void AssertRejected(RouteMessage message, string reason)
    {
        var response = MessageValidator.ValidateRegisterOwner(message);

        Assert.NotNull(response);
        Assert.Equal(RouteResults.Rejected, response!.Result);
        Assert.Equal(reason, response.Reason);
    }
}
