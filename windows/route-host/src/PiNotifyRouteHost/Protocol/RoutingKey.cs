using System.Security.Cryptography;
using System.Text;

namespace PiNotifyRouteHost.Protocol;

/// <summary>
/// routingKey = SHA-256("pi-web-route-v1\0" + instanceKey + "\0" + rawSessionId) as lowercase hex.
/// Full 256-bit; never truncated. Raw session IDs must not be logged or stored in Route Host state.
/// </summary>
public static class RoutingKey
{
    private const int SessionIdMinLength = 1;
    private const int SessionIdMaxLength = 256;
    private static readonly byte[] DomainPrefix = Encoding.UTF8.GetBytes(ProtocolConstants.RoutingKeyDomain + "\0");

    public static string Compute(string instanceKey, string rawSessionId)
    {
        if (!InstanceKeyContract.IsValid(instanceKey))
        {
            throw new ArgumentException("instanceKey is invalid.", nameof(instanceKey));
        }

        if (!IsValidSessionId(rawSessionId))
        {
            throw new ArgumentException("rawSessionId is required.", nameof(rawSessionId));
        }

        var instanceBytes = Encoding.UTF8.GetBytes(instanceKey);
        var sessionBytes = Encoding.UTF8.GetBytes(rawSessionId);
        var payload = new byte[DomainPrefix.Length + instanceBytes.Length + 1 + sessionBytes.Length];

        Buffer.BlockCopy(DomainPrefix, 0, payload, 0, DomainPrefix.Length);
        Buffer.BlockCopy(instanceBytes, 0, payload, DomainPrefix.Length, instanceBytes.Length);
        payload[DomainPrefix.Length + instanceBytes.Length] = 0;
        Buffer.BlockCopy(sessionBytes, 0, payload, DomainPrefix.Length + instanceBytes.Length + 1, sessionBytes.Length);

        var hash = SHA256.HashData(payload);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static bool IsValidSessionId(string? sessionId)
    {
        if (sessionId is null ||
            sessionId.Length < SessionIdMinLength ||
            sessionId.Length > SessionIdMaxLength)
        {
            return false;
        }

        var hasNonWhitespace = false;
        for (var index = 0; index < sessionId.Length; index++)
        {
            var code = sessionId[index];
            if (code < 0x20 ||
                code is >= '\u007f' and <= '\u009f' ||
                code == '\ufeff')
            {
                return false;
            }
            if (char.IsHighSurrogate(code))
            {
                if (index + 1 >= sessionId.Length ||
                    !char.IsLowSurrogate(sessionId[index + 1]))
                {
                    return false;
                }
                hasNonWhitespace = true;
                index++;
                continue;
            }
            if (char.IsLowSurrogate(code))
            {
                return false;
            }
            if (!IsPortableSessionWhitespace(code))
            {
                hasNonWhitespace = true;
            }
        }

        return hasNonWhitespace &&
            !sessionId.Contains("://", StringComparison.Ordinal);
    }

    private static bool IsPortableSessionWhitespace(char value) =>
        value is >= '\u0009' and <= '\u000d' or
            '\u0020' or
            '\u0085' or
            '\u00a0' or
            '\u1680' or
            >= '\u2000' and <= '\u200a' or
            '\u2028' or
            '\u2029' or
            '\u202f' or
            '\u205f' or
            '\u3000' or
            '\ufeff';

    /// <summary>Short fingerprint for logs (first 12 hex chars of routingKey). Never log full raw session ID.</summary>
    public static string Fingerprint(string routingKey)
    {
        if (string.IsNullOrEmpty(routingKey))
        {
            return string.Empty;
        }

        return routingKey.Length <= 12
            ? routingKey.ToLowerInvariant()
            : routingKey[..12].ToLowerInvariant();
    }

    public static string FingerprintInstance(string instanceKey)
    {
        if (string.IsNullOrEmpty(instanceKey))
        {
            return string.Empty;
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(instanceKey));
        return Convert.ToHexString(hash).ToLowerInvariant()[..12];
    }
}
