using System.Text;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class NativeRelayAndValidationTests
{
    [Theory]
    [InlineData("chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/", true)]
    [InlineData("chrome-extension://short/", false)]
    [InlineData("https://evil.example/", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Extension_origin_shape(string? origin, bool expected)
    {
        Assert.Equal(expected, origin is not null && NativeMessagingRelay.IsChromeExtensionOrigin(origin));
    }

    [Fact]
    public void Allowlist_is_fail_closed_when_empty()
    {
        var allowed = new HashSet<string>(StringComparer.Ordinal);
        Assert.False(NativeMessagingRelay.IsAllowedOrigin(
            "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/", allowed));
    }

    [Fact]
    public void Allowlist_accepts_exact_origin_only()
    {
        const string origin = "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";
        var allowed = new HashSet<string>(StringComparer.Ordinal) { origin };
        Assert.True(NativeMessagingRelay.IsAllowedOrigin(origin, allowed));
        Assert.False(NativeMessagingRelay.IsAllowedOrigin(
            "chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/", allowed));
    }

    [Fact]
    public async Task Relay_rejects_disallowed_caller_before_forward()
    {
        var forwarded = false;
        await using var input = new MemoryStream();
        await using var output = new MemoryStream();

        var relay = new NativeMessagingRelay(
            callerOrigin: "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/",
            allowedOrigins: Array.Empty<string>(),
            forward: (_, _) =>
            {
                forwarded = true;
                return Task.FromResult(RouteResponse.Ok("x"));
            },
            input: input,
            output: output);

        await relay.RunAsync();
        Assert.False(forwarded);

        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(output, ProtocolConstants.MaxNativeFrameBytes, CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains(RouteResults.Rejected, text, StringComparison.Ordinal);
        Assert.Contains(RejectReasons.CallerRejected, text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Relay_forwards_register_and_blocks_freeze()
    {
        var clock = new FakeClock();
        var state = new RouteStateMachine(clock);
        var dispatcher = new RouteDispatcher(state, clock);
        const string origin = "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";

        await using var input = new MemoryStream();
        await using var output = new MemoryStream();

        // Write freeze then end stdin by leaving no more data after Run reads.
        var freeze = MessageFactory.Freeze(
            clock,
            "notif-native-0001",
            "11111111-2222-3333-4444-555555555555",
            RoutingKey.Compute("11111111-2222-3333-4444-555555555555", "s"));
        await NativeMessageFraming.WriteFrameAsync(input, freeze.ToUtf8Bytes(), CancellationToken.None);
        input.Position = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: origin,
            allowedOrigins: new[] { origin },
            forward: (msg, ct) => dispatcher.DispatchAsync(msg, ct),
            input: input,
            output: output);

        await relay.RunAsync();

        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(output, ProtocolConstants.MaxNativeFrameBytes, CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains(RejectReasons.CallerRejected, text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Relay_forwards_register_open_intent_from_allowed_origin()
    {
        var clock = new FakeClock();
        const string origin =
            "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";
        const string instanceKey =
            "11111111-2222-3333-4444-555555555555";
        var forwarded = false;
        RouteMessage? forwardedMessage = null;
        await using var input = new MemoryStream();
        await using var output = new MemoryStream();
        var message = MessageFactory.RegisterOpenIntent(
            clock,
            "adapter-native-open-intent",
            "chrome",
            instanceKey,
            RoutingKey.Compute(instanceKey, "native-open-intent-session"),
            "open-event-native-intent",
            clock.UtcNowMs);
        await NativeMessageFraming.WriteFrameAsync(
            input,
            message.ToUtf8Bytes(),
            CancellationToken.None);
        input.Position = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: origin,
            allowedOrigins: new[] { origin },
            forward: (received, _) =>
            {
                forwarded = true;
                forwardedMessage = received;
                return Task.FromResult(RouteResponse.Ok(received.RequestId));
            },
            input: input,
            output: output);

        await relay.RunAsync();

        Assert.True(forwarded);
        Assert.NotNull(forwardedMessage);
        Assert.Equal(MessageTypes.RegisterOpenIntent, forwardedMessage!.Type);
        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(
            output,
            ProtocolConstants.MaxNativeFrameBytes,
            CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains($"\"result\":\"{RouteResults.Ok}\"", text, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(MessageTypes.Activate)]
    [InlineData(MessageTypes.ActivationStatus)]
    public async Task Relay_blocks_listener_only_messages_before_forward(string messageType)
    {
        var clock = new FakeClock();
        const string origin = "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";
        var forwarded = false;
        await using var input = new MemoryStream();
        await using var output = new MemoryStream();
        var message = MessageFactory.Create(messageType, clock);
        message.NotificationId = "notif-native-blocked";
        message.SnapshotId = "snapshot-native-blocked";
        message.ActivationRequestId = "activation-native-blocked";
        await NativeMessageFraming.WriteFrameAsync(
            input,
            message.ToUtf8Bytes(),
            CancellationToken.None);
        input.Position = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: origin,
            allowedOrigins: new[] { origin },
            forward: (_, _) =>
            {
                forwarded = true;
                return Task.FromResult(RouteResponse.Ok(message.RequestId));
            },
            input: input,
            output: output);

        await relay.RunAsync();

        Assert.False(forwarded);
        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(
            output,
            ProtocolConstants.MaxNativeFrameBytes,
            CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains(RejectReasons.CallerRejected, text, StringComparison.Ordinal);
    }

    [Fact]
    public void Message_parse_rejects_oversized_payload()
    {
        var huge = new byte[ProtocolConstants.MaxMessageBytes + 10];
        Array.Fill(huge, (byte)'a');
        var msg = RouteMessage.TryParse(huge, out var error);
        Assert.Null(msg);
        Assert.Equal(RejectReasons.Oversized, error);
    }

    [Fact]
    public void Message_parse_rejects_unknown_fields()
    {
        var json = Encoding.UTF8.GetBytes(
            """
            {
              "protocolVersion": 1,
              "type": "health",
              "requestId": "request-unknown-field",
              "issuedAtMs": 1700000000000,
              "expiresAtMs": 1700000005000,
              "sessionId": "must-not-be-smuggled"
            }
            """);

        var msg = RouteMessage.TryParse(json, out var error);

        Assert.Null(msg);
        Assert.Equal(RejectReasons.InvalidField, error);
    }

    [Fact]
    public void Message_parse_accepts_one_UTF8_BOM_at_the_transport_boundary()
    {
        var request = MessageFactory.Health(new FakeClock()).ToUtf8Bytes();
        var payload = new byte[Encoding.UTF8.Preamble.Length + request.Length];
        Encoding.UTF8.Preamble.CopyTo(payload);
        request.CopyTo(payload.AsSpan(Encoding.UTF8.Preamble.Length));

        var msg = RouteMessage.TryParse(payload, out var error);

        Assert.NotNull(msg);
        Assert.Null(error);
        Assert.Equal(MessageTypes.Health, msg!.Type);
    }

    [Fact]
    public void Message_parse_rejects_multiple_UTF8_BOMs()
    {
        var request = MessageFactory.Health(new FakeClock()).ToUtf8Bytes();
        var payload = new byte[(Encoding.UTF8.Preamble.Length * 2) + request.Length];
        Encoding.UTF8.Preamble.CopyTo(payload);
        Encoding.UTF8.Preamble.CopyTo(
            payload.AsSpan(Encoding.UTF8.Preamble.Length));
        request.CopyTo(payload.AsSpan(Encoding.UTF8.Preamble.Length * 2));

        var msg = RouteMessage.TryParse(payload, out var error);

        Assert.Null(msg);
        Assert.Equal(RejectReasons.InvalidField, error);
    }

    [Fact]
    public void SafeLog_sanitizes_urls_and_long_hex()
    {
        var sanitized = Logging.SafeLog.SanitizeValue("see https://10.23.50.137:30141/?session=abcdef0123456789abcdef0123456789 now");
        Assert.DoesNotContain("10.23.50.137", sanitized, StringComparison.Ordinal);
        Assert.DoesNotContain("abcdef0123456789abcdef0123456789", sanitized, StringComparison.Ordinal);
        Assert.Contains("[url]", sanitized, StringComparison.Ordinal);
    }
}
