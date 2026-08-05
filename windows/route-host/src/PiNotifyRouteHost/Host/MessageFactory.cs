using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;
using System.Security.Cryptography;
using System.Text;

namespace PiNotifyRouteHost.Host;

/// <summary>Helpers to build well-formed route messages for tests and CLI.</summary>
public static class MessageFactory
{
    public static RouteMessage Create(
        string type,
        IClock clock,
        string? requestId = null,
        int ttlMs = ProtocolConstants.DefaultRequestTtlMs,
        string? nonce = null)
    {
        var now = clock.UtcNowMs;
        var ttl = Math.Clamp(ttlMs, ProtocolConstants.MinLeaseTtlMs, ProtocolConstants.MaxRequestTtlMs);
        return new RouteMessage
        {
            ProtocolVersion = ProtocolConstants.ProtocolVersion,
            Type = type,
            RequestId = requestId ?? Guid.NewGuid().ToString("N"),
            Nonce = nonce,
            IssuedAtMs = now,
            ExpiresAtMs = now + ttl,
        };
    }

    public static RouteMessage Health(IClock clock) => Create(MessageTypes.Health, clock);

    public static RouteMessage RegisterAdapter(
        IClock clock,
        string adapterKey,
        string adapterKind,
        int? leaseTtlMs = null,
        string? adapterGeneration = null,
        long? adapterStartedAtMs = null)
    {
        var msg = Create(MessageTypes.RegisterAdapter, clock);
        msg.AdapterKey = adapterKey;
        msg.AdapterGeneration = adapterGeneration ?? DefaultAdapterGeneration(adapterKey);
        // Deterministic default keeps test/CLI retries in one generation.
        // Production adapters always supply their captured runtime start.
        msg.AdapterStartedAtMs = adapterStartedAtMs ?? 1;
        msg.AdapterKind = adapterKind;
        msg.BrowserKind = adapterKind;
        msg.ProfileKey = adapterKey;
        msg.LeaseTtlMs = leaseTtlMs;
        return msg;
    }

    public static RouteMessage RegisterOpenIntent(
        IClock clock,
        string adapterKey,
        string adapterKind,
        string instanceKey,
        string routingKey,
        string openEventId,
        long openedAtMs,
        string? adapterGeneration = null)
    {
        var msg = Create(MessageTypes.RegisterOpenIntent, clock);
        msg.AdapterKey = adapterKey;
        msg.AdapterGeneration =
            adapterGeneration ?? DefaultAdapterGeneration(adapterKey);
        msg.AdapterKind = adapterKind;
        msg.BrowserKind = adapterKind;
        msg.ProfileKey = adapterKey;
        msg.InstanceKey = instanceKey;
        msg.RoutingKey = routingKey;
        msg.OpenEventId = openEventId;
        msg.OpenedAtMs = openedAtMs;
        return msg;
    }

    public static RouteMessage RegisterOwner(
        IClock clock,
        string adapterKey,
        string adapterKind,
        string ownerKey,
        string pageKey,
        string instanceKey,
        string routingKey,
        string? pageFingerprint = null,
        int? leaseTtlMs = null,
        string? ownerEvent = null,
        string? openEventId = null,
        long? openedAtMs = null,
        string? adapterGeneration = null,
        string? replacesOwnerKey = null)
    {
        var msg = Create(MessageTypes.RegisterOwner, clock);
        msg.AdapterKey = adapterKey;
        msg.AdapterGeneration = adapterGeneration ?? DefaultAdapterGeneration(adapterKey);
        msg.AdapterKind = adapterKind;
        msg.BrowserKind = adapterKind;
        msg.ProfileKey = adapterKey;
        msg.OwnerKey = ownerKey;
        msg.ReplacesOwnerKey = replacesOwnerKey;
        msg.PageKey = pageKey;
        msg.InstanceKey = instanceKey;
        msg.RoutingKey = routingKey;
        msg.PageFingerprint = pageFingerprint;
        msg.LeaseTtlMs = leaseTtlMs;
        msg.OwnerEvent = ownerEvent;
        msg.OpenEventId = openEventId;
        msg.OpenedAtMs = openedAtMs;
        return msg;
    }

    public static RouteMessage UnregisterOwner(
        IClock clock,
        string adapterKey,
        string ownerKey,
        string? adapterGeneration = null)
    {
        var msg = Create(MessageTypes.UnregisterOwner, clock);
        msg.AdapterKey = adapterKey;
        msg.AdapterGeneration = adapterGeneration ?? DefaultAdapterGeneration(adapterKey);
        msg.OwnerKey = ownerKey;
        return msg;
    }

    public static RouteMessage Freeze(
        IClock clock,
        string notificationId,
        string instanceKey,
        string routingKey,
        string? notificationKind = null,
        int? recoveryTtlMs = null)
    {
        var msg = Create(MessageTypes.Freeze, clock);
        msg.NotificationId = notificationId;
        msg.InstanceKey = instanceKey;
        msg.RoutingKey = routingKey;
        msg.NotificationKind = notificationKind;
        msg.RecoveryTtlMs = recoveryTtlMs;
        return msg;
    }

    public static RouteMessage ResolveRecovery(
        IClock clock,
        string notificationId,
        string recoveryTicketId)
    {
        var msg = Create(MessageTypes.ResolveRecovery, clock);
        msg.NotificationId = notificationId;
        msg.RecoveryTicketId = recoveryTicketId;
        return msg;
    }

    public static RouteMessage Activate(
        IClock clock,
        string notificationId,
        string snapshotId,
        long? deadlineMs = null)
    {
        var msg = Create(MessageTypes.Activate, clock);
        msg.NotificationId = notificationId;
        msg.SnapshotId = snapshotId;
        msg.DeadlineMs = deadlineMs;
        return msg;
    }

    public static RouteMessage PollActivation(
        IClock clock,
        string adapterKey,
        int? leaseTtlMs = null,
        string? adapterGeneration = null)
    {
        var msg = Create(MessageTypes.PollActivation, clock);
        msg.AdapterKey = adapterKey;
        msg.AdapterGeneration = adapterGeneration ?? DefaultAdapterGeneration(adapterKey);
        msg.LeaseTtlMs = leaseTtlMs;
        return msg;
    }

    public static RouteMessage ActivationStatus(IClock clock, string activationRequestId)
    {
        var msg = Create(MessageTypes.ActivationStatus, clock);
        msg.ActivationRequestId = activationRequestId;
        return msg;
    }

    public static RouteMessage ActivateResult(
        IClock clock,
        string activationRequestId,
        string result,
        string? reason = null,
        string? snapshotId = null,
        string? adapterKey = null,
        long? elapsedMs = null,
        string? adapterGeneration = null)
    {
        var msg = Create(MessageTypes.ActivateResult, clock);
        msg.ActivationRequestId = activationRequestId;
        msg.Result = result;
        msg.Reason = reason;
        msg.SnapshotId = snapshotId;
        msg.AdapterKey = adapterKey;
        msg.AdapterGeneration = adapterKey is null
            ? adapterGeneration
            : adapterGeneration ?? DefaultAdapterGeneration(adapterKey);
        msg.ElapsedMs = elapsedMs;
        return msg;
    }

    public static string DefaultAdapterGeneration(string adapterKey)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(adapterKey));
        return "gen-" + Convert.ToHexString(hash.AsSpan(0, 12)).ToLowerInvariant();
    }
}
