[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Uri,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Security

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PiNotifyUser32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs
$script:NotifyActivateLogPath = Join-Path (Get-NotifyBridgeLogDir) 'activate.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyActivateLogPath) | Out-Null

function Write-NotifyActivateLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyActivateLogPath -Value $line -Encoding UTF8
}

function Get-NotifyActivateFingerprint {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Value))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Get-NotifyQueryValue {
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$ParsedUri,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $query = $ParsedUri.Query.TrimStart('?')
    if ([string]::IsNullOrWhiteSpace($query)) {
        return ''
    }

    foreach ($pair in $query -split '&') {
        if ([string]::IsNullOrWhiteSpace($pair)) {
            continue
        }

        $parts = $pair -split '=', 2
        $rawKey = if ($parts.Length -gt 0) { [string]$parts[0] } else { '' }
        $key = [Uri]::UnescapeDataString($rawKey.Replace('+', ' '))
        if ($key -ne $Name) {
            continue
        }

        if ($parts.Length -lt 2) {
            return ''
        }

        return [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
    }

    return ''
}

function Unprotect-NotifyActivationValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Resolve-NotifyActivationState {
    param([string]$ActivationId)
    if ([string]::IsNullOrWhiteSpace($ActivationId) -or $ActivationId -notmatch '^[0-9a-fA-F]{32}$') { return $null }
    $paths = @(
        (Join-Path (Get-NotifyBridgeLogDir) ('activation-{0}.json' -f $ActivationId)),
        (Join-Path (Join-Path (Get-NotifyBridgeDefaultBaseDir) 'logs') ('activation-{0}.json' -f $ActivationId))
    ) | Select-Object -Unique
    $path = @($paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if (@($path).Count -eq 0) { return $null }
    $path = [string]$path[0]
    try {
        $payload = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        foreach ($candidate in $paths) { Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue }
        $expiresAtTicks = [int64]0
        if ($payload.PSObject.Properties['expiresAtTicks']) { [int64]::TryParse([string]$payload.expiresAtTicks, [ref]$expiresAtTicks) | Out-Null }
        if ($expiresAtTicks -le [DateTime]::UtcNow.Ticks) { return $null }
        return [pscustomobject]@{
            FocusTarget = if ($payload.PSObject.Properties['protectedHost']) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedHost) } else { '' }
            CwdBase     = if ($payload.PSObject.Properties['protectedCwd']) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedCwd) } else { '' }
            TabTitle    = if ($payload.PSObject.Properties['protectedTab']) { Unprotect-NotifyActivationValue -Value ([string]$payload.protectedTab) } else { '' }
        }
    }
    catch {
        Write-NotifyActivateLog -Message ('activation-cache-read-error "{0}"' -f $_.Exception.Message)
        return $null
    }
}

function Get-CandidateWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PiNotifyUser32+EnumWindowsProc]{
        param([IntPtr]$Handle, [IntPtr]$LParam)

        if (-not [PiNotifyUser32]::IsWindowVisible($Handle)) {
            return $true
        }

        $length = [PiNotifyUser32]::GetWindowTextLength($Handle)
        if ($length -le 0) {
            return $true
        }

        $builder = New-Object System.Text.StringBuilder ($length + 1)
        [void][PiNotifyUser32]::GetWindowText($Handle, $builder, $builder.Capacity)
        $title = $builder.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $processId = [uint32]0
        [void][PiNotifyUser32]::GetWindowThreadProcessId($Handle, [ref]$processId)
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        if ($process.ProcessName -notmatch 'WindowsTerminal|Terminal') {
            return $true
        }

        $windows.Add([pscustomobject]@{
            Handle      = $Handle
            Title       = $title
            ProcessId   = $process.Id
            ProcessName = $process.ProcessName
        })
        return $true
    }

    [void][PiNotifyUser32]::EnumWindows($callback, [IntPtr]::Zero)
    return $windows
}

function Get-NotifyWindowTabs {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
        if ($null -eq $root) {
            return $rows
        }

        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem
        )
        $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($tab in $tabs) {
            $rows.Add([pscustomobject]@{
                Name    = [string]$tab.Current.Name
                Element = $tab
            }) | Out-Null
        }
    }
    catch {
    }

    return $rows
}

function Select-NotifyTab {
    param(
        [Parameter(Mandatory = $true)]
        $TabElement
    )

    try {
        $patternObj = $null
        if ($TabElement.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObj)) {
            ([System.Windows.Automation.SelectionItemPattern]$patternObj).Select()
            return $true
        }
    }
    catch {
    }

    try {
        $patternObj = $null
        if ($TabElement.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObj)) {
            ([System.Windows.Automation.InvokePattern]$patternObj).Invoke()
            return $true
        }
    }
    catch {
    }

    return $false
}

function Focus-NotifyWindow {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Keywords,
        [string]$RequiredText
    )

    $normalized = @($Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $required = if ([string]::IsNullOrWhiteSpace($RequiredText)) { '' } else { $RequiredText.Trim() }
    $windows = Get-CandidateWindows

    $best = $null
    $eligibleCount = 0
    foreach ($window in $windows) {
        $baseScore = 0
        foreach ($keyword in $normalized) {
            if ($window.Title.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $baseScore += 20
            }
        }

        $tabs = @(Get-NotifyWindowTabs -Handle $window.Handle)
        if ($tabs.Count -eq 0) {
            if ([string]::IsNullOrWhiteSpace($required) -and $baseScore -gt 0) {
                $candidate = [pscustomobject]@{
                    Window   = $window
                    Score    = $baseScore
                    TabName  = ''
                    TabFound = $false
                    Tab      = $null
                }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                    $best = $candidate
                }
            }
            continue
        }

        foreach ($tab in $tabs) {
            if (-not [string]::IsNullOrWhiteSpace($required) -and ([string]::IsNullOrWhiteSpace($tab.Name) -or $tab.Name.IndexOf($required, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
                Write-NotifyActivateLog -Message ('focus-tab-skip-required tabFingerprint="{0}" requiredFingerprint="{1}"' -f (Get-NotifyActivateFingerprint $tab.Name), (Get-NotifyActivateFingerprint $required))
                continue
            }

            $score = $baseScore
            foreach ($keyword in $normalized) {
                if (-not [string]::IsNullOrWhiteSpace($tab.Name) -and $tab.Name.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $score += 120
                }
            }
            if ($score -le 0) {
                continue
            }

            $eligibleCount += 1
            $candidate = [pscustomobject]@{
                Window   = $window
                Score    = $score
                TabName  = $tab.Name
                TabFound = $true
                Tab      = $tab.Element
            }
            if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                $best = $candidate
            }
        }
    }

    if ($eligibleCount -gt 1) {
        Write-NotifyActivateLog -Message ('focus-ambiguous candidateCount={0} bestScore={1} requiredFingerprint="{2}"' -f $eligibleCount, $best.Score, (Get-NotifyActivateFingerprint $required))
        return $false
    }

    if ($null -eq $best) {
        Write-NotifyActivateLog -Message 'focus-no-candidate'
        return $false
    }

    Write-NotifyActivateLog -Message ('focus-best windowFingerprint="{0}" tabFingerprint="{1}" score={2}' -f (Get-NotifyActivateFingerprint $best.Window.Title), (Get-NotifyActivateFingerprint $best.TabName), $best.Score)

    if ([PiNotifyUser32]::IsIconic($best.Window.Handle)) {
        [void][PiNotifyUser32]::ShowWindowAsync($best.Window.Handle, 9)
        Write-NotifyActivateLog -Message 'focus-restore-iconic'
        Start-Sleep -Milliseconds 180
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.AppActivate($best.Window.ProcessId)
    }
    catch {
    }
    Start-Sleep -Milliseconds 150
    [void][PiNotifyUser32]::SetForegroundWindow($best.Window.Handle)
    Start-Sleep -Milliseconds 120

    if ($best.TabFound -and $null -ne $best.Tab) {
        if (Select-NotifyTab -TabElement $best.Tab) {
            $scrolledToBottom = Set-NotifyBridgeTerminalScrollToBottom -WindowHandle $best.Window.Handle
            Write-NotifyActivateLog -Message ('focus-tab-selected tabFingerprint="{0}" scrolledToBottom={1}' -f (Get-NotifyActivateFingerprint $best.TabName), $scrolledToBottom)
            Start-Sleep -Milliseconds 150
            [void][PiNotifyUser32]::SetForegroundWindow($best.Window.Handle)
            return $true
        }
        Write-NotifyActivateLog -Message ('focus-tab-select-failed tabFingerprint="{0}"' -f (Get-NotifyActivateFingerprint $best.TabName))
    }

    return $true
}

Write-NotifyActivateLog -Message ('activate-start hasUri={0}' -f (-not [string]::IsNullOrWhiteSpace($Uri)))

$targetHost = $config.RemoteHostAlias
$cwdBase = ''
$tabTitle = ''
if (-not [string]::IsNullOrWhiteSpace($Uri)) {
    try {
        $parsedUri = [Uri]$Uri
        $activationIdValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'id'
        $state = Resolve-NotifyActivationState -ActivationId $activationIdValue
        if ($null -ne $state) {
            if (-not [string]::IsNullOrWhiteSpace($state.FocusTarget)) { $targetHost = ([string]$state.FocusTarget).Trim() }
            if (-not [string]::IsNullOrWhiteSpace($state.CwdBase)) { $cwdBase = ([string]$state.CwdBase).Trim() }
            if (-not [string]::IsNullOrWhiteSpace($state.TabTitle)) { $tabTitle = ([string]$state.TabTitle).Trim() }
        }
        else {
            $hostValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'host'
            $cwdBaseValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'cwdBase'
            $tabTitleValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'tabTitle'
            if (-not [string]::IsNullOrWhiteSpace($hostValue)) { $targetHost = $hostValue.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($cwdBaseValue)) { $cwdBase = $cwdBaseValue.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($tabTitleValue)) { $tabTitle = $tabTitleValue.Trim() }
        }
    }
    catch {
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_FOCUS_TARGET)) { $targetHost = $env:PI_NOTIFY_FOCUS_TARGET.Trim() }
if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_CWD_BASE)) { $cwdBase = $env:PI_NOTIFY_CWD_BASE.Trim() }
if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_TAB_TITLE)) { $tabTitle = $env:PI_NOTIFY_TAB_TITLE.Trim() }

$requiredText = if (-not [string]::IsNullOrWhiteSpace($tabTitle)) { $tabTitle } else { $cwdBase }
$keywords = @($tabTitle, $cwdBase, $targetHost) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
Write-NotifyActivateLog -Message ('activate-target targetFingerprint="{0}" hasCwd={1} hasTab={2} requiredFingerprint="{3}" keywordCount={4}' -f (Get-NotifyActivateFingerprint $targetHost), (-not [string]::IsNullOrWhiteSpace($cwdBase)), (-not [string]::IsNullOrWhiteSpace($tabTitle)), (Get-NotifyActivateFingerprint $requiredText), @($keywords).Count)
if ([string]::IsNullOrWhiteSpace($requiredText)) {
    Write-NotifyActivateLog -Message ('activate-focus-miss missing-target-metadata no-target-open-skipped targetFingerprint="{0}"' -f (Get-NotifyActivateFingerprint $targetHost))
    exit 1
}
if (Focus-NotifyWindow -Keywords $keywords -RequiredText $requiredText) {
    Write-NotifyActivateLog -Message 'activate-focus-success'
    exit 0
}

Write-NotifyActivateLog -Message ('activate-focus-miss no-target-open-skipped targetFingerprint="{0}" hasCwd={1} hasTab={2}' -f (Get-NotifyActivateFingerprint $targetHost), (-not [string]::IsNullOrWhiteSpace($cwdBase)), (-not [string]::IsNullOrWhiteSpace($tabTitle)))
exit 1
