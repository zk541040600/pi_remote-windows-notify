[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDir,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PiNotifyRouteHost'),
    [Parameter(Mandatory = $true)]
    [string]$ExtensionId,
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ExtensionId -notmatch '^[a-p]{32}$') {
    throw 'ExtensionId must be a 32-character Chromium extension id.'
}

$sourceExe = Join-Path $PublishDir 'PiNotifyRouteHost.exe'
if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
    throw "Published Route Host executable not found: $sourceExe"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Get-ChildItem -LiteralPath $PublishDir -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $InstallDir $_.Name) -Force
}

$exePath = Join-Path $InstallDir 'PiNotifyRouteHost.exe'
$hostName = 'io.pi.notify.route'
$manifestPath = Join-Path $InstallDir ($hostName + '.json')
$manifest = [ordered]@{
    name = $hostName
    description = 'Exact Pi Web notification route host'
    path = $exePath
    type = 'stdio'
    allowed_origins = @('chrome-extension://' + $ExtensionId + '/')
}
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 4),
    [System.Text.UTF8Encoding]::new($false))

foreach ($registryPath in @(
    "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$hostName",
    "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$hostName"
)) {
    New-Item -Path $registryPath -Force | Out-Null
    Set-Item -Path $registryPath -Value $manifestPath
}

# Launch at interactive user logon so the daemon has the same medium-integrity token
# as PiWebDesktop, browser Native Messaging, and the notification listener.
$launcherPath = Join-Path $InstallDir 'start-route-host.ps1'
$launcher = @"
`$ErrorActionPreference = 'Stop'
`$exePath = '$($exePath.Replace("'", "''"))'
`$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
`$startInfo.FileName = `$exePath
`$startInfo.Arguments = '--daemon'
`$startInfo.UseShellExecute = `$false
`$startInfo.CreateNoWindow = `$true
[void][System.Diagnostics.Process]::Start(`$startInfo)
"@
[System.IO.File]::WriteAllText($launcherPath, $launcher, [System.Text.UTF8Encoding]::new($false))

$runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runPath -Force | Out-Null
$runCommand = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $launcherPath
Set-ItemProperty -Path $runPath -Name 'PiNotifyRouteHost' -Value $runCommand
Unregister-ScheduledTask -TaskName 'PiNotifyRouteHost' -Confirm:$false -ErrorAction SilentlyContinue

if (-not $NoStart) {
    & powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $launcherPath

    $healthPath = Join-Path $env:TEMP ('pi-notify-route-health-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        $healthy = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $request = [ordered]@{
                protocolVersion = 1
                type = 'health'
                requestId = [Guid]::NewGuid().ToString('N')
                issuedAtMs = $now
                expiresAtMs = $now + 5000
            }
            [System.IO.File]::WriteAllText(
                $healthPath,
                ($request | ConvertTo-Json -Compress),
                [System.Text.UTF8Encoding]::new($false))
            try {
                $responseText = (& $exePath --client --json $healthPath 2>$null | Out-String).Trim()
                if (-not [string]::IsNullOrWhiteSpace($responseText)) {
                    $response = $responseText | ConvertFrom-Json
                    if ([string]$response.result -eq 'ok') {
                        $healthy = $true
                        break
                    }
                }
            }
            catch {
            }
            Start-Sleep -Milliseconds 150
        }
        if (-not $healthy) {
            throw 'Route Host daemon did not become healthy within 8 seconds.'
        }
    }
    finally {
        Remove-Item -LiteralPath $healthPath -Force -ErrorAction SilentlyContinue
    }
}

[pscustomobject]@{
    installed = $true
    installDir = $InstallDir
    nativeHostName = $hostName
    extensionId = $ExtensionId
    autostart = 'interactive-user-run-key'
    started = (-not $NoStart)
} | ConvertTo-Json -Compress
