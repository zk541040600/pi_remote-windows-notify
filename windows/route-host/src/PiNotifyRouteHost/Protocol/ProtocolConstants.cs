namespace PiNotifyRouteHost.Protocol;

/// <summary>
/// Shared protocol bounds for daemon, Native Messaging relay, and one-shot client.
/// Keep values small and fail-closed; raw session IDs and full URLs never enter state/logs.
/// </summary>
public static class ProtocolConstants
{
    public const int ProtocolVersion = 1;
    public const int RouteVersion = 1;

    /// <summary>Prefix for routingKey material: SHA-256("pi-web-route-v1\0" + instanceKey + "\0" + rawSessionId).</summary>
    public const string RoutingKeyDomain = "pi-web-route-v1";

    public const string DefaultPipeName = "PiNotifyRouteHost";
    public const string NativeHostName = "io.pi.notify.route";

    /// <summary>Max UTF-8 JSON body size for any IPC / native message (bytes).</summary>
    public const int MaxMessageBytes = 32 * 1024;

    /// <summary>Native Messaging framing uses a 32-bit length prefix; reject larger than MaxMessageBytes.</summary>
    public const int MaxNativeFrameBytes = MaxMessageBytes;

    /// <summary>Default owner/adapter lease TTL when caller omits leaseTtlMs.</summary>
    public const int DefaultLeaseTtlMs = 30_000;

    /// <summary>Hard upper bound on lease TTL (ms).</summary>
    public const int MaxLeaseTtlMs = 120_000;

    /// <summary>Minimum lease TTL (ms).</summary>
    public const int MinLeaseTtlMs = 1_000;

    /// <summary>Default freeze/activate request TTL when omitted (ms).</summary>
    public const int DefaultRequestTtlMs = 5_000;

    /// <summary>Hard upper bound on request TTL (ms).</summary>
    public const int MaxRequestTtlMs = 30_000;

    /// <summary>How long a freeze snapshot remains usable for activate (ms).</summary>
    public const int SnapshotTtlMs = 15 * 60_000;

    /// <summary>Replay cache retention for requestId / nonce (ms).</summary>
    public const int ReplayCacheTtlMs = 10 * 60_000;

    /// <summary>Max simultaneous live adapters.</summary>
    public const int MaxAdapters = 64;

    /// <summary>Max live owners across all sessions.</summary>
    public const int MaxOwners = 256;

    /// <summary>Max frozen notification snapshots retained in memory.</summary>
    public const int MaxSnapshots = 256;

    /// <summary>Max requestId/nonce replay entries.</summary>
    public const int MaxReplayEntries = 2_048;

    /// <summary>Max pending external activation commands across all adapters.</summary>
    public const int MaxPendingActivations = 64;

    /// <summary>Max undelivered/pending activation commands per adapter.</summary>
    public const int MaxPendingPerAdapter = 8;

    /// <summary>How long a completed activation result remains queryable via activation-status (ms).</summary>
    public const int ActivationResultTtlMs = 10 * 60_000;

    /// <summary>Default poll wait budget for --client --wait-ms when omitted but wait requested (ms).</summary>
    public const int DefaultClientWaitMs = 5_000;

    /// <summary>Max length for opaque string fields (keys, ids, fingerprints).</summary>
    public const int MaxOpaqueFieldLength = 128;

    /// <summary>Max length for browserKind / adapterKind labels.</summary>
    public const int MaxLabelLength = 32;

    public static readonly HashSet<string> AllowedMessageTypes = new(StringComparer.Ordinal)
    {
        MessageTypes.Health,
        MessageTypes.RegisterAdapter,
        MessageTypes.UnregisterAdapter,
        MessageTypes.RegisterOwner,
        MessageTypes.UnregisterOwner,
        MessageTypes.Heartbeat,
        MessageTypes.Freeze,
        MessageTypes.Activate,
        MessageTypes.ActivateResult,
        MessageTypes.PollActivation,
        MessageTypes.ActivationStatus,
        MessageTypes.Ping,
    };

    public static readonly HashSet<string> AllowedAdapterKinds = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome",
        "edge",
        "pi-web-desktop",
        "mock",
        "native-relay",
        "client",
    };

    public static readonly HashSet<string> AllowedNotificationKinds = new(StringComparer.Ordinal)
    {
        "ask-user",
        "turn-complete",
    };
}

public static class MessageTypes
{
    public const string Health = "health";
    public const string RegisterAdapter = "register-adapter";
    public const string UnregisterAdapter = "unregister-adapter";
    public const string RegisterOwner = "register-owner";
    public const string UnregisterOwner = "unregister-owner";
    public const string Heartbeat = "heartbeat";
    public const string Freeze = "freeze";
    public const string Activate = "activate";
    public const string ActivateResult = "activate-result";
    public const string PollActivation = "poll-activation";
    public const string ActivationStatus = "activation-status";
    public const string Ping = "ping";
    public const string Result = "result";
}

public static class RouteResults
{
    public const string Ready = "ready";
    public const string Miss = "miss";
    public const string Ambiguous = "ambiguous";
    public const string Stale = "stale";
    public const string AdapterUnavailable = "adapter-unavailable";
    public const string OwnerUnresolved = "owner-unresolved";
    public const string Accepted = "accepted";
    public const string Pending = "pending";
    public const string SessionUrlConfirmed = "session-url-confirmed";
    public const string SessionConfirmed = "session-confirmed";
    public const string AlreadyActive = "already-active";
    public const string Timeout = "timeout";
    public const string Replay = "replay";
    public const string Rejected = "rejected";
    public const string ProtocolMismatch = "protocol-mismatch";
    public const string Oversized = "oversized";
    public const string Expired = "expired";
    public const string ForegroundDenied = "foreground-denied";
    public const string SelectFailed = "select-failed";
    public const string Ok = "ok";
}

public static class RejectReasons
{
    public const string MissingField = "missing-field";
    public const string InvalidField = "invalid-field";
    public const string ProtocolMismatch = "protocol-mismatch";
    public const string Oversized = "oversized";
    public const string Expired = "expired";
    public const string Replay = "replay";
    public const string Capacity = "capacity";
    public const string UnknownType = "unknown-type";
    public const string CallerRejected = "caller-rejected";
    public const string AdapterUnknown = "adapter-unknown";
    public const string SnapshotUnknown = "snapshot-unknown";
    public const string SnapshotMismatch = "snapshot-mismatch";
    public const string OwnerChanged = "owner-changed";
    public const string LeaseExpired = "lease-expired";
    public const string NoPending = "no-pending";
    public const string ActivationUnknown = "activation-unknown";
    public const string PendingAdapterDelivery = "pending-adapter-delivery";
    public const string WrongAdapter = "wrong-adapter";
}
