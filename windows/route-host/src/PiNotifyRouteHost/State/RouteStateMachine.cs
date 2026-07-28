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
    private readonly object _gate = new();
    private readonly Dictionary<string, LiveAdapter> _adapters = new(StringComparer.Ordinal);
    private readonly Dictionary<string, LiveOwner> _ownersByKey = new(StringComparer.Ordinal);
    private readonly Dictionary<SessionRouteKey, HashSet<string>> _ownersBySession = new();
    private readonly Dictionary<string, NotificationSnapshot> _snapshotsByNotification = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotificationSnapshot> _snapshotsById = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ReplayEntry> _replay = new(StringComparer.Ordinal);
    /// <summary>activationRequestId -> pending/completed external activation.</summary>
    private readonly Dictionary<string, PendingActivation> _activations = new(StringComparer.Ordinal);
    /// <summary>adapterKey -> FIFO queue of undelivered activationRequestIds.</summary>
    private readonly Dictionary<string, Queue<string>> _pendingByAdapter = new(StringComparer.Ordinal);
    private readonly string _daemonId;

    public RouteStateMachine(IClock? clock = null, string? daemonId = null)
    {
        _clock = clock ?? new SystemClock();
        _daemonId = daemonId ?? Guid.NewGuid().ToString("N");
    }

    public string DaemonId => _daemonId;

    public int LiveAdapterCount
    {
        get { lock (_gate) { SweepExpired_NoLock(); return _adapters.Count; } }
    }

    public int LiveOwnerCount
    {
        get { lock (_gate) { SweepExpired_NoLock(); return _ownersByKey.Count; } }
    }

    public int SnapshotCount
    {
        get { lock (_gate) { SweepExpired_NoLock(); return _snapshotsById.Count; } }
    }

    public RouteResponse Handle(RouteMessage msg)
    {
        var now = _clock.UtcNowMs;
        var started = now;

        var envelopeError = MessageValidator.ValidateEnvelope(msg, now, ProtocolConstants.MaxMessageBytes);
        if (envelopeError is not null)
        {
            return envelopeError;
        }

        lock (_gate)
        {
            SweepExpired_NoLock();

            // Replay protection: identical requestId returns cached response (idempotent).
            if (_replay.TryGetValue(msg.RequestId, out var existing) && existing.ExpiresAtMs >= now)
            {
                var cached = CloneResponse(existing.Response);
                cached.Reason = existing.Response.Reason ?? RejectReasons.Replay;
                if (cached.Result is RouteResults.Ready or RouteResults.Ok or RouteResults.SessionUrlConfirmed
                    or RouteResults.AlreadyActive or RouteResults.Accepted or RouteResults.SessionConfirmed)
                {
                    // Keep original success result; mark reason as replay for observability.
                    cached.Reason = RejectReasons.Replay;
                }
                else if (string.IsNullOrEmpty(cached.Result) || cached.Result == RouteResults.Ok)
                {
                    cached.Result = RouteResults.Replay;
                }

                return cached;
            }

            if (msg.Nonce is not null)
            {
                var nonceKey = "nonce:" + msg.Nonce;
                if (_replay.TryGetValue(nonceKey, out var nonceHit) && nonceHit.ExpiresAtMs >= now)
                {
                    return Remember_NoLock(msg, RouteResponse.Reject(msg.RequestId, RouteResults.Replay, RejectReasons.Replay), now);
                }
            }

            RouteResponse response = msg.Type switch
            {
                MessageTypes.Health or MessageTypes.Ping => HandleHealth_NoLock(msg, now),
                MessageTypes.RegisterAdapter => HandleRegisterAdapter_NoLock(msg, now),
                MessageTypes.UnregisterAdapter => HandleUnregisterAdapter_NoLock(msg, now),
                MessageTypes.RegisterOwner => HandleRegisterOwner_NoLock(msg, now),
                MessageTypes.UnregisterOwner => HandleUnregisterOwner_NoLock(msg, now),
                MessageTypes.Heartbeat => HandleHeartbeat_NoLock(msg, now),
                MessageTypes.Freeze => HandleFreeze_NoLock(msg, now),
                // Activate is normally dispatched via RouteDispatcher (enqueue/in-process).
                // Direct Handle path still enqueues for external adapters for consistency.
                MessageTypes.Activate => HandleActivateEnqueue_NoLock(msg, now),
                MessageTypes.ActivateResult => HandleActivateResult_NoLock(msg, now),
                MessageTypes.PollActivation => HandlePollActivation_NoLock(msg, now),
                MessageTypes.ActivationStatus => HandleActivationStatus_NoLock(msg, now),
                _ => RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.UnknownType),
            };

            response.ElapsedMs = _clock.UtcNowMs - started;
            return Remember_NoLock(msg, response, now);
        }
    }

    /// <summary>
    /// Complete an activate after the adapter has been invoked (in-process mock path).
    /// Revalidates snapshot + owner lease; snapshot is never retargeted.
    /// </summary>
    public RouteResponse CompleteActivate(string requestId, string notificationId, string snapshotId, AdapterActivateResult adapterResult)
    {
        var now = _clock.UtcNowMs;
        lock (_gate)
        {
            SweepExpired_NoLock();

            if (!_snapshotsById.TryGetValue(snapshotId, out var snap) ||
                !string.Equals(snap.NotificationId, notificationId, StringComparison.Ordinal))
            {
                return RouteResponse.Reject(requestId, RouteResults.Stale, RejectReasons.SnapshotUnknown);
            }

            if (snap.ExpiresAtMs < now)
            {
                return RouteResponse.Reject(requestId, RouteResults.Stale, RejectReasons.Expired);
            }

            // Revalidate live owner still matches frozen page/owner/adapter/routing.
            if (!_ownersByKey.TryGetValue(snap.OwnerKey, out var owner) ||
                owner.LeaseExpiresAtMs < now ||
                !string.Equals(owner.PageKey, snap.PageKey, StringComparison.Ordinal) ||
                !string.Equals(owner.AdapterKey, snap.AdapterKey, StringComparison.Ordinal) ||
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
                    RoutingFingerprint = RoutingKey.Fingerprint(snap.RoutingKey),
                    InstanceFingerprint = RoutingKey.FingerprintInstance(snap.InstanceKey),
                    OwnerFingerprint = SafeLog.OwnerFp(snap.OwnerKey),
                    AdapterKind = snap.AdapterKind,
                };
            }

            if (!_adapters.TryGetValue(snap.AdapterKey, out var adapter) || adapter.LeaseExpiresAtMs < now)
            {
                snap.LastActivateResult = RouteResults.AdapterUnavailable;
                snap.LastActivateReason = RejectReasons.LeaseExpired;
                return new RouteResponse
                {
                    RequestId = requestId,
                    Result = RouteResults.AdapterUnavailable,
                    Reason = RejectReasons.LeaseExpired,
                    SnapshotId = snap.SnapshotId,
                };
            }

            snap.LastActivateResult = adapterResult.Result;
            snap.LastActivateReason = adapterResult.Reason;

            return new RouteResponse
            {
                RequestId = requestId,
                Result = adapterResult.Result,
                Reason = adapterResult.Reason,
                SnapshotId = snap.SnapshotId,
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
        var now = _clock.UtcNowMs;
        lock (_gate)
        {
            SweepExpired_NoLock();

            var envelopeError = MessageValidator.ValidateEnvelope(msg, now, ProtocolConstants.MaxMessageBytes);
            if (envelopeError is not null)
            {
                return (envelopeError, null, null);
            }

            if (_replay.TryGetValue(msg.RequestId, out var existing) && existing.ExpiresAtMs >= now)
            {
                return (CloneResponse(existing.Response), null, null);
            }

            var (early, snap, adapter) = BeginActivateUnlocked(msg, now);
            if (early is not null)
            {
                return (Remember_NoLock(msg, early, now), null, null);
            }

            return (null, snap, adapter);
        }
    }

    public void RememberActivateResponse(RouteMessage msg, RouteResponse response)
    {
        var now = _clock.UtcNowMs;
        lock (_gate)
        {
            Remember_NoLock(msg, response, now);
        }
    }

    public LiveAdapter? GetAdapter(string adapterKey)
    {
        lock (_gate)
        {
            SweepExpired_NoLock();
            return _adapters.TryGetValue(adapterKey, out var a) ? a : null;
        }
    }

    public NotificationSnapshot? GetSnapshot(string snapshotId)
    {
        lock (_gate)
        {
            SweepExpired_NoLock();
            return _snapshotsById.TryGetValue(snapshotId, out var s) ? s : null;
        }
    }

    public IReadOnlyList<LiveOwner> ListOwners(string instanceKey, string routingKey)
    {
        lock (_gate)
        {
            SweepExpired_NoLock();
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
            _adapters.Clear();
            _ownersByKey.Clear();
            _ownersBySession.Clear();
            _snapshotsByNotification.Clear();
            _snapshotsById.Clear();
            _replay.Clear();
            _activations.Clear();
            _pendingByAdapter.Clear();
        }
    }

    public PendingActivation? GetActivation(string activationRequestId)
    {
        lock (_gate)
        {
            SweepExpired_NoLock();
            return _activations.TryGetValue(activationRequestId, out var a) ? a : null;
        }
    }

    public int PendingActivationCount
    {
        get { lock (_gate) { SweepExpired_NoLock(); return _activations.Count(a => !a.Value.Completed); } }
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

        if (!_adapters.ContainsKey(msg.AdapterKey!) && _adapters.Count >= ProtocolConstants.MaxAdapters)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
        }

        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;
        if (_adapters.TryGetValue(msg.AdapterKey!, out var existing))
        {
            existing.LeaseExpiresAtMs = now + ttl;
            existing.LastHeartbeatMs = now;
            // Preserve in-process activator across heartbeats.
            return RouteResponse.Ok(msg.RequestId);
        }

        _adapters[msg.AdapterKey!] = new LiveAdapter
        {
            AdapterKey = msg.AdapterKey!,
            AdapterKind = msg.AdapterKind!,
            BrowserKind = msg.BrowserKind,
            ProfileKey = msg.ProfileKey,
            LeaseExpiresAtMs = now + ttl,
            RegisteredAtMs = now,
            LastHeartbeatMs = now,
        };

        SafeLog.Info("adapter-register",
            ("adapterKind", msg.AdapterKind),
            ("adapterFp", SafeLog.OwnerFp(msg.AdapterKey)));

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleUnregisterAdapter_NoLock(RouteMessage msg, long now)
    {
        if (string.IsNullOrWhiteSpace(msg.AdapterKey))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (_adapters.Remove(msg.AdapterKey!))
        {
            // Drop owners owned by this adapter.
            var toRemove = _ownersByKey.Values.Where(o => o.AdapterKey == msg.AdapterKey).Select(o => o.OwnerKey).ToList();
            foreach (var ownerKey in toRemove)
            {
                RemoveOwner_NoLock(ownerKey);
            }

            // Fail-closed: open activations for this adapter become adapter-unavailable.
            foreach (var pending in _activations.Values
                         .Where(a => string.Equals(a.AdapterKey, msg.AdapterKey, StringComparison.Ordinal) && !a.Completed)
                         .ToList())
            {
                CompleteActivation_NoLock(pending, RouteResults.AdapterUnavailable, RejectReasons.AdapterUnknown, null, now);
            }

            _pendingByAdapter.Remove(msg.AdapterKey!);
        }

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleRegisterOwner_NoLock(RouteMessage msg, long now)
    {
        var err = MessageValidator.ValidateRegisterOwner(msg);
        if (err is not null)
        {
            return err;
        }

        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter) || adapter.LeaseExpiresAtMs < now)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.AdapterUnavailable, RejectReasons.AdapterUnknown);
        }

        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;
        var sessionKey = new SessionRouteKey(msg.InstanceKey!, msg.RoutingKey!);

        if (_ownersByKey.TryGetValue(msg.OwnerKey!, out var existing))
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
                    PageKey = msg.PageKey!,
                    InstanceKey = msg.InstanceKey!,
                    RoutingKey = msg.RoutingKey!,
                    PageFingerprint = msg.PageFingerprint,
                    BrowserKind = msg.BrowserKind ?? adapter.BrowserKind,
                    ProfileKey = msg.ProfileKey ?? adapter.ProfileKey,
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
                        PageKey = msg.PageKey!,
                        InstanceKey = msg.InstanceKey!,
                        RoutingKey = msg.RoutingKey!,
                        PageFingerprint = msg.PageFingerprint,
                        BrowserKind = msg.BrowserKind ?? adapter.BrowserKind,
                        ProfileKey = msg.ProfileKey ?? adapter.ProfileKey,
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

        if (_ownersByKey.Count >= ProtocolConstants.MaxOwners)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
        }

        var owner = new LiveOwner
        {
            OwnerKey = msg.OwnerKey!,
            AdapterKey = msg.AdapterKey!,
            PageKey = msg.PageKey!,
            InstanceKey = msg.InstanceKey!,
            RoutingKey = msg.RoutingKey!,
            PageFingerprint = msg.PageFingerprint,
            BrowserKind = msg.BrowserKind ?? adapter.BrowserKind,
            ProfileKey = msg.ProfileKey ?? adapter.ProfileKey,
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

    private RouteResponse HandleUnregisterOwner_NoLock(RouteMessage msg, long now)
    {
        if (string.IsNullOrWhiteSpace(msg.OwnerKey) &&
            (string.IsNullOrWhiteSpace(msg.InstanceKey) || string.IsNullOrWhiteSpace(msg.RoutingKey)))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!string.IsNullOrWhiteSpace(msg.OwnerKey))
        {
            RemoveOwner_NoLock(msg.OwnerKey!);
            return RouteResponse.Ok(msg.RequestId);
        }

        var key = new SessionRouteKey(msg.InstanceKey!, msg.RoutingKey!);
        if (_ownersBySession.TryGetValue(key, out var set))
        {
            foreach (var ownerKey in set.ToList())
            {
                if (!string.IsNullOrWhiteSpace(msg.AdapterKey))
                {
                    if (_ownersByKey.TryGetValue(ownerKey, out var o) && o.AdapterKey != msg.AdapterKey)
                    {
                        continue;
                    }
                }

                RemoveOwner_NoLock(ownerKey);
            }
        }

        return RouteResponse.Ok(msg.RequestId);
    }

    private RouteResponse HandleHeartbeat_NoLock(RouteMessage msg, long now)
    {
        var ttl = msg.LeaseTtlMs ?? ProtocolConstants.DefaultLeaseTtlMs;

        if (!string.IsNullOrWhiteSpace(msg.AdapterKey) && _adapters.TryGetValue(msg.AdapterKey!, out var adapter))
        {
            adapter.LeaseExpiresAtMs = now + ttl;
            adapter.LastHeartbeatMs = now;
        }

        if (!string.IsNullOrWhiteSpace(msg.OwnerKey) && _ownersByKey.TryGetValue(msg.OwnerKey!, out var owner))
        {
            owner.LeaseExpiresAtMs = now + ttl;
            owner.LastHeartbeatMs = now;
        }

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
                string.Equals(existing.RoutingKey, msg.RoutingKey, StringComparison.Ordinal))
            {
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

            // Different route for same notificationId is rejected (immutable).
            if (!string.Equals(existing.InstanceKey, msg.InstanceKey, StringComparison.Ordinal) ||
                !string.Equals(existing.RoutingKey, msg.RoutingKey, StringComparison.Ordinal))
            {
                return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.SnapshotMismatch);
            }
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
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Miss,
                Reason = RouteResults.OwnerUnresolved,
                CandidateCount = 0,
                RoutingFingerprint = RoutingKey.Fingerprint(routingKey),
                InstanceFingerprint = RoutingKey.FingerprintInstance(instanceKey),
            };
        }

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
            return new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.AdapterUnavailable,
                Reason = RejectReasons.AdapterUnknown,
                CandidateCount = 1,
            };
        }

        if (_snapshotsById.Count >= ProtocolConstants.MaxSnapshots &&
            !_snapshotsByNotification.ContainsKey(msg.NotificationId!))
        {
            // Drop oldest expired or oldest snapshot to free capacity.
            EvictOldestSnapshot_NoLock(now);
            if (_snapshotsById.Count >= ProtocolConstants.MaxSnapshots)
            {
                return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
            }
        }

        var snapshot = new NotificationSnapshot
        {
            SnapshotId = Guid.NewGuid().ToString("N"),
            NotificationId = msg.NotificationId!,
            NotificationKind = msg.NotificationKind,
            InstanceKey = owner.InstanceKey,
            RoutingKey = owner.RoutingKey,
            OwnerKey = owner.OwnerKey,
            AdapterKey = owner.AdapterKey,
            PageKey = owner.PageKey,
            PageFingerprint = owner.PageFingerprint,
            AdapterKind = adapter.AdapterKind,
            BrowserKind = owner.BrowserKind ?? adapter.BrowserKind,
            CreatedAtMs = now,
            ExpiresAtMs = now + ProtocolConstants.SnapshotTtlMs,
        };

        _snapshotsByNotification[snapshot.NotificationId] = snapshot;
        _snapshotsById[snapshot.SnapshotId] = snapshot;

        SafeLog.Info("freeze-ready",
            ("routeFp", RoutingKey.Fingerprint(snapshot.RoutingKey)),
            ("instanceFp", RoutingKey.FingerprintInstance(snapshot.InstanceKey)),
            ("ownerFp", SafeLog.OwnerFp(snapshot.OwnerKey)),
            ("adapterKind", snapshot.AdapterKind),
            ("candidates", 1));

        return new RouteResponse
        {
            RequestId = msg.RequestId,
            Result = RouteResults.Ready,
            SnapshotId = snapshot.SnapshotId,
            CandidateCount = 1,
            AdapterKind = snapshot.AdapterKind,
            OwnerFingerprint = SafeLog.OwnerFp(snapshot.OwnerKey),
            RoutingFingerprint = RoutingKey.Fingerprint(snapshot.RoutingKey),
            InstanceFingerprint = RoutingKey.FingerprintInstance(snapshot.InstanceKey),
        };
    }

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

        if (msg.DeadlineMs is long deadline && deadline > 0 && now > deadline)
        {
            return (RouteResponse.Reject(msg.RequestId, RouteResults.Timeout, RejectReasons.Expired), null, null);
        }

        if (!_ownersByKey.TryGetValue(snap.OwnerKey, out var owner) || owner.LeaseExpiresAtMs < now)
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.LeaseExpired,
                SnapshotId = snap.SnapshotId,
            }, null, null);
        }

        if (!string.Equals(owner.PageKey, snap.PageKey, StringComparison.Ordinal) ||
            !string.Equals(owner.AdapterKey, snap.AdapterKey, StringComparison.Ordinal) ||
            !string.Equals(owner.RoutingKey, snap.RoutingKey, StringComparison.Ordinal) ||
            !string.Equals(owner.InstanceKey, snap.InstanceKey, StringComparison.Ordinal))
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.OwnerChanged,
                SnapshotId = snap.SnapshotId,
            }, null, null);
        }

        if (snap.PageFingerprint is not null &&
            owner.PageFingerprint is not null &&
            !string.Equals(owner.PageFingerprint, snap.PageFingerprint, StringComparison.Ordinal))
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.Stale,
                Reason = RejectReasons.OwnerChanged,
                SnapshotId = snap.SnapshotId,
            }, null, null);
        }

        if (!_adapters.TryGetValue(snap.AdapterKey, out var adapter) || adapter.LeaseExpiresAtMs < now)
        {
            return (new RouteResponse
            {
                RequestId = msg.RequestId,
                Result = RouteResults.AdapterUnavailable,
                Reason = RejectReasons.LeaseExpired,
                SnapshotId = snap.SnapshotId,
            }, null, null);
        }

        return (null, snap, adapter);
    }

    private RouteResponse HandleActivateResult_NoLock(RouteMessage msg, long now)
    {
        var activationRequestId = msg.ActivationRequestId ?? msg.RequestId;
        if (string.IsNullOrWhiteSpace(activationRequestId) || string.IsNullOrWhiteSpace(msg.Result))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.MissingField);
        }

        if (!MessageValidator.IsOpaqueId(activationRequestId) || ExceedsLabel(msg.Result!))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.InvalidField);
        }

        // Optional adapter binding: wrong adapter cannot complete another adapter's activation.
        if (!string.IsNullOrWhiteSpace(msg.AdapterKey) &&
            _activations.TryGetValue(activationRequestId, out var existingCheck) &&
            !string.Equals(existingCheck.AdapterKey, msg.AdapterKey, StringComparison.Ordinal))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.WrongAdapter);
        }

        if (!_activations.TryGetValue(activationRequestId, out var pending))
        {
            // Unknown activation: accept idempotent write only if snapshot still known (legacy path).
            if (!string.IsNullOrWhiteSpace(msg.SnapshotId) &&
                _snapshotsById.TryGetValue(msg.SnapshotId!, out var orphanSnap))
            {
                orphanSnap.LastActivateResult = msg.Result;
                orphanSnap.LastActivateReason = msg.Reason;
                return new RouteResponse
                {
                    RequestId = msg.RequestId,
                    Result = msg.Result!,
                    Reason = msg.Reason,
                    SnapshotId = msg.SnapshotId,
                    ActivationRequestId = activationRequestId,
                    ElapsedMs = msg.ElapsedMs,
                };
            }

            return RouteResponse.Reject(msg.RequestId, RouteResults.Stale, RejectReasons.ActivationUnknown);
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

        // Snapshot id mismatch is rejected (cannot retarget).
        if (!string.IsNullOrWhiteSpace(msg.SnapshotId) &&
            !string.Equals(msg.SnapshotId, pending.SnapshotId, StringComparison.Ordinal))
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.SnapshotMismatch);
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

        if (!_adapters.TryGetValue(msg.AdapterKey!, out var adapter) || adapter.LeaseExpiresAtMs < now)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.AdapterUnavailable, RejectReasons.AdapterUnknown);
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

        // Dequeue until a still-valid undelivered command is found.
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

            if (pending.Delivered)
            {
                // Already handed out; do not redeliver. Leave for status/result path.
                queue.Dequeue();
                continue;
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

            // Deliver exactly once.
            queue.Dequeue();
            pending.Delivered = true;

            SafeLog.Info("poll-activation-deliver",
                ("adapterKind", adapter.AdapterKind),
                ("routeFp", RoutingKey.Fingerprint(pending.RoutingKey)),
                ("ownerFp", SafeLog.OwnerFp(pending.OwnerKey)));

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
        var now = _clock.UtcNowMs;
        lock (_gate)
        {
            SweepExpired_NoLock();
            return EnqueuePendingActivation_NoLock(msg, snap, adapter, now);
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
                return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
            }
        }

        if (!_pendingByAdapter.TryGetValue(snap.AdapterKey, out var queue))
        {
            queue = new Queue<string>();
            _pendingByAdapter[snap.AdapterKey] = queue;
        }

        if (queue.Count >= ProtocolConstants.MaxPendingPerAdapter)
        {
            return RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.Capacity);
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
            return RouteResponse.Reject(msg.RequestId, RouteResults.Timeout, RejectReasons.Expired);
        }

        var pending = new PendingActivation
        {
            ActivationRequestId = msg.RequestId,
            NotificationId = snap.NotificationId,
            SnapshotId = snap.SnapshotId,
            AdapterKey = snap.AdapterKey,
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

        if (!_ownersByKey.TryGetValue(pending.OwnerKey, out var owner) || owner.LeaseExpiresAtMs < now)
        {
            return new RouteResponse { Result = RouteResults.Stale, Reason = RejectReasons.LeaseExpired };
        }

        if (!string.Equals(owner.PageKey, pending.PageKey, StringComparison.Ordinal) ||
            !string.Equals(owner.AdapterKey, pending.AdapterKey, StringComparison.Ordinal) ||
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

        if (!_adapters.TryGetValue(pending.AdapterKey, out var adapter) || adapter.LeaseExpiresAtMs < now)
        {
            return new RouteResponse { Result = RouteResults.AdapterUnavailable, Reason = RejectReasons.LeaseExpired };
        }

        return null;
    }

    private void EvictOldestCompletedActivation_NoLock(long now)
    {
        var victim = _activations.Values
            .Where(a => a.Completed || a.ExpiresAtMs < now)
            .OrderBy(a => a.CreatedAtMs)
            .FirstOrDefault();

        if (victim is null)
        {
            // Fall back to oldest undelivered to free capacity fail-closed.
            victim = _activations.Values.OrderBy(a => a.CreatedAtMs).FirstOrDefault();
        }

        if (victim is not null)
        {
            _activations.Remove(victim.ActivationRequestId);
            if (_pendingByAdapter.TryGetValue(victim.AdapterKey, out var queue))
            {
                var kept = new Queue<string>(queue.Where(id =>
                    !string.Equals(id, victim.ActivationRequestId, StringComparison.Ordinal)));
                _pendingByAdapter[victim.AdapterKey] = kept;
            }
        }
    }

    private static bool ExceedsLabel(string value) =>
        value.Length > ProtocolConstants.MaxLabelLength;

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

    private void SweepExpired_NoLock()
    {
        var now = _clock.UtcNowMs;

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

    private void EvictOldestSnapshot_NoLock(long now)
    {
        var oldest = _snapshotsById.Values.OrderBy(s => s.CreatedAtMs).FirstOrDefault();
        if (oldest is null)
        {
            return;
        }

        _snapshotsById.Remove(oldest.SnapshotId);
        _snapshotsByNotification.Remove(oldest.NotificationId);
    }

    private RouteResponse Remember_NoLock(RouteMessage msg, RouteResponse response, long now)
    {
        if (_replay.Count >= ProtocolConstants.MaxReplayEntries)
        {
            var victim = _replay.OrderBy(kv => kv.Value.ExpiresAtMs).First().Key;
            _replay.Remove(victim);
        }

        var entry = new ReplayEntry
        {
            Response = CloneResponse(response),
            ExpiresAtMs = now + ProtocolConstants.ReplayCacheTtlMs,
        };
        _replay[msg.RequestId] = entry;

        if (msg.Nonce is not null)
        {
            _replay["nonce:" + msg.Nonce] = new ReplayEntry
            {
                Response = CloneResponse(response),
                ExpiresAtMs = now + ProtocolConstants.ReplayCacheTtlMs,
            };
        }

        return response;
    }

    private static RouteResponse CloneResponse(RouteResponse src) => new()
    {
        ProtocolVersion = src.ProtocolVersion,
        Type = src.Type,
        RequestId = src.RequestId,
        Result = src.Result,
        Reason = src.Reason,
        SnapshotId = src.SnapshotId,
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
    }
}
