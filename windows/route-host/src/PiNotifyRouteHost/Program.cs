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
              PiNotifyRouteHost --self-test

            Modes:
              --daemon   Single-user route state machine + named pipe server
              --native   Native Messaging relay (stdin/stdout framed JSON → daemon)
              --client   One-shot JSON request/response over the daemon pipe
                         For type=activate, --wait-ms polls activation-status until
                         terminal result or deadline (for PowerShell exact-ack).
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
        var statePath = GetOption(args, "--state-file")
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PiNotifyRouteHost",
                "route-preferences.json");
        var state = new RouteStateMachine(
            preferences: new FileRoutePreferenceStore(statePath));
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
            await client.ConnectAsync(timeoutMs: 2000, ct).ConfigureAwait(false);
            return await client.SendAsync(msg, ct).ConfigureAwait(false);
        }

        var relay = new NativeMessagingRelay(callerOrigin, allowed, Forward);
        await relay.RunAsync().ConfigureAwait(false);
        return 0;
    }

    private static async Task<int> RunClientAsync(string[] args)
    {
        var pipeName = GetOption(args, "--pipe") ?? ProtocolConstants.DefaultPipeName;
        var jsonPath = GetOption(args, "--json");
        var waitMsOpt = GetOption(args, "--wait-ms");
        int? waitMs = null;
        if (waitMsOpt is not null && int.TryParse(waitMsOpt, out var parsedWait))
        {
            waitMs = Math.Clamp(parsedWait, 0, ProtocolConstants.MaxRequestTtlMs);
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

        await using var client = new NamedPipeRouteClient(pipeName);
        await client.ConnectAsync().ConfigureAwait(false);
        var response = await client.SendAsync(msg).ConfigureAwait(false);

        // Optional: for external activate, poll activation-status until terminal or deadline.
        if (waitMs is int budget && budget > 0 &&
            string.Equals(msg.Type, MessageTypes.Activate, StringComparison.Ordinal) &&
            string.Equals(response.Result, RouteResults.Accepted, StringComparison.Ordinal))
        {
            var activationRequestId = response.ActivationRequestId ?? msg.RequestId;
            var deadline = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + budget;
            if (msg.DeadlineMs is long d && d > 0)
            {
                deadline = Math.Min(deadline, d);
            }

            response = await WaitForActivationAsync(client, activationRequestId, deadline).ConfigureAwait(false);
        }

        Console.Out.WriteLine(Encoding.UTF8.GetString(response.ToUtf8Bytes()));
        return response.Result is RouteResults.Ok or RouteResults.Ready or RouteResults.SessionUrlConfirmed
            or RouteResults.AlreadyActive or RouteResults.Accepted or RouteResults.Pending
            ? 0
            : 3;
    }

    /// <summary>
    /// Poll activation-status until a terminal result or wall-clock deadline.
    /// Suitable for PowerShell exact-ack without implementing the poll loop in script.
    /// </summary>
    private static async Task<RouteResponse> WaitForActivationAsync(
        NamedPipeRouteClient client,
        string activationRequestId,
        long deadlineMs)
    {
        var clock = new SystemClock();
        RouteResponse? last = null;

        while (true)
        {
            var now = clock.UtcNowMs;
            if (now > deadlineMs)
            {
                return last is not null && last.Result != RouteResults.Pending
                    ? last
                    : RouteResponse.Reject(activationRequestId, RouteResults.Timeout, RejectReasons.Expired);
            }

            var statusMsg = MessageFactory.ActivationStatus(clock, activationRequestId);
            // Ensure envelope expires after the remaining wait budget.
            var remaining = Math.Max(ProtocolConstants.MinLeaseTtlMs, (int)Math.Min(deadlineMs - now, ProtocolConstants.MaxRequestTtlMs));
            statusMsg.ExpiresAtMs = now + remaining;

            last = await client.SendAsync(statusMsg).ConfigureAwait(false);

            if (!string.Equals(last.Result, RouteResults.Pending, StringComparison.Ordinal))
            {
                // Preserve activationRequestId on the final response for callers.
                last.ActivationRequestId ??= activationRequestId;
                return last;
            }

            var sleep = Math.Min(50, Math.Max(10, (int)(deadlineMs - now) / 4));
            await Task.Delay(sleep).ConfigureAwait(false);
        }
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
            clock, adapterKey, "owner-0001", "page-0001", instance, routing, pageFingerprint: "fp-a")).ConfigureAwait(false);

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
            clock, adapterKey, "owner-0002", "page-0002", instance, routing, pageFingerprint: "fp-b")).ConfigureAwait(false);
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

        Console.Out.WriteLine(JsonSerializer.Serialize(new
        {
            result = "ok",
            daemonId = state.DaemonId,
            routingFingerprint = RoutingKey.Fingerprint(routing),
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
