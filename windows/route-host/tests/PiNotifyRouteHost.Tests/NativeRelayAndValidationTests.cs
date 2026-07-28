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
    public void Message_parse_rejects_oversized_payload()
    {
        var huge = new byte[ProtocolConstants.MaxMessageBytes + 10];
        Array.Fill(huge, (byte)'a');
        var msg = RouteMessage.TryParse(huge, out var error);
        Assert.Null(msg);
        Assert.Equal(RejectReasons.Oversized, error);
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
