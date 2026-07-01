[CmdletBinding()]
param(
    [string]$Title,
    [string]$Body,
    [string]$FocusTarget,
    [string]$CwdBase,
    [string]$PayloadPath,
    [string]$ConfigPath,
    [int]$TimeoutSeconds = 18
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PiNotifyConsoleWindow {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}

public static class PiNotifyPopupUser32 {
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
$script:NotifyPopupLogPath = Join-Path (Get-NotifyBridgeLogDir) 'popup.log'
$script:NotifyPopupCachePath = Join-Path (Get-NotifyBridgeLogDir) 'popup-cache.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyPopupLogPath) | Out-Null

function Write-NotifyPopupLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyPopupLogPath -Value $line -Encoding UTF8
}

if (-not [string]::IsNullOrWhiteSpace($PayloadPath) -and (Test-Path -LiteralPath $PayloadPath)) {
    try {
        $payloadText = [System.IO.File]::ReadAllText($PayloadPath, [System.Text.UTF8Encoding]::new($false))
        $payload = $payloadText | ConvertFrom-Json
        if ($payload.PSObject.Properties['title']) { $Title = [string]$payload.title }
        if ($payload.PSObject.Properties['body']) { $Body = [string]$payload.body }
        if ($payload.PSObject.Properties['focusTarget']) { $FocusTarget = [string]$payload.focusTarget }
        if ($payload.PSObject.Properties['cwdBase']) { $CwdBase = [string]$payload.cwdBase }
        if ($payload.PSObject.Properties['timeoutSeconds']) { $TimeoutSeconds = [int]$payload.timeoutSeconds }
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-payload-read-error "{0}"' -f $_.Exception.Message)
    }
}

$Title = if ([string]::IsNullOrWhiteSpace($Title)) { 'Ready for input' } else { $Title }
$Body = if ([string]::IsNullOrWhiteSpace($Body)) { '' } else { $Body }
$FocusTarget = if ([string]::IsNullOrWhiteSpace($FocusTarget)) { $config.RemoteHostAlias } else { $FocusTarget }

try {
    $consoleHandle = [PiNotifyConsoleWindow]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][PiNotifyConsoleWindow]::ShowWindow($consoleHandle, 0)
    }
}
catch {
}

Write-NotifyPopupLog -Message ('popup-start title="{0}" focusTarget="{1}" cwdBase="{2}" timeout={3}' -f $Title, $FocusTarget, $CwdBase, $TimeoutSeconds)

function Get-NotifyPopupWindows {
    param(
        [switch]$TerminalOnly
    )

    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PiNotifyPopupUser32+EnumWindowsProc]{
        param([IntPtr]$Handle, [IntPtr]$LParam)

        if (-not [PiNotifyPopupUser32]::IsWindowVisible($Handle)) {
            return $true
        }

        $length = [PiNotifyPopupUser32]::GetWindowTextLength($Handle)
        if ($length -le 0) {
            return $true
        }

        $builder = New-Object System.Text.StringBuilder ($length + 1)
        [void][PiNotifyPopupUser32]::GetWindowText($Handle, $builder, $builder.Capacity)
        $title = $builder.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $processId = [uint32]0
        [void][PiNotifyPopupUser32]::GetWindowThreadProcessId($Handle, [ref]$processId)
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        if ($TerminalOnly -and ($process.ProcessName -notmatch 'WindowsTerminal|Terminal')) {
            return $true
        }

        $windows.Add([pscustomobject]@{
            Handle      = $Handle
            Title       = $title
            ProcessId   = $process.Id
            ProcessName = $process.ProcessName
        }) | Out-Null
        return $true
    }

    [void][PiNotifyPopupUser32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows.ToArray())
}

function Get-NotifyPopupCache {
    if (-not (Test-Path -LiteralPath $script:NotifyPopupCachePath)) {
        return $null
    }

    try {
        return ([System.IO.File]::ReadAllText($script:NotifyPopupCachePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-cache-read-error "{0}"' -f $_.Exception.Message)
        return $null
    }
}

function Save-NotifyPopupCache {
    param(
        [string]$TargetHostValue,
        [string]$CwdBaseValue,
        [string]$WindowTitle,
        [string]$TabTitle
    )

    try {
        $payload = @{
            host      = $TargetHostValue
            cwdBase   = $CwdBaseValue
            windowTitle = $WindowTitle
            tabTitle  = $TabTitle
            updatedAt = [DateTime]::UtcNow.ToString('o')
        }
        [System.IO.File]::WriteAllText($script:NotifyPopupCachePath, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-cache-write-error "{0}"' -f $_.Exception.Message)
    }
}

function Get-NotifyPopupTabs {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
        if ($null -eq $root) {
            return @($rows.ToArray())
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
        Write-NotifyPopupLog -Message ('popup-tabs-error "{0}"' -f $_.Exception.Message)
    }

    return @($rows.ToArray())
}

function Select-NotifyPopupTab {
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

function Invoke-NotifyPopupActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase
    )

    try {
        $startedAt = [DateTime]::UtcNow
        Write-NotifyPopupLog -Message ('popup-activate host="{0}" cwdBase="{1}"' -f $TargetHost, $CurrentDirBase)

        $keywords = @($TargetHost, $CurrentDirBase) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
        Write-NotifyPopupLog -Message ('popup-keywords "{0}"' -f ($keywords -join ','))

        $cache = Get-NotifyPopupCache
        if ($null -ne $cache) {
            Write-NotifyPopupLog -Message ('popup-cache host="{0}" cwdBase="{1}" windowTitle="{2}" tabTitle="{3}"' -f $cache.host, $cache.cwdBase, $cache.windowTitle, $cache.tabTitle)
        }

        $windows = @(Get-NotifyPopupWindows -TerminalOnly)
        Write-NotifyPopupLog -Message ('popup-terminal-window-count {0}' -f $windows.Count)
        $best = $null
        foreach ($window in $windows) {
            $baseScore = 100
            foreach ($keyword in $keywords) {
                if ($window.Title.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $baseScore += 20
                }
            }
            if ($null -ne $cache -and -not [string]::IsNullOrWhiteSpace([string]$cache.windowTitle) -and $window.Title -eq [string]$cache.windowTitle) {
                $baseScore += 80
            }

            $tabs = @(Get-NotifyPopupTabs -Handle $window.Handle)
            Write-NotifyPopupLog -Message ('popup-window title="{0}" process="{1}" tabs={2} baseScore={3}' -f $window.Title, $window.ProcessName, $tabs.Count, $baseScore)
            if ($tabs.Count -eq 0) {
                $candidate = [pscustomobject]@{ Window = $window; Score = $baseScore; Tab = $null; TabName = '' }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                    $best = $candidate
                }
                continue
            }

            foreach ($tab in $tabs) {
                $score = $baseScore
                foreach ($keyword in $keywords) {
                    if (-not [string]::IsNullOrWhiteSpace($tab.Name) -and $tab.Name.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $score += 120
                    }
                }
                if ($null -ne $cache -and -not [string]::IsNullOrWhiteSpace([string]$cache.tabTitle) -and $tab.Name -eq [string]$cache.tabTitle) {
                    $score += 200
                }
                Write-NotifyPopupLog -Message ('popup-tab name="{0}" score={1}' -f $tab.Name, $score)
                if ($score -le 0) {
                    continue
                }

                $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                    $best = $candidate
                }
            }
        }

        if ($null -eq $best) {
            $wtExe = Resolve-NotifyBridgeWtExecutable
            $arguments = @('-w', '0', 'new-tab', '--title', ("Pi@{0}" -f $TargetHost), 'ssh', $TargetHost)
            Write-NotifyPopupLog -Message ('popup-focus-miss fallback-wt="{0}" args="{1}" elapsedMs={2}' -f $wtExe, ($arguments -join ' '), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            Start-Process -FilePath $wtExe -ArgumentList $arguments | Out-Null
            return
        }

        Write-NotifyPopupLog -Message ('popup-focus-best windowTitle="{0}" tabTitle="{1}" score={2}' -f $best.Window.Title, $best.TabName, $best.Score)
        if ([PiNotifyPopupUser32]::IsIconic($best.Window.Handle)) {
            [void][PiNotifyPopupUser32]::ShowWindowAsync($best.Window.Handle, 9)
            Start-Sleep -Milliseconds 120
        }

        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.AppActivate($best.Window.ProcessId)
        }
        catch {
            Write-NotifyPopupLog -Message ('popup-appactivate-error "{0}"' -f $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 80
        [void][PiNotifyPopupUser32]::SetForegroundWindow($best.Window.Handle)
        Start-Sleep -Milliseconds 80

        if ($null -ne $best.Tab) {
            if (Select-NotifyPopupTab -TabElement $best.Tab) {
                Write-NotifyPopupLog -Message ('popup-tab-selected "{0}" elapsedMs={1}' -f $best.TabName, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
                Save-NotifyPopupCache -Host $TargetHost -CwdBaseValue $CurrentDirBase -WindowTitle $best.Window.Title -TabTitle $best.TabName
            }
            else {
                Write-NotifyPopupLog -Message ('popup-tab-select-failed "{0}" elapsedMs={1}' -f $best.TabName, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            }
        }
        else {
            Save-NotifyPopupCache -Host $TargetHost -CwdBaseValue $CurrentDirBase -WindowTitle $best.Window.Title -TabTitle ''
        }
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-activate-error "{0}"' -f $_.Exception.Message)
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Pi'
$form.Size = New-Object System.Drawing.Size(380, 110)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(58, 58, 58)
$form.Opacity = 0.985
$form.Cursor = [System.Windows.Forms.Cursors]::Hand

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$panel.BackColor = [System.Drawing.Color]::FromArgb(58, 58, 58)
$panel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($panel)

$appLabel = New-Object System.Windows.Forms.Label
$appLabel.Location = New-Object System.Drawing.Point(18, 12)
$appLabel.Size = New-Object System.Drawing.Size(200, 18)
$appLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$appLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$appLabel.Text = 'Pi'
$appLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($appLabel)

$closeLabel = New-Object System.Windows.Forms.Label
$closeLabel.Location = New-Object System.Drawing.Point(338, 9)
$closeLabel.Size = New-Object System.Drawing.Size(24, 24)
$closeLabel.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 11, [System.Drawing.FontStyle]::Regular)
$closeLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
$closeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$closeLabel.Text = '×'
$closeLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($closeLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(18, 38)
$titleLabel.Size = New-Object System.Drawing.Size(320, 26)
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Text = $Title
$titleLabel.AutoEllipsis = $true
$titleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($titleLabel)

$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Location = New-Object System.Drawing.Point(18, 66)
$bodyLabel.Size = New-Object System.Drawing.Size(344, 28)
$bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$bodyLabel.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
$bodyLabel.Text = $Body
$bodyLabel.AutoEllipsis = $true
$bodyLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($bodyLabel)

$targetHost = $FocusTarget
$targetCwdBase = $CwdBase
$didActivate = $false
$shouldActivate = $false

$activateAction = {
    if ($didActivate) {
        return
    }
    $script:didActivate = $true
    $script:shouldActivate = $true
    Write-NotifyPopupLog -Message 'popup-click'
    $form.Close()
}

$closeAction = {
    Write-NotifyPopupLog -Message 'popup-close-button'
    $form.Close()
}

foreach ($control in @($form, $panel, $appLabel, $titleLabel, $bodyLabel)) {
    $control.Add_Click($activateAction)
    $control.Add_MouseDown($activateAction)
}
$closeLabel.Add_Click($closeAction)
$closeLabel.Add_MouseDown($closeAction)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(3000, ($TimeoutSeconds * 1000))
$timer.Add_Tick({
    Write-NotifyPopupLog -Message 'popup-timeout-close'
    $timer.Stop()
    $form.Close()
})

$form.Add_Shown({
    $workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $margin = 16
    $x = [Math]::Max($workingArea.Left, $workingArea.Right - $form.Width - $margin)
    $y = [Math]::Max($workingArea.Top, $workingArea.Bottom - $form.Height - $margin)
    $form.Location = New-Object System.Drawing.Point($x, $y)
    $form.BringToFront()
    $form.Activate()
    Write-NotifyPopupLog -Message ('popup-shown x={0} y={1} w={2} h={3}' -f $x, $y, $form.Width, $form.Height)
    $timer.Start()
})

$form.Add_FormClosed({
    Write-NotifyPopupLog -Message 'popup-closed'
    try {
        $timer.Stop()
        $timer.Dispose()
    }
    catch {
    }
})

[System.Windows.Forms.Application]::Run($form)

if ($shouldActivate) {
    Invoke-NotifyPopupActivation -TargetHost $targetHost -CurrentDirBase $targetCwdBase
}
