using System.Buffers.Binary;
using System.Text;

namespace PiNotifyRouteHost.Framing;

/// <summary>
/// Named-pipe framing mirrors Native Messaging: little-endian 32-bit length + UTF-8 JSON.
/// Shared so daemon, relay, and one-shot client use one codec.
/// </summary>
public static class LengthPrefixedJson
{
    public static byte[] EncodeUtf8(string json, int maxBodyBytes = Protocol.ProtocolConstants.MaxMessageBytes)
    {
        var body = Encoding.UTF8.GetBytes(json);
        return NativeMessageFraming.Encode(body, maxBodyBytes);
    }

    public static byte[] EncodeBytes(ReadOnlySpan<byte> utf8Json, int maxBodyBytes = Protocol.ProtocolConstants.MaxMessageBytes)
        => NativeMessageFraming.Encode(utf8Json, maxBodyBytes);

    public static async Task WriteAsync(Stream stream, ReadOnlyMemory<byte> utf8Json, CancellationToken ct)
        => await NativeMessageFraming.WriteFrameAsync(stream, utf8Json, ct).ConfigureAwait(false);

    public static async Task<byte[]?> ReadAsync(Stream stream, int maxBodyBytes, CancellationToken ct)
        => await NativeMessageFraming.ReadFrameAsync(stream, maxBodyBytes, ct).ConfigureAwait(false);

    public static int PeekLength(ReadOnlySpan<byte> prefix4)
    {
        if (prefix4.Length < 4)
        {
            throw new ArgumentException("Need 4 bytes.", nameof(prefix4));
        }

        return BinaryPrimitives.ReadInt32LittleEndian(prefix4);
    }
}
