using System.IO.Pipes;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.Host;

/// <summary>
/// Daemon named-pipe listener. On Windows, pipe name is user-session local by convention
/// (Local\ scope via name choice at install time). Cross-platform byte-mode framing for tests.
/// </summary>
public sealed class NamedPipeRouteServer : IAsyncDisposable
{
    private readonly RouteDispatcher _dispatcher;
    private readonly string _pipeName;
    private readonly CancellationTokenSource _cts = new();
    private Task? _acceptLoop;
    private int _started;

    public NamedPipeRouteServer(RouteDispatcher dispatcher, string? pipeName = null)
    {
        _dispatcher = dispatcher;
        _pipeName = PipeNames.GetDaemonPipeName(pipeName);
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
                _ = Task.Run(() => HandleClientAsync(connected, ct), ct);
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
        {
            try
            {
                while (pipe.IsConnected && !ct.IsCancellationRequested)
                {
                    byte[]? body;
                    try
                    {
                        body = await LengthPrefixedJson.ReadAsync(pipe, ProtocolConstants.MaxMessageBytes, ct)
                            .ConfigureAwait(false);
                    }
                    catch (InvalidOperationException)
                    {
                        var err = RouteResponse.Reject(string.Empty, RouteResults.Oversized, RejectReasons.Oversized);
                        await WriteResponseAsync(pipe, err, ct).ConfigureAwait(false);
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
                        await WriteResponseAsync(pipe, err, ct).ConfigureAwait(false);
                        continue;
                    }

                    var response = await _dispatcher.DispatchAsync(msg, ct).ConfigureAwait(false);
                    await WriteResponseAsync(pipe, response, ct).ConfigureAwait(false);
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

    private static async Task WriteResponseAsync(Stream pipe, RouteResponse response, CancellationToken ct)
    {
        var bytes = response.ToUtf8Bytes();
        await LengthPrefixedJson.WriteAsync(pipe, bytes, ct).ConfigureAwait(false);
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

        _cts.Dispose();
    }
}
