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
/// material and are never forwarded to the daemon. Requests are forwarded with bounded
/// concurrency and read-side backpressure; responses may complete out of order and are correlated
/// by requestId. All stdout writes are serialized so response frames and wake frames cannot
/// interleave 32-bit length prefixes.
/// </summary>
public sealed class NativeMessagingRelay
{
    public const int DefaultMaxConcurrentForwards = 8;

    private readonly string? _callerOrigin;
    private readonly IReadOnlySet<string> _allowedOrigins;
    private readonly Func<RouteMessage, CancellationToken, Task<RouteResponse>> _forward;
    private readonly Stream _input;
    private readonly Stream _output;
    private readonly bool _ownsOutput;
    private readonly Action<int>? _terminateProcess;
    private readonly Func<Task>? _beforeWakeCommitAsync;
    private readonly Func<CancellationToken, Task>? _beforeWakeGateWaitAsync;
    private readonly Func<Task>? _afterGracefulInputClosedAsync;
    private readonly Action? _wakeLoopStopped;
    private readonly TimeSpan _wakeInterval;
    private readonly Func<TimeSpan, CancellationToken, Task>? _delayAsync;
    private readonly TimeSpan _outputWriteTimeout;
    private readonly int _maxConcurrentForwards;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly object _wakeCommitSync = new();
    private int _fatalOutputFailure;
    private bool _gracefulInputClosed;
    private long _wakeSeq;

    public NativeMessagingRelay(
        string? callerOrigin,
        IEnumerable<string>? allowedOrigins,
        Func<RouteMessage, CancellationToken, Task<RouteResponse>> forward,
        Stream? input = null,
        Stream? output = null,
        TimeSpan? wakeInterval = null,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
        TimeSpan? outputWriteTimeout = null,
        int maxConcurrentForwards = DefaultMaxConcurrentForwards,
        Action<int>? terminateProcess = null,
        Func<Task>? beforeWakeCommitAsync = null,
        Func<CancellationToken, Task>? beforeWakeGateWaitAsync = null,
        Func<Task>? afterGracefulInputClosedAsync = null,
        Action? wakeLoopStopped = null)
    {
        _callerOrigin = callerOrigin;
        _allowedOrigins = allowedOrigins is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : new HashSet<string>(allowedOrigins, StringComparer.Ordinal);
        _forward = forward;
        _input = input ?? Console.OpenStandardInput();
        _ownsOutput = output is null;
        _output = output ?? Console.OpenStandardOutput();
        _terminateProcess = _ownsOutput
            ? terminateProcess ?? Environment.Exit
            : terminateProcess;
        _beforeWakeCommitAsync = beforeWakeCommitAsync;
        _beforeWakeGateWaitAsync = beforeWakeGateWaitAsync;
        _afterGracefulInputClosedAsync = afterGracefulInputClosedAsync;
        _wakeLoopStopped = wakeLoopStopped;
        _wakeInterval = wakeInterval ?? TimeSpan.FromMilliseconds(ProtocolConstants.NativeWakeIntervalMs);
        _delayAsync = delayAsync;
        _outputWriteTimeout = outputWriteTimeout ??
            TimeSpan.FromMilliseconds(
                ProtocolConstants.NativeStdoutWriteTimeoutMs);
        if (_outputWriteTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(outputWriteTimeout));
        }

        if (maxConcurrentForwards <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxConcurrentForwards));
        }

        _maxConcurrentForwards = maxConcurrentForwards;
    }

    /// <summary>Number of wake frames successfully written (test/diagnostic).</summary>
    public long WakeCount => Interlocked.Read(ref _wakeSeq);

    internal bool HadFatalOutputFailure =>
        Volatile.Read(ref _fatalOutputFailure) != 0;

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
        using var wakeCts =
            CancellationTokenSource.CreateLinkedTokenSource(runCts.Token);
        lock (_wakeCommitSync)
        {
            Volatile.Write(
                ref _gracefulInputClosed,
                false);
        }

        Task? wakeTask = null;
        if (_wakeInterval > TimeSpan.Zero)
        {
            wakeTask = RunWakeLoopAsync(runCts, wakeCts.Token);
        }

        var inFlight = new HashSet<Task>();
        var drainAcceptedRequests = false;
        try
        {
            while (!runCts.IsCancellationRequested)
            {
                await ReapForCapacityAsync(inFlight, runCts.Token)
                    .ConfigureAwait(false);
                if (runCts.IsCancellationRequested)
                {
                    break;
                }

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
                    await MarkGracefulInputClosedAsync(wakeCts)
                        .ConfigureAwait(false);
                    drainAcceptedRequests = true;
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
                    await MarkGracefulInputClosedAsync(wakeCts)
                        .ConfigureAwait(false);
                    drainAcceptedRequests = true;
                    break; // stdin closed
                }

                inFlight.Add(ProcessInboundFrameAsync(body, runCts));
                await ReapCompletedAsync(inFlight).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
            when (runCts.IsCancellationRequested)
        {
            // Normal external cancellation or wake-loop shutdown.
        }
        catch (IOException)
        {
            SafeLog.Warn("native-stdout-failed", ("reason", "io"));
        }
        catch (ObjectDisposedException)
        {
            // Browser closed one of the native streams.
        }
        finally
        {
            // EOF is graceful: keep accepted requests alive until their response writes
            // complete. Stop unsolicited wake writes first so a closed browser
            // stdout cannot cancel already accepted work. Fatal I/O and external
            // cancellation still stop both wake and forwards immediately.
            var gracefulEof =
                drainAcceptedRequests &&
                !runCts.IsCancellationRequested;
            if (gracefulEof)
            {
                CancelRun(wakeCts);
                if (wakeTask is not null)
                {
                    await ObserveWakeTaskAsync(wakeTask).ConfigureAwait(false);
                    wakeTask = null;
                }
            }
            else
            {
                CancelRun(runCts);
            }

            await AwaitInFlightAsync(inFlight).ConfigureAwait(false);

            // Accepted EOF work is now drained; stop the wake loop and observe it.
            CancelRun(runCts);
            CancelRun(wakeCts);
            if (wakeTask is not null)
            {
                await ObserveWakeTaskAsync(wakeTask).ConfigureAwait(false);
            }
        }
    }

    private async Task ProcessInboundFrameAsync(
        byte[] body,
        CancellationTokenSource runCts)
    {
        var cancellationToken = runCts.Token;
        try
        {
            var msg = RouteMessage.TryParse(body, out var parseError);
            if (msg is null)
            {
                var err = RouteResponse.Reject(
                    string.Empty,
                    RouteResults.Rejected,
                    parseError ?? RejectReasons.InvalidField);
                await WriteStdoutFrameAsync(err.ToUtf8Bytes(), cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            // Never accept inbound wake frames as route traffic (host→browser only).
            if (string.Equals(msg.Type, MessageTypes.Wake, StringComparison.Ordinal))
            {
                var err = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.UnknownType);
                await WriteStdoutFrameAsync(err.ToUtf8Bytes(), cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            // Browser adapters may register, refresh, poll, and acknowledge
            // activation. Listener-owned freeze/activate/status operations
            // stay on the current-user pipe and cannot cross this boundary.
            if (msg.Type is null ||
                !ProtocolConstants.AllowedNativeAdapterMessageTypes.Contains(msg.Type))
            {
                var err = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.CallerRejected);
                await WriteStdoutFrameAsync(err.ToUtf8Bytes(), cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            RouteResponse response;
            try
            {
                response = await _forward(msg, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                SafeLog.Error("native-forward-error", ("reason", ex.GetType().Name));
                response = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.AdapterUnavailable,
                    "daemon-unreachable");
            }

            await WriteStdoutFrameAsync(response.ToUtf8Bytes(), cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Coordinated relay shutdown.
        }
        catch (IOException)
        {
            SafeLog.Warn("native-stdout-failed", ("reason", "io"));
            CancelRun(runCts);
        }
        catch (ObjectDisposedException)
        {
            CancelRun(runCts);
        }
        catch (Exception ex)
        {
            SafeLog.Error("native-request-error", ("reason", ex.GetType().Name));
            CancelRun(runCts);
        }
    }

    private async Task ReapForCapacityAsync(
        HashSet<Task> inFlight,
        CancellationToken cancellationToken)
    {
        await ReapCompletedAsync(inFlight).ConfigureAwait(false);
        while (inFlight.Count >= _maxConcurrentForwards &&
               !cancellationToken.IsCancellationRequested)
        {
            var completed = await Task.WhenAny(inFlight).ConfigureAwait(false);
            inFlight.Remove(completed);
            await ObserveWorkerAsync(completed).ConfigureAwait(false);
            await ReapCompletedAsync(inFlight).ConfigureAwait(false);
        }
    }

    private static async Task ReapCompletedAsync(HashSet<Task> inFlight)
    {
        foreach (var completed in inFlight.Where(task => task.IsCompleted).ToArray())
        {
            inFlight.Remove(completed);
            await ObserveWorkerAsync(completed).ConfigureAwait(false);
        }
    }

    private static async Task AwaitInFlightAsync(HashSet<Task> inFlight)
    {
        foreach (var task in inFlight.ToArray())
        {
            await ObserveWorkerAsync(task).ConfigureAwait(false);
        }

        inFlight.Clear();
    }

    private static async Task ObserveWorkerAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Worker cancellation is coordinated by the relay.
        }
        catch (Exception ex)
        {
            // ProcessInboundFrameAsync is fail-contained, but still observe any
            // unexpected task fault so shutdown cannot leak an unobserved exception.
            SafeLog.Warn("native-worker-stop-error", ("reason", ex.GetType().Name));
        }
    }

    private async Task RunWakeLoopAsync(
        CancellationTokenSource runCts,
        CancellationToken cancellationToken)
    {
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
                    var written = await TryWriteWakeFrameAsync(
                            body,
                            runCts.Token,
                            cancellationToken)
                        .ConfigureAwait(false);
                    if (!written)
                    {
                        break;
                    }

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
            if (!cancellationToken.IsCancellationRequested &&
                !Volatile.Read(ref _gracefulInputClosed))
            {
                CancelRun(runCts);
            }

            _wakeLoopStopped?.Invoke();
        }
    }

    private static async Task ObserveWakeTaskAsync(Task wakeTask)
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
            SafeLog.Warn(
                "native-wake-stop-error",
                ("reason", ex.GetType().Name));
        }
    }

    private async Task MarkGracefulInputClosedAsync(
        CancellationTokenSource wakeCts)
    {
        lock (_wakeCommitSync)
        {
            Volatile.Write(
                ref _gracefulInputClosed,
                true);
        }

        try
        {
            if (_afterGracefulInputClosedAsync is not null)
            {
                await _afterGracefulInputClosedAsync()
                    .ConfigureAwait(false);
            }
        }
        finally
        {
            CancelRun(wakeCts);
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
    private async Task<bool> TryWriteWakeFrameAsync(
        ReadOnlyMemory<byte> utf8Json,
        CancellationToken runCancellationToken,
        CancellationToken wakeCancellationToken)
    {
        var wakeCommitted = 0;
        using var timeoutCts =
            new CancellationTokenSource(_outputWriteTimeout);
        using var writeCts =
            CancellationTokenSource.CreateLinkedTokenSource(
                runCancellationToken,
                timeoutCts.Token);
        using var gateWaitCts =
            CancellationTokenSource.CreateLinkedTokenSource(
                writeCts.Token,
                wakeCancellationToken);
        using var timeoutRegistration = timeoutCts.Token.Register(
            () =>
            {
                if (Volatile.Read(ref _gracefulInputClosed) &&
                    Volatile.Read(ref wakeCommitted) == 0)
                {
                    return;
                }

                RequestTimeoutTermination(runCancellationToken);
            });
        var gateHeld = false;
        try
        {
            if (_beforeWakeGateWaitAsync is not null)
            {
                await _beforeWakeGateWaitAsync(gateWaitCts.Token)
                    .ConfigureAwait(false);
            }

            await _writeGate.WaitAsync(gateWaitCts.Token)
                .ConfigureAwait(false);
            gateHeld = true;

            if (_beforeWakeCommitAsync is not null)
            {
                await _beforeWakeCommitAsync().ConfigureAwait(false);
            }

            Task writeTask;
            lock (_wakeCommitSync)
            {
                if (_gracefulInputClosed ||
                    wakeCancellationToken.IsCancellationRequested)
                {
                    return false;
                }

                Volatile.Write(
                    ref wakeCommitted,
                    1);
                writeTask = NativeMessageFraming.WriteFrameAsync(
                    _output,
                    utf8Json,
                    writeCts.Token);
            }

            await writeTask.ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException)
            when ((wakeCancellationToken.IsCancellationRequested ||
                   Volatile.Read(ref _gracefulInputClosed)) &&
                  Volatile.Read(ref wakeCommitted) == 0)
        {
            return false;
        }
        catch (OperationCanceledException)
            when (!runCancellationToken.IsCancellationRequested &&
                  timeoutCts.IsCancellationRequested)
        {
            MarkFatalOutputFailure();
            throw new IOException("native-stdout-timeout");
        }
        catch (IOException)
        {
            MarkFatalOutputFailure();
            throw;
        }
        catch (ObjectDisposedException)
        {
            MarkFatalOutputFailure();
            throw;
        }
        finally
        {
            if (gateHeld)
            {
                _writeGate.Release();
            }
        }
    }

    private async Task WriteStdoutFrameAsync(ReadOnlyMemory<byte> utf8Json, CancellationToken cancellationToken)
    {
        using var timeoutCts =
            new CancellationTokenSource(_outputWriteTimeout);
        using var writeCts =
            CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                timeoutCts.Token);
        var writeToken = writeCts.Token;
        using var timeoutRegistration = timeoutCts.Token.Register(
            () => RequestTimeoutTermination(cancellationToken));
        var gateHeld = false;
        try
        {
            await _writeGate.WaitAsync(writeToken).ConfigureAwait(false);
            gateHeld = true;
            await NativeMessageFraming
                .WriteFrameAsync(_output, utf8Json, writeToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
            when (!cancellationToken.IsCancellationRequested &&
                  timeoutCts.IsCancellationRequested)
        {
            MarkFatalOutputFailure();
            throw new IOException("native-stdout-timeout");
        }
        catch (IOException)
        {
            MarkFatalOutputFailure();
            throw;
        }
        catch (ObjectDisposedException)
        {
            MarkFatalOutputFailure();
            throw;
        }
        finally
        {
            if (gateHeld)
            {
                _writeGate.Release();
            }
        }
    }

    private void RequestTimeoutTermination(
        CancellationToken cancellationToken)
    {
        var exitCode = 1;
        if (!cancellationToken.IsCancellationRequested)
        {
            MarkFatalOutputFailure();
        }
        else if (!HadFatalOutputFailure)
        {
            // A real Windows stdout write may ignore cancellation. Give a
            // normal relay shutdown until the original write deadline, then
            // terminate the dedicated native-host process successfully rather
            // than leave an orphaned blocked writer.
            exitCode = 0;
        }

        try
        {
            _terminateProcess?.Invoke(exitCode);
        }
        catch (Exception ex)
        {
            SafeLog.Warn(
                "native-stdout-terminate-error",
                ("reason", ex.GetType().Name));
        }
    }

    private void MarkFatalOutputFailure()
    {
        Interlocked.Exchange(ref _fatalOutputFailure, 1);
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
