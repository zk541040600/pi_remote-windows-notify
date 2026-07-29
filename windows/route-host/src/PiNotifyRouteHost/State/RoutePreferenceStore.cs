using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.State;

/// <summary>
/// Durable, URL-free ordering metadata for explicit session opens. Runtime owner leases and
/// notification snapshots stay in RouteStateMachine; only adapter/event ranks survive restart.
/// </summary>
public interface IRoutePreferenceStore
{
    bool TryRecordExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        string openEventId,
        long openedAtMs,
        out OwnerPreference? preference);

    OwnerPreference? GetPreference(SessionRouteKey session, string adapterKey);
}

public sealed class MemoryRoutePreferenceStore : IRoutePreferenceStore
{
    private readonly object _gate = new();
    private readonly Dictionary<string, SessionPreferenceState> _sessions = new(StringComparer.Ordinal);
    private long _nextRevision;

    public bool TryRecordExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        string openEventId,
        long openedAtMs,
        out OwnerPreference? preference)
    {
        lock (_gate)
        {
            var sessionId = SessionId(session);
            if (!_sessions.TryGetValue(sessionId, out var state))
            {
                state = new SessionPreferenceState();
                _sessions[sessionId] = state;
            }

            if (state.Adapters.TryGetValue(adapterKey, out var existing))
            {
                if (string.Equals(existing.OpenEventId, openEventId, StringComparison.Ordinal))
                {
                    preference = existing.ToPreference(adapterKey);
                    return true;
                }

                // Delayed stale publications cannot overwrite a newer explicit open.
                if (openedAtMs < existing.OpenedAtMs)
                {
                    preference = existing.ToPreference(adapterKey);
                    return true;
                }
            }

            var entry = new AdapterPreferenceState
            {
                OpenEventId = openEventId,
                OpenedAtMs = openedAtMs,
                Revision = checked(++_nextRevision),
            };
            state.Adapters[adapterKey] = entry;
            state.UpdatedAtMs = openedAtMs;
            preference = entry.ToPreference(adapterKey);
            return true;
        }
    }

    public OwnerPreference? GetPreference(SessionRouteKey session, string adapterKey)
    {
        lock (_gate)
        {
            return _sessions.TryGetValue(SessionId(session), out var state) &&
                   state.Adapters.TryGetValue(adapterKey, out var entry)
                ? entry.ToPreference(adapterKey)
                : null;
        }
    }

    private static string SessionId(SessionRouteKey session)
    {
        var material = Encoding.UTF8.GetBytes(session.InstanceKey + "\0" + session.RoutingKey);
        return Convert.ToHexString(SHA256.HashData(material)).ToLowerInvariant();
    }

    private sealed class SessionPreferenceState
    {
        public Dictionary<string, AdapterPreferenceState> Adapters { get; init; } =
            new(StringComparer.Ordinal);
        public long UpdatedAtMs { get; set; }
    }

    private sealed class AdapterPreferenceState
    {
        public string OpenEventId { get; set; } = string.Empty;
        public long OpenedAtMs { get; set; }
        public long Revision { get; set; }

        public OwnerPreference ToPreference(string adapterKey) => new()
        {
            AdapterKey = adapterKey,
            OpenEventId = OpenEventId,
            OpenedAtMs = OpenedAtMs,
            Revision = Revision,
        };
    }
}

public sealed class FileRoutePreferenceStore : IRoutePreferenceStore
{
    private const int FormatVersion = 1;
    private const int MaxSessions = 2_048;
    private readonly object _gate = new();
    private readonly string _path;
    private PreferenceDocument _document;

    public FileRoutePreferenceStore(string path)
    {
        _path = Path.GetFullPath(path);
        _document = Load(_path);
    }

    public bool TryRecordExplicitOpen(
        SessionRouteKey session,
        string adapterKey,
        string openEventId,
        long openedAtMs,
        out OwnerPreference? preference)
    {
        lock (_gate)
        {
            var sessionId = SessionId(session);
            if (!_document.Sessions.TryGetValue(sessionId, out var state))
            {
                state = new SessionPreferenceState();
                _document.Sessions[sessionId] = state;
            }

            if (state.Adapters.TryGetValue(adapterKey, out var existing))
            {
                if (string.Equals(existing.OpenEventId, openEventId, StringComparison.Ordinal) ||
                    openedAtMs < existing.OpenedAtMs)
                {
                    preference = existing.ToPreference(adapterKey);
                    return true;
                }
            }

            var before = Clone(_document);
            var entry = new AdapterPreferenceState
            {
                OpenEventId = openEventId,
                OpenedAtMs = openedAtMs,
                Revision = checked(++_document.NextRevision),
            };
            state.Adapters[adapterKey] = entry;
            state.UpdatedAtMs = openedAtMs;
            TrimOldestSessions();

            if (!TrySave())
            {
                _document = before;
                preference = null;
                return false;
            }

            preference = entry.ToPreference(adapterKey);
            return true;
        }
    }

    public OwnerPreference? GetPreference(SessionRouteKey session, string adapterKey)
    {
        lock (_gate)
        {
            return _document.Sessions.TryGetValue(SessionId(session), out var state) &&
                   state.Adapters.TryGetValue(adapterKey, out var entry)
                ? entry.ToPreference(adapterKey)
                : null;
        }
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
            SafeLog.Warn("route-preference-save-failed", ("reason", ex.GetType().Name));
            return false;
        }
    }

    private static PreferenceDocument Load(string path)
    {
        if (!File.Exists(path))
        {
            return new PreferenceDocument();
        }

        try
        {
            var bytes = File.ReadAllBytes(path);
            if (bytes.Length > ProtocolConstants.MaxMessageBytes * 8)
            {
                throw new JsonException("preference-state-oversized");
            }

            var document = JsonSerializer.Deserialize<PreferenceDocument>(bytes, JsonDefaults.Options);
            if (document is null || document.Version != FormatVersion || !IsValid(document))
            {
                throw new JsonException("preference-state-invalid");
            }

            return document;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // Deterministic fail-closed recovery: ignore the whole corrupt document. Restore
            // registrations then remain unranked until a real explicit-open is observed.
            SafeLog.Warn("route-preference-load-failed", ("reason", ex.GetType().Name));
            return new PreferenceDocument();
        }
    }

    private static bool IsValid(PreferenceDocument document)
    {
        if (document.NextRevision < 0 || document.Sessions.Count > MaxSessions)
        {
            return false;
        }

        var revisions = new HashSet<long>();
        foreach (var (sessionId, session) in document.Sessions)
        {
            if (sessionId.Length != 64 || session.Adapters.Count > ProtocolConstants.MaxAdapters)
            {
                return false;
            }

            foreach (var (adapterKey, entry) in session.Adapters)
            {
                if (!MessageValidator.IsOpaqueId(adapterKey) ||
                    !MessageValidator.IsOpaqueId(entry.OpenEventId) ||
                    entry.OpenedAtMs <= 0 ||
                    entry.Revision <= 0 ||
                    entry.Revision > document.NextRevision ||
                    !revisions.Add(entry.Revision))
                {
                    return false;
                }
            }
        }

        return true;
    }

    private void TrimOldestSessions()
    {
        while (_document.Sessions.Count > MaxSessions)
        {
            var victim = _document.Sessions
                .OrderBy(pair => pair.Value.UpdatedAtMs)
                .ThenBy(pair => pair.Key, StringComparer.Ordinal)
                .First().Key;
            _document.Sessions.Remove(victim);
        }
    }

    private static string SessionId(SessionRouteKey session)
    {
        var material = Encoding.UTF8.GetBytes(session.InstanceKey + "\0" + session.RoutingKey);
        return Convert.ToHexString(SHA256.HashData(material)).ToLowerInvariant();
    }

    private static PreferenceDocument Clone(PreferenceDocument value)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonDefaults.Options);
        return JsonSerializer.Deserialize<PreferenceDocument>(bytes, JsonDefaults.Options)
            ?? new PreferenceDocument();
    }

    private sealed class PreferenceDocument
    {
        public int Version { get; set; } = FormatVersion;
        public long NextRevision { get; set; }
        public Dictionary<string, SessionPreferenceState> Sessions { get; set; } =
            new(StringComparer.Ordinal);
    }

    private sealed class SessionPreferenceState
    {
        public Dictionary<string, AdapterPreferenceState> Adapters { get; set; } =
            new(StringComparer.Ordinal);
        public long UpdatedAtMs { get; set; }
    }

    private sealed class AdapterPreferenceState
    {
        public string OpenEventId { get; set; } = string.Empty;
        public long OpenedAtMs { get; set; }
        public long Revision { get; set; }

        public OwnerPreference ToPreference(string adapterKey) => new()
        {
            AdapterKey = adapterKey,
            OpenEventId = OpenEventId,
            OpenedAtMs = OpenedAtMs,
            Revision = Revision,
        };
    }
}
