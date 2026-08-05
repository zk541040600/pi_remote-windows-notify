using System.IO.Pipes;
using System.Text;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class FramingTests
{
    [Fact]
    public void Default_pipe_is_scoped_to_the_Windows_login_session()
    {
        Assert.Equal(
            @"LOCAL\PiNotifyRouteHost",
            ProtocolConstants.DefaultPipeName);
        Assert.Equal(
            @"LOCAL\PiNotifyRouteHost",
            PipeNames.GetDaemonPipeName());
    }

    [Fact]
    public async Task Session_local_pipe_name_is_accepted_by_server_and_client()
    {
        var pipeName =
            @"LOCAL\PiNotifyRouteHost.Test." + Guid.NewGuid().ToString("N");
        var clock = new FakeClock();
        var state = new RouteStateMachine(clock);
        var dispatcher = new RouteDispatcher(state, clock);
        await using var server = new NamedPipeRouteServer(
            dispatcher,
            pipeName);
        server.Start();

        await using var client = new NamedPipeRouteClient(pipeName);
        await client.ConnectAsync();
        var request = MessageFactory.Health(clock);
        var response = await client.SendAsync(request);

        Assert.Equal(request.RequestId, response.RequestId);
        Assert.Equal(RouteResults.Ok, response.Result);
    }

    [Theory]
    [InlineData(@"GLOBAL\PiNotifyRouteHost")]
    [InlineData(@"LOCAL\")]
    [InlineData(@"LOCAL\Nested\PiNotifyRouteHost")]
    public void Pipe_name_rejects_nonlocal_or_nested_namespace_prefixes(
        string pipeName)
    {
        Assert.Throws<ArgumentException>(
            () => PipeNames.GetDaemonPipeName(pipeName));
    }

    [Fact]
    public void Session_local_pipe_prefix_is_canonicalized()
    {
        Assert.Equal(
            @"LOCAL\PiNotifyRouteHost.Test",
            PipeNames.GetDaemonPipeName(
                @"local\PiNotifyRouteHost.Test"));
    }

    [Fact]
    public void Default_binding_state_is_scoped_to_the_Windows_login_session()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "PiNotifyRouteHost.State." + Guid.NewGuid().ToString("N"));
        var legacyPath =
            SessionStoragePaths.GetLegacyBindingStatePath(root);
        var scopedPath =
            SessionStoragePaths.GetDefaultBindingStatePath(root, 42);
        try
        {
            Directory.CreateDirectory(
                Path.GetDirectoryName(legacyPath) ??
                throw new InvalidOperationException(
                    "Legacy state path has no directory."));
            File.WriteAllText(legacyPath, "legacy-state");

            Assert.NotEqual(legacyPath, scopedPath);
            Assert.Contains(
                Path.Combine("sessions", "session-42"),
                scopedPath,
                StringComparison.OrdinalIgnoreCase);
            Assert.True(
                SessionStoragePaths.TryClaimLegacyBindingState(
                    legacyPath,
                    scopedPath));
            Assert.True(File.Exists(legacyPath));
            Assert.Equal(
                "legacy-state",
                File.ReadAllText(scopedPath));

            var otherSessionPath =
                SessionStoragePaths.GetDefaultBindingStatePath(root, 43);
            Assert.False(
                SessionStoragePaths.TryClaimLegacyBindingState(
                    legacyPath,
                    otherSessionPath));
            Assert.False(File.Exists(otherSessionPath));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void Legacy_binding_claim_resumes_only_in_the_claimed_login_session()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "PiNotifyRouteHost.State." + Guid.NewGuid().ToString("N"));
        var legacyPath =
            SessionStoragePaths.GetLegacyBindingStatePath(root);
        var claimedSessionPath =
            SessionStoragePaths.GetDefaultBindingStatePath(root, 42);
        var otherSessionPath =
            SessionStoragePaths.GetDefaultBindingStatePath(root, 43);
        try
        {
            var productDirectory =
                Path.GetDirectoryName(legacyPath) ??
                throw new InvalidOperationException(
                    "Legacy state path has no directory.");
            Directory.CreateDirectory(productDirectory);
            File.WriteAllText(legacyPath, "legacy-state");

            // Simulate a crash after durable claim publication but before the
            // legacy document was copied into the claimed session.
            File.WriteAllText(
                Path.Combine(
                    productDirectory,
                    "route-preferences.session-migration"),
                "session-42");

            Assert.False(
                SessionStoragePaths.TryClaimLegacyBindingState(
                    legacyPath,
                    otherSessionPath));
            Assert.False(File.Exists(otherSessionPath));

            Assert.True(
                SessionStoragePaths.TryClaimLegacyBindingState(
                    legacyPath,
                    claimedSessionPath));
            Assert.Equal(
                "legacy-state",
                File.ReadAllText(claimedSessionPath));
            Assert.True(File.Exists(legacyPath));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void Encode_decode_round_trip()
    {
        var body = Encoding.UTF8.GetBytes("{\"type\":\"health\"}");
        var frame = NativeMessageFraming.Encode(body);
        Assert.Equal(4 + body.Length, frame.Length);

        ReadOnlySpan<byte> span = frame;
        Assert.True(NativeMessageFraming.TryRead(ref span, out var decoded, out var error));
        Assert.Null(error);
        Assert.Equal(body, decoded);
        Assert.True(span.IsEmpty);
    }

    [Fact]
    public void TryRead_returns_false_when_incomplete()
    {
        var body = Encoding.UTF8.GetBytes("{\"x\":1}");
        var frame = NativeMessageFraming.Encode(body);
        ReadOnlySpan<byte> partial = frame.AsSpan(0, 3);
        Assert.False(NativeMessageFraming.TryRead(ref partial, out _, out var error));
        Assert.Null(error);
    }

    [Fact]
    public void Encode_rejects_oversized_body()
    {
        var huge = new byte[ProtocolConstants.MaxNativeFrameBytes + 1];
        Assert.Throws<InvalidOperationException>(() => NativeMessageFraming.Encode(huge));
    }

    [Fact]
    public void TryRead_flags_oversized_length_prefix()
    {
        var prefix = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(prefix, ProtocolConstants.MaxNativeFrameBytes + 100);
        ReadOnlySpan<byte> span = prefix;
        Assert.False(NativeMessageFraming.TryRead(ref span, out _, out var error));
        Assert.Equal(RejectReasons.Oversized, error);
    }

    [Fact]
    public async Task Stream_round_trip()
    {
        using var ms = new MemoryStream();
        var payload = Encoding.UTF8.GetBytes("{\"ok\":true}");
        await NativeMessageFraming.WriteFrameAsync(ms, payload, CancellationToken.None);
        ms.Position = 0;
        var read = await NativeMessageFraming.ReadFrameAsync(ms, ProtocolConstants.MaxNativeFrameBytes, CancellationToken.None);
        Assert.Equal(payload, read);
    }

    [Fact]
    public async Task Pipe_client_rejects_a_crossed_response_envelope()
    {
        var pipeName = "PiNotifyRouteHost.Test." + Guid.NewGuid().ToString("N");
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var serverTask = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync();
            var requestBody = await LengthPrefixedJson.ReadAsync(
                server,
                ProtocolConstants.MaxMessageBytes,
                CancellationToken.None);
            Assert.NotNull(requestBody);
            await LengthPrefixedJson.WriteAsync(
                server,
                RouteResponse.Ok("another-request-id").ToUtf8Bytes(),
                CancellationToken.None);
        });

        await using var client = new NamedPipeRouteClient(pipeName);
        await client.ConnectAsync();
        var request = MessageFactory.Health(new FakeClock());
        var response = await client.SendAsync(request);
        await serverTask;

        Assert.Equal(request.RequestId, response.RequestId);
        Assert.Equal(RouteResults.Rejected, response.Result);
        Assert.Equal(RejectReasons.InvalidField, response.Reason);
    }
}
