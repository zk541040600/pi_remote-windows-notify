using System.Security.Cryptography;
using System.Text;

namespace PiNotifyRouteHost.Protocol;

/// <summary>
/// routingKey = SHA-256("pi-web-route-v1\0" + instanceKey + "\0" + rawSessionId) as lowercase hex.
/// Full 256-bit; never truncated. Raw session IDs must not be logged or stored in Route Host state.
/// </summary>
public static class RoutingKey
{
    private static readonly byte[] DomainPrefix = Encoding.UTF8.GetBytes(ProtocolConstants.RoutingKeyDomain + "\0");

    public static string Compute(string instanceKey, string rawSessionId)
    {
        if (string.IsNullOrWhiteSpace(instanceKey))
        {
            throw new ArgumentException("instanceKey is required.", nameof(instanceKey));
        }

        if (string.IsNullOrWhiteSpace(rawSessionId))
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
