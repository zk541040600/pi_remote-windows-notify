using System.Text;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Protocol;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class FramingTests
{
    [Fact]
    public void Encode_decode_round_trip()
    {
        var body = Encoding.UTF8.GetBytes("{\"type\":\"health\"}");
        var frame = NativeMessageFraming.Encode(body);
        Assert.Equal(4 + body.Length, frame.Length);

        ReadOnlySpan<byte> span = frame;
        Assert.True(NativeMessageFraming.TryRead(ref span, out var decoded, out var error));
        Assert.Null(error);
        Assert.Equal(body, decoded);
        Assert.True(span.IsEmpty);
    }

    [Fact]
    public void TryRead_returns_false_when_incomplete()
    {
        var body = Encoding.UTF8.GetBytes("{\"x\":1}");
        var frame = NativeMessageFraming.Encode(body);
        ReadOnlySpan<byte> partial = frame.AsSpan(0, 3);
        Assert.False(NativeMessageFraming.TryRead(ref partial, out _, out var error));
        Assert.Null(error);
    }

    [Fact]
    public void Encode_rejects_oversized_body()
    {
        var huge = new byte[ProtocolConstants.MaxNativeFrameBytes + 1];
        Assert.Throws<InvalidOperationException>(() => NativeMessageFraming.Encode(huge));
    }

    [Fact]
    public void TryRead_flags_oversized_length_prefix()
    {
        var prefix = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(prefix, ProtocolConstants.MaxNativeFrameBytes + 100);
        ReadOnlySpan<byte> span = prefix;
        Assert.False(NativeMessageFraming.TryRead(ref span, out _, out var error));
        Assert.Equal(RejectReasons.Oversized, error);
    }

    [Fact]
    public async Task Stream_round_trip()
    {
        using var ms = new MemoryStream();
        var payload = Encoding.UTF8.GetBytes("{\"ok\":true}");
        await NativeMessageFraming.WriteFrameAsync(ms, payload, CancellationToken.None);
        ms.Position = 0;
        var read = await NativeMessageFraming.ReadFrameAsync(ms, ProtocolConstants.MaxNativeFrameBytes, CancellationToken.None);
        Assert.Equal(payload, read);
    }
}
