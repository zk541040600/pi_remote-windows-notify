using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Logging;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.Host;

/// <summary>
/// Native Messaging mode: Chrome/Edge launches this process; stdin/stdout use 32-bit framing.
/// Relay validates schema and forwards to the daemon named pipe. Diagnostics go to stderr only.
/// Caller origin is the first CLI argument supplied by the browser (chrome-extension://&lt;id&gt;/).
/// </summary>
public sealed class NativeMessagingRelay
{
    private readonly string? _callerOrigin;
    private readonly IReadOnlySet<string> _allowedOrigins;
    private readonly Func<RouteMessage, CancellationToken, Task<RouteResponse>> _forward;
    private readonly Stream _input;
    private readonly Stream _output;

    public NativeMessagingRelay(
        string? callerOrigin,
        IEnumerable<string>? allowedOrigins,
        Func<RouteMessage, CancellationToken, Task<RouteResponse>> forward,
        Stream? input = null,
        Stream? output = null)
    {
        _callerOrigin = callerOrigin;
        _allowedOrigins = allowedOrigins is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : new HashSet<string>(allowedOrigins, StringComparer.Ordinal);
        _forward = forward;
        _input = input ?? Console.OpenStandardInput();
        _output = output ?? Console.OpenStandardOutput();
    }

    public static bool IsAllowedOrigin(string? origin, IReadOnlySet<string> allowed)
    {
        if (string.IsNullOrWhiteSpace(origin))
        {
            return false;
        }

        if (allowed.Count == 0)
        {
            // Fail-closed when no allowlist configured.
            return false;
        }

        return allowed.Contains(origin);
    }

    public static bool IsChromeExtensionOrigin(string origin)
    {
        if (!origin.StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var rest = origin["chrome-extension://".Length..];
        if (rest.EndsWith('/'))
        {
            rest = rest[..^1];
        }

        // Extension IDs are 32 lowercase a-p chars for Chrome; Edge may differ slightly — accept opaque alnum.
        if (rest.Length is < 16 or > 64)
        {
            return false;
        }

        foreach (var c in rest)
        {
            if (!char.IsAsciiLetterOrDigit(c))
            {
                return false;
            }
        }

        return true;
    }

    public async Task RunAsync(CancellationToken cancellationToken = default)
    {
        if (!IsAllowedOrigin(_callerOrigin, _allowedOrigins) ||
            _callerOrigin is null ||
            !IsChromeExtensionOrigin(_callerOrigin))
        {
            SafeLog.Warn("native-caller-rejected", ("originFp", FingerprintOrigin(_callerOrigin)));
            var rejected = RouteResponse.Reject(string.Empty, RouteResults.Rejected, RejectReasons.CallerRejected);
            await NativeMessageFraming.WriteFrameAsync(_output, rejected.ToUtf8Bytes(), cancellationToken)
                .ConfigureAwait(false);
            return;
        }

        SafeLog.Info("native-relay-start", ("originFp", FingerprintOrigin(_callerOrigin)));

        while (!cancellationToken.IsCancellationRequested)
        {
            byte[]? body;
            try
            {
                body = await NativeMessageFraming.ReadFrameAsync(_input, ProtocolConstants.MaxNativeFrameBytes, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (InvalidOperationException)
            {
                var oversized = RouteResponse.Reject(string.Empty, RouteResults.Oversized, RejectReasons.Oversized);
                await NativeMessageFraming.WriteFrameAsync(_output, oversized.ToUtf8Bytes(), cancellationToken)
                    .ConfigureAwait(false);
                break;
            }

            if (body is null)
            {
                break; // stdin closed
            }

            var msg = RouteMessage.TryParse(body, out var parseError);
            if (msg is null)
            {
                var err = RouteResponse.Reject(string.Empty, RouteResults.Rejected, parseError ?? RejectReasons.InvalidField);
                await NativeMessageFraming.WriteFrameAsync(_output, err.ToUtf8Bytes(), cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }

            // Native path only allows registration/heartbeat/health from the extension; freeze/activate
            // come from listener via daemon pipe. Still accept activate-result from extension.
            if (msg.Type is MessageTypes.Freeze)
            {
                var err = RouteResponse.Reject(msg.RequestId, RouteResults.Rejected, RejectReasons.CallerRejected);
                await NativeMessageFraming.WriteFrameAsync(_output, err.ToUtf8Bytes(), cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }

            RouteResponse response;
            try
            {
                response = await _forward(msg, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                SafeLog.Error("native-forward-error", ("reason", ex.GetType().Name));
                response = RouteResponse.Reject(msg.RequestId, RouteResults.AdapterUnavailable, "daemon-unreachable");
            }

            await NativeMessageFraming.WriteFrameAsync(_output, response.ToUtf8Bytes(), cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static string FingerprintOrigin(string? origin)
    {
        if (string.IsNullOrEmpty(origin))
        {
            return "-";
        }

        // Never log full extension origin path with query; keep short hash-like token.
        var trimmed = origin.Length > 48 ? origin[..48] : origin;
        var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(trimmed));
        return Convert.ToHexString(hash).ToLowerInvariant()[..12];
    }
}
