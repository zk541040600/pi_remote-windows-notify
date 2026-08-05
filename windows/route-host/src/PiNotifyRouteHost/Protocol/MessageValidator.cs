namespace PiNotifyRouteHost.Protocol;

public static class MessageValidator
{
    public static RouteResponse? ValidateEnvelope(RouteMessage msg, long nowMs, int maxMessageBytes)
    {
        if (msg.ProtocolVersion != ProtocolConstants.ProtocolVersion)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.ProtocolMismatch, RejectReasons.ProtocolMismatch);
        }

        if (string.IsNullOrWhiteSpace(msg.Type) || !ProtocolConstants.AllowedMessageTypes.Contains(msg.Type))
        {
            return RouteResponse.Reject(msg.RequestId ?? string.Empty, RouteResults.Rejected, RejectReasons.UnknownType);
        }

        if (string.IsNullOrWhiteSpace(msg.RequestId) || !IsOpaqueId(msg.RequestId))
        {
            return RouteResponse.Reject(msg.RequestId ?? string.Empty, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (msg.IssuedAtMs <= 0 || msg.ExpiresAtMs <= 0)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (msg.ExpiresAtMs < msg.IssuedAtMs)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (msg.ExpiresAtMs - msg.IssuedAtMs > ProtocolConstants.MaxRequestTtlMs)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (nowMs > msg.ExpiresAtMs)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Expired, RejectReasons.Expired);
        }

        // Clock skew: issued far in the future is rejected.
        if (msg.IssuedAtMs > nowMs + ProtocolConstants.MaxFutureClockSkewMs)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (msg.Nonce is not null && !IsOpaqueId(msg.Nonce))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        // Field length guards (no raw session / URL fields exist on the wire by design).
        if (Exceeds(msg.AdapterKey) || Exceeds(msg.AdapterGeneration) ||
            Exceeds(msg.OwnerKey) || Exceeds(msg.ReplacesOwnerKey) || Exceeds(msg.PageKey) ||
            Exceeds(msg.InstanceKey) || Exceeds(msg.RoutingKey) || Exceeds(msg.NotificationId) ||
            Exceeds(msg.SnapshotId) || Exceeds(msg.RecoveryTicketId) ||
            Exceeds(msg.ProfileKey) || Exceeds(msg.PageFingerprint) ||
            Exceeds(msg.ActivationRequestId) || Exceeds(msg.ActivationPhase) ||
            Exceeds(msg.OpenEventId))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (ExceedsLabel(msg.AdapterKind) || ExceedsLabel(msg.BrowserKind) || ExceedsLabel(msg.NotificationKind) ||
            ExceedsLabel(msg.Result) || ExceedsLabel(msg.Reason) || ExceedsLabel(msg.OwnerEvent))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (msg.LeaseTtlMs is int lease)
        {
            if (lease < ProtocolConstants.MinLeaseTtlMs || lease > ProtocolConstants.MaxLeaseTtlMs)
            {
                return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
            }
        }

        if (ProtocolConstants.AdapterGenerationMessageTypes.Contains(msg.Type))
        {
            if (string.IsNullOrWhiteSpace(msg.AdapterKey) ||
                string.IsNullOrWhiteSpace(msg.AdapterGeneration))
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.MissingField);
            }

            if (!IsOpaqueId(msg.AdapterKey) ||
                !IsOpaqueId(msg.AdapterGeneration))
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.InvalidField);
            }

            if (string.Equals(
                    msg.Type,
                    MessageTypes.RegisterAdapter,
                    StringComparison.Ordinal))
            {
                if (msg.AdapterStartedAtMs is not long startedAtMs ||
                    startedAtMs <= 0)
                {
                    return RouteResponse.Reject(
                        msg.RequestId,
                        RouteResults.Rejected,
                        RejectReasons.MissingField);
                }

                // This is durable runtime-generation metadata, not transport
                // freshness. Comparing it with a newly issued envelope would
                // strand the same live generation after a system-clock rollback.
            }
            else if (msg.AdapterStartedAtMs is not null)
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.InvalidField);
            }
        }
        else if (msg.AdapterGeneration is not null ||
                 msg.AdapterStartedAtMs is not null)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (msg.RecoveryTtlMs is int recoveryTtlMs &&
            (recoveryTtlMs < ProtocolConstants.MinRecoveryTicketTtlMs ||
             recoveryTtlMs > ProtocolConstants.MaxRecoveryTicketTtlMs))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (msg.RecoveryTtlMs is not null &&
            !string.Equals(msg.Type, MessageTypes.Freeze, StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (msg.RecoveryTicketId is not null &&
            !string.Equals(msg.Type, MessageTypes.ResolveRecovery, StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (msg.ReplacesOwnerKey is not null &&
            !string.Equals(
                msg.Type,
                MessageTypes.RegisterOwner,
                StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (msg.ActivationPhase is not null &&
            !string.Equals(
                msg.Type,
                MessageTypes.ActivateProgress,
                StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        _ = maxMessageBytes; // size checked before parse
        return null;
    }

    public static RouteResponse? ValidateRegisterAdapter(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.AdapterKey) || !IsOpaqueId(msg.AdapterKey))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (string.IsNullOrWhiteSpace(msg.AdapterKind) ||
            !ProtocolConstants.AllowedAdapterKinds.Contains(msg.AdapterKind))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        return ValidateCompleteAdapterIdentity(msg);
    }

    public static RouteResponse? ValidateRegisterOpenIntent(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.AdapterKey) ||
            string.IsNullOrWhiteSpace(msg.AdapterGeneration) ||
            string.IsNullOrWhiteSpace(msg.InstanceKey) ||
            string.IsNullOrWhiteSpace(msg.RoutingKey) ||
            string.IsNullOrWhiteSpace(msg.OpenEventId) ||
            msg.OpenedAtMs is null)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.MissingField);
        }

        if (!IsOpaqueId(msg.AdapterKey) ||
            !IsOpaqueId(msg.AdapterGeneration) ||
            !InstanceKeyContract.IsValid(msg.InstanceKey) ||
            !IsRoutingKey(msg.RoutingKey) ||
            !IsOpaqueId(msg.OpenEventId) ||
            msg.OpenedAtMs <= 0)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        var identityError = ValidateCompleteAdapterIdentity(msg);
        if (identityError is not null)
        {
            return identityError;
        }

        // This message records only durable first-open evidence. It must never
        // become an alternate owner, lease, notification, or activation path.
        if (msg.OwnerKey is not null ||
            msg.ReplacesOwnerKey is not null ||
            msg.PageKey is not null ||
            msg.PageFingerprint is not null ||
            msg.OwnerEvent is not null ||
            msg.LeaseTtlMs is not null ||
            msg.AdapterStartedAtMs is not null ||
            msg.NotificationId is not null ||
            msg.NotificationKind is not null ||
            msg.SnapshotId is not null ||
            msg.ActivationRequestId is not null ||
            msg.Result is not null ||
            msg.Reason is not null ||
            msg.DeadlineMs is not null ||
            msg.ElapsedMs is not null)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        // An intent may be retained while the host is unavailable. Its event
        // time is durable ordering evidence and is not transport freshness, so
        // do not compare it with this request's newly issued envelope.
        return null;
    }

    public static RouteResponse? ValidateRegisterOwner(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.AdapterKey) ||
            string.IsNullOrWhiteSpace(msg.OwnerKey) ||
            string.IsNullOrWhiteSpace(msg.PageKey) ||
            string.IsNullOrWhiteSpace(msg.InstanceKey) ||
            string.IsNullOrWhiteSpace(msg.RoutingKey))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!IsOpaqueId(msg.AdapterKey!) || !IsOpaqueId(msg.OwnerKey!) || !IsOpaqueId(msg.PageKey!))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (msg.ReplacesOwnerKey is not null &&
            (!IsOpaqueId(msg.ReplacesOwnerKey) ||
             string.Equals(
                 msg.ReplacesOwnerKey,
                 msg.OwnerKey,
                 StringComparison.Ordinal)))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (!InstanceKeyContract.IsValid(msg.InstanceKey) ||
            !IsRoutingKey(msg.RoutingKey))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        var identityError = ValidateCompleteAdapterIdentity(msg);
        if (identityError is not null)
        {
            return identityError;
        }

        if (msg.OwnerEvent is not null &&
            msg.OwnerEvent is not OwnerEvents.ExplicitOpen and not OwnerEvents.Restore)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (string.Equals(msg.OwnerEvent, OwnerEvents.ExplicitOpen, StringComparison.Ordinal))
        {
            if (string.IsNullOrWhiteSpace(msg.OpenEventId) ||
                !IsOpaqueId(msg.OpenEventId!) ||
                msg.OpenedAtMs is not long openedAtMs ||
                openedAtMs <= 0)
            {
                return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
            }

            // The clients may retain an unacknowledged explicit-open while Route Host is
            // unavailable and retry it days later. Do not compare this durable event time
            // with the fresh transport envelope: a system-clock rollback can legitimately
            // make the original open appear to be in the future.
        }
        else if (msg.OpenEventId is not null || msg.OpenedAtMs is not null)
        {
            // Restore/legacy publications never carry first-binding candidate metadata.
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        return null;
    }

    public static RouteResponse? ValidateFreeze(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.NotificationId) ||
            string.IsNullOrWhiteSpace(msg.InstanceKey) ||
            string.IsNullOrWhiteSpace(msg.RoutingKey))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!IsOpaqueId(msg.NotificationId!) ||
            !InstanceKeyContract.IsValid(msg.InstanceKey) ||
            !IsRoutingKey(msg.RoutingKey))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (msg.NotificationKind is not null &&
            !ProtocolConstants.AllowedNotificationKinds.Contains(msg.NotificationKind))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        return null;
    }

    public static RouteResponse? ValidateActivate(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.NotificationId) || string.IsNullOrWhiteSpace(msg.SnapshotId))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!IsOpaqueId(msg.NotificationId!) || !IsOpaqueId(msg.SnapshotId!))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        return null;
    }

    public static RouteResponse? ValidateResolveRecovery(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.NotificationId) ||
            string.IsNullOrWhiteSpace(msg.RecoveryTicketId))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.MissingField);
        }

        if (!IsOpaqueId(msg.NotificationId) ||
            !IsOpaqueId(msg.RecoveryTicketId))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (msg.InstanceKey is not null ||
            msg.RoutingKey is not null ||
            msg.SnapshotId is not null ||
            msg.NotificationKind is not null ||
            msg.DeadlineMs is not null)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        return null;
    }

    public static bool IsOpaqueId(string? value)
    {
        if (value is null ||
            value.Length is < 8 or > ProtocolConstants.MaxOpaqueFieldLength)
        {
            return false;
        }

        foreach (var c in value)
        {
            if (!(char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))
            {
                return false;
            }
        }

        return true;
    }

    public static bool IsRoutingKey(string? value)
    {
        if (value is null || value.Length != 64)
        {
            return false;
        }

        foreach (var c in value)
        {
            if (!(c is >= '0' and <= '9' or >= 'a' and <= 'f'))
            {
                return false;
            }
        }

        return true;
    }

    private static bool Exceeds(string? value) =>
        value is not null && value.Length > ProtocolConstants.MaxOpaqueFieldLength;

    private static bool ExceedsLabel(string? value) =>
        value is not null && value.Length > ProtocolConstants.MaxLabelLength;

    private static RouteResponse? ValidateCompleteAdapterIdentity(RouteMessage msg)
    {
        if (string.IsNullOrWhiteSpace(msg.AdapterKind) ||
            string.IsNullOrWhiteSpace(msg.BrowserKind) ||
            string.IsNullOrWhiteSpace(msg.ProfileKey))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.MissingField);
        }

        if (!ProtocolConstants.AllowedSurfaceAdapterKinds.Contains(msg.AdapterKind) ||
            !ProtocolConstants.AllowedSurfaceAdapterKinds.Contains(msg.BrowserKind) ||
            !string.Equals(
                msg.AdapterKind,
                msg.BrowserKind,
                StringComparison.OrdinalIgnoreCase) ||
            !IsOpaqueId(msg.ProfileKey))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        return null;
    }
}
