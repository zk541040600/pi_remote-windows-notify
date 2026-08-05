using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;
using PiNotifyRouteHost.State;

namespace PiNotifyRouteHost;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length == 0)
            {
                // Browser Native Messaging often launches with only the origin argument on argv[0] path;
                // without flags, treat as help on interactive TTY, else native relay with no allowlist (fail-closed).
                if (Console.IsInputRedirected)
                {
                    return await RunNativeAsync(args).ConfigureAwait(false);
                }

                PrintHelp();
                return 2;
            }

            var mode = args[0];
            return mode switch
            {
                "--help" or "-h" or "help" => PrintHelp(),
                "--daemon" or "daemon" => await RunDaemonAsync(args).ConfigureAwait(false),
                "--native" or "native" => await RunNativeAsync(args).ConfigureAwait(false),
                "--client" or "client" => await RunClientAsync(args).ConfigureAwait(false),
                "--self-test" or "self-test" => await RunSelfTestAsync().ConfigureAwait(false),
                _ when mode.StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase)
                    => await RunNativeAsync(args).ConfigureAwait(false),
                _ => FailUnknown(mode),
            };
        }
        catch (Exception ex)
        {
            SafeLog.Error("fatal", ("reason", ex.GetType().Name), ("message", ex.Message));
            return 1;
        }
    }

    private static int PrintHelp()
    {
        Console.Out.WriteLine("""
            PiNotifyRouteHost — local exact route hub for Pi Web notify activation

            Usage:
              PiNotifyRouteHost --daemon [--pipe <name>]
              PiNotifyRouteHost --native [--allowed-origin <chrome-extension://id/>]...
                                       [--allowed-origins-file <native-host-manifest.json>]
              PiNotifyRouteHost --client --json <file-or--> [--wait-ms <ms>]
                                [--return-on-progress]
              PiNotifyRouteHost --self-test

            Modes:
              --daemon   Single-user route state machine + named pipe server
              --native   Native Messaging relay (stdin/stdout framed JSON → daemon)
              --client   One-shot JSON request/response over the daemon pipe
                         For type=activate, --wait-ms polls activation-status until
                         terminal result or deadline (for PowerShell exact-ack).
                         --return-on-progress may be combined with that wait to
                         return trusted desktop focus progress before final proof.
              --self-test In-process unique/miss/ambiguous/stale smoke (no pipe)
            """);
        return 0;
    }

    private static int FailUnknown(string mode)
    {
        SafeLog.Error("unknown-mode", ("mode", mode));
        PrintHelp();
        return 2;
    }

    private static async Task<int> RunDaemonAsync(string[] args)
    {
        using var daemonMutex = new Mutex(
            initiallyOwned: true,
            name: @"Local\PiNotifyRouteHost.Daemon",
            createdNew: out var createdNew);
        if (!createdNew)
        {
            SafeLog.Warn("daemon-already-running");
            return 3;
        }

        var pipeName = GetOption(args, "--pipe") ?? ProtocolConstants.DefaultPipeName;
        var statePath = GetOption(args, "--state-file");
        if (statePath is null)
        {
            statePath = SessionStoragePaths.GetDefaultBindingStatePath();
            SessionStoragePaths.TryClaimLegacyBindingState(
                SessionStoragePaths.GetLegacyBindingStatePath(),
                statePath);
        }
        var state = new RouteStateMachine(
            bindings: new FileRouteBindingStore(statePath));
        var dispatcher = new RouteDispatcher(state);
        await using var server = new NamedPipeRouteServer(dispatcher, pipeName);
        server.Start();

        SafeLog.Info("daemon-ready", ("pipe", server.PipeName), ("daemonId", state.DaemonId));

        var tcs = new TaskCompletionSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            tcs.TrySetResult();
        };

        await tcs.Task.ConfigureAwait(false);
        SafeLog.Info("daemon-stop", ("daemonId", state.DaemonId));
        return 0;
    }

    private static async Task<int> RunNativeAsync(string[] args)
    {
        var allowed = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--allowed-origin" && i + 1 < args.Length)
            {
                allowed.Add(args[++i]);
            }
            else if (args[i].StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase))
            {
                // Browser passes origin as first argument when launching native host.
                // Do not auto-allow it; allowlist must come from --allowed-origin / config.
            }
        }

        // The browser cannot pass arbitrary native-host arguments. Load the registered host
        // manifest beside the executable (or an explicit installer-provided path) and reuse its
        // allowed_origins as the relay allowlist. The launching origin is never auto-allowed.
        var manifestPath = GetOption(args, "--allowed-origins-file")
            ?? Environment.GetEnvironmentVariable("PI_NOTIFY_NATIVE_HOST_MANIFEST")
            ?? Path.Combine(AppContext.BaseDirectory, $"{ProtocolConstants.NativeHostName}.json");
        foreach (var origin in LoadAllowedOriginsFromManifest(manifestPath))
        {
            allowed.Add(origin);
        }

        // Optional env allowlist (semicolon-separated), set by installer — not free-form user URL.
        var env = Environment.GetEnvironmentVariable("PI_NOTIFY_NATIVE_ALLOWED_ORIGINS");
        if (!string.IsNullOrWhiteSpace(env))
        {
            foreach (var part in env.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                allowed.Add(part);
            }
        }

        var callerOrigin = args.FirstOrDefault(a => a.StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase));
        var pipeName = GetOption(args, "--pipe") ?? ProtocolConstants.DefaultPipeName;

        async Task<RouteResponse> Forward(RouteMessage msg, CancellationToken ct)
        {
            await using var client = new NamedPipeRouteClient(pipeName);
            return await client
                .SendRequestAsync(
                    msg,
                    ProtocolConstants.DefaultRequestTtlMs,
                    ct)
                .ConfigureAwait(false);
        }

        var relay = new NativeMessagingRelay(callerOrigin, allowed, Forward);
        await relay.RunAsync().ConfigureAwait(false);
        return relay.HadFatalOutputFailure ? 1 : 0;
    }

    private static async Task<int> RunClientAsync(string[] args)
    {
        var pipeName = GetOption(args, "--pipe") ?? ProtocolConstants.DefaultPipeName;
        var jsonPath = GetOption(args, "--json");
        if (!TryGetClientWaitMs(args, out var waitMs))
        {
            return WriteClientReject(string.Empty, RejectReasons.InvalidField);
        }
        if (!TryGetClientReturnOnProgress(args, out var returnOnProgress))
        {
            return WriteClientReject(string.Empty, RejectReasons.InvalidField);
        }

        string json;
        if (jsonPath is null || jsonPath == "-")
        {
            json = await Console.In.ReadToEndAsync().ConfigureAwait(false);
        }
        else
        {
            json = await File.ReadAllTextAsync(jsonPath).ConfigureAwait(false);
        }

        var bytes = Encoding.UTF8.GetBytes(json);
        if (bytes.Length > ProtocolConstants.MaxMessageBytes)
        {
            Console.Out.WriteLine(Encoding.UTF8.GetString(RouteResponse.Reject(string.Empty, RouteResults.Oversized, RejectReasons.Oversized).ToUtf8Bytes()));
            return 1;
        }

        var msg = RouteMessage.TryParse(bytes, out var error);
        if (msg is null)
        {
            Console.Out.WriteLine(Encoding.UTF8.GetString(RouteResponse.Reject(string.Empty, RouteResults.Rejected, error ?? RejectReasons.InvalidField).ToUtf8Bytes()));
            return 1;
        }

        if ((waitMs is not null || returnOnProgress) &&
            (!string.Equals(
                 msg.Type,
                 MessageTypes.Activate,
                 StringComparison.Ordinal) ||
             (returnOnProgress && waitMs is null)))
        {
            return WriteClientReject(msg.RequestId, RejectReasons.InvalidField);
        }

        await using var client = new NamedPipeRouteClient(pipeName);
        RouteResponse response;

        // For external activate, one monotonic budget covers pipe connect,
        // initial delivery and every activation-status poll.
        if (waitMs is int budget && budget > 0 &&
            string.Equals(msg.Type, MessageTypes.Activate, StringComparison.Ordinal))
        {
            var effectiveWaitMs = budget;
            if (msg.DeadlineMs is long d && d > 0)
            {
                var wallNow = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                effectiveWaitMs = (int)Math.Min(
                    budget,
                    Math.Max(0L, d - wallNow));
            }

            var clientWaitStarted = Stopwatch.GetTimestamp();
            using var clientWaitCts = new CancellationTokenSource(
                Math.Max(0, effectiveWaitMs));
            var clientWaitToken = clientWaitCts.Token;

            if (effectiveWaitMs <= 0)
            {
                response = ActivationTimeout(msg.RequestId);
            }
            else
            {
                try
                {
                    await client
                        .ConnectAsync(
                            Math.Min(2000, effectiveWaitMs),
                            clientWaitToken)
                        .ConfigureAwait(false);
                    response = await client
                        .SendAsync(msg, clientWaitToken)
                        .ConfigureAwait(false);

                    var accepted = string.Equals(
                        response.Result,
                        RouteResults.Accepted,
                        StringComparison.Ordinal);
                    var resumablePending = string.Equals(
                            response.Result,
                            RouteResults.Pending,
                            StringComparison.Ordinal) &&
                        MessageValidator.IsOpaqueId(
                            response.ActivationRequestId);
                    if (accepted || resumablePending)
                    {
                        var activationRequestId = resumablePending
                            ? response.ActivationRequestId!
                            : response.ActivationRequestId ?? msg.RequestId;
                        response = await WaitForActivationAsync(
                                client,
                                activationRequestId,
                                effectiveWaitMs,
                                clientWaitStarted,
                                returnOnProgress,
                                clientWaitToken)
                            .ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException)
                {
                    response = ActivationTimeout(msg.RequestId);
                }
            }
        }
        else
        {
            response = await client
                .SendRequestAsync(
                    msg,
                    ProtocolConstants.DefaultRequestTtlMs)
                .ConfigureAwait(false);
        }

        Console.Out.WriteLine(Encoding.UTF8.GetString(response.ToUtf8Bytes()));
        return response.Result is RouteResults.Ok or RouteResults.Ready or RouteResults.SessionUrlConfirmed
            or RouteResults.SessionConfirmed or RouteResults.AlreadyActive
            or RouteResults.Accepted or RouteResults.Pending
            or RouteResults.Recovering
            ? 0
            : 3;
    }

    private static bool TryGetClientWaitMs(
        string[] args,
        out int? waitMs)
    {
        waitMs = null;
        var optionIndex = -1;
        for (var i = 1; i < args.Length; i++)
        {
            if (!string.Equals(
                    args[i],
                    "--wait-ms",
                    StringComparison.Ordinal))
            {
                continue;
            }

            if (optionIndex >= 0)
            {
                return false;
            }

            optionIndex = i;
        }

        if (optionIndex < 0)
        {
            return true;
        }

        if (optionIndex + 1 >= args.Length ||
            !int.TryParse(
                args[optionIndex + 1],
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var parsedWait) ||
            parsedWait <= 0 ||
            parsedWait > ProtocolConstants.MaxActivationExecutionMs)
        {
            return false;
        }

        waitMs = parsedWait;
        return true;
    }

    private static bool TryGetClientReturnOnProgress(
        string[] args,
        out bool returnOnProgress)
    {
        returnOnProgress = false;
        for (var i = 1; i < args.Length; i++)
        {
            if (!string.Equals(
                    args[i],
                    "--return-on-progress",
                    StringComparison.Ordinal))
            {
                continue;
            }

            if (returnOnProgress)
            {
                return false;
            }

            returnOnProgress = true;
        }

        return true;
    }

    private static int WriteClientReject(
        string requestId,
        string reason)
    {
        var response = RouteResponse.Reject(
            requestId,
            RouteResults.Rejected,
            reason);
        Console.Out.WriteLine(
            Encoding.UTF8.GetString(response.ToUtf8Bytes()));
        return 1;
    }

    /// <summary>
    /// Poll activation-status until a terminal result or monotonic wait budget.
    /// Suitable for PowerShell exact-ack without implementing the poll loop in script.
    /// </summary>
    private static async Task<RouteResponse> WaitForActivationAsync(
        NamedPipeRouteClient client,
        string activationRequestId,
        int waitBudgetMs,
        long clientWaitStarted,
        bool returnOnProgress,
        CancellationToken clientWaitToken)
    {
        var clock = new SystemClock();
        RouteResponse? last = null;

        try
        {
            while (true)
            {
                var elapsedMs = (long)Stopwatch
                    .GetElapsedTime(clientWaitStarted)
                    .TotalMilliseconds;
                var remainingBudgetMs = (long)waitBudgetMs - elapsedMs;
                if (remainingBudgetMs <= 0)
                {
                    return ActivationTimeout(activationRequestId);
                }

                var now = clock.UtcNowMs;
                var statusMsg = MessageFactory.ActivationStatus(
                    clock,
                    activationRequestId);
                // Envelope time remains wall-clock protocol data, but its TTL
                // is derived from the monotonic local wait budget.
                var envelopeTtlMs = Math.Clamp(
                    (int)Math.Min(
                        remainingBudgetMs,
                        ProtocolConstants.MaxRequestTtlMs),
                    ProtocolConstants.MinLeaseTtlMs,
                    ProtocolConstants.MaxRequestTtlMs);
                statusMsg.ExpiresAtMs = now + envelopeTtlMs;

                last = await client
                    .SendAsync(statusMsg, clientWaitToken)
                    .ConfigureAwait(false);

                if (!string.Equals(
                        last.Result,
                        RouteResults.Pending,
                        StringComparison.Ordinal))
                {
                    // Preserve activationRequestId on the final response for callers.
                    last.ActivationRequestId ??= activationRequestId;
                    return last;
                }

                if (returnOnProgress &&
                    string.Equals(
                        last.ActivationPhase,
                        ActivationPhases.DesktopRowFocusedAwaitingProof,
                        StringComparison.Ordinal))
                {
                    last.ActivationRequestId ??= activationRequestId;
                    return last;
                }

                var sleepMs = Math.Min(
                    50,
                    Math.Max(
                        1,
                        (int)Math.Min(remainingBudgetMs, int.MaxValue) / 4));
                await Task.Delay(sleepMs, clientWaitToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (clientWaitToken.IsCancellationRequested)
        {
            return ActivationTimeout(activationRequestId);
        }
    }

    private static RouteResponse ActivationTimeout(string activationRequestId)
    {
        var response = RouteResponse.Reject(
            activationRequestId,
            RouteResults.Timeout,
            RejectReasons.Expired);
        response.ActivationRequestId = activationRequestId;
        return response;
    }

    private static async Task<int> RunSelfTestAsync()
    {
        var clock = new FakeClock();
        var state = new RouteStateMachine(clock, daemonId: "selftest");
        var dispatcher = new RouteDispatcher(state, clock);
        var instance = "11111111-2222-3333-4444-555555555555";
        var routing = RoutingKey.Compute(instance, "session-alpha-example");

        // miss
        var freezeMiss = await dispatcher.DispatchAsync(MessageFactory.Freeze(clock, "notif-miss-0001", instance, routing)).ConfigureAwait(false);
        if (freezeMiss.Result != RouteResults.Miss)
        {
            SafeLog.Error("self-test-fail", ("case", "miss"), ("result", freezeMiss.Result));
            return 1;
        }

        // unique ready + activate
        var adapterKey = "adapter-mock-0001";
        await dispatcher.DispatchAsync(MessageFactory.RegisterAdapter(clock, adapterKey, "mock")).ConfigureAwait(false);
        dispatcher.TrySetActivator(adapterKey, MockAdapterActivator.ConfirmSessionUrl);
        await dispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            clock, adapterKey, "mock", "owner-0001", "page-0001", instance, routing, pageFingerprint: "fp-a")).ConfigureAwait(false);

        var freeze = await dispatcher.DispatchAsync(MessageFactory.Freeze(clock, "notif-unique-0001", instance, routing, "turn-complete")).ConfigureAwait(false);
        if (freeze.Result != RouteResults.Ready || string.IsNullOrEmpty(freeze.SnapshotId))
        {
            SafeLog.Error("self-test-fail", ("case", "unique"), ("result", freeze.Result));
            return 1;
        }

        var activate = await dispatcher.DispatchAsync(MessageFactory.Activate(clock, "notif-unique-0001", freeze.SnapshotId!)).ConfigureAwait(false);
        if (activate.Result != RouteResults.SessionUrlConfirmed)
        {
            SafeLog.Error("self-test-fail", ("case", "activate"), ("result", activate.Result));
            return 1;
        }

        // ambiguous
        await dispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            clock, adapterKey, "mock", "owner-0002", "page-0002", instance, routing, pageFingerprint: "fp-b")).ConfigureAwait(false);
        var amb = await dispatcher.DispatchAsync(MessageFactory.Freeze(clock, "notif-amb-0001", instance, routing)).ConfigureAwait(false);
        if (amb.Result != RouteResults.Ambiguous || amb.CandidateCount != 2)
        {
            SafeLog.Error("self-test-fail", ("case", "ambiguous"), ("result", amb.Result), ("candidates", amb.CandidateCount));
            return 1;
        }

        // snapshot immutable: old unique snapshot still points at owner-0001 even after second owner appeared
        var snap = state.GetSnapshot(freeze.SnapshotId!);
        if (snap is null || snap.OwnerKey != "owner-0001")
        {
            SafeLog.Error("self-test-fail", ("case", "immutable"));
            return 1;
        }

        // first-session binding: later adapters cannot steal, offline does not fall back,
        // and restoring the bound adapter resumes routing.
        var bindingState = new RouteStateMachine(
            clock,
            daemonId: "selftest-binding",
            bindings: new MemoryRouteBindingStore());
        var bindingDispatcher = new RouteDispatcher(bindingState, clock);
        var chromeAdapter = "adapter-binding-chrome";
        var desktopAdapter = "adapter-binding-desktop";
        await bindingDispatcher.DispatchAsync(
            MessageFactory.RegisterAdapter(clock, chromeAdapter, "chrome")).ConfigureAwait(false);
        await bindingDispatcher.DispatchAsync(
            MessageFactory.RegisterAdapter(clock, desktopAdapter, "pi-web-desktop")).ConfigureAwait(false);

        var bindingRouting = RoutingKey.Compute(instance, "session-first-binding-example");
        await bindingDispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            clock,
            chromeAdapter,
            "chrome",
            "owner-binding-chrome",
            "page-binding-chrome",
            instance,
            bindingRouting,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-binding-chrome",
            openedAtMs: clock.UtcNowMs)).ConfigureAwait(false);
        clock.AdvanceMs(10);
        await bindingDispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            clock,
            desktopAdapter,
            "pi-web-desktop",
            "owner-binding-desktop",
            "page-binding-desktop",
            instance,
            bindingRouting,
            ownerEvent: OwnerEvents.ExplicitOpen,
            openEventId: "event-binding-desktop",
            openedAtMs: clock.UtcNowMs)).ConfigureAwait(false);

        var bound = await bindingDispatcher.DispatchAsync(
            MessageFactory.Freeze(clock, "notif-binding-0001", instance, bindingRouting)).ConfigureAwait(false);
        if (bound.Result != RouteResults.Ready || bound.AdapterKind != "chrome")
        {
            SafeLog.Error("self-test-fail", ("case", "first-binding"), ("result", bound.Result), ("adapterKind", bound.AdapterKind));
            return 1;
        }

        await bindingDispatcher.DispatchAsync(
            MessageFactory.UnregisterOwner(
                clock,
                chromeAdapter,
                "owner-binding-chrome")).ConfigureAwait(false);
        var boundOffline = await bindingDispatcher.DispatchAsync(
            MessageFactory.Freeze(clock, "notif-binding-offline-0001", instance, bindingRouting)).ConfigureAwait(false);
        if (boundOffline.Result != RouteResults.Miss ||
            boundOffline.Reason != RouteResults.OwnerUnresolved)
        {
            SafeLog.Error("self-test-fail", ("case", "bound-offline"), ("result", boundOffline.Result), ("reason", boundOffline.Reason));
            return 1;
        }

        await bindingDispatcher.DispatchAsync(MessageFactory.RegisterOwner(
            clock,
            chromeAdapter,
            "chrome",
            "owner-binding-chrome-restored",
            "page-binding-chrome-restored",
            instance,
            bindingRouting,
            ownerEvent: OwnerEvents.Restore)).ConfigureAwait(false);
        var boundRestored = await bindingDispatcher.DispatchAsync(
            MessageFactory.Freeze(clock, "notif-binding-restored-0001", instance, bindingRouting)).ConfigureAwait(false);
        if (boundRestored.Result != RouteResults.Ready || boundRestored.AdapterKind != "chrome")
        {
            SafeLog.Error("self-test-fail", ("case", "bound-restored"), ("result", boundRestored.Result), ("adapterKind", boundRestored.AdapterKind));
            return 1;
        }

        Console.Out.WriteLine(JsonSerializer.Serialize(new
        {
            result = "ok",
            daemonId = state.DaemonId,
            routingFingerprint = RoutingKey.Fingerprint(routing),
            binding = "first-opener",
        }, JsonDefaults.Options));
        return 0;
    }

    private static IReadOnlyList<string> LoadAllowedOriginsFromManifest(string? manifestPath)
    {
        if (string.IsNullOrWhiteSpace(manifestPath) || !File.Exists(manifestPath))
        {
            return Array.Empty<string>();
        }

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
            if (!document.RootElement.TryGetProperty("allowed_origins", out var origins) ||
                origins.ValueKind != JsonValueKind.Array)
            {
                SafeLog.Warn("native-allowlist-invalid", ("reason", "missing-allowed-origins"));
                return Array.Empty<string>();
            }

            var allowed = new List<string>();
            foreach (var item in origins.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(item.GetString()))
                {
                    allowed.Add(item.GetString()!);
                }
            }

            return allowed;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            SafeLog.Warn("native-allowlist-invalid", ("reason", ex.GetType().Name));
            return Array.Empty<string>();
        }
    }

    private static string? GetOption(string[] args, string name)
    {
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == name)
            {
                return args[i + 1];
            }
        }

        return null;
    }
}
