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
        return response ?? RouteResponse.Reject(message.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
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
