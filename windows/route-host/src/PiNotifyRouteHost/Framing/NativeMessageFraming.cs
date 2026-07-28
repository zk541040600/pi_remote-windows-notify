using System.Buffers.Binary;

namespace PiNotifyRouteHost.Framing;

/// <summary>
/// Chrome/Edge Native Messaging framing: 32-bit native-endian length prefix + UTF-8 JSON.
/// Host→browser max is 1 MiB per Chrome docs; we enforce a tighter MaxMessageBytes bound.
/// </summary>
public static class NativeMessageFraming
{
    public const int LengthPrefixBytes = 4;

    public static byte[] Encode(ReadOnlySpan<byte> utf8Json, int maxBodyBytes = Protocol.ProtocolConstants.MaxNativeFrameBytes)
    {
        if (utf8Json.Length > maxBodyBytes)
        {
            throw new InvalidOperationException($"Native message body exceeds limit ({utf8Json.Length} > {maxBodyBytes}).");
        }

        var frame = new byte[LengthPrefixBytes + utf8Json.Length];
        BinaryPrimitives.WriteInt32LittleEndian(frame.AsSpan(0, LengthPrefixBytes), utf8Json.Length);
        utf8Json.CopyTo(frame.AsSpan(LengthPrefixBytes));
        return frame;
    }

    /// <summary>
    /// Try to read one framed message from a buffer. Returns false if more data is needed.
    /// Throws / sets error on oversized or corrupt frames.
    /// </summary>
    public static bool TryRead(
        ref ReadOnlySpan<byte> buffer,
        out byte[]? body,
        out string? error,
        int maxBodyBytes = Protocol.ProtocolConstants.MaxNativeFrameBytes)
    {
        body = null;
        error = null;

        if (buffer.Length < LengthPrefixBytes)
        {
            return false;
        }

        var length = BinaryPrimitives.ReadInt32LittleEndian(buffer[..LengthPrefixBytes]);
        if (length < 0)
        {
            error = Protocol.RejectReasons.InvalidField;
            return false;
        }

        if (length > maxBodyBytes)
        {
            error = Protocol.RejectReasons.Oversized;
            return false;
        }

        var total = LengthPrefixBytes + length;
        if (buffer.Length < total)
        {
            return false;
        }

        body = buffer.Slice(LengthPrefixBytes, length).ToArray();
        buffer = buffer[total..];
        return true;
    }

    public static async Task WriteFrameAsync(Stream stream, ReadOnlyMemory<byte> utf8Json, CancellationToken ct)
    {
        var frame = Encode(utf8Json.Span);
        await stream.WriteAsync(frame, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    public static async Task<byte[]?> ReadFrameAsync(
        Stream stream,
        int maxBodyBytes,
        CancellationToken ct)
    {
        var lenBuf = new byte[LengthPrefixBytes];
        if (!await ReadExactAsync(stream, lenBuf, ct).ConfigureAwait(false))
        {
            return null;
        }

        var length = BinaryPrimitives.ReadInt32LittleEndian(lenBuf);
        if (length < 0 || length > maxBodyBytes)
        {
            throw new InvalidOperationException($"Invalid native frame length: {length}");
        }

        if (length == 0)
        {
            return Array.Empty<byte>();
        }

        var body = new byte[length];
        if (!await ReadExactAsync(stream, body, ct).ConfigureAwait(false))
        {
            return null;
        }

        return body;
    }

    private static async Task<bool> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken ct)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, buffer.Length - offset), ct).ConfigureAwait(false);
            if (read == 0)
            {
                return false;
            }

            offset += read;
        }

        return true;
    }
}
