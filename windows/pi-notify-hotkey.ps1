[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Security

if (-not ([System.Management.Automation.PSTypeName]'PiNotifyHotkeyNative').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class PiNotifyHotkeyNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public UInt32 message;
        public IntPtr wParam;
        public IntPtr lParam;
        public UInt32 time;
        public POINT pt;
    }

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, UInt32 fsModifiers, UInt32 vk);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern sbyte GetMessage(out MSG lpMsg, IntPtr hWnd, UInt32 wMsgFilterMin, UInt32 wMsgFilterMax);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);
}
"@
}

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs

$script:NotifyHotkeyLogPath = Join-Path (Get-NotifyBridgeLogDir) 'hotkey.log'
try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyHotkeyLogPath) | Out-Null } catch {}

function Write-NotifyHotkeyLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
        Add-Content -LiteralPath $script:NotifyHotkeyLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Diagnostic I/O must not interrupt notification delivery or a UI callback.
    }
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

function Test-NotifyHotkeyCommandLineContainsPath {
    param([string]$CommandLine, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    # Inspect the actual config argument; another option's value or a child path is not ownership.
    $arguments = @([regex]::Matches($CommandLine, '(?:"[^"]*"|[^\s"]+)+') | ForEach-Object { $_.Value.Replace('"', '') })
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        $argument = ''
        if ($arguments[$i] -ieq '-ConfigPath' -and ($i + 1) -lt $arguments.Count) { $argument = $arguments[$i + 1] }
        elseif ($arguments[$i].StartsWith('-ConfigPath:', [System.StringComparison]::OrdinalIgnoreCase)) { $argument = $arguments[$i].Substring(12) }
        else { continue }
        try {
            if (-not [System.IO.Path]::IsPathRooted($argument)) { return $false }
            return [System.IO.Path]::GetFullPath($argument).Equals([System.IO.Path]::GetFullPath($Path), [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch { return $false }
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
    $ownedProcesses = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'popup-live.*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $state = Read-NotifyPopupLiveJson -Path $item.FullName
            # Configurations can share a log directory; leave another instance's state alone.
            if ($state.PSObject.Properties['configFingerprint'] -and ([string]$state.configFingerprint) -ne $configFingerprint) {
                continue
            }
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

            # Several broker cards share one process. Recheck ownership on each hotkey press.
            if (-not $ownedProcesses.ContainsKey($pidValue)) {
                $ownedProcesses[$pidValue] = Test-NotifyHotkeyPopupProcessOwned -ProcessId $pidValue
            }
            if (-not $ownedProcesses[$pidValue]) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            $brokerManaged = $false
            if ($state.PSObject.Properties['brokerManaged']) { $brokerManaged = [bool]$state.brokerManaged }
            $activationKey = if ($state.PSObject.Properties['activationKey']) { [string]$state.activationKey } else { '' }
            if (-not $brokerManaged -and [string]::IsNullOrWhiteSpace((Get-NotifyPopupActivationEventName -ProcessId $pidValue -ActivationKey $activationKey))) {
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
            $targetFingerprint = if ($state.PSObject.Properties['targetFingerprint']) { [string]$state.targetFingerprint } else { '' }
            $popupId = if ($state.PSObject.Properties['popupId']) { [string]$state.popupId } else { '' }

            $rows += [pscustomobject]@{
                ProcessId         = $pidValue
                Path              = $item.FullName
                ActivationKey     = $activationKey
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
    param([Parameter(Mandatory = $true)]$PopupState)

    if ([bool]$PopupState.BrokerManaged) {
        if ([string]::IsNullOrWhiteSpace([string]$PopupState.PopupId)) { return $false }
        $payload = @{ popupId = [string]$PopupState.PopupId; activate = $true } | ConvertTo-Json -Compress
        $accepted = Send-NotifyHotkeyBrokerPost -Path '/close' -Body $payload
        if ($accepted) { Write-NotifyHotkeyLog -Message ('broker-popup-activate-request popupId={0}' -f $PopupState.PopupId) }
        return $accepted
    }

    # Reuse the popup's click handler, including origin, expiry, retry and final-proof checks.
    $activationKey = if ($PopupState.PSObject.Properties['ActivationKey']) { [string]$PopupState.ActivationKey } else { '' }
    $eventName = Get-NotifyPopupActivationEventName -ProcessId ([int]$PopupState.ProcessId) -ActivationKey $activationKey
    if ([string]::IsNullOrWhiteSpace($eventName) -or -not (Test-NotifyHotkeyPopupProcessOwned -ProcessId ([int]$PopupState.ProcessId))) { return $false }
    $signal = $null
    try {
        $signal = [System.Threading.EventWaitHandle]::OpenExisting($eventName)
        [void]$signal.Set()
        Write-NotifyHotkeyLog -Message ('popup-activate-signal pid={0}' -f $PopupState.ProcessId)
        return $true
    }
    catch {
        Write-NotifyHotkeyLog -Message ('popup-activate-signal-unavailable pid={0}' -f $PopupState.ProcessId)
        return $false
    }
    finally {
        if ($null -ne $signal) { $signal.Dispose() }
    }
}

function Send-NotifyHotkeyBrokerPost {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Body = '{}',
        [int]$TimeoutMs = 700
    )

    if (-not $config.PSObject.Properties['BrokerPort']) { return $false }
    $port = [int]$config.BrokerPort
    $client = [System.Net.Sockets.TcpClient]::new()
    $connectHandle = $null
    $requestWritten = $false
    $budgetMs = [Math]::Max(1, $TimeoutMs)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connectResult = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        $connectHandle = $connectResult.AsyncWaitHandle
        if (-not $connectHandle.WaitOne($budgetMs)) { throw 'broker connect timeout.' }
        $client.EndConnect($connectResult)
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $requestHead = "POST $Path HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestHead)
        $stream = $client.GetStream()
        foreach ($bytes in @($requestBytes, $bodyBytes)) {
            $remainingMs = $budgetMs - [int]$clock.ElapsedMilliseconds
            if ($remainingMs -le 0) { throw 'broker write timeout.' }
            $client.SendTimeout = $remainingMs
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $requestWritten = $true
        $stream.Flush()
        $responseText = ''
        $buffer = [byte[]]::new(256)
        while ($responseText.Length -lt $buffer.Length) {
            $remainingMs = $budgetMs - [int]$clock.ElapsedMilliseconds
            if ($remainingMs -le 0) { break }
            $client.ReceiveTimeout = $remainingMs
            $read = $stream.Read($buffer, 0, ($buffer.Length - $responseText.Length))
            if ($read -le 0) { break }
            $responseText += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            $lineEnd = $responseText.IndexOf("`n")
            if ($lineEnd -ge 0) {
                $firstLine = $responseText.Substring(0, $lineEnd).TrimEnd([char]13)
                if ($firstLine -match '^HTTP/1\.[01] ([0-9]{3})(?: |$)') { return ([int]$Matches[1] -eq 200) }
                break
            }
        }
        # The broker may already be activating this card. Do not select another on an ambiguous reply.
        Write-NotifyHotkeyLog -Message ('broker-post-response-unconfirmed bytes={0}' -f $responseText.Length)
        return $true
    }
    catch {
        Write-NotifyHotkeyLog -Message ('broker-post-error requestWritten={0} "{1}"' -f $requestWritten, $_.Exception.Message)
        return $requestWritten
    }
    finally {
        if ($null -ne $connectHandle) { try { $connectHandle.Close() } catch {} }
        try { $client.Close() } catch {}
    }
}

function Invoke-NotifyHotkeyBrokerActivateOldest {
    try {
        if (-not (Send-NotifyHotkeyBrokerPost -Path '/activate-oldest')) { return $false }
        Write-NotifyHotkeyLog -Message 'broker-activate-oldest-request'
        return $true
    }
    catch {
        Write-NotifyHotkeyLog -Message ('broker-activate-oldest-fallback "{0}"' -f $_.Exception.Message)
        return $false
    }
}

function Invoke-NotifyHotkeyOldestPopup {
    foreach ($state in @(Get-NotifyHotkeyLivePopupStates)) {
        if (Start-NotifyHotkeyActivation -PopupState $state) { return $true }
    }

    # Live-state writing is best effort; the broker can still know about an unlisted card.
    return (Invoke-NotifyHotkeyBrokerActivateOldest)
}

function ConvertTo-NotifyHotkeyRegistration {
    param([string]$HotkeyValue)

    $value = if ([string]::IsNullOrWhiteSpace($HotkeyValue)) { 'Alt+L' } else { [string]$HotkeyValue }
    $parts = @($value -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -lt 2) {
        throw ('Invalid popupHotkey "{0}". Use Alt+L, Ctrl+{{, Alt+P, Ctrl+P, Ctrl+Alt+P, Shift+F8, or Win+P style syntax.' -f $value)
    }

    $baseModifiers = [uint32]0x4000 # MOD_NOREPEAT
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        switch -Regex ($parts[$i].ToLowerInvariant()) {
            '^(ctrl|control)$' { $baseModifiers = $baseModifiers -bor [uint32]0x0002; continue }
            '^alt$' { $baseModifiers = $baseModifiers -bor [uint32]0x0001; continue }
            '^shift$' { $baseModifiers = $baseModifiers -bor [uint32]0x0004; continue }
            '^(win|windows|meta)$' { $baseModifiers = $baseModifiers -bor [uint32]0x0008; continue }
            default { throw ('Unsupported popupHotkey modifier "{0}" in "{1}".' -f $parts[$i], $value) }
        }
    }

    $key = $parts[$parts.Count - 1].ToUpperInvariant()
    $virtualKey = [uint32]0
    $requiresShift = $false
    $unshiftedLabel = ''
    if ($key.Length -eq 1) {
        $ch = [char]$key[0]
        if ((($ch -ge [char]'A') -and ($ch -le [char]'Z')) -or (($ch -ge [char]'0') -and ($ch -le [char]'9'))) {
            $virtualKey = [uint32][byte][char]$ch
        }
        else {
            switch ($key) {
                '[' { $virtualKey = [uint32]0xDB; break }
                '{' { $virtualKey = [uint32]0xDB; $requiresShift = $true; $unshiftedLabel = '['; break }
                ']' { $virtualKey = [uint32]0xDD; break }
                '}' { $virtualKey = [uint32]0xDD; $requiresShift = $true; $unshiftedLabel = ']'; break }
                '\' { $virtualKey = [uint32]0xDC; break }
                '|' { $virtualKey = [uint32]0xDC; $requiresShift = $true; $unshiftedLabel = '\'; break }
                ';' { $virtualKey = [uint32]0xBA; break }
                ':' { $virtualKey = [uint32]0xBA; $requiresShift = $true; $unshiftedLabel = ';'; break }
                "'" { $virtualKey = [uint32]0xDE; break }
                '"' { $virtualKey = [uint32]0xDE; $requiresShift = $true; $unshiftedLabel = "'"; break }
                ',' { $virtualKey = [uint32]0xBC; break }
                '<' { $virtualKey = [uint32]0xBC; $requiresShift = $true; $unshiftedLabel = ','; break }
                '.' { $virtualKey = [uint32]0xBE; break }
                '>' { $virtualKey = [uint32]0xBE; $requiresShift = $true; $unshiftedLabel = '.'; break }
                '/' { $virtualKey = [uint32]0xBF; break }
                '?' { $virtualKey = [uint32]0xBF; $requiresShift = $true; $unshiftedLabel = '/'; break }
                '`' { $virtualKey = [uint32]0xC0; break }
                '~' { $virtualKey = [uint32]0xC0; $requiresShift = $true; $unshiftedLabel = '`'; break }
                '-' { $virtualKey = [uint32]0xBD; break }
                '_' { $virtualKey = [uint32]0xBD; $requiresShift = $true; $unshiftedLabel = '-'; break }
                '=' { $virtualKey = [uint32]0xBB; break }
                '+' { $virtualKey = [uint32]0xBB; $requiresShift = $true; $unshiftedLabel = '='; break }
            }
        }
    }
    elseif ($key -match '^F([1-9]|1[0-9]|2[0-4])$') {
        $virtualKey = [uint32](0x70 + [int]$Matches[1] - 1)
    }
    if ($virtualKey -eq 0) {
        throw ('Unsupported popupHotkey key "{0}" in "{1}".' -f $key, $value)
    }
    if (($baseModifiers -band 0x000F) -eq 0) {
        throw ('popupHotkey must include at least one modifier: {0}' -f $value)
    }

    $registrations = New-Object System.Collections.Generic.List[object]
    $primaryModifiers = $baseModifiers
    if ($requiresShift) {
        $primaryModifiers = $primaryModifiers -bor [uint32]0x0004
    }
    $registrations.Add([pscustomobject]@{
        Label      = ($parts -join '+')
        Modifiers  = $primaryModifiers
        VirtualKey = $virtualKey
        Primary    = $true
    }) | Out-Null

    if ($requiresShift -and (($baseModifiers -band 0x0004) -eq 0) -and -not [string]::IsNullOrWhiteSpace($unshiftedLabel)) {
        $alternateParts = @($parts)
        $alternateParts[$alternateParts.Count - 1] = $unshiftedLabel
        $registrations.Add([pscustomobject]@{
            Label      = ($alternateParts -join '+')
            Modifiers  = $baseModifiers
            VirtualKey = $virtualKey
            Primary    = $false
        }) | Out-Null
    }

    return @($registrations.ToArray())
}

function Start-NotifyHotkeyResident {
    if ($config.PSObject.Properties['PopupHotkeyEnabled'] -and -not [bool]$config.PopupHotkeyEnabled) {
        Write-NotifyHotkeyLog -Message 'resident-disabled'
        return 0
    }

    $registrations = @(ConvertTo-NotifyHotkeyRegistration -HotkeyValue ([string]$config.PopupHotkey))
    $hotkeyLabels = (@($registrations | ForEach-Object { $_.Label }) -join ',')
    $mutexName = 'Local\PiNotifyHotkey-{0}' -f (Get-NotifyHotkeyFingerprint -Value $config.ConfigPath)
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-NotifyHotkeyLog -Message ('resident-existing hotkey={0}' -f $hotkeyLabels)
        return 0
    }

    $registeredIds = New-Object System.Collections.Generic.List[int]
    $idToLabel = @{}
    try {
        for ($i = 0; $i -lt $registrations.Count; $i++) {
            $registration = $registrations[$i]
            $id = 0x5050 + $i
            $registered = [PiNotifyHotkeyNative]::RegisterHotKey([IntPtr]::Zero, $id, [uint32]$registration.Modifiers, [uint32]$registration.VirtualKey)
            if (-not $registered) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-NotifyHotkeyLog -Message ('resident-register-failed hotkey={0} error={1}' -f $registration.Label, $errorCode)
                if ([bool]$registration.Primary) { return 1 }
                continue
            }
            $registeredIds.Add($id) | Out-Null
            $idToLabel[[string]$id] = [string]$registration.Label
            Write-NotifyHotkeyLog -Message ('resident-register hotkey={0} modifiers=0x{1:x} vk=0x{2:x} id={3}' -f $registration.Label, [uint32]$registration.Modifiers, [uint32]$registration.VirtualKey, $id)
        }
        if ($registeredIds.Count -eq 0) { return 1 }
        Write-NotifyHotkeyLog -Message ('resident-start hotkey={0}' -f $hotkeyLabels)
        $lastHotkeyAtTicks = [int64]0
        $debounceTicks = [TimeSpan]::FromMilliseconds(1000).Ticks
        $msg = [PiNotifyHotkeyNative+MSG]::new()
        while ($true) {
            $result = [PiNotifyHotkeyNative]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)
            if ($result -eq 0) { break }
            if ($result -lt 0) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-NotifyHotkeyLog -Message ('resident-getmessage-error error={0}' -f $errorCode)
                return 1
            }
            $messageId = $msg.wParam.ToInt32()
            if ($msg.message -eq 0x0312 -and $registeredIds.Contains($messageId)) {
                $nowTicks = [DateTime]::UtcNow.Ticks
                if ($lastHotkeyAtTicks -gt 0 -and ($nowTicks - $lastHotkeyAtTicks) -lt $debounceTicks) {
                    Write-NotifyHotkeyLog -Message ('resident-debounce hotkey={0}' -f $idToLabel[[string]$messageId])
                }
                else {
                    $lastHotkeyAtTicks = $nowTicks
                    try {
                        Write-NotifyHotkeyLog -Message ('resident-fired hotkey={0}' -f $idToLabel[[string]$messageId])
                        [void](Invoke-NotifyHotkeyOldestPopup)
                    }
                    catch {
                        Write-NotifyHotkeyLog -Message ('resident-activate-error "{0}"' -f $_.Exception.Message)
                    }
                }
            }
            [void][PiNotifyHotkeyNative]::TranslateMessage([ref]$msg)
            [void][PiNotifyHotkeyNative]::DispatchMessage([ref]$msg)
        }
        return 0
    }
    finally {
        foreach ($registeredId in @($registeredIds.ToArray())) { [void][PiNotifyHotkeyNative]::UnregisterHotKey([IntPtr]::Zero, $registeredId) }
        if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
        Write-NotifyHotkeyLog -Message ('resident-stop hotkey={0}' -f $hotkeyLabels)
    }
}

if ($Once) {
    if (Invoke-NotifyHotkeyOldestPopup) { exit 0 }
    exit 1
}

exit (Start-NotifyHotkeyResident)
