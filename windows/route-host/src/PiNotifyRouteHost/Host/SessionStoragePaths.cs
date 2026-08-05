using System.Diagnostics;
using PiNotifyRouteHost.Logging;

namespace PiNotifyRouteHost.Host;

/// <summary>
/// Keeps durable daemon state inside the same Windows login-session boundary
/// as the default LOCAL\ named pipe.
/// </summary>
public static class SessionStoragePaths
{
    private const string ProductDirectoryName = "PiNotifyRouteHost";
    private const string BindingFileName = "route-preferences.json";
    private const string MigrationLockFileName =
        "route-preferences.session-migration.lock";
    private const string MigrationMarkerFileName =
        "route-preferences.session-migration";

    public static string GetDefaultBindingStatePath()
    {
        return GetDefaultBindingStatePath(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            Process.GetCurrentProcess().SessionId);
    }

    public static string GetDefaultBindingStatePath(
        string localApplicationData,
        int sessionId)
    {
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new ArgumentException(
                "Local application data path is required.",
                nameof(localApplicationData));
        }
        if (sessionId < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sessionId));
        }

        return Path.Combine(
            Path.GetFullPath(localApplicationData),
            ProductDirectoryName,
            "sessions",
            $"session-{sessionId}",
            BindingFileName);
    }

    public static string GetLegacyBindingStatePath(
        string? localApplicationData = null)
    {
        var root = string.IsNullOrWhiteSpace(localApplicationData)
            ? Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData)
            : localApplicationData;
        return Path.Combine(
            Path.GetFullPath(root),
            ProductDirectoryName,
            BindingFileName);
    }

    /// <summary>
    /// The first upgraded login session claims a copy of the legacy user-global
    /// document. The source remains available to a rolled-back old binary.
    /// </summary>
    public static bool TryClaimLegacyBindingState(
        string legacyPath,
        string sessionPath)
    {
        var legacyFullPath = Path.GetFullPath(legacyPath);
        var sessionFullPath = Path.GetFullPath(sessionPath);
        if (string.Equals(
                legacyFullPath,
                sessionFullPath,
                StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string? sessionTemporaryPath = null;
        string? markerTemporaryPath = null;
        var createdSessionState = false;
        try
        {
            var productDirectory =
                Path.GetDirectoryName(legacyFullPath);
            var sessionDirectory =
                Path.GetDirectoryName(sessionFullPath);
            if (string.IsNullOrEmpty(productDirectory) ||
                string.IsNullOrEmpty(sessionDirectory))
            {
                return false;
            }

            Directory.CreateDirectory(productDirectory);
            var lockPath = Path.Combine(
                productDirectory,
                MigrationLockFileName);
            using var migrationLock = new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None);
            var markerPath = Path.Combine(
                productDirectory,
                MigrationMarkerFileName);
            if (File.Exists(markerPath))
            {
                var claimedSessionDirectoryName =
                    File.ReadAllText(markerPath);
                var currentSessionDirectoryName =
                    Path.GetFileName(sessionDirectory);
                if (!string.Equals(
                        claimedSessionDirectoryName,
                        currentSessionDirectoryName,
                        StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
            }
            else
            {
                if (!File.Exists(legacyFullPath))
                {
                    return false;
                }

                // The marker is the durable claim. Publish it before copying
                // so a crash can only be resumed by this login session.
                WriteMigrationMarker(
                    markerPath,
                    sessionFullPath,
                    ref markerTemporaryPath);
            }

            if (!File.Exists(legacyFullPath))
            {
                return false;
            }

            if (File.Exists(sessionFullPath))
            {
                return false;
            }

            Directory.CreateDirectory(sessionDirectory);
            sessionTemporaryPath =
                sessionFullPath + ".migration-" +
                Guid.NewGuid().ToString("N");
            File.Copy(
                legacyFullPath,
                sessionTemporaryPath,
                overwrite: false);
            File.Move(
                sessionTemporaryPath,
                sessionFullPath);
            sessionTemporaryPath = null;
            createdSessionState = true;
            return true;
        }
        catch (Exception exception)
            when (exception is IOException or
                UnauthorizedAccessException)
        {
            if (createdSessionState)
            {
                DeleteTemporaryFile(sessionFullPath);
            }
            SafeLog.Warn(
                "route-binding-migration-skipped",
                ("reason", exception.GetType().Name));
            return false;
        }
        finally
        {
            DeleteTemporaryFile(sessionTemporaryPath);
            DeleteTemporaryFile(markerTemporaryPath);
        }
    }

    private static void WriteMigrationMarker(
        string markerPath,
        string sessionPath,
        ref string? temporaryPath)
    {
        temporaryPath =
            markerPath + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(
            temporaryPath,
            Path.GetFileName(
                Path.GetDirectoryName(sessionPath)));
        File.Move(temporaryPath, markerPath);
        temporaryPath = null;
    }

    private static void DeleteTemporaryFile(string? path)
    {
        if (path is null)
        {
            return;
        }

        try
        {
            File.Delete(path);
        }
        catch (Exception exception)
            when (exception is IOException or
                UnauthorizedAccessException)
        {
            SafeLog.Warn(
                "route-binding-migration-cleanup-failed",
                ("reason", exception.GetType().Name));
        }
    }
}
