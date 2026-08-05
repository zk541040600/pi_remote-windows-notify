namespace PiNotifyRouteHost.State;

public sealed class LiveAdapter
{
    public required string AdapterKey { get; init; }
    public required string AdapterGeneration { get; init; }
    public long AdapterStartedAtMs { get; init; }
    public required string AdapterKind { get; init; }
    public required string BrowserKind { get; init; }
    public required string ProfileKey { get; init; }
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
    public required string AdapterGeneration { get; init; }
    public required string PageKey { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public string? PageFingerprint { get; set; }
    public required string BrowserKind { get; init; }
    public required string ProfileKey { get; init; }
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
    public required string AdapterGeneration { get; init; }
    public required string PageKey { get; init; }
    public string? PageFingerprint { get; init; }
    public string? AdapterKind { get; init; }
    public string? BrowserKind { get; init; }
    public required AdapterBindingIdentity AdapterIdentity { get; init; }
    public long CreatedAtMs { get; init; }
    public long ExpiresAtMs { get; init; }
    public string? LastActivateResult { get; set; }
    public string? LastActivateReason { get; set; }
    public string? ActivationRequestId { get; set; }
}

/// <summary>
/// Host-owned pre-snapshot transaction. Route material remains inside the Host;
/// callers receive only RecoveryTicketId. Once ResolvedSnapshotId is set, the
/// ticket can only replay that immutable snapshot and is never retargeted.
/// </summary>
public sealed class NotificationRecoveryTicket
{
    public required string RecoveryTicketId { get; init; }
    public required string NotificationId { get; init; }
    public string? NotificationKind { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public long CreatedAtMs { get; init; }
    public long PendingExpiresAtMs { get; init; }
    public long RetainUntilMs { get; set; }
    public string? ResolvedSnapshotId { get; set; }
    public string? TerminalResult { get; set; }
    public string? TerminalReason { get; set; }
}

public readonly record struct SessionRouteKey(string InstanceKey, string RoutingKey)
{
    public override string ToString() => InstanceKey + "\0" + RoutingKey;
}

/// <summary>
/// Immutable surface identity corroborating a durable adapter key across daemon restarts.
/// </summary>
public sealed class AdapterBindingIdentity
{
    public required string AdapterKind { get; init; }
    public required string BrowserKind { get; init; }
    public required string ProfileKey { get; init; }

    public static AdapterBindingIdentity From(LiveAdapter adapter) => new()
    {
        AdapterKind = adapter.AdapterKind,
        BrowserKind = adapter.BrowserKind,
        ProfileKey = adapter.ProfileKey,
    };
}

/// <summary>
/// Durable first explicit-open adapter for one session route. Does not contain a raw session,
/// URL, live owner key, or page key.
/// </summary>
public sealed class SessionOwnerBinding
{
    public required string AdapterKey { get; init; }
    public required AdapterBindingIdentity AdapterIdentity { get; init; }
    public required string OpenEventId { get; init; }
    public long OpenedAtMs { get; init; }
    public long Revision { get; init; }
    public long ReceiveClockEpoch { get; init; }
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
/// Pending or completed external activation. A poll delivery is leased and may
/// be re-offered unchanged until activate-result acknowledges the side effect;
/// final result is stored until TTL after completion.
/// </summary>
public sealed class PendingActivation
{
    public required string ActivationRequestId { get; init; }
    public required string NotificationId { get; init; }
    public required string SnapshotId { get; init; }
    public required string AdapterKey { get; init; }
    public required string AdapterGeneration { get; init; }
    public required string OwnerKey { get; init; }
    public required string PageKey { get; init; }
    public required string InstanceKey { get; init; }
    public required string RoutingKey { get; init; }
    public string? PageFingerprint { get; init; }
    public string? AdapterKind { get; init; }
    public long CreatedAtMs { get; init; }
    public long DeadlineMs { get; init; }
    public long ExpiresAtMs { get; set; }

    /// <summary>True after the command has been handed out at least once via poll-activation.</summary>
    public bool Delivered { get; set; }

    /// <summary>Host clock at the most recent delivery attempt.</summary>
    public long? DeliveredAtMs { get; set; }

    /// <summary>Bounded by the activation deadline; diagnostic only.</summary>
    public int DeliveryAttempts { get; set; }

    /// <summary>
    /// Latest trusted non-terminal progress. It is deliberately independent
    /// from delivery leases, deadlines, binding authority, and final results.
    /// </summary>
    public string? ActivationPhase { get; set; }

    /// <summary>Host clock of the first accepted report for ActivationPhase.</summary>
    public long? ActivationProgressAtMs { get; set; }

    /// <summary>True after a terminal result is recorded (activate-result, timeout, stale, etc.).</summary>
    public bool Completed { get; set; }

    public string? FinalResult { get; set; }
    public string? FinalReason { get; set; }
    public long? ElapsedMs { get; set; }
}
