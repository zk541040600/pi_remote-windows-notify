using System.Buffers.Binary;
using System.Diagnostics;
using System.Runtime.InteropServices;
using PiNotifyRouteHost.Framing;
using PiNotifyRouteHost.Host;
using PiNotifyRouteHost.Protocol;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class NativeRelayProcessLivenessTests
{
    private const int WindowsAnonymousPipeBufferBytes = 4_096;
    private const string AllowedOrigin =
        "chrome-extension://abcdefghijklmnopqrstuvwxyzabcdef/";

    [Fact]
    public async Task Native_process_exits_zero_on_normal_stdin_eof()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var process = StartNativeProcess();
        try
        {
            process.StandardInput.Close();
            var exited = await WaitForExitAsync(
                process,
                TimeSpan.FromSeconds(3));

            Assert.True(exited, "native process did not stop on normal stdin EOF");
            Assert.Equal(0, process.ExitCode);
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
            }
        }
    }

    [Fact]
    public async Task Native_process_exits_nonzero_when_browser_stops_draining_stdout()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var process = StartNativeProcess();
        try
        {
            // Empty bodies produce immediate local rejects that nearly fill the
            // default 4 KiB Windows anonymous stdout pipe without blocking it.
            // The final prefix declares a valid-size body but leaves it
            // incomplete, so the relay reaches and blocks in a real
            // Console.OpenStandardInput ReadAsync before wake output stalls.
            // Keep both parent pipe ends open, but never drain stdout.
            var rejectFrameBytes = NativeMessageFraming.Encode(
                RouteResponse.Reject(
                        string.Empty,
                        RouteResults.Rejected,
                        RejectReasons.MissingField)
                    .ToUtf8Bytes()).Length;
            var completeRejects =
                WindowsAnonymousPipeBufferBytes / rejectFrameBytes;
            var input = new byte[
                (completeRejects + 1) *
                NativeMessageFraming.LengthPrefixBytes];
            BinaryPrimitives.WriteInt32LittleEndian(
                input.AsSpan(
                    completeRejects *
                    NativeMessageFraming.LengthPrefixBytes),
                ProtocolConstants.MaxNativeFrameBytes);
            var standardInput = process.StandardInput;
            await standardInput.BaseStream
                .WriteAsync(input)
                .AsTask()
                .WaitAsync(TimeSpan.FromSeconds(2));
            await standardInput.BaseStream.FlushAsync();
            await Task.Delay(TimeSpan.FromMilliseconds(200));
            Assert.False(
                process.HasExited,
                "native process exited instead of blocking on the incomplete stdin frame");

            var exited = await WaitForExitAsync(
                process,
                TimeSpan.FromMilliseconds(
                    ProtocolConstants.NativeStdoutWriteTimeoutMs + 3_000));

            Assert.True(
                exited,
                "native process remained blocked after its stdout write timeout");
            Assert.NotEqual(0, process.ExitCode);
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
            }
        }
    }

    private static Process StartNativeProcess()
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = ResolveDotnetHost(),
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add(typeof(NativeMessagingRelay).Assembly.Location);
        startInfo.ArgumentList.Add("--native");
        startInfo.ArgumentList.Add("--allowed-origin");
        startInfo.ArgumentList.Add(AllowedOrigin);
        startInfo.ArgumentList.Add(AllowedOrigin);

        return Process.Start(startInfo)
            ?? throw new InvalidOperationException("failed to start native relay");
    }

    private static string ResolveDotnetHost()
    {
        var configured = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
        if (!string.IsNullOrWhiteSpace(configured) &&
            File.Exists(configured))
        {
            return configured;
        }

        var hostName = OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        var runtimeDirectory = RuntimeEnvironment.GetRuntimeDirectory();
        var candidate = Path.GetFullPath(
            Path.Combine(runtimeDirectory, "..", "..", "..", hostName));
        return File.Exists(candidate)
            ? candidate
            : throw new FileNotFoundException(
                "Unable to locate the dotnet host",
                candidate);
    }

    private static async Task<bool> WaitForExitAsync(
        Process process,
        TimeSpan timeout)
    {
        try
        {
            await process.WaitForExitAsync().WaitAsync(timeout);
            return true;
        }
        catch (TimeoutException)
        {
            return false;
        }
    }
}
