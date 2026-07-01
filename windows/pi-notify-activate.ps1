[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Uri,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

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
        [string[]]$Keywords
    )

    $normalized = @($Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $windows = Get-CandidateWindows

    $best = $null
    foreach ($window in $windows) {
        $baseScore = 0
        if ($window.ProcessName -match 'WindowsTerminal|Terminal') {
            $baseScore += 100
        }
        foreach ($keyword in $normalized) {
            if ($window.Title.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $baseScore += 20
            }
        }

        $tabs = Get-NotifyWindowTabs -Handle $window.Handle
        if ($tabs.Count -eq 0) {
            if ($baseScore -gt 0) {
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
            $score = $baseScore
            foreach ($keyword in $normalized) {
                if (-not [string]::IsNullOrWhiteSpace($tab.Name) -and $tab.Name.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $score += 120
                }
            }
            if ($score -le 0) {
                continue
            }

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

    if ($null -eq $best) {
        Write-NotifyActivateLog -Message 'focus-no-candidate'
        return $false
    }

    Write-NotifyActivateLog -Message ('focus-best windowTitle="{0}" tabTitle="{1}" score={2}' -f $best.Window.Title, $best.TabName, $best.Score)

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
            Write-NotifyActivateLog -Message ('focus-tab-selected "{0}"' -f $best.TabName)
            Start-Sleep -Milliseconds 150
            [void][PiNotifyUser32]::SetForegroundWindow($best.Window.Handle)
            return $true
        }
        Write-NotifyActivateLog -Message ('focus-tab-select-failed "{0}"' -f $best.TabName)
    }

    return $true
}

Write-NotifyActivateLog -Message ('activate-start uri="{0}"' -f $Uri)

$targetHost = $config.RemoteHostAlias
$cwdBase = ''
if (-not [string]::IsNullOrWhiteSpace($Uri)) {
    try {
        $parsedUri = [Uri]$Uri
        $hostValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'host'
        $cwdBaseValue = Get-NotifyQueryValue -ParsedUri $parsedUri -Name 'cwdBase'
        if (-not [string]::IsNullOrWhiteSpace($hostValue)) {
            $targetHost = $hostValue.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($cwdBaseValue)) {
            $cwdBase = $cwdBaseValue.Trim()
        }
    }
    catch {
    }
}

$keywords = @($targetHost, $cwdBase)
Write-NotifyActivateLog -Message ('activate-target host="{0}" cwdBase="{1}" keywords="{2}"' -f $targetHost, $cwdBase, ($keywords -join ','))
if (Focus-NotifyWindow -Keywords $keywords) {
    Write-NotifyActivateLog -Message 'activate-focus-success'
    exit 0
}

$wtExe = Resolve-NotifyBridgeWtExecutable
$arguments = @('-w', '0', 'new-tab', '--title', ("Pi@{0}" -f $targetHost), 'ssh', $targetHost)
Write-NotifyActivateLog -Message ('activate-focus-miss fallback-wt="{0}" args="{1}"' -f $wtExe, ($arguments -join ' '))
Start-Process -FilePath $wtExe -ArgumentList $arguments | Out-Null
