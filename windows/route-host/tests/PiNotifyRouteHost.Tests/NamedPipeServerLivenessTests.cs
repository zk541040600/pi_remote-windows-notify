using System.IO.Pipes;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class NamedPipeServerLivenessTests
{
    [Fact]
    public async Task Client_that_does_not_drain_responses_is_closed_within_the_write_budget()
    {
        var pipeName =
            "PiNotifyRouteHost.Test.Write." + Guid.NewGuid().ToString("N");
        var clock = new FakeClock();
        var state = new RouteStateMachine(clock);
        var dispatcher = new RouteDispatcher(state, clock);
        await using var server = new NamedPipeRouteServer(
            dispatcher,
            pipeName,
            clientWriteTimeout: TimeSpan.FromMilliseconds(100));
        server.Start();

        await using var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await client.ConnectAsync(timeout.Token);
        var requestFrame = LengthPrefixedJson.EncodeBytes(
            MessageFactory.Health(clock).ToUtf8Bytes());

        var peerClosed = false;
        try
        {
            for (var index = 0; index < 20_000; index++)
            {
                await client.WriteAsync(requestFrame, timeout.Token);
            }
        }
        catch (IOException)
        {
            peerClosed = true;
        }

        Assert.True(
            peerClosed,
            "A client that never drains responses must be disconnected.");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(2)]
    public async Task Idle_or_partial_pipe_frame_is_closed_within_the_server_budget(
        int prefixBytes)
    {
        var pipeName =
            "PiNotifyRouteHost.Test.Idle." + Guid.NewGuid().ToString("N");
        var clock = new FakeClock();
        var state = new RouteStateMachine(clock);
        var dispatcher = new RouteDispatcher(state, clock);
        await using var server = new NamedPipeRouteServer(
            dispatcher,
            pipeName,
            clientIdleTimeout: TimeSpan.FromMilliseconds(100));
        server.Start();

        await using var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await client.ConnectAsync(timeout.Token);
        if (prefixBytes > 0)
        {
            await client.WriteAsync(
                new byte[prefixBytes],
                timeout.Token);
        }

        var response = await LengthPrefixedJson.ReadAsync(
            client,
            ProtocolConstants.MaxMessageBytes,
            timeout.Token);

        Assert.Null(response);
    }
}
