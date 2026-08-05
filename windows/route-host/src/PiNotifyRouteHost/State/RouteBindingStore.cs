using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.State;

/// <summary>
/// Durable, URL-free first-opener binding for each Pi session route. Live owner leases and
/// notification snapshots stay in RouteStateMachine; only the bound adapter/event survives restart.
/// </summary>
public interface IRouteBindingStore
{
    /// <summary>
    /// Whether a single restore-only owner may route when no explicit-open binding exists.
    /// Durable stores disable this because an absent entry can mean missing, discarded, or
    /// capacity-evicted metadata rather than a trustworthy never-bound session.
    /// </summary>
    bool AllowsUnboundSingleOwnerRouting { get; }

    bool IsAdapterIdentityCompatible(
        string adapterKey,
        AdapterBindingIdentity adapterIdentity);

    /// <summary>
    /// Observe one Host receive timestamp before replay lookup or any route
    /// mutation. A strict wall-clock regression advances a durable causal
    /// epoch; failure leaves route traffic fail-closed until the barrier can
    /// be persisted.
    /// </summary>
    bool TryObserveReceiveClock(long receivedAtMs);

    bool TryBindFirstExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        AdapterBindingIdentity adapterIdentity,
        string openEventId,
        long openedAtMs,
        long receivedAtMs,
        out SessionOwnerBinding? binding);

    SessionOwnerBinding? GetBinding(SessionRouteKey session);
}

public sealed class MemoryRouteBindingStore : IRouteBindingStore
{
    private readonly object _gate = new();
    private readonly Dictionary<string, RouteBindingState> _sessions = new(StringComparer.Ordinal);
    private long _nextRevision;
    private long _clockEpoch;
    private long _lastReceivedAtMs;

    public bool AllowsUnboundSingleOwnerRouting => true;

    public bool IsAdapterIdentityCompatible(
        string adapterKey,
        AdapterBindingIdentity adapterIdentity)
    {
        lock (_gate)
        {
            return _sessions.Values.All(entry =>
                !string.Equals(entry.AdapterKey, adapterKey, StringComparison.Ordinal) ||
                RouteBindingStoreLogic.IdentityMatches(
                    entry.AdapterIdentity!,
                    adapterIdentity));
        }
    }

    public bool TryObserveReceiveClock(long receivedAtMs)
    {
        lock (_gate)
        {
            return ObserveReceiveClock_NoLock(receivedAtMs);
        }
    }

    public bool TryBindFirstExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        AdapterBindingIdentity adapterIdentity,
        string openEventId,
        long openedAtMs,
        out SessionOwnerBinding? binding) =>
        TryBindFirstExplicitOpen(
            session,
            adapterKey,
            adapterIdentity,
            openEventId,
            openedAtMs,
            openedAtMs,
            out binding);

    public bool TryBindFirstExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        AdapterBindingIdentity adapterIdentity,
        string openEventId,
        long openedAtMs,
        long receivedAtMs,
        out SessionOwnerBinding? binding)
    {
        lock (_gate)
        {
            if (!ObserveReceiveClock_NoLock(receivedAtMs))
            {
                binding = null;
                return false;
            }

            var sessionId = RouteBindingStoreLogic.SessionId(session);
            if (_sessions.TryGetValue(sessionId, out var existing) &&
                !RouteBindingStoreLogic.CandidatePrecedes(
                    existing,
                    openEventId,
                    openedAtMs,
                    _clockEpoch))
            {
                binding = existing.ToBinding();
                return true;
            }

            var entry = new RouteBindingState
            {
                AdapterKey = adapterKey,
                AdapterIdentity = adapterIdentity,
                OpenEventId = openEventId,
                OpenedAtMs = openedAtMs,
                Revision = checked(++_nextRevision),
                ReceiveClockEpoch = _clockEpoch,
            };
            _sessions[sessionId] = entry;
            binding = entry.ToBinding();
            return true;
        }
    }

    public SessionOwnerBinding? GetBinding(SessionRouteKey session)
    {
        lock (_gate)
        {
            return _sessions.TryGetValue(RouteBindingStoreLogic.SessionId(session), out var entry)
                ? entry.ToBinding()
                : null;
        }
    }

    private bool ObserveReceiveClock_NoLock(long receivedAtMs)
    {
        if (receivedAtMs <= 0)
        {
            return false;
        }

        try
        {
            if (_clockEpoch == 0)
            {
                _clockEpoch = 1;
            }
            else if (_lastReceivedAtMs > 0 &&
                     receivedAtMs < _lastReceivedAtMs)
            {
                _clockEpoch = checked(_clockEpoch + 1);
            }
        }
        catch (OverflowException)
        {
            return false;
        }

        _lastReceivedAtMs = receivedAtMs;
        return true;
    }
}

public sealed class FileRouteBindingStore : IRouteBindingStore
{
    // Version 1 stored mutable last-open ranks. Version 2 stored only adapterKey, which cannot
    // prevent a different surface from inheriting a binding after daemon restart. Neither old
    // format has enough identity evidence for a safe migration. Version 3 is the closed-schema
    // first-opener document and is migrated fail-closed into the receive-clock epoch format.
    private const int FormatVersion = 4;
    private const int LegacyBindingFormatVersion = 3;
    private const int MaxSessions = 2_048;
    private const int MaxDocumentBytes = 4 * 1024 * 1024;
    private readonly object _gate = new();
    private readonly string _path;
    private BindingDocument _document;
    private bool _documentAvailable;
    private long _lastReceivedAtMs;
    private bool _clockPersistencePending;

    public bool AllowsUnboundSingleOwnerRouting => false;

    public bool IsAdapterIdentityCompatible(
        string adapterKey,
        AdapterBindingIdentity adapterIdentity)
    {
        lock (_gate)
        {
            if (!EnsureDocumentAvailable())
            {
                return false;
            }

            return _document.Sessions.Values.All(entry =>
                !string.Equals(entry.AdapterKey, adapterKey, StringComparison.Ordinal) ||
                RouteBindingStoreLogic.IdentityMatches(
                    entry.AdapterIdentity!,
                    adapterIdentity));
        }
    }

    public FileRouteBindingStore(string path)
    {
        _path = Path.GetFullPath(path);
        var loaded = Load(_path);
        _document = loaded.Document;
        _documentAvailable = loaded.Available;
        _lastReceivedAtMs = _document.ClockHighWaterMs;
    }

    public bool TryObserveReceiveClock(long receivedAtMs)
    {
        lock (_gate)
        {
            if (!EnsureDocumentAvailable())
            {
                return false;
            }

            return ObserveReceiveClock_NoLock(receivedAtMs);
        }
    }

    public bool TryBindFirstExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        AdapterBindingIdentity adapterIdentity,
        string openEventId,
        long openedAtMs,
        out SessionOwnerBinding? binding) =>
        TryBindFirstExplicitOpen(
            session,
            adapterKey,
            adapterIdentity,
            openEventId,
            openedAtMs,
            openedAtMs,
            out binding);

    public bool TryBindFirstExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        AdapterBindingIdentity adapterIdentity,
        string openEventId,
        long openedAtMs,
        long receivedAtMs,
        out SessionOwnerBinding? binding)
    {
        lock (_gate)
        {
            if (!EnsureDocumentAvailable())
            {
                binding = null;
                return false;
            }

            if (!ObserveReceiveClock_NoLock(receivedAtMs))
            {
                binding = null;
                return false;
            }

            var before = Clone(_document);
            var sessionId = RouteBindingStoreLogic.SessionId(session);
            _document.Sessions.TryGetValue(sessionId, out var existing);
            var bindingChanged =
                existing is null ||
                RouteBindingStoreLogic.CandidatePrecedes(
                    existing,
                    openEventId,
                    openedAtMs,
                    _document.ClockEpoch);
            RouteBindingState selected;
            if (bindingChanged)
            {
                CompactRevisionsAtLimit();
                selected = new RouteBindingState
                {
                    AdapterKey = adapterKey,
                    AdapterIdentity = adapterIdentity,
                    OpenEventId = openEventId,
                    OpenedAtMs = openedAtMs,
                    Revision = checked(++_document.NextRevision),
                    ReceiveClockEpoch = _document.ClockEpoch,
                };
                _document.Sessions[sessionId] = selected;
                TrimOldestSessions(sessionId);
            }
            else
            {
                selected = existing!;
            }

            var clockChanged =
                _document.ClockHighWaterMs != receivedAtMs;
            if (receivedAtMs > _document.ClockHighWaterMs)
            {
                _document.ClockHighWaterMs = receivedAtMs;
            }

            if ((bindingChanged || clockChanged) && !TrySave())
            {
                var failedClockEpoch = _document.ClockEpoch;
                var failedClockHighWaterMs = _document.ClockHighWaterMs;
                _document = before;
                if (failedClockEpoch != before.ClockEpoch ||
                    failedClockHighWaterMs != before.ClockHighWaterMs)
                {
                    // Keep only the causal clock transition pending in memory.
                    // Never retain an unpersisted binding/revision mutation.
                    _document.ClockEpoch = failedClockEpoch;
                    _document.ClockHighWaterMs = failedClockHighWaterMs;
                    _clockPersistencePending = true;
                }
                binding = null;
                return false;
            }

            binding = selected.ToBinding();
            return true;
        }
    }

    public SessionOwnerBinding? GetBinding(SessionRouteKey session)
    {
        lock (_gate)
        {
            if (!EnsureDocumentAvailable())
            {
                return null;
            }

            return _document.Sessions.TryGetValue(RouteBindingStoreLogic.SessionId(session), out var entry)
                ? entry.ToBinding()
                : null;
        }
    }

    private bool EnsureDocumentAvailable()
    {
        if (_documentAvailable)
        {
            return true;
        }

        // A startup-time share/permission failure is not evidence that the
        // durable document is empty. Retry the read on later route operations;
        // never overwrite the original with a synthetic empty document.
        var loaded = Load(_path);
        _document = loaded.Document;
        _documentAvailable = loaded.Available;
        _lastReceivedAtMs = _document.ClockHighWaterMs;
        _clockPersistencePending = false;
        return _documentAvailable;
    }

    private bool ObserveReceiveClock_NoLock(long receivedAtMs)
    {
        if (receivedAtMs <= 0)
        {
            return false;
        }

        var mustPersist = _clockPersistencePending;
        try
        {
            if (_document.ClockEpoch == 0)
            {
                _document.ClockEpoch = 1;
                _document.ClockHighWaterMs = receivedAtMs;
                mustPersist = true;
            }
            else if (_lastReceivedAtMs > 0 &&
                     receivedAtMs < _lastReceivedAtMs)
            {
                _document.ClockEpoch = checked(_document.ClockEpoch + 1);
                _document.ClockHighWaterMs = receivedAtMs;
                mustPersist = true;
            }
            else if (_clockPersistencePending &&
                     receivedAtMs > _document.ClockHighWaterMs)
            {
                _document.ClockHighWaterMs = receivedAtMs;
            }
        }
        catch (OverflowException)
        {
            return false;
        }

        _lastReceivedAtMs = receivedAtMs;
        if (!mustPersist)
        {
            return true;
        }

        _clockPersistencePending = true;
        if (!TrySave())
        {
            return false;
        }

        _clockPersistencePending = false;
        return true;
    }

    private void CompactRevisionsAtLimit()
    {
        if (_document.NextRevision < long.MaxValue)
        {
            return;
        }

        // Revision is an internal receive-order/audit field, not part of first-opener
        // selection. Preserve its relative order while rebasing the bounded document so
        // a valid saturated file cannot crash the next registration.
        long revision = 0;
        foreach (var pair in _document.Sessions
                     .OrderBy(item => item.Value.Revision)
                     .ThenBy(item => item.Key, StringComparer.Ordinal))
        {
            pair.Value.Revision = checked(++revision);
        }

        _document.NextRevision = revision;
    }

    private bool TrySave()
    {
        try
        {
            var directory = Path.GetDirectoryName(_path);
            if (string.IsNullOrEmpty(directory))
            {
                return false;
            }

            Directory.CreateDirectory(directory);
            var temp = _path + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                var bytes = JsonSerializer.SerializeToUtf8Bytes(_document, JsonDefaults.Options);
                if (bytes.Length > MaxDocumentBytes)
                {
                    return false;
                }
                File.WriteAllBytes(temp, bytes);
                File.Move(temp, _path, overwrite: true);
                return true;
            }
            finally
            {
                if (File.Exists(temp))
                {
                    File.Delete(temp);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            SafeLog.Warn("route-binding-save-failed", ("reason", ex.GetType().Name));
            return false;
        }
    }

    private static BindingLoadResult Load(string path)
    {
        byte[] bytes;
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read);
            if (stream.Length > MaxDocumentBytes)
            {
                SafeLog.Warn("route-binding-load-failed", ("reason", "binding-state-oversized"));
                return new BindingLoadResult(new BindingDocument(), Available: true);
            }

            bytes = new byte[checked((int)stream.Length)];
            stream.ReadExactly(bytes);
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        {
            return new BindingLoadResult(new BindingDocument(), Available: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SafeLog.Warn("route-binding-load-unavailable", ("reason", ex.GetType().Name));
            return new BindingLoadResult(new BindingDocument(), Available: false);
        }

        try
        {
            if (bytes.Length > MaxDocumentBytes)
            {
                throw new JsonException("binding-state-oversized");
            }

            if (HasDuplicateJsonPropertyNames(bytes))
            {
                throw new JsonException("binding-state-duplicate-property");
            }

            var document = JsonSerializer.Deserialize<BindingDocument>(bytes, JsonDefaults.Options);
            if (document is null)
            {
                throw new JsonException("binding-state-invalid");
            }

            if (document.Version == LegacyBindingFormatVersion)
            {
                if (!HasExactLegacyV3Shape(bytes) ||
                    !IsValidLegacyV3(document))
                {
                    throw new JsonException("binding-state-invalid");
                }

                document.Version = FormatVersion;
                document.ClockEpoch = 0;
                document.ClockHighWaterMs = 0;
                foreach (var entry in document.Sessions.Values)
                {
                    entry.ReceiveClockEpoch = 0;
                }
            }
            else if (document.Version != FormatVersion ||
                     !HasExactV4Shape(bytes) ||
                     !IsValid(document))
            {
                throw new JsonException("binding-state-invalid");
            }

            return new BindingLoadResult(document, Available: true);
        }
        catch (JsonException ex)
        {
            // Deterministic fail-closed recovery: ignore the whole corrupt or legacy document.
            // Restored owners remain unbound until a real explicit-open establishes version 4.
            SafeLog.Warn("route-binding-load-failed", ("reason", ex.GetType().Name));
            return new BindingLoadResult(new BindingDocument(), Available: true);
        }
    }

    private static bool HasDuplicateJsonPropertyNames(ReadOnlySpan<byte> bytes)
    {
        var reader = new Utf8JsonReader(
            bytes,
            new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = JsonDefaults.Options.MaxDepth,
            });
        var propertyNamesByObjectDepth = new List<HashSet<string>>();
        var objectDepth = 0;
        while (reader.Read())
        {
            switch (reader.TokenType)
            {
                case JsonTokenType.StartObject:
                    if (propertyNamesByObjectDepth.Count == objectDepth)
                    {
                        propertyNamesByObjectDepth.Add(
                            new HashSet<string>(StringComparer.OrdinalIgnoreCase));
                    }
                    else
                    {
                        propertyNamesByObjectDepth[objectDepth].Clear();
                    }
                    objectDepth++;
                    break;
                case JsonTokenType.PropertyName:
                    {
                        if (objectDepth == 0 ||
                            !propertyNamesByObjectDepth[objectDepth - 1]
                                .Add(reader.GetString()!))
                        {
                            return true;
                        }
                        break;
                    }
                case JsonTokenType.EndObject:
                    if (objectDepth == 0)
                    {
                        return true;
                    }
                    objectDepth--;
                    break;
            }
        }

        return objectDepth != 0;
    }

    private static bool IsValid(BindingDocument document)
    {
        if (document.Sessions is null ||
            document.ClockEpoch < 1 ||
            document.ClockHighWaterMs <= 0 ||
            document.NextRevision < 0 ||
            document.Sessions.Count > MaxSessions)
        {
            return false;
        }

        var revisions = new HashSet<long>();
        var adapterIdentities = new Dictionary<string, AdapterBindingIdentity>(
            StringComparer.Ordinal);
        foreach (var (sessionId, entry) in document.Sessions)
        {
            if (!IsLowerSha256Hex(sessionId) ||
                entry is null ||
                !MessageValidator.IsOpaqueId(entry.AdapterKey) ||
                entry.AdapterIdentity is null ||
                !ProtocolConstants.AllowedSurfaceAdapterKinds.Contains(entry.AdapterIdentity.AdapterKind) ||
                string.IsNullOrWhiteSpace(entry.AdapterIdentity.BrowserKind) ||
                !ProtocolConstants.AllowedSurfaceAdapterKinds.Contains(entry.AdapterIdentity.BrowserKind) ||
                !string.Equals(
                    entry.AdapterIdentity.AdapterKind,
                    entry.AdapterIdentity.BrowserKind,
                    StringComparison.OrdinalIgnoreCase) ||
                string.IsNullOrWhiteSpace(entry.AdapterIdentity.ProfileKey) ||
                !MessageValidator.IsOpaqueId(entry.AdapterIdentity.ProfileKey) ||
                 !MessageValidator.IsOpaqueId(entry.OpenEventId) ||
                 entry.OpenedAtMs <= 0 ||
                 entry.Revision <= 0 ||
                 entry.Revision > document.NextRevision ||
                 entry.ReceiveClockEpoch < 0 ||
                 entry.ReceiveClockEpoch > document.ClockEpoch ||
                 !revisions.Add(entry.Revision))
            {
                return false;
            }

            if (adapterIdentities.TryGetValue(
                    entry.AdapterKey,
                    out var existingIdentity))
            {
                if (!RouteBindingStoreLogic.IdentityMatches(
                        existingIdentity,
                        entry.AdapterIdentity))
                {
                    return false;
                }
            }
            else
            {
                adapterIdentities.Add(entry.AdapterKey, entry.AdapterIdentity);
            }
        }

        return true;
    }

    private static bool IsValidLegacyV3(BindingDocument document)
    {
        if (document.ClockEpoch != 0 ||
            document.ClockHighWaterMs != 0 ||
            document.Sessions is null ||
            document.NextRevision < 0 ||
            document.Sessions.Count > MaxSessions)
        {
            return false;
        }

        var revisions = new HashSet<long>();
        var adapterIdentities = new Dictionary<string, AdapterBindingIdentity>(
            StringComparer.Ordinal);
        foreach (var (sessionId, entry) in document.Sessions)
        {
            if (!IsLowerSha256Hex(sessionId) ||
                entry is null ||
                entry.ReceiveClockEpoch != 0 ||
                !MessageValidator.IsOpaqueId(entry.AdapterKey) ||
                entry.AdapterIdentity is null ||
                !ProtocolConstants.AllowedSurfaceAdapterKinds.Contains(entry.AdapterIdentity.AdapterKind) ||
                string.IsNullOrWhiteSpace(entry.AdapterIdentity.BrowserKind) ||
                !ProtocolConstants.AllowedSurfaceAdapterKinds.Contains(entry.AdapterIdentity.BrowserKind) ||
                !string.Equals(
                    entry.AdapterIdentity.AdapterKind,
                    entry.AdapterIdentity.BrowserKind,
                    StringComparison.OrdinalIgnoreCase) ||
                string.IsNullOrWhiteSpace(entry.AdapterIdentity.ProfileKey) ||
                !MessageValidator.IsOpaqueId(entry.AdapterIdentity.ProfileKey) ||
                !MessageValidator.IsOpaqueId(entry.OpenEventId) ||
                entry.OpenedAtMs <= 0 ||
                entry.Revision <= 0 ||
                entry.Revision > document.NextRevision ||
                !revisions.Add(entry.Revision))
            {
                return false;
            }

            if (adapterIdentities.TryGetValue(
                    entry.AdapterKey,
                    out var existingIdentity))
            {
                if (!RouteBindingStoreLogic.IdentityMatches(
                        existingIdentity,
                        entry.AdapterIdentity))
                {
                    return false;
                }
            }
            else
            {
                adapterIdentities.Add(entry.AdapterKey, entry.AdapterIdentity);
            }
        }

        return true;
    }

    private static bool HasExactLegacyV3Shape(ReadOnlySpan<byte> bytes)
    {
        using var json = JsonDocument.Parse(bytes.ToArray());
        var root = json.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !HasExactJsonProperties(
                root,
                "version",
                "nextRevision",
                "sessions"))
        {
            return false;
        }

        if (!root.TryGetProperty("sessions", out var sessions) ||
            sessions.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        foreach (var session in sessions.EnumerateObject())
        {
            if (session.Value.ValueKind != JsonValueKind.Object ||
                !HasExactJsonProperties(
                    session.Value,
                    "adapterKey",
                    "adapterIdentity",
                    "openEventId",
                    "openedAtMs",
                    "revision") ||
                !session.Value.TryGetProperty(
                    "adapterIdentity",
                    out var identity) ||
                identity.ValueKind != JsonValueKind.Object ||
                !HasExactJsonProperties(
                    identity,
                    "adapterKind",
                    "browserKind",
                    "profileKey"))
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasExactV4Shape(ReadOnlySpan<byte> bytes)
    {
        using var json = JsonDocument.Parse(bytes.ToArray());
        var root = json.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !HasExactJsonProperties(
                root,
                "version",
                "clockEpoch",
                "clockHighWaterMs",
                "nextRevision",
                "sessions"))
        {
            return false;
        }

        if (!root.TryGetProperty("sessions", out var sessions) ||
            sessions.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        foreach (var session in sessions.EnumerateObject())
        {
            if (session.Value.ValueKind != JsonValueKind.Object ||
                !HasExactJsonProperties(
                    session.Value,
                    "adapterKey",
                    "adapterIdentity",
                    "openEventId",
                    "openedAtMs",
                    "revision",
                    "receiveClockEpoch") ||
                !session.Value.TryGetProperty(
                    "adapterIdentity",
                    out var identity) ||
                identity.ValueKind != JsonValueKind.Object ||
                !HasExactJsonProperties(
                    identity,
                    "adapterKind",
                    "browserKind",
                    "profileKey"))
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasExactJsonProperties(
        JsonElement value,
        params string[] expected)
    {
        var actual = value
            .EnumerateObject()
            .Select(property => property.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        var canonicalExpected = expected
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        return actual.SequenceEqual(
            canonicalExpected,
            StringComparer.Ordinal);
    }

    private static bool IsLowerSha256Hex(string value)
    {
        if (value.Length != 64)
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

    private void TrimOldestSessions(string protectedSessionId)
    {
        while (_document.Sessions.Count > MaxSessions)
        {
            // Client-captured open time selects the winner inside one session, but it must
            // not control global storage retention. Revision is the trusted host admission
            // order and remains deterministic after compaction.
            var victim = _document.Sessions
                .Where(pair => !string.Equals(pair.Key, protectedSessionId, StringComparison.Ordinal))
                .OrderBy(pair => pair.Value.Revision)
                .ThenBy(pair => pair.Key, StringComparer.Ordinal)
                .First().Key;
            _document.Sessions.Remove(victim);
        }
    }

    private static BindingDocument Clone(BindingDocument value)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonDefaults.Options);
        return JsonSerializer.Deserialize<BindingDocument>(bytes, JsonDefaults.Options)
            ?? new BindingDocument();
    }

    private sealed class BindingDocument
    {
        public int Version { get; set; } = FormatVersion;
        public long ClockEpoch { get; set; }
        public long ClockHighWaterMs { get; set; }
        public long NextRevision { get; set; }
        public Dictionary<string, RouteBindingState> Sessions { get; set; } =
            new(StringComparer.Ordinal);
    }

    private readonly record struct BindingLoadResult(
        BindingDocument Document,
        bool Available);
}

internal static class RouteBindingStoreLogic
{
    public static bool IdentityMatches(
        AdapterBindingIdentity persisted,
        AdapterBindingIdentity candidate) =>
        string.Equals(
            persisted.AdapterKind,
            candidate.AdapterKind,
            StringComparison.OrdinalIgnoreCase) &&
        string.Equals(
            persisted.BrowserKind,
            candidate.BrowserKind,
            StringComparison.OrdinalIgnoreCase) &&
        string.Equals(
            persisted.ProfileKey,
            candidate.ProfileKey,
            StringComparison.Ordinal);

    public static bool CandidatePrecedes(
        RouteBindingState existing,
        string openEventId,
        long openedAtMs,
        long receiveClockEpoch)
    {
        // Replays are idempotent even if a malformed retry changes its timestamp. For distinct
        // events, only an earlier user-open timestamp received in the same causal wall-clock
        // epoch may correct the durable first binding.
        return !string.Equals(existing.OpenEventId, openEventId, StringComparison.Ordinal) &&
               existing.ReceiveClockEpoch == receiveClockEpoch &&
               openedAtMs < existing.OpenedAtMs;
    }

    public static string SessionId(SessionRouteKey session)
    {
        var material = Encoding.UTF8.GetBytes(session.InstanceKey + "\0" + session.RoutingKey);
        return Convert.ToHexString(SHA256.HashData(material)).ToLowerInvariant();
    }
}

internal sealed class RouteBindingState
{
    public string AdapterKey { get; set; } = string.Empty;
    public AdapterBindingIdentity? AdapterIdentity { get; set; }
    public string OpenEventId { get; set; } = string.Empty;
    public long OpenedAtMs { get; set; }
    public long Revision { get; set; }
    public long ReceiveClockEpoch { get; set; }

    public SessionOwnerBinding ToBinding() => new()
    {
        AdapterKey = AdapterKey,
        AdapterIdentity = AdapterIdentity!,
        OpenEventId = OpenEventId,
        OpenedAtMs = OpenedAtMs,
        Revision = Revision,
        ReceiveClockEpoch = ReceiveClockEpoch,
    };
}
