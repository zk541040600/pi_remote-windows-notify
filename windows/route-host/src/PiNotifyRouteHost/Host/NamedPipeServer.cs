using System.Collections.Concurrent;
using System.IO.Pipes;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.Host;

/// <summary>
/// Daemon named-pipe listener. The production default uses Windows LOCAL\ pipe
/// scope so independent login sessions cannot share one daemon endpoint.
/// </summary>
public sealed class NamedPipeRouteServer : IAsyncDisposable
{
    private readonly RouteDispatcher _dispatcher;
    private readonly string _pipeName;
    private readonly TimeSpan _clientIdleTimeout;
    private readonly TimeSpan _clientWriteTimeout;
    private readonly CancellationTokenSource _cts = new();
    private readonly ConcurrentDictionary<long, Task> _clientTasks = new();
    private Task? _acceptLoop;
    private int _started;
    private long _nextClientId;

    public NamedPipeRouteServer(
        RouteDispatcher dispatcher,
        string? pipeName = null,
        TimeSpan? clientIdleTimeout = null,
        TimeSpan? clientWriteTimeout = null)
    {
        _dispatcher = dispatcher;
        _pipeName = PipeNames.GetDaemonPipeName(pipeName);
        _clientIdleTimeout = clientIdleTimeout ??
            TimeSpan.FromMilliseconds(
                ProtocolConstants.PipeClientIdleTimeoutMs);
        if (_clientIdleTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(clientIdleTimeout));
        }

        _clientWriteTimeout = clientWriteTimeout ??
            TimeSpan.FromMilliseconds(
                ProtocolConstants.PipeClientWriteTimeoutMs);
        if (_clientWriteTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(clientWriteTimeout));
        }
    }

    public string PipeName => _pipeName;

    public void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) == 1)
        {
            return;
        }

        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        SafeLog.Info("daemon-start", ("pipe", _pipeName), ("daemonId", _dispatcher.State.DaemonId));
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            NamedPipeServerStream? pipe = null;
            try
            {
                pipe = CreateServerStream();
                await pipe.WaitForConnectionAsync(ct).ConfigureAwait(false);
                var connected = pipe;
                pipe = null;
                // Do not pass the shutdown token to Task.Run itself. If it is
                // canceled between accept and scheduling, the delegate would
                // never run and the accepted pipe would never be disposed.
                TrackClient(
                    Task.Run(() => HandleClientAsync(connected, ct)));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                SafeLog.Error("daemon-accept-error", ("reason", ex.GetType().Name));
                if (pipe is not null)
                {
                    await pipe.DisposeAsync().ConfigureAwait(false);
                }

                try
                {
                    await Task.Delay(50, ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }

    private async Task HandleClientAsync(NamedPipeServerStream pipe, CancellationToken ct)
    {
        await using (pipe)
        using (var clientBudgetCts =
               CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            try
            {
                while (pipe.IsConnected && !ct.IsCancellationRequested)
                {
                    byte[]? body;
                    try
                    {
                        clientBudgetCts.CancelAfter(_clientIdleTimeout);
                        body = await LengthPrefixedJson
                            .ReadAsync(
                                pipe,
                                ProtocolConstants.MaxMessageBytes,
                                clientBudgetCts.Token)
                            .ConfigureAwait(false);
                        clientBudgetCts.CancelAfter(
                            Timeout.InfiniteTimeSpan);
                    }
                    catch (InvalidOperationException)
                    {
                        var err = RouteResponse.Reject(string.Empty, RouteResults.Oversized, RejectReasons.Oversized);
                        await TryWriteResponseAsync(
                                pipe,
                                err,
                                clientBudgetCts,
                                ct)
                            .ConfigureAwait(false);
                        break;
                    }
                    catch (OperationCanceledException)
                        when (!ct.IsCancellationRequested)
                    {
                        break;
                    }

                    if (body is null)
                    {
                        break;
                    }

                    var msg = RouteMessage.TryParse(body, out var parseError);
                    if (msg is null)
                    {
                        var err = RouteResponse.Reject(string.Empty, RouteResults.Rejected, parseError ?? RejectReasons.InvalidField);
                        if (!await TryWriteResponseAsync(
                                pipe,
                                err,
                                clientBudgetCts,
                                ct)
                            .ConfigureAwait(false))
                        {
                            break;
                        }
                        continue;
                    }

                    var response = await _dispatcher.DispatchAsync(msg, ct).ConfigureAwait(false);
                    if (!await TryWriteResponseAsync(
                            pipe,
                            response,
                            clientBudgetCts,
                            ct)
                        .ConfigureAwait(false))
                    {
                        break;
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                // shutting down
            }
            catch (IOException)
            {
                // client disconnected
            }
            catch (Exception ex)
            {
                SafeLog.Error("daemon-client-error", ("reason", ex.GetType().Name));
            }
        }
    }

    private void TrackClient(Task clientTask)
    {
        var clientId = Interlocked.Increment(ref _nextClientId);
        _clientTasks[clientId] = clientTask;
        _ = clientTask.ContinueWith(
            completed =>
            {
                _ = completed.Exception;
                _clientTasks.TryRemove(clientId, out _);
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private async Task<bool> TryWriteResponseAsync(
        Stream pipe,
        RouteResponse response,
        CancellationTokenSource clientBudgetCts,
        CancellationToken shutdownToken)
    {
        try
        {
            clientBudgetCts.CancelAfter(_clientWriteTimeout);
            var bytes = response.ToUtf8Bytes();
            await LengthPrefixedJson
                .WriteAsync(pipe, bytes, clientBudgetCts.Token)
                .ConfigureAwait(false);
            clientBudgetCts.CancelAfter(Timeout.InfiniteTimeSpan);
            return true;
        }
        catch (OperationCanceledException)
            when (!shutdownToken.IsCancellationRequested)
        {
            return false;
        }
    }

    private NamedPipeServerStream CreateServerStream()
    {
        // Restrict every pipe instance to the daemon's Windows user. This is the protocol's
        // authorization boundary; browser origin checks are an additional Native Messaging boundary.
        return new NamedPipeServerStream(
            _pipeName,
            PipeDirection.InOut,
            NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
            inBufferSize: ProtocolConstants.MaxMessageBytes + 16,
            outBufferSize: ProtocolConstants.MaxMessageBytes + 16);
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        if (_acceptLoop is not null)
        {
            try
            {
                await _acceptLoop.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // expected
            }
        }

        var clientTasks = _clientTasks.Values.ToArray();
        if (clientTasks.Length > 0)
        {
            try
            {
                await Task.WhenAll(clientTasks).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected after the server shutdown token is canceled.
            }
        }

        _cts.Dispose();
    }
}
