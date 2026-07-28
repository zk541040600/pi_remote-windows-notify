using System.Text;
using System.Text.Json;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using Xunit;

namespace PiNotifyRouteHost.Tests;

/// <summary>
/// Deterministic tests for unsolicited host→extension wake frames.
/// Uses injected delay (no real long sleeps) and controllable stdin streams.
/// </summary>
public class NativeWakeTests
{
    private const string AllowedOrigin = "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";

    /// <summary>
    /// Readable stream that blocks until <see cref="SignalEof"/> (or cancellation), then returns EOF.
    /// Optional preloaded frames are returned first.
    /// </summary>
    private sealed class ControllableInputStream : Stream
    {
        private readonly Queue<byte> _buffer = new();
        private readonly object _gate = new();
        private readonly TaskCompletionSource _eof = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool _completed;

        public void EnqueueFrame(ReadOnlySpan<byte> utf8Json)
        {
            var frame = NativeMessageFraming.Encode(utf8Json);
            lock (_gate)
            {
                foreach (var b in frame)
                {
                    _buffer.Enqueue(b);
                }
            }
        }

        public void SignalEof()
        {
            lock (_gate)
            {
                _completed = true;
            }

            _eof.TrySetResult();
        }

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            lock (_gate)
            {
                if (_buffer.Count > 0)
                {
                    var n = Math.Min(buffer.Length, _buffer.Count);
                    for (var i = 0; i < n; i++)
                    {
                        buffer.Span[i] = _buffer.Dequeue();
                    }

                    return ValueTask.FromResult(n);
                }

                if (_completed)
                {
                    return ValueTask.FromResult(0);
                }
            }

            return new ValueTask<int>(WaitForEofAsync(buffer, cancellationToken));
        }

        /// <summary>Wait for EOF/cancellation without retaining a Span across an await.</summary>
        private async Task<int> WaitForEofAsync(Memory<byte> buffer, CancellationToken cancellationToken)
        {
            await _eof.Task.WaitAsync(cancellationToken);
            return await ReadAsync(buffer, cancellationToken);
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException("Use ReadAsync");

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    /// <summary>Writable stream whose async write always fails like a closed browser stdout.</summary>
    private sealed class FailingOutputStream : Stream
    {
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) =>
            ValueTask.FromException(new IOException("stdout-closed"));

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new IOException("stdout-closed");

        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public void Wake_frame_bytes_are_versioned_and_free_of_sensitive_fields()
    {
        var body = NativeMessagingRelay.BuildWakeFrameBytes(seq: 7);
        var text = Encoding.UTF8.GetString(body);

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        Assert.Equal(MessageTypes.Wake, root.GetProperty("type").GetString());
        Assert.Equal(ProtocolConstants.ProtocolVersion, root.GetProperty("protocolVersion").GetInt32());
        Assert.Equal(7, root.GetProperty("seq").GetInt64());

        foreach (var forbidden in new[]
                 {
                     "sessionId", "session", "routingKey", "instanceKey", "token",
                     "url", "pageUrl", "body", "title", "ownerKey", "pageKey",
                     "adapterKey", "notificationId", "snapshotId", "activationRequestId",
                 })
        {
            Assert.False(root.TryGetProperty(forbidden, out _), $"wake must not contain {forbidden}");
        }

        Assert.DoesNotContain("http://", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https://", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("session=", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Wake_message_type_is_not_in_allowed_daemon_message_types()
    {
        Assert.DoesNotContain(MessageTypes.Wake, ProtocolConstants.AllowedMessageTypes);
        Assert.Equal("wake", MessageTypes.Wake);
        Assert.Equal(1_000, ProtocolConstants.NativeWakeIntervalMs);
        Assert.True(ProtocolConstants.NativeWakeIntervalMs * 3 < ProtocolConstants.DefaultClientWaitMs);
    }

    [Fact]
    public async Task Relay_emits_one_wake_frame_then_stops_on_stdin_eof()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();

        using var wakeWriteReady = new ManualResetEventSlim(false);
        var delayCalls = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("unused")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: async (_, ct) =>
            {
                var n = Interlocked.Increment(ref delayCalls);
                if (n == 1)
                {
                    // Return immediately so the wake frame is written.
                    return;
                }

                wakeWriteReady.Set();
                try
                {
                    await Task.Delay(Timeout.Infinite, ct);
                }
                catch (OperationCanceledException)
                {
                    // expected after EOF cancels run CTS
                }
            });

        var run = relay.RunAsync();

        // Wait until second delay starts → first wake write has completed.
        Assert.True(wakeWriteReady.Wait(TimeSpan.FromSeconds(5)), "first wake was not written");
        Assert.True(relay.WakeCount >= 1);

        input.SignalEof();
        await run;

        var final = relay.WakeCount;
        Assert.True(final >= 1);

        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(
            output,
            ProtocolConstants.MaxNativeFrameBytes,
            CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains("\"type\":\"wake\"", text, StringComparison.Ordinal);
        Assert.Contains("\"protocolVersion\":1", text, StringComparison.Ordinal);
        Assert.DoesNotContain("routingKey", text, StringComparison.Ordinal);
        Assert.DoesNotContain("instanceKey", text, StringComparison.Ordinal);
        Assert.DoesNotContain("session", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Relay_does_not_start_wake_for_disallowed_origin()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();
        var delayCalls = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: Array.Empty<string>(),
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("x")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, _) =>
            {
                Interlocked.Increment(ref delayCalls);
                return Task.CompletedTask;
            });

        await relay.RunAsync();

        Assert.Equal(0, delayCalls);
        Assert.Equal(0, relay.WakeCount);

        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(
            output,
            ProtocolConstants.MaxNativeFrameBytes,
            CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains(RejectReasons.CallerRejected, text, StringComparison.Ordinal);
        Assert.DoesNotContain("\"type\":\"wake\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Concurrent_response_and_wake_keep_framing_uncorrupted()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();

        var forwardEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var allowForward = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var delayCalls = 0;

        var health = new RouteMessage
        {
            ProtocolVersion = ProtocolConstants.ProtocolVersion,
            Type = MessageTypes.Health,
            RequestId = "req-concurrent-wake-01",
            IssuedAtMs = 1_700_000_000_000,
            ExpiresAtMs = 1_700_000_005_000,
        };
        input.EnqueueFrame(health.ToUtf8Bytes());

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: async (msg, _) =>
            {
                forwardEntered.TrySetResult();
                await allowForward.Task.WaitAsync(TimeSpan.FromSeconds(5));
                return RouteResponse.Ok(msg.RequestId, RouteResults.Ok);
            },
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: async (_, ct) =>
            {
                var n = Interlocked.Increment(ref delayCalls);
                if (n == 1)
                {
                    // Wait until forward is in-flight so wake write races the response write.
                    await forwardEntered.Task.WaitAsync(TimeSpan.FromSeconds(5), ct);
                    return; // proceed to wake write
                }

                try
                {
                    await Task.Delay(Timeout.Infinite, ct);
                }
                catch (OperationCanceledException)
                {
                    // expected
                }
            });

        var run = relay.RunAsync();

        await forwardEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        // Let wake delay complete and contend for write gate.
        await Task.Delay(20);
        allowForward.TrySetResult();

        // After response is written, next stdin read blocks until EOF.
        // Wait for at least one wake, then signal EOF to finish cleanly.
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (relay.WakeCount < 1 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }

        Assert.True(relay.WakeCount >= 1, "expected wake under concurrency");
        input.SignalEof();

        await run;

        output.Position = 0;
        var frames = new List<string>();
        while (true)
        {
            var body = await NativeMessageFraming.ReadFrameAsync(
                output,
                ProtocolConstants.MaxNativeFrameBytes,
                CancellationToken.None);
            if (body is null)
            {
                break;
            }

            var text = Encoding.UTF8.GetString(body);
            using var doc = JsonDocument.Parse(text);
            frames.Add(text);
        }

        Assert.True(frames.Count >= 2, $"expected response + wake, got {frames.Count}");
        Assert.Contains(frames, f => f.Contains("\"type\":\"wake\"", StringComparison.Ordinal));
        Assert.Contains(frames, f => f.Contains("req-concurrent-wake-01", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Wake_stdout_failure_cancels_relay_while_stdin_is_blocked()
    {
        await using var input = new ControllableInputStream();
        await using var output = new FailingOutputStream();
        var delayCalls = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("unused")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, _) =>
            {
                Interlocked.Increment(ref delayCalls);
                return Task.CompletedTask;
            });

        await relay.RunAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(1, delayCalls);
        Assert.Equal(0, relay.WakeCount);
    }

    [Fact]
    public async Task Wake_delay_failure_is_observed_and_cancels_blocked_read()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();
        var delayCalls = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("unused")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, _) =>
            {
                Interlocked.Increment(ref delayCalls);
                return Task.FromException(new InvalidOperationException("wake-delay-failed"));
            });

        await relay.RunAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(1, delayCalls);
        Assert.Equal(0, relay.WakeCount);
    }

    [Fact]
    public async Task Wake_stops_on_cancellation_token()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();

        using var cts = new CancellationTokenSource();
        using var firstWakeWritten = new ManualResetEventSlim(false);
        var delayCalls = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("x")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: async (_, ct) =>
            {
                var n = Interlocked.Increment(ref delayCalls);
                if (n == 1)
                {
                    return; // write first wake
                }

                firstWakeWritten.Set();
                try
                {
                    await Task.Delay(Timeout.Infinite, ct);
                }
                catch (OperationCanceledException)
                {
                    // expected
                }
            });

        var run = relay.RunAsync(cts.Token);
        Assert.True(firstWakeWritten.Wait(TimeSpan.FromSeconds(5)));
        Assert.True(relay.WakeCount >= 1);

        await cts.CancelAsync();
        await run;

        var wakesAfterCancel = relay.WakeCount;
        await Task.Delay(20);
        Assert.Equal(wakesAfterCancel, relay.WakeCount);
    }

    [Fact]
    public async Task Wake_stops_on_stdin_close()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();

        using var firstWakeWritten = new ManualResetEventSlim(false);
        using var wakeStopped = new ManualResetEventSlim(false);
        var delayCalls = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("x")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: async (_, ct) =>
            {
                var n = Interlocked.Increment(ref delayCalls);
                if (n == 1)
                {
                    return;
                }

                firstWakeWritten.Set();
                try
                {
                    await Task.Delay(Timeout.Infinite, ct);
                }
                catch (OperationCanceledException)
                {
                    // expected after stdin EOF
                }
                finally
                {
                    wakeStopped.Set();
                }
            });

        var run = relay.RunAsync();
        Assert.True(firstWakeWritten.Wait(TimeSpan.FromSeconds(5)));
        Assert.True(relay.WakeCount >= 1);

        input.SignalEof();
        await run;

        Assert.True(wakeStopped.IsSet, "RunAsync returned before wake cleanup completed");
        var final = relay.WakeCount;
        await Task.Delay(20);
        Assert.Equal(final, relay.WakeCount);
    }

    [Fact]
    public async Task Inbound_wake_type_is_rejected_and_not_forwarded()
    {
        await using var input = new ControllableInputStream();
        await using var output = new MemoryStream();

        var forwarded = 0;
        var wakeBody = NativeMessagingRelay.BuildWakeFrameBytes(1);
        input.EnqueueFrame(wakeBody);
        input.SignalEof();

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) =>
            {
                Interlocked.Increment(ref forwarded);
                return Task.FromResult(RouteResponse.Ok("should-not-run"));
            },
            input: input,
            output: output,
            wakeInterval: TimeSpan.Zero);

        await relay.RunAsync();

        Assert.Equal(0, forwarded);

        output.Position = 0;
        var body = await NativeMessageFraming.ReadFrameAsync(
            output,
            ProtocolConstants.MaxNativeFrameBytes,
            CancellationToken.None);
        Assert.NotNull(body);
        var text = Encoding.UTF8.GetString(body!);
        Assert.Contains(RejectReasons.UnknownType, text, StringComparison.Ordinal);
        Assert.Contains(RouteResults.Rejected, text, StringComparison.Ordinal);
    }
}
