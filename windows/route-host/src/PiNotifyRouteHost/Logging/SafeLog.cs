using System.Text.RegularExpressions;
using PiNotifyRouteHost.Protocol;

namespace PiNotifyRouteHost.Logging;

/// <summary>
/// Structured stderr-only diagnostics. Never logs raw session IDs, full URLs, tokens, or secrets.
/// </summary>
public static partial class SafeLog
{
    private static readonly object Gate = new();

    // Heuristic: long hex that could be a full session id / routing material beyond fingerprint.
    [GeneratedRegex(@"[0-9a-fA-F]{24,}", RegexOptions.CultureInvariant)]
    private static partial Regex LongHexRegex();

    [GeneratedRegex(@"https?://\S+", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex UrlRegex();

    public static void Info(string eventName, params (string Key, object? Value)[] fields)
        => Write("info", eventName, fields);

    public static void Warn(string eventName, params (string Key, object? Value)[] fields)
        => Write("warn", eventName, fields);

    public static void Error(string eventName, params (string Key, object? Value)[] fields)
        => Write("error", eventName, fields);

    private static void Write(string level, string eventName, (string Key, object? Value)[] fields)
    {
        var parts = new List<string>
        {
            $"ts={DateTimeOffset.UtcNow:O}",
            $"level={level}",
            $"event={SanitizeToken(eventName)}",
        };

        foreach (var (key, value) in fields)
        {
            parts.Add($"{SanitizeToken(key)}={SanitizeValue(value)}");
        }

        var line = string.Join(' ', parts);
        lock (Gate)
        {
            Console.Error.WriteLine(line);
        }
    }

    public static string SanitizeValue(object? value)
    {
        if (value is null)
        {
            return "-";
        }

        var text = value switch
        {
            string s => s,
            bool b => b ? "true" : "false",
            IFormattable f => f.ToString(null, System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty,
            _ => value.ToString() ?? string.Empty,
        };

        text = UrlRegex().Replace(text, "[url]");
        // Collapse long hex runs to fingerprint-sized tokens so raw session IDs never appear.
        text = LongHexRegex().Replace(text, m => m.Value.Length <= 12 ? m.Value : m.Value[..12] + "…");

        if (text.Length > 160)
        {
            text = text[..160] + "…";
        }

        return Quote(text);
    }

    public static string OwnerFp(string? ownerKey) =>
        string.IsNullOrEmpty(ownerKey) ? "-" : RoutingKey.Fingerprint(ownerKey);

    public static string RouteFp(string? routingKey) =>
        string.IsNullOrEmpty(routingKey) ? "-" : RoutingKey.Fingerprint(routingKey);

    public static string InstanceFp(string? instanceKey) =>
        string.IsNullOrEmpty(instanceKey) ? "-" : RoutingKey.FingerprintInstance(instanceKey);

    private static string SanitizeToken(string token)
    {
        if (string.IsNullOrEmpty(token))
        {
            return "x";
        }

        Span<char> buf = stackalloc char[Math.Min(token.Length, 48)];
        var n = 0;
        foreach (var c in token)
        {
            if (n >= buf.Length)
            {
                break;
            }

            buf[n++] = char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or '.' ? c : '_';
        }

        return new string(buf[..n]);
    }

    private static string Quote(string value)
    {
        if (value.Length == 0)
        {
            return "\"\"";
        }

        if (!value.Contains(' ') && !value.Contains('"'))
        {
            return value;
        }

        return "\"" + value.Replace("\"", "'", StringComparison.Ordinal) + "\"";
    }
}
