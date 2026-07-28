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
        if (msg.IssuedAtMs > nowMs + 60_000)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (msg.Nonce is not null && !IsOpaqueId(msg.Nonce))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        // Field length guards (no raw session / URL fields exist on the wire by design).
        if (Exceeds(msg.AdapterKey) || Exceeds(msg.OwnerKey) || Exceeds(msg.PageKey) ||
            Exceeds(msg.InstanceKey) || Exceeds(msg.RoutingKey) || Exceeds(msg.NotificationId) ||
            Exceeds(msg.SnapshotId) || Exceeds(msg.ProfileKey) || Exceeds(msg.PageFingerprint) ||
            Exceeds(msg.ActivationRequestId))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (ExceedsLabel(msg.AdapterKind) || ExceedsLabel(msg.BrowserKind) || ExceedsLabel(msg.NotificationKind) ||
            ExceedsLabel(msg.Result) || ExceedsLabel(msg.Reason))
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

        if (!IsHexOrOpaqueKey(msg.InstanceKey!) || !IsHexOrOpaqueKey(msg.RoutingKey!))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        // routingKey must be full SHA-256 hex (64 chars) or base64url-ish opaque of similar length.
        if (msg.RoutingKey!.Length < 32 || msg.RoutingKey.Length > ProtocolConstants.MaxOpaqueFieldLength)
        {
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
            !IsHexOrOpaqueKey(msg.InstanceKey!) ||
            !IsHexOrOpaqueKey(msg.RoutingKey!))
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

    public static bool IsOpaqueId(string value)
    {
        if (value.Length is < 8 or > ProtocolConstants.MaxOpaqueFieldLength)
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

    public static bool IsHexOrOpaqueKey(string value)
    {
        if (value.Length is < 8 or > ProtocolConstants.MaxOpaqueFieldLength)
        {
            return false;
        }

        foreach (var c in value)
        {
            if (!(char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' or '+' or '/' or '='))
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
}
