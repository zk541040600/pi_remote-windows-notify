using System.Diagnostics;
using System.IO.Pipes;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public sealed class ClientWaitBudgetTests
{
    [Fact]
    public async Task Client_wait_budget_bounds_pipe_connect()
    {
        var pipeName = NewPipeName();
        var requestPath = WriteActivateRequest();

        try
        {
            var (exitCode, elapsed) = await RunBoundedClientAsync(
                pipeName,
                requestPath);

            Assert.Equal(3, exitCode);
            Assert.InRange(elapsed.TotalMilliseconds, 1, 1_500);
        }
        finally
        {
            File.Delete(requestPath);
        }
    }

    [Fact]
    public async Task Client_wait_budget_bounds_initial_activate_send()
    {
        var pipeName = NewPipeName();
        var requestPath = WriteActivateRequest();
        using var serverCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var serverTask = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync(serverCts.Token);
            var request = await LengthPrefixedJson.ReadAsync(
                server,
                ProtocolConstants.MaxMessageBytes,
                serverCts.Token);
            Assert.NotNull(request);
            await Task.Delay(Timeout.InfiniteTimeSpan, serverCts.Token);
        });

        try
        {
            var (exitCode, elapsed) = await RunBoundedClientAsync(
                pipeName,
                requestPath);

            Assert.Equal(3, exitCode);
            Assert.InRange(elapsed.TotalMilliseconds, 1, 1_500);
        }
        finally
        {
            serverCts.Cancel();
            try
            {
                await serverTask;
            }
            catch (OperationCanceledException)
            {
                // Expected after the bounded client returns.
            }
            File.Delete(requestPath);
        }
    }

    [Fact]
    public async Task Bounded_request_exchange_times_out_a_stalled_response()
    {
        var pipeName = NewPipeName();
        using var serverCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var serverTask = Task.Run(async () =>
        {
            await server.WaitForConnectionAsync(serverCts.Token);
            var request = await LengthPrefixedJson.ReadAsync(
                server,
                ProtocolConstants.MaxMessageBytes,
                serverCts.Token);
            Assert.NotNull(request);
            await Task.Delay(Timeout.InfiniteTimeSpan, serverCts.Token);
        });

        try
        {
            await using var client = new NamedPipeRouteClient(pipeName);
            var request = MessageFactory.Health(new FakeClock());
            var stopwatch = Stopwatch.StartNew();
            var response = await client.SendRequestAsync(
                request,
                timeoutMs: 150);
            stopwatch.Stop();

            Assert.Equal(RouteResults.AdapterUnavailable, response.Result);
            Assert.Equal("pipe-timeout", response.Reason);
            Assert.InRange(stopwatch.Elapsed.TotalMilliseconds, 1, 1_500);
        }
        finally
        {
            serverCts.Cancel();
            try
            {
                await serverTask;
            }
            catch (OperationCanceledException)
            {
                // Expected after the bounded client returns.
            }
        }
    }

    [Theory]
    [InlineData("invalid")]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("30001")]
    public async Task Client_rejects_invalid_wait_budget_instead_of_falling_back_to_one_shot(
        string waitValue)
    {
        var pipeName = NewPipeName();
        var requestPath = WriteActivateRequest();
        using var serverCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var serverTask = RunAcceptedResponseServerAsync(pipeName, serverCts.Token);

        try
        {
            var exitCode = await Program.Main(
            [
                "--client",
                "--pipe",
                pipeName,
                "--json",
                requestPath,
                "--wait-ms",
                waitValue
            ]);

            Assert.Equal(1, exitCode);
        }
        finally
        {
            serverCts.Cancel();
            await IgnoreCancellationAsync(serverTask);
            File.Delete(requestPath);
        }
    }

    [Fact]
    public async Task Client_rejects_wait_option_without_a_value()
    {
        var pipeName = NewPipeName();
        var requestPath = WriteActivateRequest();
        using var serverCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var serverTask = RunAcceptedResponseServerAsync(pipeName, serverCts.Token);

        try
        {
            var exitCode = await Program.Main(
            [
                "--client",
                "--pipe",
                pipeName,
                "--json",
                requestPath,
                "--wait-ms"
            ]);

            Assert.Equal(1, exitCode);
        }
        finally
        {
            serverCts.Cancel();
            await IgnoreCancellationAsync(serverTask);
            File.Delete(requestPath);
        }
    }

    [Fact]
    public async Task Client_rejects_duplicate_wait_options()
    {
        var pipeName = NewPipeName();
        var requestPath = WriteActivateRequest();
        using var serverCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var serverTask = RunAcceptedResponseServerAsync(pipeName, serverCts.Token);

        try
        {
            var exitCode = await Program.Main(
            [
                "--client",
                "--pipe",
                pipeName,
                "--json",
                requestPath,
                "--wait-ms",
                "150",
                "--wait-ms",
                "150"
            ]);

            Assert.Equal(1, exitCode);
        }
        finally
        {
            serverCts.Cancel();
            await IgnoreCancellationAsync(serverTask);
            File.Delete(requestPath);
        }
    }

    [Fact]
    public async Task Client_rejects_wait_option_for_a_non_activate_request()
    {
        var pipeName = NewPipeName();
        var requestPath = WriteHealthRequest();
        using var serverCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var serverTask = RunAcceptedResponseServerAsync(pipeName, serverCts.Token);

        try
        {
            var exitCode = await Program.Main(
            [
                "--client",
                "--pipe",
                pipeName,
                "--json",
                requestPath,
                "--wait-ms",
                "150"
            ]);

            Assert.Equal(1, exitCode);
        }
        finally
        {
            serverCts.Cancel();
            await IgnoreCancellationAsync(serverTask);
            File.Delete(requestPath);
        }
    }

    private static async Task<(int ExitCode, TimeSpan Elapsed)>
        RunBoundedClientAsync(
            string pipeName,
            string requestPath)
    {
        var stopwatch = Stopwatch.StartNew();
        var runTask = Program.Main(
        [
            "--client",
            "--pipe",
            pipeName,
            "--json",
            requestPath,
            "--wait-ms",
            "150"
        ]);
        var completed = await Task.WhenAny(
            runTask,
            Task.Delay(TimeSpan.FromSeconds(2)));
        stopwatch.Stop();

        Assert.Same(runTask, completed);
        return (await runTask, stopwatch.Elapsed);
    }

    private static string WriteActivateRequest()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"pi-notify-client-wait-{Guid.NewGuid():N}.json");
        var request = MessageFactory.Activate(
            new FakeClock(),
            "notification-wait-budget",
            "snapshot-wait-budget");
        File.WriteAllBytes(path, request.ToUtf8Bytes());
        return path;
    }

    private static string WriteHealthRequest()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"pi-notify-client-health-{Guid.NewGuid():N}.json");
        var request = MessageFactory.Health(new FakeClock());
        File.WriteAllBytes(path, request.ToUtf8Bytes());
        return path;
    }

    private static async Task RunAcceptedResponseServerAsync(
        string pipeName,
        CancellationToken cancellationToken)
    {
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await server.WaitForConnectionAsync(cancellationToken);
        for (var i = 0; i < 2; i++)
        {
            var body = await LengthPrefixedJson.ReadAsync(
                server,
                ProtocolConstants.MaxMessageBytes,
                cancellationToken);
            if (body is null)
            {
                return;
            }

            var request = RouteMessage.TryParse(body, out var parseError);
            Assert.Null(parseError);
            Assert.NotNull(request);

            var response = RouteResponse.Ok(
                request!.RequestId,
                string.Equals(
                    request.Type,
                    MessageTypes.ActivationStatus,
                    StringComparison.Ordinal)
                    ? RouteResults.SessionUrlConfirmed
                    : RouteResults.Accepted);
            response.ActivationRequestId =
                request.ActivationRequestId ?? request.RequestId;
            await LengthPrefixedJson.WriteAsync(
                server,
                response.ToUtf8Bytes(),
                cancellationToken);

            if (!string.Equals(
                    request.Type,
                    MessageTypes.Activate,
                    StringComparison.Ordinal))
            {
                return;
            }
        }
    }

    private static async Task IgnoreCancellationAsync(Task task)
    {
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
            // Expected when CLI validation rejects before opening the pipe.
        }
    }

    private static string NewPipeName() =>
        "PiNotifyRouteHost.Test." + Guid.NewGuid().ToString("N");
}
