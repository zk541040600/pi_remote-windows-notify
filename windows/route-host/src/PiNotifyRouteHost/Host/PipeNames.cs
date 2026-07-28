namespace PiNotifyRouteHost.Host;

public static class PipeNames
{
    /// <summary>
    /// Current-user scoped named pipe base. On Windows the OS isolates Local\\ pipes per session;
    /// we still embed a stable product name only (no secrets).
    /// </summary>
    public static string GetDaemonPipeName(string? overrideName = null)
    {
        var baseName = string.IsNullOrWhiteSpace(overrideName)
            ? Protocol.ProtocolConstants.DefaultPipeName
            : overrideName.Trim();

        // Keep pipe name simple and allowlist-safe.
        foreach (var c in baseName)
        {
            if (!(char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))
            {
                throw new ArgumentException("Invalid pipe name characters.", nameof(overrideName));
            }
        }

        return baseName;
    }
}
