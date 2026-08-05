namespace PiNotifyRouteHost.Host;

public static class PipeNames
{
    private const string SessionLocalPrefix = @"LOCAL\";

    /// <summary>
    /// Current-user scoped named pipe base. On Windows the OS isolates Local\\ pipes per session;
    /// we still embed a stable product name only (no secrets).
    /// </summary>
    public static string GetDaemonPipeName(string? overrideName = null)
    {
        var baseName = string.IsNullOrWhiteSpace(overrideName)
            ? Protocol.ProtocolConstants.DefaultPipeName
            : overrideName.Trim();

        var isSessionLocal = baseName.StartsWith(
            SessionLocalPrefix,
            StringComparison.OrdinalIgnoreCase);
        var simpleName = isSessionLocal
            ? baseName[SessionLocalPrefix.Length..]
            : baseName;
        if (simpleName.Length == 0)
        {
            throw new ArgumentException(
                "Pipe name must not be empty.",
                nameof(overrideName));
        }

        // Allow only the Windows login-session prefix plus one simple name.
        foreach (var c in simpleName)
        {
            if (!(char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))
            {
                throw new ArgumentException("Invalid pipe name characters.", nameof(overrideName));
            }
        }

        return isSessionLocal
            ? SessionLocalPrefix + simpleName
            : simpleName;
    }
}
