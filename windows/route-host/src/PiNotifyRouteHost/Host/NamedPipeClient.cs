using System.IO.Pipes;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.Host;

/// <summary>One-shot or short-session client for daemon named pipe.</summary>
public sealed class NamedPipeRouteClient : IAsyncDisposable
{
    private readonly string _pipeName;
    private NamedPipeClientStream? _stream;

    public NamedPipeRouteClient(string? pipeName = null)
    {
        _pipeName = PipeNames.GetDaemonPipeName(pipeName);
    }

    public async Task ConnectAsync(int timeoutMs = 2000, CancellationToken cancellationToken = default)
    {
        _stream = new NamedPipeClientStream(
            serverName: ".",
            pipeName: _pipeName,
            direction: PipeDirection.InOut,
            options: PipeOptions.Asynchronous);

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(timeoutMs);
        await _stream.ConnectAsync(cts.Token).ConfigureAwait(false);
    }

    public async Task<RouteResponse> SendAsync(RouteMessage message, CancellationToken cancellationToken = default)
    {
        if (_stream is null || !_stream.IsConnected)
        {
            throw new InvalidOperationException("Pipe client is not connected.");
        }

        var body = message.ToUtf8Bytes();
        if (body.Length > ProtocolConstants.MaxMessageBytes)
        {
            return RouteResponse.Reject(message.RequestId, RouteResults.Oversized, RejectReasons.Oversized);
        }

        await LengthPrefixedJson.WriteAsync(_stream, body, cancellationToken).ConfigureAwait(false);
        var responseBody = await LengthPrefixedJson.ReadAsync(_stream, ProtocolConstants.MaxMessageBytes, cancellationToken)
            .ConfigureAwait(false);
        if (responseBody is null)
        {
            return RouteResponse.Reject(message.RequestId, RouteResults.AdapterUnavailable, "pipe-closed");
        }

        var response = System.Text.Json.JsonSerializer.Deserialize<RouteResponse>(responseBody, JsonDefaults.Options);
        if (response is null ||
            response.ProtocolVersion != ProtocolConstants.ProtocolVersion ||
            !string.Equals(response.Type, MessageTypes.Result, StringComparison.Ordinal) ||
            !string.Equals(response.RequestId, message.RequestId, StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                message.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        return response;
    }

    /// <summary>
    /// Connect and exchange one request under a single bounded transport budget.
    /// External cancellation still propagates; a local timeout is a structured
    /// adapter-unavailable response so native and CLI callers can keep running.
    /// </summary>
    public async Task<RouteResponse> SendRequestAsync(
        RouteMessage message,
        int timeoutMs = ProtocolConstants.DefaultRequestTtlMs,
        CancellationToken cancellationToken = default)
    {
        if (timeoutMs <= 0)
        {
            return RouteResponse.Reject(
                message.RequestId,
                RouteResults.AdapterUnavailable,
                "pipe-timeout");
        }

        var boundedTimeoutMs = Math.Min(
            timeoutMs,
            ProtocolConstants.MaxRequestTtlMs);
        using var requestCts =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        requestCts.CancelAfter(boundedTimeoutMs);

        try
        {
            await ConnectAsync(
                    Math.Min(2000, boundedTimeoutMs),
                    requestCts.Token)
                .ConfigureAwait(false);
            return await SendAsync(message, requestCts.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
            when (!cancellationToken.IsCancellationRequested)
        {
            return RouteResponse.Reject(
                message.RequestId,
                RouteResults.AdapterUnavailable,
                "pipe-timeout");
        }
        catch (TimeoutException)
        {
            return RouteResponse.Reject(
                message.RequestId,
                RouteResults.AdapterUnavailable,
                "pipe-timeout");
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_stream is not null)
        {
            await _stream.DisposeAsync().ConfigureAwait(false);
            _stream = null;
        }
    }
}
