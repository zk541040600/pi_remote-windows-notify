using System.Text.Json;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class NativeRelayConcurrencyTests
{
    private const string AllowedOrigin =
        "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";

    [Fact]
    public async Task Later_request_can_finish_while_first_forward_is_blocked_and_eof_drains_both()
    {
        await using var input = await CreateInputAsync("relay-concurrent-first", "relay-concurrent-second");
        await using var output = new ResponseObservingOutputStream("relay-concurrent-second");
        var firstEntered = NewSignal();
        var releaseFirst = NewSignal();
        var secondFinished = NewSignal();

        var relay = CreateRelay(
            input,
            output,
            async (message, cancellationToken) =>
            {
                if (message.RequestId == "relay-concurrent-first")
                {
                    firstEntered.TrySetResult();
                    await releaseFirst.Task.WaitAsync(cancellationToken);
                }
                else
                {
                    secondFinished.TrySetResult();
                }

                return RouteResponse.Ok(message.RequestId);
            });

        var run = relay.RunAsync();
        await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await secondFinished.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await output.ResponseWritten.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(run.IsCompleted, "EOF must wait for the blocked accepted request");

        releaseFirst.TrySetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        var responses = await ReadResponseIdsAsync(output);
        Assert.Equal(
            new[] { "relay-concurrent-second", "relay-concurrent-first" },
            responses);
    }

    [Fact]
    public async Task Eof_stops_wake_without_canceling_an_accepted_forward()
    {
        const string requestId = "relay-eof-wake-forward";
        await using var seed = await CreateInputAsync(requestId);
        await using var input = new EofSignalingInputStream(seed.ToArray());
        await using var output = new WakeFailingOutputStream(requestId);
        var forwardEntered = NewSignal();
        var forwardRelease = NewSignal();
        var wakeDelayEntered = NewSignal();
        var wakeRelease = NewSignal();
        var wakeTokenCanceled = NewSignal();
        var forwardCanceled = 0;
        var forwardCompleted = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: async (message, cancellationToken) =>
            {
                forwardEntered.TrySetResult();
                try
                {
                    await forwardRelease.Task.WaitAsync(cancellationToken);
                    Interlocked.Exchange(ref forwardCompleted, 1);
                    return RouteResponse.Ok(message.RequestId);
                }
                catch (OperationCanceledException)
                {
                    Interlocked.Exchange(ref forwardCanceled, 1);
                    throw;
                }
            },
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, cancellationToken) =>
            {
                wakeDelayEntered.TrySetResult();
                cancellationToken.Register(
                    () => wakeTokenCanceled.TrySetResult());
                // Deliberately ignore cancellation until the test releases the
                // delay. RunWakeLoopAsync must inspect its token before writing.
                return wakeRelease.Task;
            },
            outputWriteTimeout: TimeSpan.FromSeconds(1));

        var run = relay.RunAsync();
        await forwardEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await wakeDelayEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await input.EofObserved.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var wakeStoppedAtEof = await Task.WhenAny(
            wakeTokenCanceled.Task,
            Task.Delay(TimeSpan.FromMilliseconds(200)));
        wakeRelease.TrySetResult();
        await Task.WhenAny(
            output.WakeWriteAttempted.Task,
            Task.Delay(TimeSpan.FromMilliseconds(100)));
        forwardRelease.TrySetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Same(wakeTokenCanceled.Task, wakeStoppedAtEof);
        Assert.False(output.WakeWriteAttempted.Task.IsCompleted);
        Assert.Equal(0, Volatile.Read(ref forwardCanceled));
        Assert.Equal(1, Volatile.Read(ref forwardCompleted));
        await output.ResponseWritten.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task Eof_after_wake_check_but_before_commit_does_not_emit_wake()
    {
        await using var input = new GatedEofInputStream(Array.Empty<byte>());
        await using var output = new MemoryStream();
        var beforeWakeCommit = NewSignal();
        var releaseWakeCommit = NewSignal();
        var wakeCanceled = NewSignal();

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: (_, _) => Task.FromResult(RouteResponse.Ok("unused")),
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, cancellationToken) =>
            {
                cancellationToken.Register(
                    () => wakeCanceled.TrySetResult());
                return Task.CompletedTask;
            },
            beforeWakeCommitAsync: async () =>
            {
                beforeWakeCommit.TrySetResult();
                await releaseWakeCommit.Task;
            });

        var run = relay.RunAsync();
        await input.EofReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await beforeWakeCommit.Task.WaitAsync(TimeSpan.FromSeconds(5));

        input.AllowEof.TrySetResult();
        await input.EofReturned.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await wakeCanceled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        releaseWakeCommit.TrySetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(0, relay.WakeCount);
        Assert.Empty(output.ToArray());
    }

    [Fact]
    public async Task Precommit_timeout_during_eof_cancel_gap_is_not_fatal()
    {
        const string requestId = "relay-eof-timeout-gap";
        await using var seed = await CreateInputAsync(requestId);
        await using var input = new GatedEofInputStream(seed.ToArray());
        await using var output = new MemoryStream();
        var forwardEntered = NewSignal();
        var forwardRelease = NewSignal();
        var wakeBeforeGateWait = NewSignal();
        var releaseWakeGateWait = NewSignal();
        var wakeWaitCanceled = NewSignal();
        var eofFlagSet = NewSignal();
        var releaseEofCancellation = NewSignal();
        var wakeLoopStopped = NewSignal();
        var forwardCanceled = 0;
        var forwardCompleted = 0;
        var terminationRequests = 0;

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: async (message, cancellationToken) =>
            {
                forwardEntered.TrySetResult();
                try
                {
                    await forwardRelease.Task.WaitAsync(cancellationToken);
                    Interlocked.Exchange(ref forwardCompleted, 1);
                    return RouteResponse.Ok(message.RequestId);
                }
                catch (OperationCanceledException)
                {
                    Interlocked.Exchange(ref forwardCanceled, 1);
                    throw;
                }
            },
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, _) => Task.CompletedTask,
            outputWriteTimeout: TimeSpan.FromMilliseconds(50),
            terminateProcess: _ =>
                Interlocked.Increment(ref terminationRequests),
            beforeWakeGateWaitAsync: async cancellationToken =>
            {
                cancellationToken.Register(
                    () => wakeWaitCanceled.TrySetResult());
                wakeBeforeGateWait.TrySetResult();
                await releaseWakeGateWait.Task;
            },
            afterGracefulInputClosedAsync: async () =>
            {
                eofFlagSet.TrySetResult();
                await releaseEofCancellation.Task;
            },
            wakeLoopStopped: () =>
                wakeLoopStopped.TrySetResult());

        var run = relay.RunAsync();
        await forwardEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await input.EofReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await wakeBeforeGateWait.Task.WaitAsync(TimeSpan.FromSeconds(5));

        input.AllowEof.TrySetResult();
        await eofFlagSet.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await wakeWaitCanceled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        releaseWakeGateWait.TrySetResult();
        await wakeLoopStopped.Task.WaitAsync(TimeSpan.FromSeconds(5));

        releaseEofCancellation.TrySetResult();
        forwardRelease.TrySetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(0, Volatile.Read(ref terminationRequests));
        Assert.Equal(0, Volatile.Read(ref forwardCanceled));
        Assert.Equal(1, Volatile.Read(ref forwardCompleted));
        Assert.Equal(0, relay.WakeCount);
        Assert.Equal(
            new[] { requestId },
            await ReadResponseIdsAsync(output));
    }

    [Fact]
    public async Task Eof_does_not_cancel_a_wake_frame_after_its_prefix_is_written()
    {
        const string requestId = "relay-eof-wake-frame";
        await using var seed = await CreateInputAsync(requestId);
        await using var input = new GatedEofInputStream(seed.ToArray());
        await using var output = new PartialWakeOutputStream();
        var forwardEntered = NewSignal();
        var forwardRelease = NewSignal();
        var wakeDelayEntered = NewSignal();
        var wakeRelease = NewSignal();

        var relay = new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: async (message, cancellationToken) =>
            {
                forwardEntered.TrySetResult();
                await forwardRelease.Task.WaitAsync(cancellationToken);
                return RouteResponse.Ok(message.RequestId);
            },
            input: input,
            output: output,
            wakeInterval: TimeSpan.FromMilliseconds(1),
            delayAsync: (_, _) =>
            {
                wakeDelayEntered.TrySetResult();
                return wakeRelease.Task;
            },
            outputWriteTimeout: TimeSpan.FromSeconds(1));

        var run = relay.RunAsync();
        await forwardEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await wakeDelayEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await input.EofReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        wakeRelease.TrySetResult();
        await output.WakePrefixWritten.Task.WaitAsync(TimeSpan.FromSeconds(5));
        input.AllowEof.TrySetResult();
        await input.EofReturned.Task.WaitAsync(TimeSpan.FromSeconds(5));

        await Task.WhenAny(
            output.WakeWriteCanceled.Task,
            Task.Delay(TimeSpan.FromMilliseconds(200)));
        output.FinishWakeWrite.TrySetResult();
        forwardRelease.TrySetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.False(output.WakeWriteCanceled.Task.IsCompleted);
        AssertWakeThenResponse(output.ToArray(), requestId);
    }

    [Fact]
    public async Task Relay_applies_default_eight_request_backpressure_before_forward()
    {
        var requestIds = Enumerable.Range(0, 9)
            .Select(index => $"relay-bounded-{index:D2}")
            .ToArray();
        await using var input = await CreateInputAsync(requestIds);
        await using var output = new MemoryStream();
        var eightEntered = NewSignal();
        var ninthEntered = NewSignal();
        var release = NewSignal();
        var entered = 0;
        var active = 0;
        var peak = 0;

        var relay = CreateRelay(
            input,
            output,
            async (message, cancellationToken) =>
            {
                var current = Interlocked.Increment(ref active);
                UpdateMaximum(ref peak, current);
                var ordinal = Interlocked.Increment(ref entered);
                if (ordinal == 8)
                {
                    eightEntered.TrySetResult();
                }

                if (ordinal == 9)
                {
                    ninthEntered.TrySetResult();
                }

                try
                {
                    await release.Task.WaitAsync(cancellationToken);
                    return RouteResponse.Ok(message.RequestId);
                }
                finally
                {
                    Interlocked.Decrement(ref active);
                }
            });

        var run = relay.RunAsync();
        await eightEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var prematureNinth = await Task.WhenAny(
            ninthEntered.Task,
            Task.Delay(TimeSpan.FromMilliseconds(150)));
        Assert.NotSame(ninthEntered.Task, prematureNinth);
        Assert.Equal(8, Volatile.Read(ref entered));
        Assert.Equal(8, Volatile.Read(ref peak));

        release.TrySetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(9, Volatile.Read(ref entered));
        Assert.InRange(Volatile.Read(ref peak), 1, 8);
        Assert.Equal(0, Volatile.Read(ref active));
        Assert.Equal(9, (await ReadResponseIdsAsync(output)).Count);
    }

    [Fact]
    public async Task Cancellation_awaits_every_in_flight_forward_without_orphans()
    {
        var requestIds = Enumerable.Range(0, 8)
            .Select(index => $"relay-cancel-{index:D2}")
            .ToArray();
        await using var input = await CreateInputAsync(requestIds);
        await using var output = new MemoryStream();
        using var cancellation = new CancellationTokenSource();
        var allEntered = NewSignal();
        var entered = 0;
        var exited = 0;
        var active = 0;

        var relay = CreateRelay(
            input,
            output,
            async (_, cancellationToken) =>
            {
                Interlocked.Increment(ref active);
                if (Interlocked.Increment(ref entered) == 8)
                {
                    allEntered.TrySetResult();
                }

                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                    return RouteResponse.Ok("unreachable");
                }
                finally
                {
                    Interlocked.Increment(ref exited);
                    Interlocked.Decrement(ref active);
                }
            });

        var run = relay.RunAsync(cancellation.Token);
        await allEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await cancellation.CancelAsync();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(8, Volatile.Read(ref entered));
        Assert.Equal(8, Volatile.Read(ref exited));
        Assert.Equal(0, Volatile.Read(ref active));
    }

    [Fact]
    public async Task Fatal_stdout_failure_cancels_and_awaits_every_in_flight_forward()
    {
        var requestIds = Enumerable.Range(0, 8)
            .Select(index => $"relay-write-fail-{index:D2}")
            .ToArray();
        await using var input = await CreateInputAsync(requestIds);
        await using var output = new FailingOutputStream();
        var allEntered = NewSignal();
        var entered = 0;
        var exited = 0;
        var active = 0;

        var relay = CreateRelay(
            input,
            output,
            async (message, cancellationToken) =>
            {
                Interlocked.Increment(ref active);
                if (Interlocked.Increment(ref entered) == 8)
                {
                    allEntered.TrySetResult();
                }

                try
                {
                    await allEntered.Task.WaitAsync(cancellationToken);
                    if (message.RequestId == "relay-write-fail-00")
                    {
                        return RouteResponse.Ok(message.RequestId);
                    }

                    await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                    return RouteResponse.Ok("unreachable");
                }
                finally
                {
                    Interlocked.Increment(ref exited);
                    Interlocked.Decrement(ref active);
                }
            });

        await relay.RunAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(8, Volatile.Read(ref entered));
        Assert.Equal(8, Volatile.Read(ref exited));
        Assert.Equal(0, Volatile.Read(ref active));
    }

    private static NativeMessagingRelay CreateRelay(
        Stream input,
        Stream output,
        Func<RouteMessage, CancellationToken, Task<RouteResponse>> forward)
    {
        return new NativeMessagingRelay(
            callerOrigin: AllowedOrigin,
            allowedOrigins: new[] { AllowedOrigin },
            forward: forward,
            input: input,
            output: output,
            wakeInterval: TimeSpan.Zero);
    }

    private static async Task<MemoryStream> CreateInputAsync(params string[] requestIds)
    {
        var input = new MemoryStream();
        foreach (var requestId in requestIds)
        {
            var message = new RouteMessage
            {
                ProtocolVersion = ProtocolConstants.ProtocolVersion,
                Type = MessageTypes.Health,
                RequestId = requestId,
                IssuedAtMs = 1_700_000_000_000,
                ExpiresAtMs = 1_700_000_005_000,
            };
            await NativeMessageFraming.WriteFrameAsync(
                input,
                message.ToUtf8Bytes(),
                CancellationToken.None);
        }

        input.Position = 0;
        return input;
    }

    private static async Task<List<string>> ReadResponseIdsAsync(Stream output)
    {
        output.Position = 0;
        var requestIds = new List<string>();
        while (true)
        {
            var body = await NativeMessageFraming.ReadFrameAsync(
                output,
                ProtocolConstants.MaxNativeFrameBytes,
                CancellationToken.None);
            if (body is null)
            {
                return requestIds;
            }

            using var document = JsonDocument.Parse(body);
            requestIds.Add(
                document.RootElement.GetProperty("requestId").GetString()
                ?? throw new InvalidOperationException("response requestId missing"));
        }
    }

    private static TaskCompletionSource NewSignal() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static void AssertWakeThenResponse(
        byte[] output,
        string requestId)
    {
        var remaining = (ReadOnlySpan<byte>)output;
        Assert.True(
            NativeMessageFraming.TryRead(
                ref remaining,
                out var wakeBody,
                out var wakeError));
        Assert.Null(wakeError);
        Assert.NotNull(wakeBody);
        using (var wake = JsonDocument.Parse(wakeBody!))
        {
            Assert.Equal(
                MessageTypes.Wake,
                wake.RootElement.GetProperty("type").GetString());
        }

        Assert.True(
            NativeMessageFraming.TryRead(
                ref remaining,
                out var responseBody,
                out var responseError));
        Assert.Null(responseError);
        Assert.NotNull(responseBody);
        using (var response = JsonDocument.Parse(responseBody!))
        {
            Assert.Equal(
                MessageTypes.Result,
                response.RootElement.GetProperty("type").GetString());
            Assert.Equal(
                requestId,
                response.RootElement.GetProperty("requestId").GetString());
        }

        Assert.True(remaining.IsEmpty);
    }

    private static void UpdateMaximum(ref int target, int candidate)
    {
        while (true)
        {
            var current = Volatile.Read(ref target);
            if (candidate <= current ||
                Interlocked.CompareExchange(ref target, candidate, current) == current)
            {
                return;
            }
        }
    }

    private sealed class FailingOutputStream : Stream
    {
        public override ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default) =>
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

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) =>
            throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }

    private sealed class GatedEofInputStream(byte[] bytes) : Stream
    {
        private readonly MemoryStream _inner = new(bytes);

        public TaskCompletionSource EofReadEntered { get; } = NewSignal();
        public TaskCompletionSource AllowEof { get; } = NewSignal();
        public TaskCompletionSource EofReturned { get; } = NewSignal();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var read = await _inner.ReadAsync(buffer, cancellationToken);
            if (read > 0)
            {
                return read;
            }

            EofReadEntered.TrySetResult();
            await AllowEof.Task.WaitAsync(cancellationToken);
            EofReturned.TrySetResult();
            return 0;
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException("Use ReadAsync");

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) =>
            throw new NotSupportedException();

        public override void Flush()
        {
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => _inner.Length;
        public override long Position
        {
            get => _inner.Position;
            set => throw new NotSupportedException();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _inner.Dispose();
            }

            base.Dispose(disposing);
        }

        public override async ValueTask DisposeAsync()
        {
            await _inner.DisposeAsync();
            GC.SuppressFinalize(this);
        }
    }

    private sealed class EofSignalingInputStream(byte[] bytes) :
        MemoryStream(bytes)
    {
        public TaskCompletionSource EofObserved { get; } = NewSignal();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var read = await base.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                EofObserved.TrySetResult();
            }

            return read;
        }
    }

    private sealed class PartialWakeOutputStream : Stream
    {
        private readonly MemoryStream _inner = new();
        private int _wakeWriteStarted;

        public TaskCompletionSource WakePrefixWritten { get; } = NewSignal();
        public TaskCompletionSource FinishWakeWrite { get; } = NewSignal();
        public TaskCompletionSource WakeWriteCanceled { get; } = NewSignal();

        public byte[] ToArray() => _inner.ToArray();

        public override async ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var frame = buffer.ToArray();
            var isFirstWake =
                IsWakeFrame(frame) &&
                Interlocked.CompareExchange(
                    ref _wakeWriteStarted,
                    1,
                    0) == 0;
            if (!isFirstWake)
            {
                cancellationToken.ThrowIfCancellationRequested();
                _inner.Write(frame);
                return;
            }

            _inner.Write(frame, 0, NativeMessageFraming.LengthPrefixBytes);
            WakePrefixWritten.TrySetResult();
            try
            {
                await FinishWakeWrite.Task.WaitAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                WakeWriteCanceled.TrySetResult();
                throw;
            }

            _inner.Write(
                frame,
                NativeMessageFraming.LengthPrefixBytes,
                frame.Length - NativeMessageFraming.LengthPrefixBytes);
        }

        private static bool IsWakeFrame(byte[] frame)
        {
            var remaining = (ReadOnlySpan<byte>)frame;
            if (!NativeMessageFraming.TryRead(
                    ref remaining,
                    out var body,
                    out var error) ||
                error is not null ||
                body is null)
            {
                throw new InvalidOperationException("invalid test frame");
            }

            using var document = JsonDocument.Parse(body);
            return string.Equals(
                document.RootElement.GetProperty("type").GetString(),
                MessageTypes.Wake,
                StringComparison.Ordinal);
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            _inner.Read(buffer, offset, count);

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException("Use WriteAsync");

        public override long Seek(long offset, SeekOrigin origin) =>
            _inner.Seek(offset, origin);

        public override void SetLength(long value) =>
            _inner.SetLength(value);

        public override void Flush()
        {
        }

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => true;
        public override long Length => _inner.Length;
        public override long Position
        {
            get => _inner.Position;
            set => _inner.Position = value;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _inner.Dispose();
            }

            base.Dispose(disposing);
        }

        public override async ValueTask DisposeAsync()
        {
            await _inner.DisposeAsync();
            GC.SuppressFinalize(this);
        }
    }

    private sealed class WakeFailingOutputStream(string requestId) : Stream
    {
        private readonly MemoryStream _inner = new();

        public TaskCompletionSource WakeWriteAttempted { get; } = NewSignal();
        public TaskCompletionSource ResponseWritten { get; } = NewSignal();

        public override ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var remaining = (ReadOnlySpan<byte>)buffer.Span;
            if (!NativeMessageFraming.TryRead(
                    ref remaining,
                    out var body,
                    out var error) ||
                error is not null ||
                body is null)
            {
                return ValueTask.FromException(
                    new InvalidOperationException("invalid test frame"));
            }

            using var document = JsonDocument.Parse(body);
            var type = document.RootElement.GetProperty("type").GetString();
            if (string.Equals(type, MessageTypes.Wake, StringComparison.Ordinal))
            {
                WakeWriteAttempted.TrySetResult();
                return ValueTask.FromException(
                    new IOException("wake-stdout-closed"));
            }

            _inner.Write(buffer.Span);
            if (document.RootElement.TryGetProperty(
                    "requestId",
                    out var requestIdElement) &&
                string.Equals(
                    requestIdElement.GetString(),
                    requestId,
                    StringComparison.Ordinal))
            {
                ResponseWritten.TrySetResult();
            }

            return ValueTask.CompletedTask;
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            _inner.Read(buffer, offset, count);

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException("Use WriteAsync");

        public override long Seek(long offset, SeekOrigin origin) =>
            _inner.Seek(offset, origin);

        public override void SetLength(long value) =>
            _inner.SetLength(value);

        public override void Flush()
        {
        }

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => true;
        public override long Length => _inner.Length;
        public override long Position
        {
            get => _inner.Position;
            set => _inner.Position = value;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _inner.Dispose();
            }

            base.Dispose(disposing);
        }

        public override async ValueTask DisposeAsync()
        {
            await _inner.DisposeAsync();
            GC.SuppressFinalize(this);
        }
    }

    private sealed class ResponseObservingOutputStream(string requestId) : Stream
    {
        private readonly MemoryStream _inner = new();

        public TaskCompletionSource ResponseWritten { get; } = NewSignal();

        public override ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _inner.Write(buffer.Span);
            var remaining = (ReadOnlySpan<byte>)buffer.Span;
            if (NativeMessageFraming.TryRead(
                    ref remaining,
                    out var body,
                    out var error) &&
                error is null &&
                body is not null)
            {
                using var document = JsonDocument.Parse(body);
                if (document.RootElement.TryGetProperty("requestId", out var requestIdElement) &&
                    string.Equals(
                        requestIdElement.GetString(),
                        requestId,
                        StringComparison.Ordinal))
                {
                    ResponseWritten.TrySetResult();
                }
            }

            return ValueTask.CompletedTask;
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            _inner.Read(buffer, offset, count);

        public override int Read(Span<byte> buffer) => _inner.Read(buffer);

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException("Use WriteAsync");

        public override long Seek(long offset, SeekOrigin origin) =>
            _inner.Seek(offset, origin);

        public override void SetLength(long value) => _inner.SetLength(value);

        public override void Flush()
        {
        }

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => true;
        public override long Length => _inner.Length;
        public override long Position
        {
            get => _inner.Position;
            set => _inner.Position = value;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _inner.Dispose();
            }

            base.Dispose(disposing);
        }

        public override async ValueTask DisposeAsync()
        {
            await _inner.DisposeAsync();
            GC.SuppressFinalize(this);
        }
    }
}
