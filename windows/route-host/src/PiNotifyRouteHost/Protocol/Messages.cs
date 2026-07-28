using System.Text.Json;
using System.Text.Json.Serialization;

namespace PiNotifyRouteHost.Protocol;

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        AllowTrailingCommas = false,
        MaxDepth = 8,
    };
}

/// <summary>Envelope common to all pipe / native messages.</summary>
public sealed class RouteMessage
{
    [JsonPropertyName("protocolVersion")]
    public int ProtocolVersion { get; set; }

    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    [JsonPropertyName("nonce")]
    public string? Nonce { get; set; }

    /// <summary>Unix epoch milliseconds when the message was issued.</summary>
    [JsonPropertyName("issuedAtMs")]
    public long IssuedAtMs { get; set; }

    /// <summary>Unix epoch milliseconds after which the message must be rejected.</summary>
    [JsonPropertyName("expiresAtMs")]
    public long ExpiresAtMs { get; set; }

    // --- adapter / owner registration ---

    [JsonPropertyName("adapterKey")]
    public string? AdapterKey { get; set; }

    [JsonPropertyName("adapterKind")]
    public string? AdapterKind { get; set; }

    [JsonPropertyName("browserKind")]
    public string? BrowserKind { get; set; }

    [JsonPropertyName("profileKey")]
    public string? ProfileKey { get; set; }

    [JsonPropertyName("ownerKey")]
    public string? OwnerKey { get; set; }

    [JsonPropertyName("pageKey")]
    public string? PageKey { get; set; }

    [JsonPropertyName("instanceKey")]
    public string? InstanceKey { get; set; }

    [JsonPropertyName("routingKey")]
    public string? RoutingKey { get; set; }

    [JsonPropertyName("leaseTtlMs")]
    public int? LeaseTtlMs { get; set; }

    [JsonPropertyName("pageFingerprint")]
    public string? PageFingerprint { get; set; }

    // --- freeze / activate ---

    [JsonPropertyName("notificationId")]
    public string? NotificationId { get; set; }

    [JsonPropertyName("notificationKind")]
    public string? NotificationKind { get; set; }

    [JsonPropertyName("snapshotId")]
    public string? SnapshotId { get; set; }

    [JsonPropertyName("deadlineMs")]
    public long? DeadlineMs { get; set; }

    /// <summary>
    /// Identifies a pending/completed external activation (activate requestId or dedicated id).
    /// Used by activate-result, poll-activation (optional), and activation-status.
    /// </summary>
    [JsonPropertyName("activationRequestId")]
    public string? ActivationRequestId { get; set; }

    // --- activate result from adapter ---

    [JsonPropertyName("result")]
    public string? Result { get; set; }

    [JsonPropertyName("reason")]
    public string? Reason { get; set; }

    [JsonPropertyName("elapsedMs")]
    public long? ElapsedMs { get; set; }

    public static RouteMessage? TryParse(ReadOnlySpan<byte> utf8Json, out string? error)
    {
        error = null;
        if (utf8Json.IsEmpty)
        {
            error = RejectReasons.MissingField;
            return null;
        }

        if (utf8Json.Length > ProtocolConstants.MaxMessageBytes)
        {
            error = RejectReasons.Oversized;
            return null;
        }

        try
        {
            var msg = JsonSerializer.Deserialize<RouteMessage>(utf8Json, JsonDefaults.Options);
            if (msg is null)
            {
                error = RejectReasons.InvalidField;
                return null;
            }

            return msg;
        }
        catch (JsonException)
        {
            error = RejectReasons.InvalidField;
            return null;
        }
    }

    public byte[] ToUtf8Bytes()
    {
        return JsonSerializer.SerializeToUtf8Bytes(this, JsonDefaults.Options);
    }
}

/// <summary>Structured response returned to callers (and serialized as type=result).</summary>
public sealed class RouteResponse
{
    [JsonPropertyName("protocolVersion")]
    public int ProtocolVersion { get; set; } = ProtocolConstants.ProtocolVersion;

    [JsonPropertyName("type")]
    public string Type { get; set; } = MessageTypes.Result;

    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    [JsonPropertyName("result")]
    public string Result { get; set; } = string.Empty;

    [JsonPropertyName("reason")]
    public string? Reason { get; set; }

    [JsonPropertyName("snapshotId")]
    public string? SnapshotId { get; set; }

    [JsonPropertyName("candidateCount")]
    public int? CandidateCount { get; set; }

    [JsonPropertyName("adapterKind")]
    public string? AdapterKind { get; set; }

    [JsonPropertyName("ownerFingerprint")]
    public string? OwnerFingerprint { get; set; }

    [JsonPropertyName("routingFingerprint")]
    public string? RoutingFingerprint { get; set; }

    [JsonPropertyName("instanceFingerprint")]
    public string? InstanceFingerprint { get; set; }

    [JsonPropertyName("elapsedMs")]
    public long? ElapsedMs { get; set; }

    [JsonPropertyName("daemonId")]
    public string? DaemonId { get; set; }

    [JsonPropertyName("liveAdapters")]
    public int? LiveAdapters { get; set; }

    [JsonPropertyName("liveOwners")]
    public int? LiveOwners { get; set; }

    [JsonPropertyName("snapshots")]
    public int? Snapshots { get; set; }

    /// <summary>Pending/completed external activation id (equals activate requestId).</summary>
    [JsonPropertyName("activationRequestId")]
    public string? ActivationRequestId { get; set; }

    /// <summary>Frozen owner key when delivering a polled activate command.</summary>
    [JsonPropertyName("ownerKey")]
    public string? OwnerKey { get; set; }

    /// <summary>Frozen page key when delivering a polled activate command.</summary>
    [JsonPropertyName("pageKey")]
    public string? PageKey { get; set; }

    /// <summary>Instance key on polled activate command (opaque UUID).</summary>
    [JsonPropertyName("instanceKey")]
    public string? InstanceKey { get; set; }

    /// <summary>Routing key on polled activate command (opaque hash).</summary>
    [JsonPropertyName("routingKey")]
    public string? RoutingKey { get; set; }

    /// <summary>Page fingerprint on polled activate command.</summary>
    [JsonPropertyName("pageFingerprint")]
    public string? PageFingerprint { get; set; }

    /// <summary>Deadline for the polled activation command (unix ms).</summary>
    [JsonPropertyName("deadlineMs")]
    public long? DeadlineMs { get; set; }

    /// <summary>Notification id when returning a polled activate command.</summary>
    [JsonPropertyName("notificationId")]
    public string? NotificationId { get; set; }

    public static RouteResponse Reject(string requestId, string result, string reason) => new()
    {
        RequestId = requestId,
        Result = result,
        Reason = reason,
    };

    public static RouteResponse Ok(string requestId, string result = RouteResults.Ok) => new()
    {
        RequestId = requestId,
        Result = result,
    };

    public byte[] ToUtf8Bytes()
    {
        return JsonSerializer.SerializeToUtf8Bytes(this, JsonDefaults.Options);
    }
}

/// <summary>
/// Host→browser unsolicited wake frame. Versioned, no session/URL/routing/token/user content.
/// Never accepted as an inbound route command and never forwarded to the daemon.
/// </summary>
public sealed class WakeMessage
{
    [JsonPropertyName("protocolVersion")]
    public int ProtocolVersion { get; set; } = ProtocolConstants.ProtocolVersion;

    [JsonPropertyName("type")]
    public string Type { get; set; } = MessageTypes.Wake;

    /// <summary>Monotonic wake sequence for diagnostics only (not a request id).</summary>
    [JsonPropertyName("seq")]
    public long Seq { get; set; }

    public static WakeMessage Create(long seq) => new()
    {
        ProtocolVersion = ProtocolConstants.ProtocolVersion,
        Type = MessageTypes.Wake,
        Seq = seq,
    };

    public byte[] ToUtf8Bytes()
    {
        return JsonSerializer.SerializeToUtf8Bytes(this, JsonDefaults.Options);
    }
}

/// <summary>Command delivered to a live adapter for activation (via poll-activation).</summary>
public sealed class ActivateCommand
{
    [JsonPropertyName("protocolVersion")]
    public int ProtocolVersion { get; set; } = ProtocolConstants.ProtocolVersion;

    [JsonPropertyName("type")]
    public string Type { get; set; } = MessageTypes.Activate;

    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    [JsonPropertyName("activationRequestId")]
    public string ActivationRequestId { get; set; } = string.Empty;

    [JsonPropertyName("notificationId")]
    public string NotificationId { get; set; } = string.Empty;

    [JsonPropertyName("snapshotId")]
    public string SnapshotId { get; set; } = string.Empty;

    [JsonPropertyName("ownerKey")]
    public string OwnerKey { get; set; } = string.Empty;

    [JsonPropertyName("pageKey")]
    public string PageKey { get; set; } = string.Empty;

    [JsonPropertyName("instanceKey")]
    public string InstanceKey { get; set; } = string.Empty;

    [JsonPropertyName("routingKey")]
    public string RoutingKey { get; set; } = string.Empty;

    [JsonPropertyName("pageFingerprint")]
    public string? PageFingerprint { get; set; }

    [JsonPropertyName("deadlineMs")]
    public long DeadlineMs { get; set; }

    public byte[] ToUtf8Bytes()
    {
        return JsonSerializer.SerializeToUtf8Bytes(this, JsonDefaults.Options);
    }
}
