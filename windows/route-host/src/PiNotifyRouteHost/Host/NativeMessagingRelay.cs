using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.Host;

/// <summary>
/// Native Messaging mode: Chrome/Edge launches this process; stdin/stdout use 32-bit framing.
/// Relay validates schema and forwards to the daemon named pipe. Diagnostics go to stderr only.
/// Caller origin is the first CLI argument supplied by the browser (chrome-extension://&lt;id&gt;/).
///
/// After origin allowlist validation the relay emits bounded unsolicited <c>wake</c> frames on
/// stdout. Inbound Native Messaging traffic wakes the MV3 service worker so poll-activation can
/// run while the worker would otherwise be idle. Wake frames never carry session/URL/routing
/// material and are never forwarded to the daemon. All stdout writes are serialized so response
/// frames and wake frames cannot interleave 32-bit length prefixes.
/// </summary>
public sealed class NativeMessagingRelay
{
    private readonly string? _callerOrigin;
    private readonly IReadOnlySet<string> _allowedOrigins;
    private readonly Func<RouteMessage, CancellationToken, Task<RouteResponse>> _forward;
    private readonly Stream _input;
    private readonly Stream _output;
    private readonly TimeSpan _wakeInterval;
    private readonly Func<TimeSpan, CancellationToken, Task>? _delayAsync;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private long _wakeSeq;

    public NativeMessagingRelay(
        string? callerOrigin,
        IEnumerable<string>? allowedOrigins,
        Func<RouteMessage, CancellationToken, Task<RouteResponse>> forward,
        Stream? input = null,
        Stream? output = null,
        TimeSpan? wakeInterval = null,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null)
    {
        _callerOrigin = callerOrigin;
        _allowedOrigins = allowedOrigins is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : new HashSet<string>(allowedOrigins, StringComparer.Ordinal);
        _forward = forward;
        _input = input ?? Console.OpenStandardInput();
        _output = output ?? Console.OpenStandardOutput();
        _wakeInterval = wakeInterval ?? TimeSpan.FromMilliseconds(ProtocolConstants.NativeWakeIntervalMs);
        _delayAsync = delayAsync;
    }

    /// <summary>Number of wake frames successfully written (test/diagnostic).</summary>
    public long WakeCount => Interlocked.Read(ref _wakeSeq);

    public static bool IsAllowedOrigin(string? origin, IReadOnlySet<string> allowed)
    {
        if (string.IsNullOrWhiteSpace(origin))
        {
            return false;
        }

        if (allowed.Count == 0)
        {
            // Fail-closed when no allowlist configured.
            return false;
        }

        return allowed.Contains(origin);
    }

    public static bool IsChromeExtensionOrigin(string origin)
    {
        if (!origin.StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var rest = origin["chrome-extension://".Length..];
        if (rest.EndsWith('/'))
        {
            rest = rest[..^1];
        }

        // Extension IDs are 32 lowercase a-p chars for Chrome; Edge may differ slightly — accept opaque alnum.
        if (rest.Length is < 16 or > 64)
        {
            return false;
        }

        foreach (var c in rest)
        {
            if (!char.IsAsciiLetterOrDigit(c))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Build the UTF-8 body of an internal wake frame. Exposed for tests so framing/content
    /// assertions do not depend on private serialization details.
    /// </summary>
    public static byte[] BuildWakeFrameBytes(long seq)
    {
        return WakeMessage.Create(seq).ToUtf8Bytes();
    }

    public async Task RunAsync(CancellationToken cancellationToken = default)
    {
        if (!IsAllowedOrigin(_callerOrigin, _allowedOrigins) ||
            _callerOrigin is null ||
            !IsChromeExtensionOrigin(_callerOrigin))
        {
            SafeLog.Warn("native-caller-rejected", ("originFp", FingerprintOrigin(_callerOrigin)));
            var rejected = RouteResponse.Reject(string.Empty, RouteResults.Rejected, RejectReasons.CallerRejected);
            // No wake task for rejected callers — single reject frame then exit.
            await WriteStdoutFrameAsync(rejected.ToUtf8Bytes(), cancellationToken).ConfigureAwait(false);
            return;
        }

        SafeLog.Info("native-relay-start", ("originFp", FingerprintOrigin(_callerOrigin)));

        using var runCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task? wakeTask = null;
        if (_wakeInterval > TimeSpan.Zero)
        {
            wakeTask = RunWakeLoopAsync(runCts);
        }

        try
        {
            while (!runCts.IsCancellationRequested)
            {
                byte[]? body;
                try
                {
                    body = await NativeMessageFraming.ReadFrameAsync(
                            _input,
                            ProtocolConstants.MaxNativeFrameBytes,
                            runCts.Token)
                        .ConfigureAwait(false);
                }
                catch (ObjectDisposedException)
                {
                    break; // stdin disposed/closed
                }
                catch (InvalidOperationException)
                {
                    var oversized = RouteResponse.Reject(string.Empty, RouteResults.Oversized, RejectReasons.Oversized);
                    try
                    {
                        await WriteStdoutFrameAsync(oversized.ToUtf8Bytes(), runCts.Token).ConfigureAwait(false);
                    }
                    catch (IOException)
                    {
                        // stdout already gone
                    }
                    catch (ObjectDisposedException)
                    {
                        // stdout already gone
                    }

                    break;
                }
                catch (OperationCanceledException) when (runCts.IsCancellationRequested)
                {
                    break;
                }
                catch (IOException)
                {
                    break; // stdin broken
                }

                if (body is null)
                {
                    break; // stdin closed
                }

                var msg = RouteMessage.TryParse(body, out var parseError);
                if (msg is null)
                {
                    var err = RouteResponse.Reject(string.Empty, RouteResults.Rejected, parseError ?? RejectReasons.InvalidField);
                    await WriteStdoutFrameAsync(err.ToUtf8Bytes(), runCts.Token).ConfigureAwait(false);
                    continue;
                }

                // Never accept inbound wake frames as route traffic (host→browser only).
                if (string.Equals(msg.Type, MessageTypes.Wake, StringComparison.Ordinal))
                {
                    var err = RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.UnknownType);
                    await WriteStdoutFrameAsync(err.ToUtf8Bytes(), runCts.Token).ConfigureAwait(false);
                    continue;
                }

                // Native path only allows registration/heartbeat/health from the extension; freeze/activate
                // come from listener via daemon pipe. Still accept activate-result from extension.
                if (msg.Type is MessageTypes.Freeze)
                {
                    var err = RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.CallerRejected);
                    await WriteStdoutFrameAsync(err.ToUtf8Bytes(), runCts.Token).ConfigureAwait(false);
                    continue;
                }

                RouteResponse response;
                try
                {
                    response = await _forward(msg, runCts.Token).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    SafeLog.Error("native-forward-error", ("reason", ex.GetType().Name));
                    response = RouteResponse.Reject(msg.RequestId, RouteResults.AdapterUnavailable, "daemon-unreachable");
                }

                try
                {
                    await WriteStdoutFrameAsync(response.ToUtf8Bytes(), runCts.Token).ConfigureAwait(false);
                }
                catch (IOException)
                {
                    SafeLog.Warn("native-stdout-failed", ("reason", "io"));
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
            }
        }
        finally
        {
            // Cancel wake loop and await it so no orphan task remains.
            try
            {
                runCts.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // already disposed
            }

            if (wakeTask is not null)
            {
                try
                {
                    await wakeTask.ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    // expected on shutdown
                }
                catch (Exception ex)
                {
                    SafeLog.Warn("native-wake-stop-error", ("reason", ex.GetType().Name));
                }
            }
        }
    }

    private async Task RunWakeLoopAsync(CancellationTokenSource runCts)
    {
        var cancellationToken = runCts.Token;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await DelayAsync(_wakeInterval, cancellationToken).ConfigureAwait(false);
                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }

                var seq = Interlocked.Read(ref _wakeSeq) + 1;
                var body = BuildWakeFrameBytes(seq);
                try
                {
                    await WriteStdoutFrameAsync(body, cancellationToken).ConfigureAwait(false);
                    Interlocked.Exchange(ref _wakeSeq, seq);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (IOException)
                {
                    SafeLog.Warn("native-wake-stdout-failed", ("reason", "io"));
                    CancelRun(runCts);
                    break;
                }
                catch (ObjectDisposedException)
                {
                    CancelRun(runCts);
                    break;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // normal shutdown
        }
        finally
        {
            // Any wake-loop exit not caused by normal relay shutdown must stop the read loop.
            // This covers unexpected delay/write faults as well as stdout closure while stdin blocks.
            if (!cancellationToken.IsCancellationRequested)
            {
                CancelRun(runCts);
            }
        }
    }

    private static void CancelRun(CancellationTokenSource runCts)
    {
        try
        {
            runCts.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // Relay shutdown already disposed the linked source.
        }
    }

    private Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        if (_delayAsync is not null)
        {
            return _delayAsync(delay, cancellationToken);
        }

        return Task.Delay(delay, cancellationToken);
    }

    /// <summary>
    /// Serialize all native stdout writes (responses, rejects, and wake frames) so 32-bit
    /// length prefixes cannot interleave under concurrent response + wake emission.
    /// </summary>
    private async Task WriteStdoutFrameAsync(ReadOnlyMemory<byte> utf8Json, CancellationToken cancellationToken)
    {
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await NativeMessageFraming.WriteFrameAsync(_output, utf8Json, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private static string FingerprintOrigin(string? origin)
    {
        if (string.IsNullOrEmpty(origin))
        {
            return "-";
        }

        // Never log full extension origin path with query; keep short hash-like token.
        var trimmed = origin.Length > 48 ? origin[..48] : origin;
        var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(trimmed));
        return Convert.ToHexString(hash).ToLowerInvariant()[..12];
    }
}
