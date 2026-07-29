namespace PiNotifyRouteHost.State;

public sealed class LiveAdapter
{
    public required string AdapterKey { get; init; }
    public required string AdapterKind { get; init; }
    public string? BrowserKind { get; init; }
    public string? ProfileKey { get; init; }
    public long LeaseExpiresAtMs { get; set; }
    public long RegisteredAtMs { get; init; }
    public long LastHeartbeatMs { get; set; }

    /// <summary>Optional in-process activator used by mock adapters / unit tests.</summary>
    public IAdapterActivator? Activator { get; set; }
}

public sealed class LiveOwner
{
    public required string OwnerKey { get; init; }
    public required string AdapterKey { get; init; }
    public required string PageKey { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public string? PageFingerprint { get; set; }
    public string? BrowserKind { get; init; }
    public string? ProfileKey { get; init; }
    public long LeaseExpiresAtMs { get; set; }
    public long RegisteredAtMs { get; init; }
    public long LastHeartbeatMs { get; set; }
}

/// <summary>
/// Immutable freeze target. After creation, owner/page identity cannot be retargeted.
/// Does not store raw session IDs or full URLs.
/// </summary>
public sealed class NotificationSnapshot
{
    public required string SnapshotId { get; init; }
    public required string NotificationId { get; init; }
    public string? NotificationKind { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public required string OwnerKey { get; init; }
    public required string AdapterKey { get; init; }
    public required string PageKey { get; init; }
    public string? PageFingerprint { get; init; }
    public string? AdapterKind { get; init; }
    public string? BrowserKind { get; init; }
    public long CreatedAtMs { get; init; }
    public long ExpiresAtMs { get; init; }
    public string? LastActivateResult { get; set; }
    public string? LastActivateReason { get; set; }
}

public readonly record struct SessionRouteKey(string InstanceKey, string RoutingKey)
{
    public override string ToString() => InstanceKey + "\0" + RoutingKey;
}

public sealed class OwnerPreference
{
    public required string AdapterKey { get; init; }
    public required string OpenEventId { get; init; }
    public long OpenedAtMs { get; init; }
    public long Revision { get; init; }
}

/// <summary>In-process hook so unit tests can exercise activate without real pipes.</summary>
public interface IAdapterActivator
{
    Task<AdapterActivateResult> ActivateAsync(ActivateRequest request, CancellationToken cancellationToken);
}

public sealed class ActivateRequest
{
    public required string RequestId { get; init; }
    public required string NotificationId { get; init; }
    public required string SnapshotId { get; init; }
    public required string OwnerKey { get; init; }
    public required string PageKey { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public string? PageFingerprint { get; init; }
    public long DeadlineMs { get; init; }
}

public sealed class AdapterActivateResult
{
    public required string Result { get; init; }
    public string? Reason { get; init; }
    public long ElapsedMs { get; init; }
}

/// <summary>
/// Pending or completed external activation. Command is delivered exactly once via poll-activation;
/// final result is stored until TTL after activate-result or timeout/stale revalidation.
/// </summary>
public sealed class PendingActivation
{
    public required string ActivationRequestId { get; init; }
    public required string NotificationId { get; init; }
    public required string SnapshotId { get; init; }
    public required string AdapterKey { get; init; }
    public required string OwnerKey { get; init; }
    public required string PageKey { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public string? PageFingerprint { get; init; }
    public string? AdapterKind { get; init; }
    public long CreatedAtMs { get; init; }
    public long DeadlineMs { get; init; }
    public long ExpiresAtMs { get; set; }

    /// <summary>True after the command has been handed out exactly once via poll-activation.</summary>
    public bool Delivered { get; set; }

    /// <summary>True after a terminal result is recorded (activate-result, timeout, stale, etc.).</summary>
    public bool Completed { get; set; }

    public string? FinalResult { get; set; }
    public string? FinalReason { get; set; }
    public long? ElapsedMs { get; set; }
}
