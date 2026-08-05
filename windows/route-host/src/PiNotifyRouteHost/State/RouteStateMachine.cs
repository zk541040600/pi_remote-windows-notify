using System.Diagnostics;
using System.Security.Cryptography;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.State;

/// <summary>
/// Pure in-memory routing state: live adapters/owners, immutable notification snapshots,
/// requestId/nonce replay protection. Fail-closed: zero owners → miss, multiple → ambiguous.
/// </summary>
public sealed class RouteStateMachine
{
    private readonly IClock _clock;
    private readonly IRouteBindingStore _bindings;
    private readonly object _gate = new();
    private readonly Dictionary<string, LiveAdapter> _adapters = new(StringComparer.Ordinal);
    private readonly Dictionary<string, AdapterGenerationFence> _adapterGenerationFences =
        new(StringComparer.Ordinal);
    private readonly Dictionary<string, LiveOwner> _ownersByKey = new(StringComparer.Ordinal);
    private readonly Dictionary<SessionRouteKey, HashSet<string>> _ownersBySession = new();
    private readonly Dictionary<string, NotificationSnapshot> _snapshotsByNotification = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotificationSnapshot> _snapshotsById = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotificationRecoveryTicket> _recoveriesByNotification = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotificationRecoveryTicket> _recoveriesById = new(StringComparer.Ordinal);
    private readonly Dictionary<string, RecoveryTombstone> _recoveryTombstones = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ReplayEntry> _replay = new(StringComparer.Ordinal);
    /// <summary>activationRequestId -> pending/completed external activation.</summary>
    private readonly Dictionary<string, PendingActivation> _activations = new(StringComparer.Ordinal);
    /// <summary>adapterKey -> FIFO queue of undelivered activationRequestIds.</summary>
    private readonly Dictionary<string, Queue<string>> _pendingByAdapter = new(StringComparer.Ordinal);
    private readonly string _daemonId;
    private long _lastObservedUtcMs;

    public RouteStateMachine(
        IClock? clock = null,
        string? daemonId = null,
        IRouteBindingStore? bindings = null)
    {
        _clock = clock ?? new SystemClock();
        _daemonId = daemonId ?? Guid.NewGuid().ToString("N");
        _bindings = bindings ?? new MemoryRouteBindingStore();
        _lastObservedUtcMs = _clock.UtcNowMs;
    }

    public string DaemonId => _daemonId;

    public int LiveAdapterCount
    {
        get { lock (_gate) { ObserveNowAndSweep_NoLock(); return _adapters.Count; } }
    }

    public int LiveOwnerCount
    {
        get { lock (_gate) { ObserveNowAndSweep_NoLock(); return _ownersByKey.Count; } }
    }

    public int SnapshotCount
    {
        get { lock (_gate) { ObserveNowAndSweep_NoLock(); return _snapshotsById.Count; } }
    }

    public RouteResponse Handle(RouteMessage msg)
    {
        var started = Stopwatch.GetTimestamp();

        lock (_gate)
        {
            var clockError = ObserveRequestNow_NoLock(
                msg.RequestId,
                out var now);
            if (clockError is not null)
            {
                return clockError;
            }
            var envelopeError = MessageValidator.ValidateEnvelope(
                msg,
                now,
                ProtocolConstants.MaxMessageBytes);
            if (envelopeError is not null)
            {
                return envelopeError;
            }

            // Replay protection: identical requestId returns cached response (idempotent).
            var replay = GetRequestReplay_NoLock(msg, now, markSuccessfulReplay: true);
            if (replay is not null)
            {
                return replay;
            }

            var nonceReplay = GetNonceReplay_NoLock(
                msg,
                now,
                markSuccessfulReplay: true);
            if (nonceReplay is not null)
            {
                return nonceReplay;
            }

            RouteResponse response = msg.Type switch
            {
                MessageTypes.Health or MessageTypes.Ping => HandleHealth_NoLock(msg, now),
                MessageTypes.RegisterAdapter => HandleRegisterAdapter_NoLock(msg, now),
                MessageTypes.UnregisterAdapter => HandleUnregisterAdapter_NoLock(msg, now),
                MessageTypes.RegisterOpenIntent => HandleRegisterOpenIntent_NoLock(msg, now),
                MessageTypes.RegisterOwner => HandleRegisterOwner_NoLock(msg, now),
                MessageTypes.UnregisterOwner => HandleUnregisterOwner_NoLock(msg, now),
                MessageTypes.Heartbeat => HandleHeartbeat_NoLock(msg, now),
                MessageTypes.Freeze => HandleFreeze_NoLock(msg, now),
                MessageTypes.ResolveRecovery => HandleResolveRecovery_NoLock(msg, now),
                // Activate is normally dispatched via RouteDispatcher (enqueue/in-process).
                // Direct Handle path still enqueues for external adapters for consistency.
                MessageTypes.Activate => HandleActivateEnqueue_NoLock(msg, now),
                MessageTypes.ActivateResult => HandleActivateResult_NoLock(msg, now),
                MessageTypes.PollActivation => HandlePollActivation_NoLock(msg, now),
                MessageTypes.ActivationStatus => HandleActivationStatus_NoLock(msg, now),
                _ => RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.UnknownType),
            };

            response.ElapsedMs = (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            return Remember_NoLock(msg, response, now);
        }
    }

    /// <summary>
    /// Complete an activate after the adapter has been invoked (in-process mock path).
    /// Revalidates snapshot + owner lease; snapshot is never retargeted.
    /// </summary>
    public RouteResponse CompleteActivate(string requestId, string notificationId, string snapshotId, AdapterActivateResult adapterResult)
    {
        lock (_gate)
        {
            var clockError = ObserveRequestNow_NoLock(
                requestId,
                out var now);
            if (clockError is not null)
            {
                return clockError;
            }

            if (!_snapshotsById.TryGetValue(snapshotId, out var snap) ||
                !string.Equals(snap.NotificationId, notificationId, StringComparison.Ordinal))
            {
                return RouteResponse.Reject(requestId, RouteResults.Stale, RejectReasons.SnapshotUnknown);
            }

            if (snap.ExpiresAtMs < now)
            {
                return RouteResponse.Reject(requestId, RouteResults.Stale, RejectReasons.Expired);
            }

            if (!SnapshotMatchesCurrentBinding_NoLock(snap))
            {
                snap.LastActivateResult = RouteResults.Stale;
                snap.LastActivateReason = RejectReasons.OwnerChanged;
                return SnapshotBindingChangedResponse(requestId, snap);
            }

            // Revalidate live owner still matches frozen page/owner/adapter/routing.
            if (!_ownersByKey.TryGetValue(snap.OwnerKey, out var owner) ||
                owner.LeaseExpiresAtMs < now ||
                !string.Equals(owner.PageKey, snap.PageKey, StringComparison.Ordinal) ||
                !string.Equals(owner.AdapterKey, snap.AdapterKey, StringComparison.Ordinal) ||
                !string.Equals(
                    owner.AdapterGeneration,
                    snap.AdapterGeneration,
                    StringComparison.Ordinal) ||
                !string.Equals(owner.InstanceKey, snap.InstanceKey, StringComparison.Ordinal) ||
                !string.Equals(owner.RoutingKey, snap.RoutingKey, StringComparison.Ordinal) ||
                (snap.PageFingerprint is not null &&
                 owner.PageFingerprint is not null &&
                 !string.Equals(owner.PageFingerprint, snap.PageFingerprint, StringComparison.Ordinal)))
            {
                snap.LastActivateResult = RouteResults.Stale;
                snap.LastActivateReason = RejectReasons.OwnerChanged;
                return new RouteResponse
                {
                    RequestId = requestId,
                    Result = RouteResults.Stale,
                    Reason = RejectReasons.OwnerChanged,
                    SnapshotId = snap.SnapshotId,
                    ActivationRequestId = snap.ActivationRequestId,
                    RoutingFingerprint = RoutingKey.Fingerprint(snap.RoutingKey),
                    InstanceFingerprint = RoutingKey.FingerprintInstance(snap.InstanceKey),
                    OwnerFingerprint = SafeLog.OwnerFp(snap.OwnerKey),
                    AdapterKind = snap.AdapterKind,
                };
            }

            if (!_adapters.TryGetValue(snap.AdapterKey, out var adapter) ||
                adapter.LeaseExpiresAtMs < now ||
                !string.Equals(
                    adapter.AdapterGeneration,
                    snap.AdapterGeneration,
                    StringComparison.Ordinal))
            {
                snap.LastActivateResult = RouteResults.AdapterUnavailable;
                snap.LastActivateReason = RejectReasons.LeaseExpired;
                return new RouteResponse
                {
                    RequestId = requestId,
                    Result = RouteResults.AdapterUnavailable,
                    Reason = RejectReasons.LeaseExpired,
                    SnapshotId = snap.SnapshotId,
                    ActivationRequestId = snap.ActivationRequestId,
                };
            }

            snap.LastActivateResult = adapterResult.Result;
            snap.LastActivateReason = adapterResult.Reason;
            snap.ActivationRequestId ??= requestId;

            return new RouteResponse
            {
                RequestId = requestId,
                Result = adapterResult.Result,
                Reason = adapterResult.Reason,
                SnapshotId = snap.SnapshotId,
                ActivationRequestId = snap.ActivationRequestId,
                AdapterKind = snap.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(snap.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(snap.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(snap.InstanceKey),
                ElapsedMs = adapterResult.ElapsedMs,
            };
        }
    }

    /// <summary>
    /// Resolve activate target for dispatch. Returns null response when ready to dispatch.
    /// Does not mutate snapshot owner. Caller must invoke adapter then CompleteActivate.
    /// </summary>
    public (RouteResponse? Early, NotificationSnapshot? Snapshot, LiveAdapter? Adapter) BeginActivate(RouteMessage msg)
    {
        lock (_gate)
        {
            var clockError = ObserveRequestNow_NoLock(
                msg.RequestId,
                out var now);
            if (clockError is not null)
            {
                return (clockError, null, null);
            }

            var envelopeError = MessageValidator.ValidateEnvelope(msg, now, ProtocolConstants.MaxMessageBytes);
            if (envelopeError is not null)
            {
                return (envelopeError, null, null);
            }

            var replay = GetRequestReplay_NoLock(msg, now, markSuccessfulReplay: false);
            if (replay is not null)
            {
                return (replay, null, null);
            }

            var nonceReplay = GetNonceReplay_NoLock(
                msg,
                now,
                markSuccessfulReplay: false);
            if (nonceReplay is not null)
            {
                return (nonceReplay, null, null);
            }

            var (early, snap, adapter) = BeginActivateUnlocked(msg, now);
            if (early is not null)
            {
                return (Remember_NoLock(msg, early, now), null, null);
            }

            // Reserve the request identity before an in-process activator runs
            // outside the state lock. An exact concurrent retry observes this
            // pending replay instead of invoking the foreground side effect twice.
            Remember_NoLock(
                msg,
                new RouteResponse
                {
                    RequestId = msg.RequestId,
                    Result = RouteResults.Pending,
                    Reason = RejectReasons.Replay,
                    SnapshotId = snap!.SnapshotId,
                    ActivationRequestId = msg.RequestId,
                    AdapterKind = adapter!.AdapterKind,
                },
                now);
            return (null, snap, adapter);
        }
    }

    public RouteResponse RememberActivateResponse(RouteMessage msg, RouteResponse response)
    {
        lock (_gate)
        {
            var clockError = ObserveRequestNow_NoLock(
                msg.RequestId,
                out var now);
            if (clockError is not null)
            {
                return clockError;
            }
            return Remember_NoLock(msg, response, now);
        }
    }

    public LiveAdapter? GetAdapter(string adapterKey)
    {
        lock (_gate)
        {
            ObserveNowAndSweep_NoLock();
            return _adapters.TryGetValue(adapterKey, out var a) ? a : null;
        }
    }

    public NotificationSnapshot? GetSnapshot(string snapshotId)
    {
        lock (_gate)
        {
            ObserveNowAndSweep_NoLock();
            return _snapshotsById.TryGetValue(snapshotId, out var s) ? s : null;
        }
    }

    public IReadOnlyList<LiveOwner> ListOwners(string instanceKey, string routingKey)
    {
        lock (_gate)
        {
            ObserveNowAndSweep_NoLock();
            var key = new SessionRouteKey(instanceKey, routingKey);
            if (!_ownersBySession.TryGetValue(key, out var set))
            {
                return Array.Empty<LiveOwner>();
            }

            return set.Select(k => _ownersByKey[k]).ToList();
        }
    }

    /// <summary>Simulate daemon restart: drop all runtime handles; replay/snapshots/activations cleared.</summary>
    public void ResetForRestart()
    {
        lock (_gate)
        {
            ClearRuntimeState_NoLock();
            _adapterGenerationFences.Clear();
            _lastObservedUtcMs = _clock.UtcNowMs;
        }
    }

    public PendingActivation? GetActivation(string activationRequestId)
    {
        lock (_gate)
        {
            ObserveNowAndSweep_NoLock();
            return _activations.TryGetValue(activationRequestId, out var a) ? a : null;
        }
    }

    public int PendingActivationCount
    {
        get { lock (_gate) { ObserveNowAndSweep_NoLock(); return _activations.Count(a => !a.Value.Completed); } }
    }

    private RouteResponse HandleHealth_NoLock(RouteMessage msg, long now)
    {
        var response = new RouteResponse
        {
            RequestId = msg.RequestId,
            Result = RouteResults.Ok,
            DaemonId = _daemonId,
            LiveAdapters = _adapters.Count,
            LiveOwners = _ownersByKey.Count,
            Snapshots = _snapshotsById.Count,
        };

        // A unique owner may expose only irreversible fingerprints for installation diagnostics.
        // Never return the routing key, instance key, raw session, page key, or full URL.
        if (_ownersByKey.Count == 1)
        {
            var owner = _ownersByKey.Values.Single();
            if (_adapters.TryGetValue(owner.AdapterKey, out var adapter))
            {
                response.AdapterKind = adapter.AdapterKind;
            }
            response.OwnerFingerprint = SafeLog.OwnerFp(owner.OwnerKey);
            response.RoutingFingerprint = RoutingKey.Fingerprint(owner.RoutingKey);
            response.InstanceFingerprint = RoutingKey.FingerprintInstance(owner.InstanceKey);
        }

        return response;
    }

    private RouteResponse HandleRegisterAdapter_NoLock(RouteMessage msg, long now)
    {
        var err = MessageValidator.ValidateRegisterAdapter(msg);
        if (err is not null)
        {
            return err;
        }

        var candidateIdentity = new AdapterBindingIdentity
        {
            AdapterKind = msg.AdapterKind!,
            BrowserKind = msg.BrowserKind!,
            ProfileKey = msg.ProfileKey!,
        };
        if (!_bindings.IsAdapterIdentityCompatible(
                msg.AdapterKey!,
                candidateIdentity))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (_adapterGenerationFences.TryGetValue(msg.AdapterKey!, out var fence))
        {
            if (!RouteBindingStoreLogic.IdentityMatches(fence.Identity, candidateIdentity))
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.InvalidField);
            }

            if (msg.AdapterStartedAtMs!.Value < fence.AdapterStartedAtMs ||
                (msg.AdapterStartedAtMs.Value == fence.AdapterStartedAtMs &&
                 !string.Equals(
                     msg.AdapterGeneration,
                     fence.AdapterGeneration,
                     StringComparison.Ordinal)))
            {
                return RejectAdapterGeneration_NoLock(msg.RequestId);
            }
        }
        else if (_adapterGenerationFences.Count >=
                 ProtocolConstants.MaxAdapterGenerationFences)
        {
            // Never evict a generation fence: doing so would allow a delayed
            // superseded process to reclaim that adapter key. New keys fail
            // closed until the next daemon epoch instead.
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.Capacity);
        }

        if (!_adapters.ContainsKey(msg.AdapterKey!) && _adapters.Count >= ProtocolConstants.MaxAdapters)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
        }

        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;
        if (_adapters.TryGetValue(msg.AdapterKey!, out var existing))
        {
            if (!AdapterIdentityMatches(existing, msg))
            {
                // adapterKey is the durable first-binding identity. Reusing it for another
                // browser/profile/surface would silently transfer or merge session ownership.
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.InvalidField);
            }

            if (string.Equals(
                    existing.AdapterGeneration,
                    msg.AdapterGeneration,
                    StringComparison.Ordinal))
            {
                if (existing.AdapterStartedAtMs != msg.AdapterStartedAtMs)
                {
                    return RouteResponse.Reject(
                        msg.RequestId,
                        RouteResults.Rejected,
                        RejectReasons.InvalidField);
                }

                // A lost acknowledgement can cause the same runtime to retry
                // register-adapter with a fresh request ID. This is a lease
                // refresh, not a new generation barrier.
                existing.LeaseExpiresAtMs = now + ttl;
                existing.LastHeartbeatMs = now;
                RememberAdapterGeneration_NoLock(msg, candidateIdentity);
                return RouteResponse.Ok(msg.RequestId);
            }

            if (msg.AdapterStartedAtMs!.Value <= existing.AdapterStartedAtMs)
            {
                // A delayed frame from an older process must never take the
                // adapter back from the newer live generation.
                return RejectAdapterGeneration_NoLock(msg.RequestId);
            }

            // A genuinely newer process/connection generation is the barrier.
            // It rebuilds owner/page keys, so retaining the prior generation
            // would make restored sessions ambiguous until lease expiry.
            var activator = existing.Activator;
            ClearAdapterRuntimeState_NoLock(msg.AdapterKey!, now);
            _adapters[msg.AdapterKey!] = new LiveAdapter
            {
                AdapterKey = msg.AdapterKey!,
                AdapterGeneration = msg.AdapterGeneration!,
                AdapterStartedAtMs = msg.AdapterStartedAtMs.Value,
                AdapterKind = msg.AdapterKind!,
                BrowserKind = msg.BrowserKind!,
                ProfileKey = msg.ProfileKey!,
                LeaseExpiresAtMs = now + ttl,
                RegisteredAtMs = now,
                LastHeartbeatMs = now,
                // Preserve the optional in-process test activator; production
                // adapters republish current owners immediately.
                Activator = activator,
            };
            RememberAdapterGeneration_NoLock(msg, candidateIdentity);
            return RouteResponse.Ok(msg.RequestId);
        }

        _adapters[msg.AdapterKey!] = new LiveAdapter
        {
            AdapterKey = msg.AdapterKey!,
            AdapterGeneration = msg.AdapterGeneration!,
            AdapterStartedAtMs = msg.AdapterStartedAtMs!.Value,
            AdapterKind = msg.AdapterKind!,
            BrowserKind = msg.BrowserKind!,
            ProfileKey = msg.ProfileKey!,
            LeaseExpiresAtMs = now + ttl,
            RegisteredAtMs = now,
            LastHeartbeatMs = now,
        };
        RememberAdapterGeneration_NoLock(msg, candidateIdentity);

        SafeLog.Info("adapter-register",
            ("adapterKind", msg.AdapterKind),
            ("adapterFp", SafeLog.OwnerFp(msg.AdapterKey)));

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleUnregisterAdapter_NoLock(RouteMessage msg, long now)
    {
        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter))
        {
            // Repeating an already completed unregister is harmless.
            return RouteResponse.Ok(msg.RequestId);
        }

        if (!AdapterGenerationMatches(adapter, msg))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        _adapters.Remove(msg.AdapterKey!);
        ClearAdapterRuntimeState_NoLock(msg.AdapterKey!, now);
        return RouteResponse.Ok(msg.RequestId);
    }

    private void ClearAdapterRuntimeState_NoLock(string adapterKey, long now)
    {
        var toRemove = _ownersByKey.Values
            .Where(owner => string.Equals(
                owner.AdapterKey,
                adapterKey,
                StringComparison.Ordinal))
            .Select(owner => owner.OwnerKey)
            .ToList();
        foreach (var ownerKey in toRemove)
        {
            RemoveOwner_NoLock(ownerKey);
        }

        // Commands handed to the old process generation must never be claimed
        // or completed by its replacement.
        foreach (var pending in _activations.Values
                     .Where(activation =>
                         string.Equals(
                             activation.AdapterKey,
                             adapterKey,
                             StringComparison.Ordinal) &&
                         !activation.Completed)
                     .ToList())
        {
            CompleteActivation_NoLock(
                pending,
                RouteResults.AdapterUnavailable,
                RejectReasons.AdapterUnknown,
                null,
                now);
        }

        _pendingByAdapter.Remove(adapterKey);
    }

    private RouteResponse HandleRegisterOpenIntent_NoLock(
        RouteMessage msg,
        long now)
    {
        var err = MessageValidator.ValidateRegisterOpenIntent(msg);
        if (err is not null)
        {
            return err;
        }

        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter) ||
            adapter.LeaseExpiresAtMs < now)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.AdapterUnavailable,
                RejectReasons.AdapterUnknown);
        }

        if (!AdapterGenerationMatches(adapter, msg))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        if (!AdapterIdentityMatches(adapter, msg))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        var bindingError = ValidateAndBindExplicitOpen_NoLock(
            msg,
            adapter,
            new SessionRouteKey(msg.InstanceKey!, msg.RoutingKey!),
            now,
            bindExplicitOpen: true);
        return bindingError ?? RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleRegisterOwner_NoLock(RouteMessage msg, long now)
    {
        var err = MessageValidator.ValidateRegisterOwner(msg);
        if (err is not null)
        {
            return err;
        }

        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter) ||
            adapter.LeaseExpiresAtMs < now)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.AdapterUnavailable, RejectReasons.AdapterUnknown);
        }

        if (!AdapterGenerationMatches(adapter, msg))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        if (!AdapterIdentityMatches(adapter, msg))
        {
            // Real Chrome/Desktop publications repeat adapter identity. This closes the
            // owner path after a colliding adapter registration was rejected.
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        _ownersByKey.TryGetValue(msg.OwnerKey!, out var existing);
        if (existing is not null &&
            (!string.Equals(existing.AdapterKey, msg.AdapterKey, StringComparison.Ordinal) ||
             !string.Equals(
                 existing.AdapterGeneration,
                 msg.AdapterGeneration,
                 StringComparison.Ordinal)))
        {
            // ownerKey is the immutable child identity captured by notification snapshots.
            // Reparenting it would invalidate frozen targets and could strand the durable
            // adapter binding. Reject before any binding-store mutation.
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.OwnerChanged);
        }

        LiveOwner? predecessor = null;
        if (msg.ReplacesOwnerKey is not null &&
            _ownersByKey.TryGetValue(msg.ReplacesOwnerKey, out predecessor) &&
            (!string.Equals(
                 predecessor.AdapterKey,
                 msg.AdapterKey,
                 StringComparison.Ordinal) ||
             !string.Equals(
                 predecessor.AdapterGeneration,
                 msg.AdapterGeneration,
                 StringComparison.Ordinal)))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.OwnerChanged);
        }

        // Capacity is an admission decision, so it must happen before durable
        // first-opener binding is mutated. A rejected owner must never create
        // or correct a phantom session binding.
        var projectedOwnerCount = _ownersByKey.Count +
            (existing is null ? 1 : 0) -
            (predecessor is null ? 0 : 1);
        if (projectedOwnerCount > ProtocolConstants.MaxOwners)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
        }

        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;
        var sessionKey = new SessionRouteKey(msg.InstanceKey!, msg.RoutingKey!);
        var bindingError = ValidateAndBindExplicitOpen_NoLock(
            msg,
            adapter,
            sessionKey,
            now,
            bindExplicitOpen: string.Equals(
                msg.OwnerEvent,
                OwnerEvents.ExplicitOpen,
                StringComparison.Ordinal));
        if (bindingError is not null)
        {
            return bindingError;
        }

        if (predecessor is not null)
        {
            RemoveOwner_NoLock(predecessor.OwnerKey);
        }

        if (existing is not null)
        {
            // Owner re-register: if session identity changes, move between session buckets.
            if (!string.Equals(existing.InstanceKey, msg.InstanceKey, StringComparison.Ordinal) ||
                !string.Equals(existing.RoutingKey, msg.RoutingKey, StringComparison.Ordinal))
            {
                RemoveOwnerFromSession_NoLock(existing);
                existing = new LiveOwner
                {
                    OwnerKey = msg.OwnerKey!,
                    AdapterKey = msg.AdapterKey!,
                    AdapterGeneration = msg.AdapterGeneration!,
                    PageKey = msg.PageKey!,
                    InstanceKey = msg.InstanceKey!,
                    RoutingKey = msg.RoutingKey!,
                    PageFingerprint = msg.PageFingerprint,
                    BrowserKind = msg.BrowserKind!,
                    ProfileKey = msg.ProfileKey!,
                    LeaseExpiresAtMs = now + ttl,
                    RegisteredAtMs = now,
                    LastHeartbeatMs = now,
                };
                _ownersByKey[msg.OwnerKey!] = existing;
                AddOwnerToSession_NoLock(existing);
            }
            else
            {
                // Same session: refresh lease and page identity (page navigated within session).
                if (!string.Equals(existing.PageKey, msg.PageKey, StringComparison.Ordinal))
                {
                    existing = new LiveOwner
                    {
                        OwnerKey = msg.OwnerKey!,
                        AdapterKey = msg.AdapterKey!,
                        AdapterGeneration = msg.AdapterGeneration!,
                        PageKey = msg.PageKey!,
                        InstanceKey = msg.InstanceKey!,
                        RoutingKey = msg.RoutingKey!,
                        PageFingerprint = msg.PageFingerprint,
                        BrowserKind = msg.BrowserKind!,
                        ProfileKey = msg.ProfileKey!,
                        LeaseExpiresAtMs = now + ttl,
                        RegisteredAtMs = existing.RegisteredAtMs,
                        LastHeartbeatMs = now,
                    };
                    _ownersByKey[msg.OwnerKey!] = existing;
                }
                else
                {
                    existing.LeaseExpiresAtMs = now + ttl;
                    existing.LastHeartbeatMs = now;
                    existing.PageFingerprint = msg.PageFingerprint ?? existing.PageFingerprint;
                }
            }

            return RouteResponse.Ok(msg.RequestId);
        }

        var owner = new LiveOwner
        {
            OwnerKey = msg.OwnerKey!,
            AdapterKey = msg.AdapterKey!,
            AdapterGeneration = msg.AdapterGeneration!,
            PageKey = msg.PageKey!,
            InstanceKey = msg.InstanceKey!,
            RoutingKey = msg.RoutingKey!,
            PageFingerprint = msg.PageFingerprint,
            BrowserKind = msg.BrowserKind!,
            ProfileKey = msg.ProfileKey!,
            LeaseExpiresAtMs = now + ttl,
            RegisteredAtMs = now,
            LastHeartbeatMs = now,
        };

        _ownersByKey[owner.OwnerKey] = owner;
        AddOwnerToSession_NoLock(owner);

        SafeLog.Info("owner-register",
            ("adapterKind", adapter.AdapterKind),
            ("routeFp", RoutingKey.Fingerprint(owner.RoutingKey)),
            ("instanceFp", RoutingKey.FingerprintInstance(owner.InstanceKey)),
            ("ownerFp", SafeLog.OwnerFp(owner.OwnerKey)),
            ("candidates", CountLiveOwners_NoLock(sessionKey, now)));

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse? ValidateAndBindExplicitOpen_NoLock(
        RouteMessage msg,
        LiveAdapter adapter,
        SessionRouteKey sessionKey,
        long receivedAtMs,
        bool bindExplicitOpen)
    {
        var existingBinding = _bindings.GetBinding(sessionKey);
        if (existingBinding is not null &&
            string.Equals(
                existingBinding.AdapterKey,
                msg.AdapterKey,
                StringComparison.Ordinal) &&
            !BindingIdentityMatches(existingBinding.AdapterIdentity, adapter))
        {
            // A persisted adapter key cannot be inherited by another surface
            // after restart. Reject before any binding correction.
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.InvalidField);
        }

        if (!bindExplicitOpen)
        {
            return null;
        }

        if (!_bindings.TryBindFirstExplicitOpen(
                sessionKey,
                msg.AdapterKey!,
                AdapterBindingIdentity.From(adapter),
                msg.OpenEventId!,
                msg.OpenedAtMs!.Value,
                receivedAtMs,
                out _))
        {
            // Do not acknowledge a binding mutation that cannot survive daemon
            // restart.
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.BindingPersistFailed);
        }

        return null;
    }

    private RouteResponse HandleUnregisterOwner_NoLock(RouteMessage msg, long now)
    {
        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter) ||
            adapter.LeaseExpiresAtMs < now)
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.AdapterUnavailable,
                RejectReasons.AdapterUnknown);
        }

        if (!AdapterGenerationMatches(adapter, msg))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        if (string.IsNullOrWhiteSpace(msg.OwnerKey) &&
            (string.IsNullOrWhiteSpace(msg.InstanceKey) || string.IsNullOrWhiteSpace(msg.RoutingKey)))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!string.IsNullOrWhiteSpace(msg.OwnerKey))
        {
            if (_ownersByKey.TryGetValue(msg.OwnerKey!, out var owner) &&
                (!string.Equals(
                     owner.AdapterKey,
                     msg.AdapterKey,
                     StringComparison.Ordinal) ||
                 !string.Equals(
                     owner.AdapterGeneration,
                     msg.AdapterGeneration,
                     StringComparison.Ordinal)))
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.OwnerChanged);
            }

            RemoveOwner_NoLock(msg.OwnerKey!);
            return RouteResponse.Ok(msg.RequestId);
        }

        var key = new SessionRouteKey(msg.InstanceKey!, msg.RoutingKey!);
        if (_ownersBySession.TryGetValue(key, out var set))
        {
            foreach (var ownerKey in set.ToList())
            {
                if (_ownersByKey.TryGetValue(ownerKey, out var o) &&
                    (!string.Equals(
                         o.AdapterKey,
                         msg.AdapterKey,
                         StringComparison.Ordinal) ||
                     !string.Equals(
                         o.AdapterGeneration,
                         msg.AdapterGeneration,
                         StringComparison.Ordinal)))
                {
                    continue;
                }

                RemoveOwner_NoLock(ownerKey);
            }
        }

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleHeartbeat_NoLock(RouteMessage msg, long now)
    {
        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;

        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter))
        {
            // A lease refresh is proof only when the target still exists.
            // Returning ok here strands clients after daemon restart or
            // expiry because they have no reason to re-register.
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.AdapterUnavailable,
                RejectReasons.AdapterUnknown);
        }

        if (!AdapterGenerationMatches(adapter, msg))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        if (!string.IsNullOrWhiteSpace(msg.OwnerKey))
        {
            if (!_ownersByKey.TryGetValue(msg.OwnerKey!, out var owner) ||
                (!string.IsNullOrWhiteSpace(msg.AdapterKey) &&
                 !string.Equals(
                     owner.AdapterKey,
                     msg.AdapterKey,
                     StringComparison.Ordinal)) ||
                !string.Equals(
                    owner.AdapterGeneration,
                    msg.AdapterGeneration,
                    StringComparison.Ordinal))
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Stale,
                    RejectReasons.OwnerChanged);
            }

            owner.LeaseExpiresAtMs = now + ttl;
            owner.LastHeartbeatMs = now;
        }

        // Do not refresh the adapter until every requested child proof passes.
        // A stale/foreign owner heartbeat cannot keep an otherwise dead
        // generation alive through a rejected partial mutation.
        adapter.LeaseExpiresAtMs = now + ttl;
        adapter.LastHeartbeatMs = now;

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleFreeze_NoLock(RouteMessage msg, long now)
    {
        var err = MessageValidator.ValidateFreeze(msg);
        if (err is not null)
        {
            return err;
        }

        // Idempotent freeze: same notificationId returns existing snapshot if still valid.
        if (_snapshotsByNotification.TryGetValue(msg.NotificationId!, out var existing))
        {
            if (existing.ExpiresAtMs >= now &&
                string.Equals(existing.InstanceKey, msg.InstanceKey, StringComparison.Ordinal) &&
                string.Equals(existing.RoutingKey, msg.RoutingKey, StringComparison.Ordinal) &&
                string.Equals(
                    existing.NotificationKind,
                    msg.NotificationKind,
                    StringComparison.Ordinal))
            {
                if (!SnapshotMatchesCurrentBinding_NoLock(existing))
                {
                    return SnapshotBindingChangedResponse(
                        msg.RequestId,
                        existing);
                }

                return new RouteResponse
                {
                    RequestId = msg.RequestId,
                    Result = RouteResults.Ready,
                    SnapshotId = existing.SnapshotId,
                    CandidateCount = 1,
                    AdapterKind = existing.AdapterKind,
                    OwnerFingerprint = SafeLog.OwnerFp(existing.OwnerKey),
                    RoutingFingerprint = RoutingKey.Fingerprint(existing.RoutingKey),
                    InstanceFingerprint = RoutingKey.FingerprintInstance(existing.InstanceKey),
                    Reason = RejectReasons.Replay,
                };
            }

            // Route and kind are immutable fields of a notificationId.
            if (!string.Equals(existing.InstanceKey, msg.InstanceKey, StringComparison.Ordinal) ||
                !string.Equals(existing.RoutingKey, msg.RoutingKey, StringComparison.Ordinal) ||
                !string.Equals(
                    existing.NotificationKind,
                    msg.NotificationKind,
                    StringComparison.Ordinal))
            {
                return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.SnapshotMismatch);
            }
        }

        // A recovery ticket is a pre-snapshot transaction. A duplicate freeze
        // may advance that same transaction, but can never create a second route
        // or mutate its notification fields.
        if (_recoveriesByNotification.TryGetValue(msg.NotificationId!, out var recovery))
        {
            if (!RecoveryFieldsMatch(recovery, msg))
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.SnapshotMismatch);
            }

            return ResolveRecoveryTicket_NoLock(
                msg.RequestId,
                recovery,
                now);
        }

        var instanceKey = msg.InstanceKey!;
        var routingKey = msg.RoutingKey!;
        var sessionKey = new SessionRouteKey(instanceKey, routingKey);
        var live = CollectLiveOwners_NoLock(sessionKey, now);

        if (live.Count == 0)
        {
            SafeLog.Info("freeze-miss",
                ("routeFp", RoutingKey.Fingerprint(routingKey)),
                ("instanceFp", RoutingKey.FingerprintInstance(instanceKey)),
                ("candidates", 0));
            var miss = new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Miss,
                Reason = RouteResults.OwnerUnresolved,
                CandidateCount = 0,
                RoutingFingerprint = RoutingKey.Fingerprint(routingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(instanceKey),
            };
            return BeginRecoveryOrReturn_NoLock(msg, sessionKey, miss, now);
        }

        var binding = _bindings.GetBinding(sessionKey);
        if (binding is not null)
        {
            var boundOwners = live
                .Where(owner =>
                    string.Equals(owner.AdapterKey, binding.AdapterKey, StringComparison.Ordinal) &&
                    _adapters.TryGetValue(owner.AdapterKey, out var boundAdapter) &&
                    BindingIdentityMatches(binding.AdapterIdentity, boundAdapter))
                .ToList();

            // A durable binding must never silently transfer just because its adapter is
            // temporarily offline. The bound adapter can restore its owner and resume later.
            if (boundOwners.Count == 0)
            {
                SafeLog.Info("freeze-bound-owner-unavailable",
                    ("routeFp", RoutingKey.Fingerprint(routingKey)),
                    ("instanceFp", RoutingKey.FingerprintInstance(instanceKey)),
                    ("candidates", 0));
                var unavailable = new RouteResponse
                {
                    RequestId = msg.RequestId,
                    Result = RouteResults.Miss,
                    Reason = RouteResults.OwnerUnresolved,
                    CandidateCount = 0,
                    RoutingFingerprint = RoutingKey.Fingerprint(routingKey),
                    InstanceFingerprint = RoutingKey.FingerprintInstance(instanceKey),
                };
                return BeginRecoveryOrReturn_NoLock(
                    msg,
                    sessionKey,
                    unavailable,
                    now);
            }

            live = boundOwners;
        }
        else if (live.Count == 1 && !_bindings.AllowsUnboundSingleOwnerRouting)
        {
            // A durable store cannot distinguish a genuinely never-bound route from one whose
            // metadata was missing, rejected as legacy/corrupt, or evicted at capacity. A lone
            // restore owner therefore cannot become the winner without a real explicit open.
            var unresolved = new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Miss,
                Reason = RouteResults.OwnerUnresolved,
                CandidateCount = 0,
                RoutingFingerprint = RoutingKey.Fingerprint(routingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(instanceKey),
            };
            return BeginRecoveryOrReturn_NoLock(
                msg,
                sessionKey,
                unresolved,
                now);
        }

        // One adapter may expose multiple same-session pages. An adapter binding cannot safely
        // choose a tab, so retain fail-closed ambiguity inside the bound adapter.
        if (live.Count > 1)
        {
            SafeLog.Info("freeze-ambiguous",
                ("routeFp", RoutingKey.Fingerprint(routingKey)),
                ("instanceFp", RoutingKey.FingerprintInstance(instanceKey)),
                ("candidates", live.Count));
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Ambiguous,
                CandidateCount = live.Count,
                RoutingFingerprint = RoutingKey.Fingerprint(routingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(instanceKey),
            };
        }

        var owner = live[0];
        if (!_adapters.TryGetValue(owner.AdapterKey, out var adapter) || adapter.LeaseExpiresAtMs < now)
        {
            var unavailable = new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.AdapterUnavailable,
                Reason = RejectReasons.AdapterUnknown,
                CandidateCount = 1,
            };
            return BeginRecoveryOrReturn_NoLock(
                msg,
                sessionKey,
                unavailable,
                now);
        }

        return CreateSnapshot_NoLock(
            msg.RequestId,
            msg.NotificationId!,
            msg.NotificationKind,
            owner,
            adapter,
            now);
    }

    private RouteResponse HandleResolveRecovery_NoLock(
        RouteMessage msg,
        long now)
    {
        var error = MessageValidator.ValidateResolveRecovery(msg);
        if (error is not null)
        {
            return error;
        }

        if (!_recoveriesById.TryGetValue(
                msg.RecoveryTicketId!,
                out var recovery))
        {
            if (_recoveryTombstones.TryGetValue(
                    msg.RecoveryTicketId!,
                    out var tombstone) &&
                tombstone.RetainUntilMs >= now &&
                string.Equals(
                    tombstone.NotificationId,
                    msg.NotificationId,
                    StringComparison.Ordinal))
            {
                return RecoveryTerminalResponse(
                    msg.RequestId,
                    tombstone.RecoveryTicketId,
                    tombstone.Result,
                    tombstone.Reason);
            }

            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.RecoveryUnknown,
                RecoveryTicketId = msg.RecoveryTicketId,
            };
        }

        if (!string.Equals(
                recovery.NotificationId,
                msg.NotificationId,
                StringComparison.Ordinal))
        {
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.RecoveryUnknown,
                RecoveryTicketId = msg.RecoveryTicketId,
            };
        }

        return ResolveRecoveryTicket_NoLock(
            msg.RequestId,
            recovery,
            now);
    }

    private RouteResponse BeginRecoveryOrReturn_NoLock(
        RouteMessage msg,
        SessionRouteKey session,
        RouteResponse fallback,
        long now)
    {
        if (msg.RecoveryTtlMs is null)
        {
            return fallback;
        }

        if (_recoveriesById.Count >= ProtocolConstants.MaxRecoveryTickets)
        {
            EvictOldestRecovery_NoLock(now);
            if (_recoveriesById.Count >= ProtocolConstants.MaxRecoveryTickets)
            {
                return RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.Capacity);
            }
        }

        var ttlMs = msg.RecoveryTtlMs ??
            ProtocolConstants.DefaultRecoveryTicketTtlMs;
        var recovery = new NotificationRecoveryTicket
        {
            RecoveryTicketId = Guid.NewGuid().ToString("N"),
            NotificationId = msg.NotificationId!,
            NotificationKind = msg.NotificationKind,
            InstanceKey = session.InstanceKey,
            RoutingKey = session.RoutingKey,
            CreatedAtMs = now,
            PendingExpiresAtMs = now + ttlMs,
            RetainUntilMs = now + ttlMs + ProtocolConstants.RecoveryResultTtlMs,
        };

        _recoveriesByNotification[recovery.NotificationId] = recovery;
        _recoveriesById[recovery.RecoveryTicketId] = recovery;

        SafeLog.Info(
            "freeze-recovering",
            ("routeFp", RoutingKey.Fingerprint(recovery.RoutingKey)),
            ("instanceFp", RoutingKey.FingerprintInstance(recovery.InstanceKey)),
            ("ticketFp", RoutingKey.Fingerprint(recovery.RecoveryTicketId)),
            ("binding", _bindings.GetBinding(session) is not null));

        return RecoveringResponse(
            msg.RequestId,
            recovery,
            fallback.Reason ?? RouteResults.OwnerUnresolved,
            fallback.CandidateCount ?? 0);
    }

    private RouteResponse ResolveRecoveryTicket_NoLock(
        string requestId,
        NotificationRecoveryTicket recovery,
        long now)
    {
        if (recovery.TerminalResult is not null)
        {
            return new RouteResponse
            {
                RequestId = requestId,
                Result = recovery.TerminalResult,
                Reason = recovery.TerminalReason,
                RecoveryTicketId = recovery.RecoveryTicketId,
            };
        }

        var session = new SessionRouteKey(
            recovery.InstanceKey,
            recovery.RoutingKey);
        var currentBinding = _bindings.GetBinding(session);

        if (recovery.ResolvedSnapshotId is not null)
        {
            if (_snapshotsById.TryGetValue(
                    recovery.ResolvedSnapshotId,
                    out var resolved))
            {
                if (resolved.ExpiresAtMs < now)
                {
                    return CompleteRecovery_NoLock(
                        requestId,
                        recovery,
                        RouteResults.Expired,
                        RejectReasons.RecoveryExpired,
                        now);
                }

                if (!string.Equals(
                        resolved.NotificationId,
                        recovery.NotificationId,
                        StringComparison.Ordinal) ||
                    !SnapshotMatchesCurrentBinding_NoLock(resolved))
                {
                    return CompleteRecovery_NoLock(
                        requestId,
                        recovery,
                        RouteResults.Stale,
                        RejectReasons.OwnerChanged,
                        now);
                }

                return SnapshotReadyResponse(
                    requestId,
                    resolved,
                    recovery.RecoveryTicketId,
                    RejectReasons.Replay);
            }

            return CompleteRecovery_NoLock(
                requestId,
                recovery,
                RouteResults.Expired,
                RejectReasons.RecoveryExpired,
                now);
        }

        if (now > recovery.PendingExpiresAtMs)
        {
            return CompleteRecovery_NoLock(
                requestId,
                recovery,
                RouteResults.Expired,
                RejectReasons.RecoveryExpired,
                now);
        }


        // Pending is intentionally target-free. Delayed evidence of an earlier
        // explicit open may still correct the durable first-opener binding. Each
        // resolve therefore reads the current authoritative binding; a lone
        // restore owner can never become the winner by itself.
        if (currentBinding is null)
        {
            return RecoveringResponse(
                requestId,
                recovery,
                RouteResults.OwnerUnresolved,
                0);
        }

        var live = CollectLiveOwners_NoLock(session, now)
            .Where(owner =>
                string.Equals(
                    owner.AdapterKey,
                    currentBinding.AdapterKey,
                    StringComparison.Ordinal) &&
                _adapters.TryGetValue(owner.AdapterKey, out var boundAdapter) &&
                BindingIdentityMatches(
                    currentBinding.AdapterIdentity,
                    boundAdapter))
            .ToList();

        // A transition may briefly publish zero or multiple bound pages. A
        // recovery ticket waits for a unique target until its own deadline;
        // unlike an initial ambiguous freeze, it never chooses arbitrarily.
        if (live.Count != 1)
        {
            return RecoveringResponse(
                requestId,
                recovery,
                live.Count > 1
                    ? RouteResults.Ambiguous
                    : RouteResults.OwnerUnresolved,
                live.Count);
        }

        var owner = live[0];
        if (!_adapters.TryGetValue(owner.AdapterKey, out var adapter) ||
            adapter.LeaseExpiresAtMs < now)
        {
            return RecoveringResponse(
                requestId,
                recovery,
                RejectReasons.AdapterUnknown,
                0);
        }

        var response = CreateSnapshot_NoLock(
            requestId,
            recovery.NotificationId,
            recovery.NotificationKind,
            owner,
            adapter,
            now,
            recovery.RecoveryTicketId);
        if (string.Equals(
                response.Result,
                RouteResults.Ready,
                StringComparison.Ordinal) &&
            response.SnapshotId is not null)
        {
            recovery.ResolvedSnapshotId = response.SnapshotId;
            if (_snapshotsById.TryGetValue(response.SnapshotId, out var snapshot))
            {
                recovery.RetainUntilMs = snapshot.ExpiresAtMs;
            }

            SafeLog.Info(
                "recovery-resolved",
                ("routeFp", RoutingKey.Fingerprint(recovery.RoutingKey)),
                ("instanceFp", RoutingKey.FingerprintInstance(recovery.InstanceKey)),
                ("ticketFp", RoutingKey.Fingerprint(recovery.RecoveryTicketId)),
                ("ownerFp", SafeLog.OwnerFp(owner.OwnerKey)),
                ("adapterKind", adapter.AdapterKind));
            return response;
        }

        return CompleteRecovery_NoLock(
            requestId,
            recovery,
            response.Result,
            response.Reason ?? RejectReasons.Capacity,
            now);
    }

    private RouteResponse CreateSnapshot_NoLock(
        string requestId,
        string notificationId,
        string? notificationKind,
        LiveOwner owner,
        LiveAdapter adapter,
        long now,
        string? recoveryTicketId = null)
    {
        if (_snapshotsById.Count >= ProtocolConstants.MaxSnapshots &&
            !_snapshotsByNotification.ContainsKey(notificationId))
        {
            EvictOldestSnapshot_NoLock(now);
            if (_snapshotsById.Count >= ProtocolConstants.MaxSnapshots)
            {
                return RouteResponse.Reject(
                    requestId,
                    RouteResults.Rejected,
                    RejectReasons.Capacity);
            }
        }

        var snapshot = new NotificationSnapshot
        {
            SnapshotId = Guid.NewGuid().ToString("N"),
            NotificationId = notificationId,
            NotificationKind = notificationKind,
            InstanceKey = owner.InstanceKey,
            RoutingKey = owner.RoutingKey,
            OwnerKey = owner.OwnerKey,
            AdapterKey = owner.AdapterKey,
            AdapterGeneration = owner.AdapterGeneration,
            PageKey = owner.PageKey,
            PageFingerprint = owner.PageFingerprint,
            AdapterKind = adapter.AdapterKind,
            BrowserKind = owner.BrowserKind ?? adapter.BrowserKind,
            AdapterIdentity = AdapterBindingIdentity.From(adapter),
            CreatedAtMs = now,
            ExpiresAtMs = now + ProtocolConstants.SnapshotTtlMs,
        };

        _snapshotsByNotification[snapshot.NotificationId] = snapshot;
        _snapshotsById[snapshot.SnapshotId] = snapshot;

        SafeLog.Info(
            "freeze-ready",
            ("routeFp", RoutingKey.Fingerprint(snapshot.RoutingKey)),
            ("instanceFp", RoutingKey.FingerprintInstance(snapshot.InstanceKey)),
            ("ownerFp", SafeLog.OwnerFp(snapshot.OwnerKey)),
            ("adapterKind", snapshot.AdapterKind),
            ("candidates", 1));

        return SnapshotReadyResponse(
            requestId,
            snapshot,
            recoveryTicketId);
    }

    private static RouteResponse SnapshotReadyResponse(
        string requestId,
        NotificationSnapshot snapshot,
        string? recoveryTicketId,
        string? reason = null) =>
        new()
        {
            RequestId = requestId,
            Result = RouteResults.Ready,
            Reason = reason,
            SnapshotId = snapshot.SnapshotId,
            RecoveryTicketId = recoveryTicketId,
            CandidateCount = 1,
            AdapterKind = snapshot.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(snapshot.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(snapshot.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(snapshot.InstanceKey),
        };

    private static RouteResponse RecoveringResponse(
        string requestId,
        NotificationRecoveryTicket recovery,
        string reason,
        int candidateCount) =>
        new()
        {
            RequestId = requestId,
            Result = RouteResults.Recovering,
            Reason = reason,
            RecoveryTicketId = recovery.RecoveryTicketId,
            CandidateCount = candidateCount,
            RoutingFingerprint = RoutingKey.Fingerprint(recovery.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(recovery.InstanceKey),
        };

    private static RouteResponse CompleteRecovery_NoLock(
        string requestId,
        NotificationRecoveryTicket recovery,
        string result,
        string reason,
        long now)
    {
        recovery.TerminalResult = result;
        recovery.TerminalReason = reason;
        recovery.RetainUntilMs = now + ProtocolConstants.RecoveryResultTtlMs;
        return RecoveryTerminalResponse(
            requestId,
            recovery.RecoveryTicketId,
            result,
            reason);
    }

    private static RouteResponse RecoveryTerminalResponse(
        string requestId,
        string recoveryTicketId,
        string result,
        string reason) =>
        new()
        {
            RequestId = requestId,
            Result = result,
            Reason = reason,
            RecoveryTicketId = recoveryTicketId,
        };

    private static bool RecoveryFieldsMatch(
        NotificationRecoveryTicket recovery,
        RouteMessage msg) =>
        string.Equals(
            recovery.InstanceKey,
            msg.InstanceKey,
            StringComparison.Ordinal) &&
        string.Equals(
            recovery.RoutingKey,
            msg.RoutingKey,
            StringComparison.Ordinal) &&
        string.Equals(
            recovery.NotificationKind,
            msg.NotificationKind,
            StringComparison.Ordinal);


    /// <summary>
    /// Direct Handle path for activate: validate + enqueue pending command for external poll.
    /// In-process activators still go through <see cref="RouteDispatcher.DispatchActivateAsync"/>.
    /// </summary>
    private RouteResponse HandleActivateEnqueue_NoLock(RouteMessage msg, long now)
    {
        var (early, snap, adapter) = BeginActivateUnlocked(msg, now);
        if (early is not null)
        {
            return early;
        }

        return EnqueuePendingActivation_NoLock(msg, snap!, adapter!, now);
    }

    private (RouteResponse? Early, NotificationSnapshot? Snapshot, LiveAdapter? Adapter) BeginActivateUnlocked(
        RouteMessage msg, long now)
    {
        var fieldError = MessageValidator.ValidateActivate(msg);
        if (fieldError is not null)
        {
            return (fieldError, null, null);
        }

        if (!_snapshotsById.TryGetValue(msg.SnapshotId!, out var snap) ||
            !string.Equals(snap.NotificationId, msg.NotificationId, StringComparison.Ordinal))
        {
            var r = RouteResponse.Reject(msg.RequestId, RouteResults.Stale, RejectReasons.SnapshotUnknown);
            return (r, null, null);
        }

        if (snap.ExpiresAtMs < now)
        {
            return (RouteResponse.Reject(msg.RequestId, RouteResults.Stale, RejectReasons.Expired), null, null);
        }

        // Claim identity outranks mutable live topology. Once any activation
        // owns this snapshot, lost-response retries must observe that canonical
        // operation even if its owner/page/binding rotates while it is pending
        // or after it completes. Only an unclaimed snapshot is revalidated
        // against current routing state below.
        if (snap.ActivationRequestId is not null)
        {
            return (
                ExistingSnapshotActivationResponse_NoLock(
                    msg.RequestId,
                    snap),
                null,
                null);
        }

        var (targetError, adapter) =
            ValidateSnapshotTargetForActivation_NoLock(msg, snap, now);
        if (targetError is not null)
        {
            return (targetError, null, null);
        }

        // Claim the immutable snapshot before dispatch leaves the state lock.
        // Different requestIds from duplicate popups can then only observe and
        // await this one activation; they cannot enqueue a second focus side effect.
        snap.ActivationRequestId = msg.RequestId;

        return (null, snap, adapter);
    }

    private (RouteResponse? Error, LiveAdapter? Adapter)
        ValidateSnapshotTargetForActivation_NoLock(
            RouteMessage msg,
            NotificationSnapshot snap,
            long now)
    {
        if (!SnapshotMatchesCurrentBinding_NoLock(snap))
        {
            return (SnapshotBindingChangedResponse(msg.RequestId, snap), null);
        }

        if (msg.DeadlineMs is long deadline && deadline > 0 && now > deadline)
        {
            return (
                RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Timeout,
                    RejectReasons.Expired),
                null);
        }

        if (!_ownersByKey.TryGetValue(snap.OwnerKey, out var owner) ||
            owner.LeaseExpiresAtMs < now)
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.LeaseExpired,
                SnapshotId = snap.SnapshotId,
                ActivationRequestId = snap.ActivationRequestId,
            }, null);
        }

        if (!string.Equals(owner.PageKey, snap.PageKey, StringComparison.Ordinal) ||
            !string.Equals(owner.AdapterKey, snap.AdapterKey, StringComparison.Ordinal) ||
            !string.Equals(
                owner.AdapterGeneration,
                snap.AdapterGeneration,
                StringComparison.Ordinal) ||
            !string.Equals(owner.RoutingKey, snap.RoutingKey, StringComparison.Ordinal) ||
            !string.Equals(owner.InstanceKey, snap.InstanceKey, StringComparison.Ordinal) ||
            (snap.PageFingerprint is not null &&
             owner.PageFingerprint is not null &&
             !string.Equals(
                 owner.PageFingerprint,
                 snap.PageFingerprint,
                 StringComparison.Ordinal)))
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.OwnerChanged,
                SnapshotId = snap.SnapshotId,
                ActivationRequestId = snap.ActivationRequestId,
            }, null);
        }

        if (!_adapters.TryGetValue(snap.AdapterKey, out var adapter) ||
            adapter.LeaseExpiresAtMs < now ||
            !string.Equals(
                adapter.AdapterGeneration,
                snap.AdapterGeneration,
                StringComparison.Ordinal))
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.AdapterUnavailable,
                Reason = RejectReasons.LeaseExpired,
                SnapshotId = snap.SnapshotId,
                ActivationRequestId = snap.ActivationRequestId,
            }, null);
        }

        return (null, adapter);
    }

    private RouteResponse ExistingSnapshotActivationResponse_NoLock(
        string requestId,
        NotificationSnapshot snapshot)
    {
        var activationRequestId = snapshot.ActivationRequestId!;
        if (_activations.TryGetValue(activationRequestId, out var pending))
        {
            return new RouteResponse
            {
                RequestId = requestId,
                Result = pending.Completed
                    ? pending.FinalResult ?? RouteResults.Stale
                    : RouteResults.Accepted,
                Reason = pending.Completed
                    ? pending.FinalReason ?? RejectReasons.Replay
                    : RejectReasons.PendingAdapterDelivery,
                SnapshotId = snapshot.SnapshotId,
                ActivationRequestId = activationRequestId,
                AdapterKind = snapshot.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(snapshot.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(snapshot.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(snapshot.InstanceKey),
                ElapsedMs = pending.ElapsedMs,
            };
        }

        if (snapshot.LastActivateResult is not null)
        {
            return new RouteResponse
            {
                RequestId = requestId,
                Result = snapshot.LastActivateResult,
                Reason = snapshot.LastActivateReason ?? RejectReasons.Replay,
                SnapshotId = snapshot.SnapshotId,
                ActivationRequestId = activationRequestId,
                AdapterKind = snapshot.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(snapshot.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(snapshot.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(snapshot.InstanceKey),
            };
        }

        return new RouteResponse
        {
            RequestId = requestId,
            Result = RouteResults.Pending,
            Reason = RejectReasons.Replay,
            SnapshotId = snapshot.SnapshotId,
            ActivationRequestId = activationRequestId,
            AdapterKind = snapshot.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(snapshot.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(snapshot.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(snapshot.InstanceKey),
        };
    }

    private RouteResponse HandleActivateResult_NoLock(RouteMessage msg, long now)
    {
        var activationRequestId = msg.ActivationRequestId ?? msg.RequestId;
        if (string.IsNullOrWhiteSpace(activationRequestId) || string.IsNullOrWhiteSpace(msg.Result))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!MessageValidator.IsOpaqueId(activationRequestId) ||
            ExceedsLabel(msg.Result!) ||
            !ProtocolConstants.AllowedActivateResults.Contains(msg.Result!) ||
            msg.ElapsedMs is < 0 ||
            (msg.SnapshotId is not null &&
             !MessageValidator.IsOpaqueId(msg.SnapshotId)) ||
            (msg.NotificationId is not null &&
             !MessageValidator.IsOpaqueId(msg.NotificationId)))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        if (!_activations.TryGetValue(activationRequestId, out var pending))
        {
            // Snapshot knowledge is not activation authority. Accepting an
            // orphan result would let any local adapter mutate another frozen
            // notification without the enqueue/poll correlation.
            return RouteResponse.Reject(msg.RequestId, RouteResults.Stale, RejectReasons.ActivationUnknown);
        }

        if (!string.Equals(
                pending.AdapterKey,
                msg.AdapterKey,
                StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.WrongAdapter);
        }

        if (!string.Equals(
                pending.AdapterGeneration,
                msg.AdapterGeneration,
                StringComparison.Ordinal))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        // Immutable activation correlation must be proven before target
        // revalidation or completion can mutate the pending record.
        if ((!string.IsNullOrWhiteSpace(msg.SnapshotId) &&
             !string.Equals(
                 msg.SnapshotId,
                 pending.SnapshotId,
                 StringComparison.Ordinal)) ||
            (!string.IsNullOrWhiteSpace(msg.NotificationId) &&
             !string.Equals(
                 msg.NotificationId,
                 pending.NotificationId,
                 StringComparison.Ordinal)))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.SnapshotMismatch);
        }

        if (pending.Completed)
        {
            // Idempotent: return stored final result.
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = pending.FinalResult ?? msg.Result!,
                Reason = pending.FinalReason ?? RejectReasons.Replay,
                SnapshotId = pending.SnapshotId,
                ActivationRequestId = pending.ActivationRequestId,
                AdapterKind = pending.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(pending.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(pending.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(pending.InstanceKey),
                ElapsedMs = pending.ElapsedMs ?? msg.ElapsedMs,
            };
        }

        if (pending.ExpiresAtMs < now || pending.DeadlineMs < now)
        {
            CompleteActivation_NoLock(pending, RouteResults.Timeout, RejectReasons.Expired, msg.ElapsedMs, now);
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Timeout,
                Reason = RejectReasons.Expired,
                SnapshotId = pending.SnapshotId,
                ActivationRequestId = pending.ActivationRequestId,
            };
        }

        // Revalidate snapshot + owner before accepting adapter claim.
        var revalidation = RevalidatePendingTarget_NoLock(pending, now);
        if (revalidation is not null)
        {
            CompleteActivation_NoLock(pending, revalidation.Result, revalidation.Reason, msg.ElapsedMs, now);
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = revalidation.Result,
                Reason = revalidation.Reason,
                SnapshotId = pending.SnapshotId,
                ActivationRequestId = pending.ActivationRequestId,
                AdapterKind = pending.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(pending.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(pending.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(pending.InstanceKey),
                ElapsedMs = msg.ElapsedMs,
            };
        }

        CompleteActivation_NoLock(pending, msg.Result!, msg.Reason, msg.ElapsedMs, now);

        SafeLog.Info("activate-result",
            ("result", msg.Result),
            ("adapterKind", pending.AdapterKind),
            ("routeFp", RoutingKey.Fingerprint(pending.RoutingKey)),
            ("ownerFp", SafeLog.OwnerFp(pending.OwnerKey)));

        return new RouteResponse
        {
            RequestId = msg.RequestId,
            Result = msg.Result!,
            Reason = msg.Reason,
            SnapshotId = pending.SnapshotId,
            ActivationRequestId = pending.ActivationRequestId,
            AdapterKind = pending.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(pending.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(pending.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(pending.InstanceKey),
            ElapsedMs = msg.ElapsedMs,
        };
    }

    private RouteResponse HandlePollActivation_NoLock(RouteMessage msg, long now)
    {
        if (string.IsNullOrWhiteSpace(msg.AdapterKey) || !MessageValidator.IsOpaqueId(msg.AdapterKey!))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter) ||
            adapter.LeaseExpiresAtMs < now)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.AdapterUnavailable, RejectReasons.AdapterUnknown);
        }

        if (!AdapterGenerationMatches(adapter, msg))
        {
            return RejectAdapterGeneration_NoLock(msg.RequestId);
        }

        // Refresh adapter lease on successful poll connection.
        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;
        adapter.LeaseExpiresAtMs = now + ttl;
        adapter.LastHeartbeatMs = now;

        if (!_pendingByAdapter.TryGetValue(msg.AdapterKey!, out var queue) || queue.Count == 0)
        {
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Ok,
                Reason = RejectReasons.NoPending,
                AdapterKind = adapter.AdapterKind,
            };
        }

        // Keep the head until a terminal result. Returning a poll response is
        // not proof that the adapter received it; after a bounded delivery
        // lease, re-offer the same immutable activation.
        while (queue.Count > 0)
        {
            var activationRequestId = queue.Peek();
            if (!_activations.TryGetValue(activationRequestId, out var pending))
            {
                queue.Dequeue();
                continue;
            }

            if (pending.Completed)
            {
                queue.Dequeue();
                continue;
            }

            if (pending.Delivered &&
                pending.DeliveredAtMs is long deliveredAtMs &&
                now >= deliveredAtMs &&
                now - deliveredAtMs < ProtocolConstants.ActivationDeliveryRetryMs)
            {
                return new RouteResponse
                {
                    RequestId = msg.RequestId,
                    Result = RouteResults.Ok,
                    Reason = RejectReasons.NoPending,
                    AdapterKind = adapter.AdapterKind,
                };
            }

            if (pending.ExpiresAtMs < now || pending.DeadlineMs < now)
            {
                queue.Dequeue();
                CompleteActivation_NoLock(pending, RouteResults.Timeout, RejectReasons.Expired, null, now);
                continue;
            }

            var revalidation = RevalidatePendingTarget_NoLock(pending, now);
            if (revalidation is not null)
            {
                queue.Dequeue();
                CompleteActivation_NoLock(pending, revalidation.Result, revalidation.Reason, null, now);
                continue;
            }

            // Delivery is leased, not terminal. CompleteActivation_NoLock
            // removes the queue entry after the adapter result is accepted.
            pending.Delivered = true;
            pending.DeliveredAtMs = now;
            pending.DeliveryAttempts++;

            SafeLog.Info("poll-activation-deliver",
                ("adapterKind", adapter.AdapterKind),
                ("routeFp", RoutingKey.Fingerprint(pending.RoutingKey)),
                ("ownerFp", SafeLog.OwnerFp(pending.OwnerKey)),
                ("attempt", pending.DeliveryAttempts));

            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Ready,
                Reason = null,
                ActivationRequestId = pending.ActivationRequestId,
                SnapshotId = pending.SnapshotId,
                NotificationId = pending.NotificationId,
                OwnerKey = pending.OwnerKey,
                PageKey = pending.PageKey,
                InstanceKey = pending.InstanceKey,
                RoutingKey = pending.RoutingKey,
                PageFingerprint = pending.PageFingerprint,
                DeadlineMs = pending.DeadlineMs,
                AdapterKind = pending.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(pending.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(pending.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(pending.InstanceKey),
            };
        }

        return new RouteResponse
        {
            RequestId = msg.RequestId,
            Result = RouteResults.Ok,
            Reason = RejectReasons.NoPending,
            AdapterKind = adapter.AdapterKind,
        };
    }

    private RouteResponse HandleActivationStatus_NoLock(RouteMessage msg, long now)
    {
        var activationRequestId = msg.ActivationRequestId ?? msg.NotificationId;
        if (string.IsNullOrWhiteSpace(activationRequestId) || !MessageValidator.IsOpaqueId(activationRequestId!))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!_activations.TryGetValue(activationRequestId!, out var pending))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Miss, RejectReasons.ActivationUnknown);
        }

        // Lazy timeout if still open past deadline.
        if (!pending.Completed && (pending.ExpiresAtMs < now || pending.DeadlineMs < now))
        {
            CompleteActivation_NoLock(pending, RouteResults.Timeout, RejectReasons.Expired, null, now);
        }
        else if (!pending.Completed)
        {
            var revalidation = RevalidatePendingTarget_NoLock(pending, now);
            if (revalidation is not null)
            {
                CompleteActivation_NoLock(pending, revalidation.Result, revalidation.Reason, null, now);
            }
        }

        if (pending.Completed)
        {
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = pending.FinalResult ?? RouteResults.Stale,
                Reason = pending.FinalReason,
                SnapshotId = pending.SnapshotId,
                ActivationRequestId = pending.ActivationRequestId,
                AdapterKind = pending.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(pending.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(pending.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(pending.InstanceKey),
                ElapsedMs = pending.ElapsedMs,
            };
        }

        return new RouteResponse
        {
            RequestId = msg.RequestId,
            Result = RouteResults.Pending,
            Reason = pending.Delivered ? "delivered-awaiting-result" : RejectReasons.PendingAdapterDelivery,
            SnapshotId = pending.SnapshotId,
            ActivationRequestId = pending.ActivationRequestId,
            AdapterKind = pending.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(pending.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(pending.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(pending.InstanceKey),
        };
    }

    /// <summary>
    /// Enqueue one bounded external activation command after BeginActivate validation.
    /// activationRequestId == activate requestId for idempotency with replay cache.
    /// </summary>
    public RouteResponse EnqueuePendingActivation(RouteMessage msg, NotificationSnapshot snap, LiveAdapter adapter)
    {
        lock (_gate)
        {
            var clockError = ObserveRequestNow_NoLock(
                msg.RequestId,
                out var now);
            if (clockError is not null)
            {
                return clockError;
            }
            var envelopeError = MessageValidator.ValidateEnvelope(
                msg,
                now,
                ProtocolConstants.MaxMessageBytes);
            if (envelopeError is not null)
            {
                return envelopeError;
            }

            if (!_snapshotsById.TryGetValue(msg.SnapshotId!, out var currentSnapshot) ||
                !ReferenceEquals(currentSnapshot, snap) ||
                !string.Equals(
                    currentSnapshot.NotificationId,
                    msg.NotificationId,
                    StringComparison.Ordinal) ||
                currentSnapshot.ExpiresAtMs < now)
            {
                var stale = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Stale,
                    RejectReasons.OwnerChanged);
                FinalizeSnapshotActivationFailure_NoLock(
                    snap,
                    msg.RequestId,
                    stale);
                return stale;
            }

            if (!string.Equals(
                    currentSnapshot.ActivationRequestId,
                    msg.RequestId,
                    StringComparison.Ordinal))
            {
                if (currentSnapshot.ActivationRequestId is not null)
                {
                    return ExistingSnapshotActivationResponse_NoLock(
                        msg.RequestId,
                        currentSnapshot);
                }

                var stale = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Stale,
                    RejectReasons.OwnerChanged);
                FinalizeSnapshotActivationFailure_NoLock(
                    snap,
                    msg.RequestId,
                    stale);
                return stale;
            }

            // This is the commit phase for the request that already claimed
            // the snapshot in BeginActivate. Revalidate mutable topology
            // without treating that same canonical claim as a duplicate.
            var (targetError, currentAdapter) =
                ValidateSnapshotTargetForActivation_NoLock(
                    msg,
                    currentSnapshot,
                    now);
            if (targetError is not null)
            {
                FinalizeSnapshotActivationFailure_NoLock(
                    snap,
                    msg.RequestId,
                    targetError);
                return targetError;
            }

            if (!ReferenceEquals(currentAdapter, adapter))
            {
                var stale = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Stale,
                    RejectReasons.OwnerChanged);
                FinalizeSnapshotActivationFailure_NoLock(
                    snap,
                    msg.RequestId,
                    stale);
                return stale;
            }

            return EnqueuePendingActivation_NoLock(
                msg,
                currentSnapshot!,
                currentAdapter!,
                now);
        }
    }

    private RouteResponse EnqueuePendingActivation_NoLock(
        RouteMessage msg,
        NotificationSnapshot snap,
        LiveAdapter adapter,
        long now)
    {
        // Idempotent: same activationRequestId already pending/completed.
        if (_activations.TryGetValue(msg.RequestId, out var existing))
        {
            if (existing.Completed)
            {
                return new RouteResponse
                {
                    RequestId = msg.RequestId,
                    Result = existing.FinalResult ?? RouteResults.Accepted,
                    Reason = existing.FinalReason ?? RejectReasons.Replay,
                    SnapshotId = existing.SnapshotId,
                    ActivationRequestId = existing.ActivationRequestId,
                    AdapterKind = existing.AdapterKind,
                    OwnerFingerprint = SafeLog.OwnerFp(existing.OwnerKey),
                    RoutingFingerprint = RoutingKey.Fingerprint(existing.RoutingKey),
                    InstanceFingerprint = RoutingKey.FingerprintInstance(existing.InstanceKey),
                    ElapsedMs = existing.ElapsedMs,
                };
            }

            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Accepted,
                Reason = RejectReasons.PendingAdapterDelivery,
                SnapshotId = existing.SnapshotId,
                ActivationRequestId = existing.ActivationRequestId,
                AdapterKind = existing.AdapterKind,
                OwnerFingerprint = SafeLog.OwnerFp(existing.OwnerKey),
                RoutingFingerprint = RoutingKey.Fingerprint(existing.RoutingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(existing.InstanceKey),
            };
        }

        if (_activations.Count >= ProtocolConstants.MaxPendingActivations)
        {
            EvictOldestCompletedActivation_NoLock(now);
            if (_activations.Count >= ProtocolConstants.MaxPendingActivations)
            {
                var capacity = RouteResponse.Reject(
                    msg.RequestId,
                    RouteResults.Rejected,
                    RejectReasons.Capacity);
                FinalizeSnapshotActivationFailure_NoLock(
                    snap,
                    msg.RequestId,
                    capacity);
                return capacity;
            }
        }

        if (!_pendingByAdapter.TryGetValue(snap.AdapterKey, out var queue))
        {
            queue = new Queue<string>();
            _pendingByAdapter[snap.AdapterKey] = queue;
        }

        if (queue.Count >= ProtocolConstants.MaxPendingPerAdapter)
        {
            var capacity = RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.Capacity);
            FinalizeSnapshotActivationFailure_NoLock(
                snap,
                msg.RequestId,
                capacity);
            return capacity;
        }

        var deadline = msg.DeadlineMs is long d && d > 0
            ? d
            : now + ProtocolConstants.DefaultRequestTtlMs;

        // Cap deadline to MaxRequestTtlMs from now for fail-closed bounded wait.
        var maxDeadline = now + ProtocolConstants.MaxRequestTtlMs;
        if (deadline > maxDeadline)
        {
            deadline = maxDeadline;
        }

        if (deadline <= now)
        {
            var timeout = RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Timeout,
                RejectReasons.Expired);
            FinalizeSnapshotActivationFailure_NoLock(
                snap,
                msg.RequestId,
                timeout);
            return timeout;
        }

        var pending = new PendingActivation
        {
            ActivationRequestId = msg.RequestId,
            NotificationId = snap.NotificationId,
            SnapshotId = snap.SnapshotId,
            AdapterKey = snap.AdapterKey,
            AdapterGeneration = snap.AdapterGeneration,
            OwnerKey = snap.OwnerKey,
            PageKey = snap.PageKey,
            InstanceKey = snap.InstanceKey,
            RoutingKey = snap.RoutingKey,
            PageFingerprint = snap.PageFingerprint,
            AdapterKind = adapter.AdapterKind,
            CreatedAtMs = now,
            DeadlineMs = deadline,
            ExpiresAtMs = Math.Max(deadline, now + ProtocolConstants.ActivationResultTtlMs),
            Delivered = false,
            DeliveredAtMs = null,
            DeliveryAttempts = 0,
            Completed = false,
        };

        _activations[pending.ActivationRequestId] = pending;
        queue.Enqueue(pending.ActivationRequestId);

        SafeLog.Info("activate-enqueued",
            ("adapterKind", adapter.AdapterKind),
            ("routeFp", RoutingKey.Fingerprint(snap.RoutingKey)),
            ("ownerFp", SafeLog.OwnerFp(snap.OwnerKey)));

        return new RouteResponse
        {
            RequestId = msg.RequestId,
            Result = RouteResults.Accepted,
            Reason = RejectReasons.PendingAdapterDelivery,
            SnapshotId = snap.SnapshotId,
            ActivationRequestId = pending.ActivationRequestId,
            AdapterKind = adapter.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(snap.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(snap.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(snap.InstanceKey),
        };
    }

    private static void FinalizeSnapshotActivationFailure_NoLock(
        NotificationSnapshot snapshot,
        string activationRequestId,
        RouteResponse failure)
    {
        if (!string.Equals(
                snapshot.ActivationRequestId,
                activationRequestId,
                StringComparison.Ordinal))
        {
            return;
        }

        snapshot.LastActivateResult = failure.Result;
        snapshot.LastActivateReason = failure.Reason;
    }

    private void CompleteActivation_NoLock(
        PendingActivation pending,
        string result,
        string? reason,
        long? elapsedMs,
        long now)
    {
        pending.Completed = true;
        pending.FinalResult = result;
        pending.FinalReason = reason;
        pending.ElapsedMs = elapsedMs;
        // Keep result queryable for a bounded window.
        pending.ExpiresAtMs = now + ProtocolConstants.ActivationResultTtlMs;

        if (_snapshotsById.TryGetValue(pending.SnapshotId, out var snap))
        {
            snap.LastActivateResult = result;
            snap.LastActivateReason = reason;
        }

        // Remove from adapter queue if still present.
        if (_pendingByAdapter.TryGetValue(pending.AdapterKey, out var queue))
        {
            // Rebuild without this id (queue is small/bounded).
            if (queue.Count > 0 && queue.Contains(pending.ActivationRequestId))
            {
                var kept = new Queue<string>();
                while (queue.Count > 0)
                {
                    var id = queue.Dequeue();
                    if (!string.Equals(id, pending.ActivationRequestId, StringComparison.Ordinal))
                    {
                        kept.Enqueue(id);
                    }
                }

                _pendingByAdapter[pending.AdapterKey] = kept;
            }
        }
    }

    /// <summary>
    /// Returns non-null RouteResponse fields (Result/Reason) when target is no longer valid.
    /// </summary>
    private RouteResponse? RevalidatePendingTarget_NoLock(PendingActivation pending, long now)
    {
        if (!_snapshotsById.TryGetValue(pending.SnapshotId, out var snap) ||
            !string.Equals(snap.NotificationId, pending.NotificationId, StringComparison.Ordinal))
        {
            return new RouteResponse { Result = RouteResults.Stale, Reason = RejectReasons.SnapshotUnknown };
        }

        if (snap.ExpiresAtMs < now)
        {
            return new RouteResponse { Result = RouteResults.Stale, Reason = RejectReasons.Expired };
        }

        if (!SnapshotMatchesCurrentBinding_NoLock(snap))
        {
            return SnapshotBindingChangedResponse(
                pending.ActivationRequestId,
                snap);
        }

        if (!_ownersByKey.TryGetValue(pending.OwnerKey, out var owner) || owner.LeaseExpiresAtMs < now)
        {
            return new RouteResponse { Result = RouteResults.Stale, Reason = RejectReasons.LeaseExpired };
        }

        if (!string.Equals(owner.PageKey, pending.PageKey, StringComparison.Ordinal) ||
            !string.Equals(owner.AdapterKey, pending.AdapterKey, StringComparison.Ordinal) ||
            !string.Equals(
                owner.AdapterGeneration,
                pending.AdapterGeneration,
                StringComparison.Ordinal) ||
            !string.Equals(owner.RoutingKey, pending.RoutingKey, StringComparison.Ordinal) ||
            !string.Equals(owner.InstanceKey, pending.InstanceKey, StringComparison.Ordinal))
        {
            return new RouteResponse { Result = RouteResults.Stale, Reason = RejectReasons.OwnerChanged };
        }

        if (pending.PageFingerprint is not null &&
            owner.PageFingerprint is not null &&
            !string.Equals(owner.PageFingerprint, pending.PageFingerprint, StringComparison.Ordinal))
        {
            return new RouteResponse { Result = RouteResults.Stale, Reason = RejectReasons.OwnerChanged };
        }

        if (!_adapters.TryGetValue(pending.AdapterKey, out var adapter) ||
            adapter.LeaseExpiresAtMs < now ||
            !string.Equals(
                adapter.AdapterGeneration,
                pending.AdapterGeneration,
                StringComparison.Ordinal))
        {
            return new RouteResponse { Result = RouteResults.AdapterUnavailable, Reason = RejectReasons.LeaseExpired };
        }

        return null;
    }

    private void EvictOldestCompletedActivation_NoLock(long now)
    {
        PendingActivation? victim = null;
        foreach (var candidate in _activations.Values)
        {
            if ((!candidate.Completed && candidate.ExpiresAtMs >= now) ||
                (victim is not null && candidate.CreatedAtMs >= victim.CreatedAtMs))
            {
                continue;
            }

            victim = candidate;
        }

        if (victim is not null)
        {
            _activations.Remove(victim.ActivationRequestId);
            if (_pendingByAdapter.TryGetValue(victim.AdapterKey, out var queue))
            {
                var kept = new Queue<string>(queue.Count);
                while (queue.Count > 0)
                {
                    var id = queue.Dequeue();
                    if (!string.Equals(id, victim.ActivationRequestId, StringComparison.Ordinal))
                    {
                        kept.Enqueue(id);
                    }
                }

                if (kept.Count == 0)
                {
                    _pendingByAdapter.Remove(victim.AdapterKey);
                }
                else
                {
                    _pendingByAdapter[victim.AdapterKey] = kept;
                }
            }
        }
    }

    private static bool ExceedsLabel(string value) =>
        value.Length > ProtocolConstants.MaxLabelLength;

    private static bool AdapterIdentityMatches(LiveAdapter adapter, RouteMessage msg)
        => string.Equals(
               adapter.AdapterKind,
               msg.AdapterKind,
               StringComparison.OrdinalIgnoreCase) &&
           string.Equals(
               adapter.BrowserKind,
               msg.BrowserKind,
               StringComparison.OrdinalIgnoreCase) &&
           string.Equals(
               adapter.ProfileKey,
               msg.ProfileKey,
               StringComparison.Ordinal);

    private static bool AdapterGenerationMatches(
        LiveAdapter adapter,
        RouteMessage msg) =>
        string.Equals(
            adapter.AdapterGeneration,
            msg.AdapterGeneration,
            StringComparison.Ordinal);

    private void RememberAdapterGeneration_NoLock(
        RouteMessage msg,
        AdapterBindingIdentity identity)
    {
        _adapterGenerationFences[msg.AdapterKey!] = new AdapterGenerationFence(
            msg.AdapterGeneration!,
            msg.AdapterStartedAtMs!.Value,
            identity);
    }

    private static RouteResponse RejectAdapterGeneration_NoLock(
        string requestId) =>
        RouteResponse.Reject(
            requestId,
            RouteResults.AdapterUnavailable,
            RejectReasons.AdapterGenerationChanged);

    private static bool BindingIdentityMatches(
        AdapterBindingIdentity persisted,
        LiveAdapter live) =>
        RouteBindingStoreLogic.IdentityMatches(
            persisted,
            AdapterBindingIdentity.From(live));

    private bool SnapshotMatchesCurrentBinding_NoLock(
        NotificationSnapshot snapshot)
    {
        var binding = _bindings.GetBinding(
            new SessionRouteKey(
                snapshot.InstanceKey,
                snapshot.RoutingKey));
        if (binding is null)
        {
            // Memory-only callers historically allow a single restore owner
            // without a durable binding. Production file stores fail closed.
            return _bindings.AllowsUnboundSingleOwnerRouting;
        }

        return string.Equals(
                   binding.AdapterKey,
                   snapshot.AdapterKey,
                   StringComparison.Ordinal) &&
               RouteBindingStoreLogic.IdentityMatches(
                   binding.AdapterIdentity,
                   snapshot.AdapterIdentity);
    }

    private static RouteResponse SnapshotBindingChangedResponse(
        string requestId,
        NotificationSnapshot snapshot) =>
        new()
        {
            RequestId = requestId,
            Result = RouteResults.Stale,
            Reason = RejectReasons.OwnerChanged,
            SnapshotId = snapshot.SnapshotId,
            ActivationRequestId = snapshot.ActivationRequestId,
            AdapterKind = snapshot.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(snapshot.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(
                snapshot.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(
                snapshot.InstanceKey),
        };

    private List<LiveOwner> CollectLiveOwners_NoLock(SessionRouteKey key, long now)
    {
        var list = new List<LiveOwner>();
        if (!_ownersBySession.TryGetValue(key, out var set))
        {
            return list;
        }

        foreach (var ownerKey in set.ToList())
        {
            if (!_ownersByKey.TryGetValue(ownerKey, out var owner) || owner.LeaseExpiresAtMs < now)
            {
                RemoveOwner_NoLock(ownerKey);
                continue;
            }

            if (!_adapters.TryGetValue(owner.AdapterKey, out var adapter) || adapter.LeaseExpiresAtMs < now)
            {
                // Adapter dead → owner not usable for freeze.
                continue;
            }

            list.Add(owner);
        }

        return list;
    }

    private int CountLiveOwners_NoLock(SessionRouteKey key, long now) => CollectLiveOwners_NoLock(key, now).Count;

    private void AddOwnerToSession_NoLock(LiveOwner owner)
    {
        var key = new SessionRouteKey(owner.InstanceKey, owner.RoutingKey);
        if (!_ownersBySession.TryGetValue(key, out var set))
        {
            set = new HashSet<string>(StringComparer.Ordinal);
            _ownersBySession[key] = set;
        }

        set.Add(owner.OwnerKey);
    }

    private void RemoveOwnerFromSession_NoLock(LiveOwner owner)
    {
        var key = new SessionRouteKey(owner.InstanceKey, owner.RoutingKey);
        if (_ownersBySession.TryGetValue(key, out var set))
        {
            set.Remove(owner.OwnerKey);
            if (set.Count == 0)
            {
                _ownersBySession.Remove(key);
            }
        }
    }

    private void RemoveOwner_NoLock(string ownerKey)
    {
        if (_ownersByKey.Remove(ownerKey, out var owner))
        {
            RemoveOwnerFromSession_NoLock(owner);
        }
    }

    private long ObserveNowAndSweep_NoLock()
    {
        var now = _clock.UtcNowMs;
        SweepExpired_NoLock(now);
        return now;
    }

    private RouteResponse? ObserveRequestNow_NoLock(
        string requestId,
        out long now)
    {
        now = _clock.UtcNowMs;
        if (!_bindings.TryObserveReceiveClock(now))
        {
            return RouteResponse.Reject(
                requestId,
                RouteResults.Rejected,
                RejectReasons.BindingPersistFailed);
        }

        SweepExpired_NoLock(now);
        return null;
    }

    private void SweepExpired_NoLock(long now)
    {
        if (now < _lastObservedUtcMs &&
            (decimal)_lastObservedUtcMs - now >
                ProtocolConstants.MaxFutureClockSkewMs)
        {
            // Every runtime lease/deadline is wall-clock based. Keeping those
            // absolute expiries after a material rollback could make dead
            // adapters, owners, snapshots, and replay entries appear live for
            // hours. Drop only ephemeral state; durable first-session bindings
            // remain authoritative and clients republish current owners.
            ClearRuntimeState_NoLock();
            _lastObservedUtcMs = now;
            SafeLog.Warn(
                "clock-rollback-runtime-reset",
                ("reason", "wall-clock-regressed"));
            return;
        }

        if (now > _lastObservedUtcMs)
        {
            _lastObservedUtcMs = now;
        }

        foreach (var key in _adapters.Where(kv => kv.Value.LeaseExpiresAtMs < now).Select(kv => kv.Key).ToList())
        {
            _adapters.Remove(key);
        }

        foreach (var key in _ownersByKey.Where(kv => kv.Value.LeaseExpiresAtMs < now).Select(kv => kv.Key).ToList())
        {
            RemoveOwner_NoLock(key);
        }

        // Also drop owners whose adapter vanished.
        foreach (var owner in _ownersByKey.Values.Where(o => !_adapters.ContainsKey(o.AdapterKey)).Select(o => o.OwnerKey).ToList())
        {
            RemoveOwner_NoLock(owner);
        }

        foreach (var key in _snapshotsById.Where(kv => kv.Value.ExpiresAtMs < now).Select(kv => kv.Key).ToList())
        {
            if (_snapshotsById.Remove(key, out var snap))
            {
                _snapshotsByNotification.Remove(snap.NotificationId);
            }
        }

        // Expiry is a state transition, not merely a retention deadline. Mark
        // unresolved tickets terminal before capacity checks so a burst cannot
        // reserve every recovery slot for the full result-retention window.
        foreach (var recovery in _recoveriesById.Values
                     .Where(recovery =>
                         recovery.TerminalResult is null &&
                         recovery.ResolvedSnapshotId is null &&
                         recovery.PendingExpiresAtMs < now)
                     .ToList())
        {
            recovery.TerminalResult = RouteResults.Expired;
            recovery.TerminalReason = RejectReasons.RecoveryExpired;
            recovery.RetainUntilMs = recovery.PendingExpiresAtMs +
                ProtocolConstants.RecoveryResultTtlMs;
        }

        foreach (var key in _recoveriesById
                     .Where(kv => kv.Value.RetainUntilMs < now)
                     .Select(kv => kv.Key)
                     .ToList())
        {
            RemoveRecovery_NoLock(key);
        }

        foreach (var key in _recoveryTombstones
                     .Where(kv => kv.Value.RetainUntilMs < now)
                     .Select(kv => kv.Key)
                     .ToList())
        {
            _recoveryTombstones.Remove(key);
        }

        foreach (var key in _replay.Where(kv => kv.Value.ExpiresAtMs < now).Select(kv => kv.Key).ToList())
        {
            _replay.Remove(key);
        }

        // Timeout open activations past deadline; drop fully expired completed records.
        foreach (var pending in _activations.Values.ToList())
        {
            if (!pending.Completed && (pending.DeadlineMs < now || pending.ExpiresAtMs < now))
            {
                CompleteActivation_NoLock(pending, RouteResults.Timeout, RejectReasons.Expired, null, now);
            }
            else if (pending.Completed && pending.ExpiresAtMs < now)
            {
                _activations.Remove(pending.ActivationRequestId);
            }
        }

        // Drop empty adapter queues.
        foreach (var key in _pendingByAdapter.Where(kv => kv.Value.Count == 0).Select(kv => kv.Key).ToList())
        {
            _pendingByAdapter.Remove(key);
        }
    }

    private void ClearRuntimeState_NoLock()
    {
        _adapters.Clear();
        _ownersByKey.Clear();
        _ownersBySession.Clear();
        _snapshotsByNotification.Clear();
        _snapshotsById.Clear();
        _recoveriesByNotification.Clear();
        _recoveriesById.Clear();
        _recoveryTombstones.Clear();
        _replay.Clear();
        _activations.Clear();
        _pendingByAdapter.Clear();
    }

    private sealed record AdapterGenerationFence(
        string AdapterGeneration,
        long AdapterStartedAtMs,
        AdapterBindingIdentity Identity);

    private void EvictOldestSnapshot_NoLock(long now)
    {
        var activeSnapshotIds = _activations.Values
            .Where(activation =>
                !activation.Completed &&
                activation.DeadlineMs >= now &&
                activation.ExpiresAtMs >= now)
            .Select(activation => activation.SnapshotId)
            .ToHashSet(StringComparer.Ordinal);
        var oldest = _snapshotsById.Values
            .Where(snapshot => !activeSnapshotIds.Contains(snapshot.SnapshotId))
            .OrderBy(snapshot => snapshot.CreatedAtMs)
            .ThenBy(snapshot => snapshot.SnapshotId, StringComparer.Ordinal)
            .FirstOrDefault();
        if (oldest is null)
        {
            return;
        }

        _snapshotsById.Remove(oldest.SnapshotId);
        _snapshotsByNotification.Remove(oldest.NotificationId);
    }

    private void EvictOldestRecovery_NoLock(long now)
    {
        var victim = _recoveriesById.Values
            .Where(recovery =>
                recovery.RetainUntilMs < now ||
                recovery.TerminalResult is not null ||
                recovery.ResolvedSnapshotId is not null)
            .OrderBy(recovery => recovery.CreatedAtMs)
            .ThenBy(
                recovery => recovery.RecoveryTicketId,
                StringComparer.Ordinal)
            .FirstOrDefault();
        if (victim is not null)
        {
            RemoveRecovery_NoLock(
                victim.RecoveryTicketId,
                preserveTerminalTombstone:
                    victim.TerminalResult is not null &&
                    victim.RetainUntilMs >= now);
        }
    }

    private void RemoveRecovery_NoLock(
        string recoveryTicketId,
        bool preserveTerminalTombstone = false)
    {
        if (!_recoveriesById.Remove(recoveryTicketId, out var recovery))
        {
            return;
        }

        if (preserveTerminalTombstone &&
            recovery.TerminalResult is not null &&
            recovery.TerminalReason is not null)
        {
            RememberRecoveryTombstone_NoLock(recovery);
        }

        if (_recoveriesByNotification.TryGetValue(
                recovery.NotificationId,
                out var current) &&
            ReferenceEquals(current, recovery))
        {
            _recoveriesByNotification.Remove(recovery.NotificationId);
        }
    }

    private void RememberRecoveryTombstone_NoLock(
        NotificationRecoveryTicket recovery)
    {
        while (_recoveryTombstones.Count >=
               ProtocolConstants.MaxRecoveryTombstones)
        {
            var victim = _recoveryTombstones.Values
                .OrderBy(item => item.RetainUntilMs)
                .ThenBy(item => item.RecoveryTicketId, StringComparer.Ordinal)
                .First();
            _recoveryTombstones.Remove(victim.RecoveryTicketId);
        }

        _recoveryTombstones[recovery.RecoveryTicketId] = new RecoveryTombstone(
            recovery.RecoveryTicketId,
            recovery.NotificationId,
            recovery.TerminalResult!,
            recovery.TerminalReason!,
            recovery.RetainUntilMs);
    }

    private RouteResponse Remember_NoLock(RouteMessage msg, RouteResponse response, long now)
    {
        var requestFingerprint = MessageFingerprint(msg);
        if (_replay.TryGetValue(msg.RequestId, out var existing) &&
            existing.ExpiresAtMs >= now &&
            !string.Equals(
                existing.RequestFingerprint,
                requestFingerprint,
                StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.RequestIdConflict);
        }

        var entry = new ReplayEntry
        {
            Response = CloneResponse(response),
            ExpiresAtMs = now + ProtocolConstants.ReplayCacheTtlMs,
            RequestFingerprint = requestFingerprint,
        };
        _replay[msg.RequestId] = entry;

        string? nonceKey = null;
        if (msg.Nonce is not null)
        {
            nonceKey = "nonce:" + msg.Nonce;
            _replay[nonceKey] = new ReplayEntry
            {
                Response = CloneResponse(response),
                ExpiresAtMs = now + ProtocolConstants.ReplayCacheTtlMs,
                RequestFingerprint = requestFingerprint,
            };
        }

        TrimReplayCache_NoLock(msg.RequestId, nonceKey);
        return response;
    }

    private RouteResponse? GetRequestReplay_NoLock(
        RouteMessage msg,
        long now,
        bool markSuccessfulReplay)
    {
        if (!_replay.TryGetValue(msg.RequestId, out var existing) ||
            existing.ExpiresAtMs < now)
        {
            return null;
        }

        if (!string.Equals(
                existing.RequestFingerprint,
                MessageFingerprint(msg),
                StringComparison.Ordinal))
        {
            return RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Rejected,
                RejectReasons.RequestIdConflict);
        }

        return BuildReplayResponse(existing, markSuccessfulReplay);
    }

    private RouteResponse? GetNonceReplay_NoLock(
        RouteMessage msg,
        long now,
        bool markSuccessfulReplay)
    {
        if (msg.Nonce is null)
        {
            return null;
        }

        var nonceKey = "nonce:" + msg.Nonce;
        if (!_replay.TryGetValue(nonceKey, out var existing) ||
            existing.ExpiresAtMs < now)
        {
            return null;
        }

        var requestFingerprint = MessageFingerprint(msg);
        var response = string.Equals(
            existing.RequestFingerprint,
            requestFingerprint,
            StringComparison.Ordinal)
            ? BuildReplayResponse(existing, markSuccessfulReplay)
            : RouteResponse.Reject(
                msg.RequestId,
                RouteResults.Replay,
                RejectReasons.Replay);

        // Recover/cache this request ID without replacing the authoritative
        // nonce entry. A different body under the same nonce must never poison
        // the original replay record or reach an activation side effect.
        _replay[msg.RequestId] = new ReplayEntry
        {
            Response = CloneResponse(response),
            ExpiresAtMs = existing.ExpiresAtMs,
            RequestFingerprint = requestFingerprint,
        };
        TrimReplayCache_NoLock(msg.RequestId, nonceKey);
        return response;
    }

    private static RouteResponse BuildReplayResponse(
        ReplayEntry existing,
        bool markSuccessfulReplay)
    {
        var cached = CloneResponse(existing.Response);
        if (!markSuccessfulReplay)
        {
            return cached;
        }

        cached.Reason = existing.Response.Reason ?? RejectReasons.Replay;
        if (cached.Result is RouteResults.Ready or RouteResults.Ok or
            RouteResults.SessionUrlConfirmed or RouteResults.AlreadyActive or
            RouteResults.Accepted or RouteResults.SessionConfirmed)
        {
            cached.Reason = RejectReasons.Replay;
        }
        else if (string.IsNullOrEmpty(cached.Result))
        {
            cached.Result = RouteResults.Replay;
        }

        return cached;
    }

    private static string MessageFingerprint(RouteMessage msg) =>
        Convert.ToHexString(SHA256.HashData(msg.ToUtf8Bytes()));

    private void TrimReplayCache_NoLock(string currentRequestId, string? currentNonceKey)
    {
        // A message can add two keys. Trim after both writes and protect that pair so the
        // request we just accepted cannot lose replay protection at the capacity boundary.
        while (_replay.Count > ProtocolConstants.MaxReplayEntries)
        {
            string? victim = null;
            long oldestExpiry = long.MaxValue;

            foreach (var candidate in _replay)
            {
                if (string.Equals(candidate.Key, currentRequestId, StringComparison.Ordinal) ||
                    string.Equals(candidate.Key, currentNonceKey, StringComparison.Ordinal))
                {
                    continue;
                }

                if (victim is null || candidate.Value.ExpiresAtMs < oldestExpiry)
                {
                    victim = candidate.Key;
                    oldestExpiry = candidate.Value.ExpiresAtMs;
                }
            }

            if (victim is null)
            {
                throw new InvalidOperationException("Replay cache capacity is smaller than one request/nonce pair.");
            }

            _replay.Remove(victim);
        }
    }

    private static RouteResponse CloneResponse(RouteResponse src) => new()
    {
        ProtocolVersion = src.ProtocolVersion,
        Type = src.Type,
        RequestId = src.RequestId,
        Result = src.Result,
        Reason = src.Reason,
        SnapshotId = src.SnapshotId,
        RecoveryTicketId = src.RecoveryTicketId,
        CandidateCount = src.CandidateCount,
        AdapterKind = src.AdapterKind,
        OwnerFingerprint = src.OwnerFingerprint,
        RoutingFingerprint = src.RoutingFingerprint,
        InstanceFingerprint = src.InstanceFingerprint,
        ElapsedMs = src.ElapsedMs,
        DaemonId = src.DaemonId,
        LiveAdapters = src.LiveAdapters,
        LiveOwners = src.LiveOwners,
        Snapshots = src.Snapshots,
        ActivationRequestId = src.ActivationRequestId,
        OwnerKey = src.OwnerKey,
        PageKey = src.PageKey,
        InstanceKey = src.InstanceKey,
        RoutingKey = src.RoutingKey,
        PageFingerprint = src.PageFingerprint,
        DeadlineMs = src.DeadlineMs,
        NotificationId = src.NotificationId,
    };

    private sealed class ReplayEntry
    {
        public required RouteResponse Response { get; init; }
        public long ExpiresAtMs { get; init; }
        public required string RequestFingerprint { get; init; }
    }

    private sealed record RecoveryTombstone(
        string RecoveryTicketId,
        string NotificationId,
        string Result,
        string Reason,
        long RetainUntilMs);
}
