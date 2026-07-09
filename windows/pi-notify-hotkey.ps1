[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Security

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs

$script:NotifyHotkeyLogPath = Join-Path (Get-NotifyBridgeLogDir) 'hotkey.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyHotkeyLogPath) | Out-Null

function Write-NotifyHotkeyLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyHotkeyLogPath -Value $line -Encoding UTF8
}

function Get-NotifyHotkeyFingerprint {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(([string]$Value).Trim()))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function Unprotect-NotifyHotkeyValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        $protected = [Convert]::FromBase64String($Value)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        Write-NotifyHotkeyLog -Message ('popup-state-unprotect-error "{0}"' -f $_.Exception.Message)
        return ''
    }
}

function Test-NotifyHotkeyCommandLineContainsPath {
    param(
        [string]$CommandLine,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $needle = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $start = 0
    while ($start -lt $CommandLine.Length) {
        $index = $CommandLine.IndexOf($needle, $start, [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { return $false }
        $end = $index + $needle.Length
        if ($end -ge $CommandLine.Length) { return $true }
        $next = [string]$CommandLine[$end]
        if ([char]::IsWhiteSpace($CommandLine[$end]) -or $next -eq '"' -or $next -eq "'" -or $next -eq '\' -or $next -eq '/') { return $true }
        $start = $index + 1
    }
    return $false
}

function Test-NotifyHotkeyPopupProcessOwned {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return $false }
    try {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop
        if ($null -eq $process) { return $false }
        $commandLine = [string]$process.CommandLine
        return (($commandLine -like '*pi-notify-popup.ps1*' -or $commandLine -like '*pi-notify-broker.ps1*') -and (Test-NotifyHotkeyCommandLineContainsPath -CommandLine $commandLine -Path $config.ConfigPath))
    }
    catch {
        return $false
    }
}

function Get-NotifyHotkeyLivePopupStates {
    $rows = @()
    $logDir = Get-NotifyBridgeLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { return @($rows) }

    $configFingerprint = Get-NotifyHotkeyFingerprint -Value $config.ConfigPath
    $nowTicks = [DateTime]::UtcNow.Ticks
    foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'popup-live.*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $state = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $pidValue = 0
            if (-not ($state.PSObject.Properties['processId']) -or -not [int]::TryParse([string]$state.processId, [ref]$pidValue)) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            $expiresAtTicks = [int64]0
            if ($state.PSObject.Properties['expiresAtTicks'] -and [int64]::TryParse([string]$state.expiresAtTicks, [ref]$expiresAtTicks) -and $expiresAtTicks -lt $nowTicks) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            if (-not (Test-NotifyHotkeyPopupProcessOwned -ProcessId $pidValue)) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            if ($state.PSObject.Properties['configFingerprint'] -and ([string]$state.configFingerprint) -ne $configFingerprint) {
                continue
            }

            $targetHost = if ($state.PSObject.Properties['protectedHost']) { Unprotect-NotifyHotkeyValue -Value ([string]$state.protectedHost) } else { '' }
            $cwdBase = if ($state.PSObject.Properties['protectedCwd']) { Unprotect-NotifyHotkeyValue -Value ([string]$state.protectedCwd) } else { '' }
            $tabTitle = if ($state.PSObject.Properties['protectedTab']) { Unprotect-NotifyHotkeyValue -Value ([string]$state.protectedTab) } else { '' }
            if ([string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle)) {
                continue
            }

            $startedAtTicks = [int64]$item.CreationTimeUtc.Ticks
            if ($state.PSObject.Properties['startedAtTicks']) {
                [int64]::TryParse([string]$state.startedAtTicks, [ref]$startedAtTicks) | Out-Null
            }
            $stackIndex = -1
            if ($state.PSObject.Properties['stackIndex']) {
                [int]::TryParse([string]$state.stackIndex, [ref]$stackIndex) | Out-Null
            }
            $targetFingerprint = if ($state.PSObject.Properties['targetFingerprint']) { [string]$state.targetFingerprint } else { Get-NotifyHotkeyFingerprint -Value $targetHost }
            $brokerManaged = $false
            if ($state.PSObject.Properties['brokerManaged']) { $brokerManaged = [bool]$state.brokerManaged }
            $popupId = if ($state.PSObject.Properties['popupId']) { [string]$state.popupId } else { '' }

            $rows += [pscustomobject]@{
                ProcessId         = $pidValue
                Path              = $item.FullName
                TargetHost        = $targetHost
                CwdBase           = $cwdBase
                TabTitle          = $tabTitle
                TargetFingerprint = $targetFingerprint
                StackIndex        = $stackIndex
                StartedAtTicks    = $startedAtTicks
                BrokerManaged     = $brokerManaged
                PopupId           = $popupId
            }
        }
        catch {
            Write-NotifyHotkeyLog -Message ('popup-state-read-error fileFingerprint={0} "{1}"' -f (Get-NotifyHotkeyFingerprint -Value $item.Name), $_.Exception.Message)
        }
    }

    return @($rows | Sort-Object StartedAtTicks, StackIndex, ProcessId)
}

function Start-NotifyHotkeyActivation {
    param(
        [Parameter(Mandatory = $true)]
        $PopupState
    )

    $activationScript = Join-Path (Get-NotifyBridgeBinDir) 'pi-notify-activate.ps1'
    if (-not (Test-Path -LiteralPath $activationScript)) {
        $activationScript = Join-Path $PSScriptRoot 'pi-notify-activate.ps1'
    }
    if (-not (Test-Path -LiteralPath $activationScript)) {
        Write-NotifyHotkeyLog -Message 'activate-missing-script'
        return $false
    }

    $arguments = Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $activationScript,
        '-ConfigPath', $config.ConfigPath
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-NotifyBridgePowerShellExe
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['PI_NOTIFY_FOCUS_TARGET'] = [string]$PopupState.TargetHost
    $startInfo.EnvironmentVariables['PI_NOTIFY_CWD_BASE'] = [string]$PopupState.CwdBase
    $startInfo.EnvironmentVariables['PI_NOTIFY_TAB_TITLE'] = [string]$PopupState.TabTitle

    $hasCwd = -not [string]::IsNullOrWhiteSpace([string]$PopupState.CwdBase)
    $hasTab = -not [string]::IsNullOrWhiteSpace([string]$PopupState.TabTitle)
    $brokerManaged = [bool]$PopupState.BrokerManaged
    Write-NotifyHotkeyLog -Message ('activate-oldest pid={0} targetFingerprint={1} hasCwd={2} hasTab={3} stackIndex={4} brokerManaged={5}' -f $PopupState.ProcessId, $PopupState.TargetFingerprint, $hasCwd, $hasTab, $PopupState.StackIndex, $brokerManaged)

    if ($brokerManaged) {
        $brokerCloseUrl = $null
        if ($config.PSObject.Properties['BrokerCloseUrl']) { $brokerCloseUrl = [string]$config.BrokerCloseUrl }
        elseif ($config.PSObject.Properties['BrokerPort']) {
            $brokerCloseUrl = ('http://127.0.0.1:{0}/close' -f [int]$config.BrokerPort)
        }
        if ([string]::IsNullOrWhiteSpace($brokerCloseUrl) -or [string]::IsNullOrWhiteSpace([string]$PopupState.PopupId)) {
            Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
            return $false
        }
        try {
            $closePayload = ('{{"popupId":"{0}","activate":true}}' -f ([string]$PopupState.PopupId))
            $closeBytes = [System.Text.Encoding]::UTF8.GetBytes($closePayload)
            $closeReq = [System.Net.HttpWebRequest]::Create($brokerCloseUrl)
            $closeReq.Method = 'POST'
            $closeReq.ContentType = 'application/json; charset=utf-8'
            $closeReq.ContentLength = $closeBytes.Length
            $closeReq.Timeout = 2000
            $closeReq.ReadWriteTimeout = 2000
            $closeStream = $closeReq.GetRequestStream()
            try { $closeStream.Write($closeBytes, 0, $closeBytes.Length) } finally { $closeStream.Close() }
            $closeResp = $closeReq.GetResponse()
            try { } finally { $closeResp.Close() }
            Write-NotifyHotkeyLog -Message ('broker-popup-activate-request popupId={0}' -f $PopupState.PopupId)
            return $true
        }
        catch {
            Write-NotifyHotkeyLog -Message ('broker-popup-activate-request-error popupId={0} "{1}"' -f $PopupState.PopupId, $_.Exception.Message)
            return $false
        }
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { return $false }

    $completed = $process.WaitForExit(8000)
    if (-not $completed) {
        Write-NotifyHotkeyLog -Message ('activate-timeout pid={0} activationPid={1}' -f $PopupState.ProcessId, $process.Id)
        return $false
    }

    if ($process.ExitCode -eq 0) {
        if ($brokerManaged) {
            # Broker-managed popups: do NOT kill the broker process; ask the broker to close this popup card.
            $brokerCloseUrl = $null
            if ($config.PSObject.Properties['BrokerCloseUrl']) { $brokerCloseUrl = [string]$config.BrokerCloseUrl }
            elseif ($config.PSObject.Properties['BrokerPort']) {
                $brokerCloseUrl = ('http://127.0.0.1:{0}/close' -f [int]$config.BrokerPort)
            }
            if (-not [string]::IsNullOrWhiteSpace($brokerCloseUrl) -and -not [string]::IsNullOrWhiteSpace([string]$PopupState.PopupId)) {
                try {
                    $closePayload = ('{{"popupId":"{0}"}}' -f ([string]$PopupState.PopupId))
                    $closeBytes = [System.Text.Encoding]::UTF8.GetBytes($closePayload)
                    $closeReq = [System.Net.HttpWebRequest]::Create($brokerCloseUrl)
                    $closeReq.Method = 'POST'
                    $closeReq.ContentType = 'application/json; charset=utf-8'
                    $closeReq.ContentLength = $closeBytes.Length
                    $closeReq.Timeout = 2000
                    $closeReq.ReadWriteTimeout = 2000
                    $closeStream = $closeReq.GetRequestStream()
                    try { $closeStream.Write($closeBytes, 0, $closeBytes.Length) } finally { $closeStream.Close() }
                    $closeResp = $closeReq.GetResponse()
                    try { } finally { $closeResp.Close() }
                    Write-NotifyHotkeyLog -Message ('broker-popup-close-after-activate popupId={0}' -f $PopupState.PopupId)
                }
                catch {
                    Write-NotifyHotkeyLog -Message ('broker-popup-close-after-activate-error popupId={0} "{1}"' -f $PopupState.PopupId, $_.Exception.Message)
                    # Fallback: remove the live-state file so the stale popup is not re-activated
                    Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            try {
                Stop-Process -Id ([int]$PopupState.ProcessId) -Force -ErrorAction Stop
                Remove-Item -LiteralPath ([string]$PopupState.Path) -Force -ErrorAction SilentlyContinue
                Write-NotifyHotkeyLog -Message ('popup-close-after-activate pid={0}' -f $PopupState.ProcessId)
            }
            catch {
                Write-NotifyHotkeyLog -Message ('popup-close-after-activate-error pid={0} "{1}"' -f $PopupState.ProcessId, $_.Exception.Message)
            }
        }
        return $true
    }

    Write-NotifyHotkeyLog -Message ('activate-failed pid={0} exitCode={1}' -f $PopupState.ProcessId, $process.ExitCode)
    return $false
}

function Invoke-NotifyHotkeyOldestPopup {
    $states = @(Get-NotifyHotkeyLivePopupStates)
    if ($states.Count -eq 0) {
        Write-NotifyHotkeyLog -Message 'hotkey-no-live-popups'
        return $false
    }

    return (Start-NotifyHotkeyActivation -PopupState $states[0])
}

if (Invoke-NotifyHotkeyOldestPopup) { exit 0 }
exit 1
