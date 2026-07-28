using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;

namespace PiNotifyRouteHost.Host;

/// <summary>
/// Dispatches route messages against the state machine. Activate is the only type that
/// may call into an in-process <see cref="IAdapterActivator"/> after revalidation.
/// </summary>
public sealed class RouteDispatcher
{
    private readonly RouteStateMachine _state;
    private readonly IClock _clock;

    public RouteDispatcher(RouteStateMachine state, IClock? clock = null)
    {
        _state = state;
        _clock = clock ?? new SystemClock();
    }

    public RouteStateMachine State => _state;

    public async Task<RouteResponse> DispatchAsync(RouteMessage msg, CancellationToken cancellationToken = default)
    {
        if (string.Equals(msg.Type, MessageTypes.Activate, StringComparison.Ordinal))
        {
            return await DispatchActivateAsync(msg, cancellationToken).ConfigureAwait(false);
        }

        return _state.Handle(msg);
    }

    public async Task<RouteResponse> DispatchActivateAsync(RouteMessage msg, CancellationToken cancellationToken = default)
    {
        var (early, snapshot, adapter) = _state.BeginActivate(msg);
        if (early is not null)
        {
            return early;
        }

        if (snapshot is null || adapter is null)
        {
            var reject = RouteResponse.Reject(msg.RequestId, RouteResults.Stale, RejectReasons.SnapshotUnknown);
            _state.RememberActivateResponse(msg, reject);
            return reject;
        }

        var deadline = msg.DeadlineMs is long d && d > 0
            ? d
            : _clock.UtcNowMs + ProtocolConstants.DefaultRequestTtlMs;

        var request = new ActivateRequest
        {
            RequestId = msg.RequestId,
            NotificationId = snapshot.NotificationId,
            SnapshotId = snapshot.SnapshotId,
            OwnerKey = snapshot.OwnerKey,
            PageKey = snapshot.PageKey,
            InstanceKey = snapshot.InstanceKey,
            RoutingKey = snapshot.RoutingKey,
            PageFingerprint = snapshot.PageFingerprint,
            DeadlineMs = deadline,
        };

        AdapterActivateResult adapterResult;
        if (adapter.Activator is null)
        {
            // External adapter (Chrome/Edge/Desktop): enqueue one bounded command for poll-activation.
            // Final ack arrives via activate-result; callers poll activation-status for the terminal result.
            var pending = _state.EnqueuePendingActivation(msg, snapshot, adapter);
            _state.RememberActivateResponse(msg, pending);
            return pending;
        }

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var remaining = deadline - _clock.UtcNowMs;
            if (remaining <= 0)
            {
                var timeout = RouteResponse.Reject(msg.RequestId, RouteResults.Timeout, RejectReasons.Expired);
                _state.RememberActivateResponse(msg, timeout);
                return timeout;
            }

            cts.CancelAfter(TimeSpan.FromMilliseconds(Math.Min(remaining, ProtocolConstants.MaxRequestTtlMs)));
            adapterResult = await adapter.Activator.ActivateAsync(request, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            var timeout = RouteResponse.Reject(msg.RequestId, RouteResults.Timeout, RejectReasons.Expired);
            _state.RememberActivateResponse(msg, timeout);
            return timeout;
        }
        catch (Exception ex)
        {
            SafeLog.Error("activate-adapter-error",
                ("adapterKind", adapter.AdapterKind),
                ("reason", ex.GetType().Name));
            adapterResult = new AdapterActivateResult
            {
                Result = RouteResults.SelectFailed,
                Reason = "adapter-exception",
                ElapsedMs = 0,
            };
        }

        var response = _state.CompleteActivate(msg.RequestId, snapshot.NotificationId, snapshot.SnapshotId, adapterResult);
        _state.RememberActivateResponse(msg, response);
        return response;
    }

    /// <summary>Attach an in-process activator to a registered adapter (tests / mock mode).</summary>
    public bool TrySetActivator(string adapterKey, IAdapterActivator activator)
    {
        var adapter = _state.GetAdapter(adapterKey);
        if (adapter is null)
        {
            return false;
        }

        adapter.Activator = activator;
        return true;
    }
}

/// <summary>Mock activator for unit tests and CLI probes.</summary>
public sealed class MockAdapterActivator : IAdapterActivator
{
    private readonly Func<ActivateRequest, CancellationToken, Task<AdapterActivateResult>> _handler;

    public MockAdapterActivator(Func<ActivateRequest, CancellationToken, Task<AdapterActivateResult>>? handler = null)
    {
        _handler = handler ?? ((req, _) => Task.FromResult(new AdapterActivateResult
        {
            Result = RouteResults.SessionUrlConfirmed,
            Reason = null,
            ElapsedMs = 1,
        }));
    }

    public static MockAdapterActivator ConfirmSessionUrl { get; } = new();

    public static MockAdapterActivator Stale { get; } = new((_, _) => Task.FromResult(new AdapterActivateResult
    {
        Result = RouteResults.Stale,
        Reason = RejectReasons.OwnerChanged,
        ElapsedMs = 1,
    }));

    public Task<AdapterActivateResult> ActivateAsync(ActivateRequest request, CancellationToken cancellationToken)
        => _handler(request, cancellationToken);
}
