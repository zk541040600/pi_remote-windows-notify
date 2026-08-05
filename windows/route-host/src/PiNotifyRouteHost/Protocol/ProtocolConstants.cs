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

    public const string DefaultPipeName = @"LOCAL\PiNotifyRouteHost";
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

    /// <summary>Maximum accepted client timestamp lead over the host clock (ms).</summary>
    public const int MaxFutureClockSkewMs = 60_000;

    /// <summary>How long a freeze snapshot remains usable for activate (ms).</summary>
    public const int SnapshotTtlMs = 15 * 60_000;

    /// <summary>Replay cache retention for requestId / nonce (ms).</summary>
    public const int ReplayCacheTtlMs = 10 * 60_000;

    /// <summary>Max simultaneous live adapters.</summary>
    public const int MaxAdapters = 64;

    /// <summary>
    /// Max distinct adapter keys whose generation high-water must survive
    /// unregister and lease expiry inside one daemon epoch.
    /// </summary>
    public const int MaxAdapterGenerationFences = 256;

    /// <summary>Max live owners across all sessions.</summary>
    public const int MaxOwners = 256;

    /// <summary>Max frozen notification snapshots retained in memory.</summary>
    public const int MaxSnapshots = 256;

    /// <summary>Default lifetime of an unresolved, pre-snapshot recovery ticket.</summary>
    public const int DefaultRecoveryTicketTtlMs = 120_000;

    /// <summary>Bounds for caller-requested recovery lifetime.</summary>
    public const int MinRecoveryTicketTtlMs = 60_000;
    public const int MaxRecoveryTicketTtlMs = 5 * 60_000;

    /// <summary>Max pre-snapshot recovery tickets retained in one daemon epoch.</summary>
    public const int MaxRecoveryTickets = 256;

    /// <summary>Max evicted terminal recovery outcomes retained as lightweight tombstones.</summary>
    public const int MaxRecoveryTombstones = 256;

    /// <summary>How long a terminal recovery outcome remains idempotently queryable.</summary>
    public const int RecoveryResultTtlMs = 10 * 60_000;

    /// <summary>Max requestId/nonce replay entries.</summary>
    public const int MaxReplayEntries = 2_048;

    /// <summary>Max pending external activation commands across all adapters.</summary>
    public const int MaxPendingActivations = 64;

    /// <summary>Max undelivered/pending activation commands per adapter.</summary>
    public const int MaxPendingPerAdapter = 8;

    /// <summary>
    /// A poll response is not an acknowledgement that the adapter received the
    /// command. Re-offer the same immutable activation after this lease.
    /// </summary>
    public const int ActivationDeliveryRetryMs = 1_000;

    /// <summary>How long a completed activation result remains queryable via activation-status (ms).</summary>
    public const int ActivationResultTtlMs = 10 * 60_000;

    /// <summary>Default poll wait budget for --client --wait-ms when omitted but wait requested (ms).</summary>
    public const int DefaultClientWaitMs = 5_000;

    /// <summary>
    /// Unsolicited host→extension wake interval for Native Messaging (ms).
    /// Inbound frames wake the MV3 service worker so poll-activation can run while idle.
    /// Chosen to guarantee multiple poll opportunities inside DefaultClientWaitMs (5s)
    /// without high traffic; must never carry session/URL/routing material.
    /// </summary>
    public const int NativeWakeIntervalMs = 1_000;

    /// <summary>
    /// Total budget for one native stdout frame. A browser that leaves stdout
    /// open but stops draining it must not strand the relay indefinitely.
    /// </summary>
    public const int NativeStdoutWriteTimeoutMs = DefaultRequestTtlMs;

    /// <summary>
    /// Maximum time a connected daemon pipe may remain between complete
    /// request frames. Production adapters send maintenance more frequently.
    /// </summary>
    public const int PipeClientIdleTimeoutMs = MaxRequestTtlMs;

    /// <summary>
    /// Total budget for one daemon response frame. A client that stops draining
    /// responses must not strand a connection handler indefinitely.
    /// </summary>
    public const int PipeClientWriteTimeoutMs = DefaultRequestTtlMs;

    /// <summary>Max length for opaque string fields (keys, ids, fingerprints).</summary>
    public const int MaxOpaqueFieldLength = 128;

    /// <summary>Max length for browserKind / adapterKind labels.</summary>
    public const int MaxLabelLength = 32;

    public static readonly HashSet<string> AllowedMessageTypes = new(StringComparer.Ordinal)
    {
        MessageTypes.Health,
        MessageTypes.RegisterAdapter,
        MessageTypes.UnregisterAdapter,
        MessageTypes.RegisterOpenIntent,
        MessageTypes.RegisterOwner,
        MessageTypes.UnregisterOwner,
        MessageTypes.Heartbeat,
        MessageTypes.Freeze,
        MessageTypes.ResolveRecovery,
        MessageTypes.Activate,
        MessageTypes.ActivateResult,
        MessageTypes.PollActivation,
        MessageTypes.ActivationStatus,
        MessageTypes.Ping,
    };

    /// <summary>
    /// Messages that mutate or consume one live adapter generation. Health,
    /// freeze, activate, and activation-status are listener/client operations
    /// and intentionally do not carry adapter-generation authority.
    /// </summary>
    public static readonly HashSet<string> AdapterGenerationMessageTypes =
        new(StringComparer.Ordinal)
        {
            MessageTypes.RegisterAdapter,
            MessageTypes.UnregisterAdapter,
            MessageTypes.RegisterOpenIntent,
            MessageTypes.RegisterOwner,
            MessageTypes.UnregisterOwner,
            MessageTypes.Heartbeat,
            MessageTypes.PollActivation,
            MessageTypes.ActivateResult,
        };

    /// <summary>
    /// Messages an authenticated browser extension may send through Native
    /// Messaging. Listener-owned freeze/activate/status calls remain pipe-only.
    /// </summary>
    public static readonly HashSet<string> AllowedNativeAdapterMessageTypes =
        new(StringComparer.Ordinal)
        {
            MessageTypes.Health,
            MessageTypes.RegisterAdapter,
            MessageTypes.UnregisterAdapter,
            MessageTypes.RegisterOpenIntent,
            MessageTypes.RegisterOwner,
            MessageTypes.UnregisterOwner,
            MessageTypes.Heartbeat,
            MessageTypes.PollActivation,
            MessageTypes.ActivateResult,
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

    /// <summary>
    /// Adapter kinds allowed to own a Pi Web session and receive activation.
    /// Transport/client process labels are intentionally excluded.
    /// </summary>
    public static readonly HashSet<string> AllowedSurfaceAdapterKinds =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "chrome",
            "edge",
            "pi-web-desktop",
            "mock",
        };

    public static readonly HashSet<string> AllowedNotificationKinds = new(StringComparer.Ordinal)
    {
        "ask-user",
        "turn-complete",
    };

    /// <summary>
    /// Terminal outcomes an external surface may report after attempting one
    /// immutable activation command. Queue/control responses are excluded.
    /// </summary>
    public static readonly HashSet<string> AllowedActivateResults = new(StringComparer.Ordinal)
    {
        RouteResults.SessionUrlConfirmed,
        RouteResults.SessionConfirmed,
        RouteResults.AlreadyActive,
        RouteResults.Stale,
        RouteResults.Timeout,
        RouteResults.Rejected,
        RouteResults.ForegroundDenied,
        RouteResults.SelectFailed,
    };
}

public static class MessageTypes
{
    public const string Health = "health";
    public const string RegisterAdapter = "register-adapter";
    public const string UnregisterAdapter = "unregister-adapter";
    public const string RegisterOpenIntent = "register-open-intent";
    public const string RegisterOwner = "register-owner";
    public const string UnregisterOwner = "unregister-owner";
    public const string Heartbeat = "heartbeat";
    public const string Freeze = "freeze";
    public const string ResolveRecovery = "resolve-recovery";
    public const string Activate = "activate";
    public const string ActivateResult = "activate-result";
    public const string PollActivation = "poll-activation";
    public const string ActivationStatus = "activation-status";
    public const string Ping = "ping";
    public const string Result = "result";

    /// <summary>
    /// Internal host→browser keep-alive only. Never accepted from callers, never forwarded
    /// to the daemon, and must not carry session/URL/routing/token fields.
    /// </summary>
    public const string Wake = "wake";
}

public static class OwnerEvents
{
    public const string ExplicitOpen = "explicit-open";
    public const string Restore = "restore";
}

public static class RouteResults
{
    public const string Ready = "ready";
    public const string Miss = "miss";
    public const string Ambiguous = "ambiguous";
    public const string Stale = "stale";
    public const string AdapterUnavailable = "adapter-unavailable";
    public const string OwnerUnresolved = "owner-unresolved";
    public const string Recovering = "recovering";
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
    public const string RequestIdConflict = "request-id-conflict";
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
    public const string RecoveryUnknown = "recovery-unknown";
    public const string RecoveryExpired = "recovery-expired";
    public const string OwnerChanged = "owner-changed";
    public const string LeaseExpired = "lease-expired";
    public const string NoPending = "no-pending";
    public const string ActivationUnknown = "activation-unknown";
    public const string PendingAdapterDelivery = "pending-adapter-delivery";
    public const string WrongAdapter = "wrong-adapter";
    public const string AdapterGenerationChanged = "adapter-generation-changed";
    // Wire value is retained for protocol-v1 compatibility even though version-2
    // storage represents a first-session binding rather than a mutable preference.
    public const string BindingPersistFailed = "preference-persist-failed";
    public const string PreferencePersistFailed = BindingPersistFailed;
}
