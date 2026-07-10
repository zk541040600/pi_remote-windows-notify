[CmdletBinding()]
param(
    [string]$Title,
    [string]$Body,
    [string]$FocusTarget,
    [string]$CwdBase,
    [string]$SourceTabTitle,
    [string]$SessionName,
    [string]$PayloadPath,
    [string]$TargetFingerprint,
    [string]$ConfigPath,
    [int]$TimeoutSeconds = 1800,
    [int]$StackIndex = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class PiNotifyNoActivateForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation {
        get { return true; }
    }

    protected override System.Windows.Forms.CreateParams CreateParams {
        get {
            const int WS_EX_NOACTIVATE = 0x08000000;
            const int WS_EX_TOOLWINDOW = 0x00000080;
            System.Windows.Forms.CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    protected override void WndProc(ref System.Windows.Forms.Message m) {
        const int WM_MOUSEACTIVATE = 0x0021;
        const int MA_NOACTIVATE = 3;
        if (m.Msg == WM_MOUSEACTIVATE) {
            m.Result = (IntPtr)MA_NOACTIVATE;
            return;
        }
        base.WndProc(ref m);
    }
}

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

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs
$PopupPlacement = if ([string]::IsNullOrWhiteSpace([string]$config.PopupPlacement)) { 'cursor' } else { [string]$config.PopupPlacement }
$script:NotifyPopupHwndTopMost = [IntPtr](-1)
$script:NotifyPopupSwpShowNoActivate = [uint32](0x0010 -bor 0x0040)
if ([string]::IsNullOrWhiteSpace($Title) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_TITLE)) { $Title = $env:PI_NOTIFY_TITLE }
if ([string]::IsNullOrWhiteSpace($Body) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_BODY)) { $Body = $env:PI_NOTIFY_BODY }
if ([string]::IsNullOrWhiteSpace($FocusTarget) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_FOCUS_TARGET)) { $FocusTarget = $env:PI_NOTIFY_FOCUS_TARGET }
if ([string]::IsNullOrWhiteSpace($CwdBase) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_CWD_BASE)) { $CwdBase = $env:PI_NOTIFY_CWD_BASE }
if ([string]::IsNullOrWhiteSpace($SourceTabTitle) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_TAB_TITLE)) { $SourceTabTitle = $env:PI_NOTIFY_TAB_TITLE }
if ([string]::IsNullOrWhiteSpace($SessionName) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_SESSION_NAME)) { $SessionName = $env:PI_NOTIFY_SESSION_NAME }
$script:NotifyPopupLogPath = Join-Path (Get-NotifyBridgeLogDir) 'popup.log'
$script:NotifyPopupCachePath = Join-Path (Get-NotifyBridgeLogDir) 'popup-cache.json'
$popupWallpaperPath = if ($config.PSObject.Properties['PopupWallpaperPath']) { [string]$config.PopupWallpaperPath } else { '' }
$script:NotifyPopupWallpaperOffsetYPixels = 0
if ($config.PSObject.Properties['PopupWallpaperOffsetYPixels']) {
    try { $script:NotifyPopupWallpaperOffsetYPixels = [int]$config.PopupWallpaperOffsetYPixels } catch { }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyPopupLogPath) | Out-Null

function Write-NotifyPopupLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyPopupLogPath -Value $line -Encoding UTF8
}

function Get-NotifyPopupWallpaperImage {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    try {
        $resolved = [System.IO.Path]::GetFullPath($Path.Trim())
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            Write-NotifyPopupLog -Message ('popup-wallpaper-missing "{0}"' -f $resolved)
            return $null
        }

        $bytes = [System.IO.File]::ReadAllBytes($resolved)
        $stream = [System.IO.MemoryStream]::new($bytes)
        $loaded = $null
        $graphics = $null
        try {
            $loaded = [System.Drawing.Image]::FromStream($stream, $true, $true)
            # Image.FromStream can lazily depend on the source stream. Copy pixels into
            # a standalone bitmap before disposing the MemoryStream, otherwise later
            # WinForms paint events may raise "Stream was not readable" dialogs.
            $bitmap = [System.Drawing.Bitmap]::new($loaded.Width, $loaded.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.DrawImage($loaded, 0, 0, $loaded.Width, $loaded.Height)
            Write-NotifyPopupLog -Message ('popup-wallpaper-loaded "{0}" {1}x{2}' -f $resolved, $bitmap.Width, $bitmap.Height)
            return $bitmap
        }
        finally {
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $loaded) { $loaded.Dispose() }
            $stream.Dispose()
        }
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-wallpaper-error "{0}"' -f $_.Exception.Message)
        return $null
    }
}

function Get-NotifyPopupCoverSourceRectangle {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Image]$Image,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [int]$VerticalOffsetPixels = 0
    )

    if ($TargetWidth -le 0 -or $TargetHeight -le 0 -or $Image.Width -le 0 -or $Image.Height -le 0) {
        return [System.Drawing.Rectangle]::new(0, 0, $Image.Width, $Image.Height)
    }

    $targetRatio = [double]$TargetWidth / [double]$TargetHeight
    $imageRatio = [double]$Image.Width / [double]$Image.Height
    if ($imageRatio -gt $targetRatio) {
        $sourceWidth = [Math]::Max(1, [int][Math]::Round($Image.Height * $targetRatio))
        $sourceX = [Math]::Max(0, [int][Math]::Round(($Image.Width - $sourceWidth) / 2))
        return [System.Drawing.Rectangle]::new($sourceX, 0, $sourceWidth, $Image.Height)
    }

    $sourceHeight = [Math]::Max(1, [int][Math]::Round($Image.Width / $targetRatio))
    $maxSourceY = [Math]::Max(0, $Image.Height - $sourceHeight)
    $sourceY = [int][Math]::Round($maxSourceY / 2)
    if ($VerticalOffsetPixels -ne 0) {
        $sourceOffsetY = [int][Math]::Round(([double]$VerticalOffsetPixels * [double]$sourceHeight) / [Math]::Max(1, $TargetHeight))
        $sourceY -= $sourceOffsetY
    }
    $sourceY = [Math]::Min($maxSourceY, [Math]::Max(0, $sourceY))
    return [System.Drawing.Rectangle]::new(0, $sourceY, $Image.Width, $sourceHeight)
}

function Get-NotifyPopupContextFingerprint {
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

function Protect-NotifyPopupLiveValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Get-NotifyPopupLiveStatePath {
    return (Join-Path (Get-NotifyBridgeLogDir) ('popup-live.{0}.json' -f $PID))
}

function Save-NotifyPopupLiveState {
    param(
        [string]$TargetHostValue,
        [string]$CwdBaseValue,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprintValue,
        [int]$StackIndexValue,
        [int]$TimeoutSecondsValue
    )

    $path = Get-NotifyPopupLiveStatePath
    try {
        $ttlSeconds = [Math]::Max(300, ([Math]::Max(3, $TimeoutSecondsValue) + 60))
        $payload = @{
            processId         = $PID
            configFingerprint = Get-NotifyPopupContextFingerprint -Value $config.ConfigPath
            targetFingerprint = $TargetFingerprintValue
            stackIndex        = $StackIndexValue
            startedAtTicks    = [DateTime]::UtcNow.Ticks
            createdAtUtc      = [DateTime]::UtcNow.ToString('o')
            expiresAtTicks    = [DateTime]::UtcNow.AddSeconds($ttlSeconds).Ticks
            protectedHost     = Protect-NotifyPopupLiveValue -Value $TargetHostValue
            protectedCwd      = Protect-NotifyPopupLiveValue -Value $CwdBaseValue
            protectedTab      = Protect-NotifyPopupLiveValue -Value $SourceTabTitleValue
        }
        [System.IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        Write-NotifyPopupLog -Message ('popup-live-state pid={0} targetFingerprint={1} stackIndex={2} pathFingerprint={3}' -f $PID, $TargetFingerprintValue, $StackIndexValue, (Get-NotifyPopupContextFingerprint -Value $path))
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-live-state-write-error "{0}"' -f $_.Exception.Message)
    }
}

function Remove-NotifyPopupLiveState {
    try {
        Remove-Item -LiteralPath (Get-NotifyPopupLiveStatePath) -Force -ErrorAction SilentlyContinue
    }
    catch {
    }
}

$script:NotifyPopupWallpaperImage = Get-NotifyPopupWallpaperImage -Path $popupWallpaperPath

function Get-NotifyPopupDedupeSignature {
    param(
        [string]$TitleValue,
        [string]$BodyValue,
        [string]$FocusTargetValue
    )

    $text = ('{0}`n{1}`n{2}' -f ([string]$FocusTargetValue).Trim().ToLowerInvariant(), ([string]$TitleValue).Trim(), ([string]$BodyValue).Trim())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NotifyPopupDedupeState {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
    catch { return $null }
}

function Test-NotifyPopupDedupeStateFresh {
    param($State)

    if ($null -eq $State -or -not $State.PSObject.Properties['expiresAtTicks']) { return $false }
    $expiresAtTicks = [int64]0
    if (-not [int64]::TryParse([string]$State.expiresAtTicks, [ref]$expiresAtTicks)) { return $false }
    return ($expiresAtTicks -gt [DateTime]::UtcNow.Ticks)
}

function Initialize-NotifyPopupDedupe {
    param(
        [string]$TitleValue,
        [string]$BodyValue,
        [string]$FocusTargetValue,
        [string]$CwdBaseValue,
        [string]$SourceTabTitleValue,
        [string]$PayloadPathValue
    )

    $precise = -not [string]::IsNullOrWhiteSpace($CwdBaseValue) -or -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
    $signature = Get-NotifyPopupDedupeSignature -TitleValue $TitleValue -BodyValue $BodyValue -FocusTargetValue $FocusTargetValue
    return [pscustomobject]@{ Drop = $false; Path = ''; Precise = $precise }
}

function Test-NotifyPopupDedupeSuperseded {
    if ($script:NotifyPopupIsPrecise) { return $false }
    $state = Get-NotifyPopupDedupeState -Path $script:NotifyPopupDedupePath
    if (-not (Test-NotifyPopupDedupeStateFresh -State $state)) { return $false }
    if (-not ($state.PSObject.Properties['precise']) -or -not ([bool]$state.precise)) { return $false }
    if ($state.PSObject.Properties['pid'] -and ([string]$state.pid -eq [string]$PID)) { return $false }
    return $true
}

$Title = if ([string]::IsNullOrWhiteSpace($Title)) { 'Ready for input' } else { $Title }
$Body = if ([string]::IsNullOrWhiteSpace($Body)) { '' } else { $Body }
$FocusTarget = if ([string]::IsNullOrWhiteSpace($FocusTarget)) { $config.RemoteHostAlias } else { $FocusTarget }
$SessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) { '' } else { $SessionName.Trim() }

if (([string]$CwdBase).Trim() -match '^\{[^}]+\}$') { $CwdBase = '' }
if (([string]$SourceTabTitle).Trim() -match '^\{[^}]+\}$') { $SourceTabTitle = '' }
if ([string]::IsNullOrWhiteSpace($CwdBase) -and [string]::IsNullOrWhiteSpace($SourceTabTitle)) {
    Write-NotifyPopupLog -Message ('popup-drop missing-target-metadata targetFingerprint={0}' -f (Get-NotifyPopupContextFingerprint -Value $FocusTarget))
    exit 0
}

$dedupe = Initialize-NotifyPopupDedupe -TitleValue $Title -BodyValue $Body -FocusTargetValue $FocusTarget -CwdBaseValue $CwdBase -SourceTabTitleValue $SourceTabTitle -PayloadPathValue $PayloadPath
$script:NotifyPopupDedupePath = [string]$dedupe.Path
$script:NotifyPopupIsPrecise = [bool]$dedupe.Precise
if ([bool]$dedupe.Drop) { exit 0 }

try {
    $consoleHandle = [PiNotifyConsoleWindow]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][PiNotifyConsoleWindow]::ShowWindow($consoleHandle, 0)
    }
}
catch {
}

Write-NotifyPopupLog -Message ('popup-start targetFingerprint={0} hasCwd={1} hasTab={2} timeout={3} stackIndex={4}' -f (Get-NotifyPopupContextFingerprint -Value $FocusTarget), (-not [string]::IsNullOrWhiteSpace($CwdBase)), (-not [string]::IsNullOrWhiteSpace($SourceTabTitle)), $TimeoutSeconds, $StackIndex)
$liveTargetFingerprint = if ([string]::IsNullOrWhiteSpace($TargetFingerprint)) { Get-NotifyPopupContextFingerprint -Value $FocusTarget } else { $TargetFingerprint }
Save-NotifyPopupLiveState -TargetHostValue $FocusTarget -CwdBaseValue $CwdBase -SourceTabTitleValue $SourceTabTitle -TargetFingerprintValue $liveTargetFingerprint -StackIndexValue $StackIndex -TimeoutSecondsValue $TimeoutSeconds

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
        [string]$TabTitle,
        [int]$TabIndex = -1
    )

    try {
        $payload = @{
            hostFingerprint   = Get-NotifyPopupContextFingerprint -Value $TargetHostValue
            cwdFingerprint    = Get-NotifyPopupContextFingerprint -Value $CwdBaseValue
            windowFingerprint = Get-NotifyPopupContextFingerprint -Value $WindowTitle
            tabFingerprint    = Get-NotifyPopupContextFingerprint -Value $TabTitle
            tabIndex          = $TabIndex
            updatedAt         = [DateTime]::UtcNow.ToString('o')
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
        $tabIndex = 0
        foreach ($tab in $tabs) {
            $isSelected = $false
            try {
                $patternObj = $null
                if ($tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObj)) {
                    $isSelected = ([System.Windows.Automation.SelectionItemPattern]$patternObj).Current.IsSelected
                }
            }
            catch {
            }

            $rows.Add([pscustomobject]@{
                Name       = [string]$tab.Current.Name
                Element    = $tab
                IsSelected = $isSelected
                Index      = $tabIndex
            }) | Out-Null
            $tabIndex += 1
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

function Get-NotifyPopupSelectedTerminalTarget {
    foreach ($window in @(Get-NotifyPopupWindows -TerminalOnly)) {
        foreach ($tab in @(Get-NotifyPopupTabs -Handle $window.Handle)) {
            if ($tab.IsSelected) {
                return [pscustomobject]@{
                    WindowTitle = $window.Title
                    TabTitle    = $tab.Name
                    TabIndex    = $tab.Index
                }
            }
        }
    }

    return $null
}

function Test-NotifyPopupForegroundTarget {
    param(
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue
    )

    if ([string]::IsNullOrWhiteSpace($CurrentDirBase) -and [string]::IsNullOrWhiteSpace($SourceTabTitleValue)) {
        return $false
    }

    try {
        $handle = [PiNotifyPopupUser32]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) {
            return $false
        }

        $processId = [uint32]0
        [void][PiNotifyPopupUser32]::GetWindowThreadProcessId($handle, [ref]$processId)
        $process = Get-Process -Id $processId -ErrorAction Stop
        if ($process.ProcessName -notmatch 'WindowsTerminal|Terminal') {
            return $false
        }

        $titleLength = [PiNotifyPopupUser32]::GetWindowTextLength($handle)
        $windowTitle = ''
        if ($titleLength -gt 0) {
            $builder = New-Object System.Text.StringBuilder ($titleLength + 1)
            [void][PiNotifyPopupUser32]::GetWindowText($handle, $builder, $builder.Capacity)
            $windowTitle = $builder.ToString().Trim()
        }

        $selectedTab = @(Get-NotifyPopupTabs -Handle $handle | Where-Object { $_.IsSelected } | Select-Object -First 1)
        $selectedTitle = if ($selectedTab.Count -gt 0) { [string]$selectedTab[0].Name } else { '' }
        $haystack = @($selectedTitle, $windowTitle) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        if (-not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)) {
            foreach ($value in $haystack) {
                if ($value.IndexOf($SourceTabTitleValue, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Write-NotifyPopupLog -Message ('popup-foreground-target-match sourceTabFingerprint={0} selectedTabFingerprint={1} windowFingerprint={2}' -f (Get-NotifyPopupContextFingerprint -Value $SourceTabTitleValue), (Get-NotifyPopupContextFingerprint -Value $selectedTitle), (Get-NotifyPopupContextFingerprint -Value $windowTitle))
                    return $true
                }
            }

            # A precise tab title identifies the popup's own Pi tab. Do not fall back to
            # cwd matching here: multiple Pi tabs commonly share the same cwd, and a
            # click on one popup would otherwise make sibling popups dismiss themselves.
            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
            foreach ($value in $haystack) {
                if ($value.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Write-NotifyPopupLog -Message ('popup-foreground-target-match cwdFingerprint={0} selectedTabFingerprint={1} windowFingerprint={2}' -f (Get-NotifyPopupContextFingerprint -Value $CurrentDirBase), (Get-NotifyPopupContextFingerprint -Value $selectedTitle), (Get-NotifyPopupContextFingerprint -Value $windowTitle))
                    return $true
                }
            }
        }
    }
    catch {
    }

    return $false
}

function Invoke-NotifyPopupActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue
    )

    try {
        $startedAt = [DateTime]::UtcNow
        $requiresCwdMatch = -not [string]::IsNullOrWhiteSpace($CurrentDirBase)
        $hasPreciseSourceTitle = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
        Write-NotifyPopupLog -Message ('popup-activate targetFingerprint={0} cwdFingerprint={1} sourceTabFingerprint={2}' -f (Get-NotifyPopupContextFingerprint -Value $TargetHost), (Get-NotifyPopupContextFingerprint -Value $CurrentDirBase), (Get-NotifyPopupContextFingerprint -Value $SourceTabTitleValue))
        if (-not $requiresCwdMatch -and -not $hasPreciseSourceTitle) {
            Write-NotifyPopupLog -Message ('popup-focus-miss missing-target-metadata no-target-open-skipped targetFingerprint={0} elapsedMs={1}' -f (Get-NotifyPopupContextFingerprint -Value $TargetHost), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }
        Write-NotifyPopupLog -Message ('popup-focus-policy requiresCwdMatch={0} requiresSourceTabTitle={1} allowSelectedFallback={2} allowOpenNew={3}' -f $requiresCwdMatch, $hasPreciseSourceTitle, $false, $false)

        $keywords = @($SourceTabTitleValue, $CurrentDirBase, $TargetHost) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
        Write-NotifyPopupLog -Message ('popup-keywords count={0}' -f @($keywords).Count)

        $cache = Get-NotifyPopupCache
        $cacheMatches = $false
        $cacheWindowFingerprint = ''
        $cacheTabFingerprint = ''
        if ($null -ne $cache) {
            $cachedTabIndex = if ($cache.PSObject.Properties['tabIndex']) { [string]$cache.tabIndex } else { '' }
            $cacheWindowFingerprint = if ($cache.PSObject.Properties['windowFingerprint']) { [string]$cache.windowFingerprint } else { '' }
            $cacheTabFingerprint = if ($cache.PSObject.Properties['tabFingerprint']) { [string]$cache.tabFingerprint } else { '' }
            $cacheHostFingerprint = if ($cache.PSObject.Properties['hostFingerprint']) { [string]$cache.hostFingerprint } else { '' }
            $cacheCwdFingerprint = if ($cache.PSObject.Properties['cwdFingerprint']) { [string]$cache.cwdFingerprint } else { '' }
            Write-NotifyPopupLog -Message ('popup-cache hostFingerprint={0} cwdFingerprint={1} windowFingerprint={2} tabFingerprint={3} tabIndex={4}' -f $cacheHostFingerprint, $cacheCwdFingerprint, $cacheWindowFingerprint, $cacheTabFingerprint, $cachedTabIndex)
            $cacheMatches = -not [string]::IsNullOrWhiteSpace($CurrentDirBase) -and
                $cacheHostFingerprint -eq (Get-NotifyPopupContextFingerprint -Value $TargetHost) -and
                $cacheCwdFingerprint -eq (Get-NotifyPopupContextFingerprint -Value $CurrentDirBase)
            Write-NotifyPopupLog -Message ('popup-cache-match {0}' -f $cacheMatches)
        }
        if ($null -ne $script:NotifyPopupInitialTarget) {
            Write-NotifyPopupLog -Message ('popup-initial windowFingerprint={0} tabFingerprint={1} tabIndex={2}' -f (Get-NotifyPopupContextFingerprint -Value $script:NotifyPopupInitialTarget.WindowTitle), (Get-NotifyPopupContextFingerprint -Value $script:NotifyPopupInitialTarget.TabTitle), $script:NotifyPopupInitialTarget.TabIndex)
        }

        $windows = @(Get-NotifyPopupWindows -TerminalOnly)
        Write-NotifyPopupLog -Message ('popup-terminal-window-count {0}' -f $windows.Count)
        $best = $null
        foreach ($window in $windows) {
            $baseScore = 0
            foreach ($keyword in $keywords) {
                if ($window.Title.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $baseScore += 20
                }
            }
            if ($cacheMatches -and -not [string]::IsNullOrWhiteSpace($cacheWindowFingerprint) -and (Get-NotifyPopupContextFingerprint -Value $window.Title) -eq $cacheWindowFingerprint) {
                $baseScore += 80
            }
            if ([string]::IsNullOrWhiteSpace($CurrentDirBase) -and $null -ne $script:NotifyPopupInitialTarget -and $window.Title -eq $script:NotifyPopupInitialTarget.WindowTitle) {
                $baseScore += 50
            }

            $tabs = @(Get-NotifyPopupTabs -Handle $window.Handle)
            Write-NotifyPopupLog -Message ('popup-window titleFingerprint={0} process="{1}" tabs={2} baseScore={3}' -f (Get-NotifyPopupContextFingerprint -Value $window.Title), $window.ProcessName, $tabs.Count, $baseScore)
            if ($tabs.Count -eq 0) {
                if (-not $requiresCwdMatch -and -not $hasPreciseSourceTitle -and $baseScore -gt 0) {
                    $candidate = [pscustomobject]@{ Window = $window; Score = $baseScore; Tab = $null; TabName = ''; TabIndex = -1 }
                    if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                        $best = $candidate
                    }
                }
                continue
            }

            foreach ($tab in $tabs) {
                $score = $baseScore
                $matchedKeywords = New-Object System.Collections.Generic.List[string]
                foreach ($keyword in $keywords) {
                    if (-not [string]::IsNullOrWhiteSpace($tab.Name) -and $tab.Name.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $score += 120
                        [void]$matchedKeywords.Add($keyword)
                    }
                }
                $sourceTabTitleMatch = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue) -and -not [string]::IsNullOrWhiteSpace($tab.Name) -and $tab.Name.IndexOf($SourceTabTitleValue, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                if ($sourceTabTitleMatch) {
                    $score += 300
                }
                $cacheTitleMatchesSource = -not $hasPreciseSourceTitle -or (-not [string]::IsNullOrWhiteSpace($cacheTabFingerprint) -and $cacheTabFingerprint -eq (Get-NotifyPopupContextFingerprint -Value $SourceTabTitleValue))
                $cacheTabMatch = $cacheMatches -and $cacheTitleMatchesSource -and -not [string]::IsNullOrWhiteSpace($cacheTabFingerprint) -and (Get-NotifyPopupContextFingerprint -Value $tab.Name) -eq $cacheTabFingerprint -and $cacheTabFingerprint -ne ''
                if ($cacheTabMatch) {
                    $score += 200
                }
                $windowCwdMatch = $requiresCwdMatch -and $window.Title.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                $cwdKeywordMatch = $requiresCwdMatch -and (($matchedKeywords -contains $CurrentDirBase) -or $windowCwdMatch)
                if ($hasPreciseSourceTitle -and -not $sourceTabTitleMatch -and -not $cacheTabMatch -and -not $cwdKeywordMatch) {
                    $score = 0
                }
                elseif ($requiresCwdMatch -and -not $sourceTabTitleMatch -and -not $cacheTabMatch -and -not $cwdKeywordMatch) {
                    $score = 0
                }
                $initialTabMatch = [string]::IsNullOrWhiteSpace($CurrentDirBase) -and $null -ne $script:NotifyPopupInitialTarget -and $tab.Name -eq $script:NotifyPopupInitialTarget.TabTitle
                if ($initialTabMatch) {
                    $score += 500
                }
                $selectedFallback = $false
                if ($score -le 0 -and $tab.IsSelected -and [string]::IsNullOrWhiteSpace($CurrentDirBase) -and -not $hasPreciseSourceTitle) {
                    $score = 1
                    $selectedFallback = $true
                }
                Write-NotifyPopupLog -Message ('popup-tab index={0} nameFingerprint={1} selected={2} score={3} matchedKeywordCount={4} sourceTabTitleMatch={5} cacheTabMatch={6} initialTabMatch={7} selectedFallback={8}' -f $tab.Index, (Get-NotifyPopupContextFingerprint -Value $tab.Name), $tab.IsSelected, $score, @($matchedKeywords).Count, $sourceTabTitleMatch, $cacheTabMatch, $initialTabMatch, $selectedFallback)
                if ($score -le 0) {
                    continue
                }

                $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name; TabIndex = $tab.Index }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                    $best = $candidate
                }
            }
        }

        if ($null -eq $best) {
            Write-NotifyPopupLog -Message ('popup-focus-miss no-target-open-skipped targetFingerprint={0} cwdFingerprint={1} keywordCount={2} elapsedMs={3}' -f (Get-NotifyPopupContextFingerprint -Value $TargetHost), (Get-NotifyPopupContextFingerprint -Value $CurrentDirBase), @($keywords).Count, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }

        Write-NotifyPopupLog -Message ('popup-focus-best windowFingerprint={0} tabFingerprint={1} tabIndex={2} score={3}' -f (Get-NotifyPopupContextFingerprint -Value $best.Window.Title), (Get-NotifyPopupContextFingerprint -Value $best.TabName), $best.TabIndex, $best.Score)
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
                Write-NotifyPopupLog -Message ('popup-tab-selected tabFingerprint={0} elapsedMs={1}' -f (Get-NotifyPopupContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
                if (-not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
                    Save-NotifyPopupCache -TargetHostValue $TargetHost -CwdBaseValue $CurrentDirBase -WindowTitle $best.Window.Title -TabTitle $best.TabName -TabIndex $best.TabIndex
                }
            }
            else {
                Write-NotifyPopupLog -Message ('popup-tab-select-failed tabFingerprint={0} elapsedMs={1}' -f (Get-NotifyPopupContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            }
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
                Save-NotifyPopupCache -TargetHostValue $TargetHost -CwdBaseValue $CurrentDirBase -WindowTitle $best.Window.Title -TabTitle '' -TabIndex -1
            }
        }
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-activate-error "{0}"' -f $_.Exception.Message)
    }
}

$script:NotifyPopupInitialTarget = Get-NotifyPopupSelectedTerminalTarget
if ($null -ne $script:NotifyPopupInitialTarget) {
    Write-NotifyPopupLog -Message ('popup-initial-captured windowFingerprint={0} tabFingerprint={1} tabIndex={2}' -f (Get-NotifyPopupContextFingerprint -Value $script:NotifyPopupInitialTarget.WindowTitle), (Get-NotifyPopupContextFingerprint -Value $script:NotifyPopupInitialTarget.TabTitle), $script:NotifyPopupInitialTarget.TabIndex)
}

[System.Windows.Forms.Application]::EnableVisualStyles()

function New-NotifyPopupRoundedPath {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Rectangle]$Rectangle,
        [int]$Radius = 14
    )

    $diameter = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

$cardColor = [System.Drawing.Color]::FromArgb(28, 30, 36)
$borderColor = [System.Drawing.Color]::FromArgb(74, 80, 96)
$accentColor = [System.Drawing.Color]::FromArgb(94, 234, 212)
$mutedColor = [System.Drawing.Color]::FromArgb(168, 178, 195)

$form = New-Object PiNotifyNoActivateForm
$form.Text = 'Pi'
$form.Size = New-Object System.Drawing.Size(420, 154)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
# Do not use Form.TopMost: native SetWindowPos applies topmost with SWP_NOACTIVATE.
$form.TopMost = $false
$form.BackColor = $cardColor
$form.Opacity = 0.98
$form.Cursor = [System.Windows.Forms.Cursors]::Hand

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$panel.BackColor = $cardColor
$panel.Cursor = [System.Windows.Forms.Cursors]::Hand
$panel.Add_Paint({
    try {
        $graphics = $_.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rect = New-Object System.Drawing.Rectangle(0, 0, ($panel.Width - 1), ($panel.Height - 1))

        if ($null -ne $script:NotifyPopupWallpaperImage) {
            $dest = New-Object System.Drawing.Rectangle(0, 0, $panel.Width, $panel.Height)
            $source = Get-NotifyPopupCoverSourceRectangle -Image $script:NotifyPopupWallpaperImage -TargetWidth $panel.Width -TargetHeight $panel.Height -VerticalOffsetPixels $script:NotifyPopupWallpaperOffsetYPixels
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($script:NotifyPopupWallpaperImage, $dest, $source, [System.Drawing.GraphicsUnit]::Pixel)
            $overlay = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
                $dest,
                [System.Drawing.Color]::FromArgb(170, 0, 0, 0),
                [System.Drawing.Color]::FromArgb(70, 0, 0, 0),
                [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            try { $graphics.FillRectangle($overlay, $dest) } finally { $overlay.Dispose() }
        }

        $path = New-NotifyPopupRoundedPath -Rectangle $rect -Radius 14
        $pen = New-Object System.Drawing.Pen($borderColor, 1)
        $accentBrush = New-Object System.Drawing.SolidBrush($accentColor)
        $graphics.DrawPath($pen, $path)
        $graphics.FillRectangle($accentBrush, 0, 0, 5, $panel.Height)
        $accentBrush.Dispose()
        $pen.Dispose()
        $path.Dispose()
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-paint-error "{0}"' -f $_.Exception.Message)
    }
})
[void]$form.Controls.Add($panel)

$appLabel = New-Object System.Windows.Forms.Label
$appLabel.Location = New-Object System.Drawing.Point(22, 13)
$appLabel.Size = New-Object System.Drawing.Size(240, 18)
$appLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$appLabel.ForeColor = $mutedColor
$appLabel.Text = 'Pi Remote'
$appLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($appLabel)

$closeLabel = New-Object System.Windows.Forms.Label
$closeLabel.Location = New-Object System.Drawing.Point(384, 10)
$closeLabel.Size = New-Object System.Drawing.Size(24, 24)
$closeLabel.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 12, [System.Drawing.FontStyle]::Regular)
$closeLabel.ForeColor = [System.Drawing.Color]::FromArgb(198, 207, 222)
$closeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$closeLabel.Text = 'x'
$closeLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($closeLabel)

$sessionDisplayName = $SessionName
if ([string]::IsNullOrWhiteSpace($sessionDisplayName) -and -not [string]::IsNullOrWhiteSpace($SourceTabTitle)) {
    $tabPrefix = ([string][char]0x03c0) + ' - '
    $middleDotSeparator = ' ' + ([string][char]0x00b7) + ' '
    if ($SourceTabTitle.StartsWith($tabPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $start = $tabPrefix.Length
        $middleDotIndex = $SourceTabTitle.IndexOf($middleDotSeparator, [System.StringComparison]::OrdinalIgnoreCase)
        $dashIndex = $SourceTabTitle.LastIndexOf(' - ', [System.StringComparison]::OrdinalIgnoreCase)
        if ($dashIndex -gt $start) {
            $sessionDisplayName = $SourceTabTitle.Substring($start, $dashIndex - $start).Trim()
        }
        elseif ($middleDotIndex -gt $start) {
            $sessionDisplayName = $SourceTabTitle.Substring($start, $middleDotIndex - $start).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($sessionDisplayName)) {
        $sessionDisplayName = $SourceTabTitle.Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($sessionDisplayName)) { $sessionDisplayName = $CwdBase }
if ([string]::IsNullOrWhiteSpace($sessionDisplayName)) { $sessionDisplayName = 'Pi Session' }

$sessionLabel = New-Object System.Windows.Forms.Label
$sessionLabel.Location = New-Object System.Drawing.Point(22, 34)
$sessionLabel.Size = New-Object System.Drawing.Size(354, 30)
$sessionLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14, [System.Drawing.FontStyle]::Regular)
$sessionLabel.ForeColor = $accentColor
$sessionLabel.Text = $sessionDisplayName
$sessionLabel.AutoEllipsis = $true
$sessionLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($sessionLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(22, 68)
$titleLabel.Size = New-Object System.Drawing.Size(354, 24)
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Regular)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$titleLabel.Text = $Title
$titleLabel.AutoEllipsis = $true
$titleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($titleLabel)

$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Location = New-Object System.Drawing.Point(22, 96)
$bodyLabel.Size = New-Object System.Drawing.Size(374, 42)
$bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$bodyLabel.ForeColor = [System.Drawing.Color]::FromArgb(214, 221, 233)
$bodyLabel.Text = $Body
$bodyLabel.AutoEllipsis = $true
$bodyLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$panel.Controls.Add($bodyLabel)

if ($null -ne $script:NotifyPopupWallpaperImage) {
    foreach ($label in @($appLabel, $closeLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
        $label.BackColor = [System.Drawing.Color]::Transparent
    }
}

$targetHost = $FocusTarget
$targetCwdBase = $CwdBase
$targetSourceTabTitle = $SourceTabTitle
$didActivate = $false
$shouldActivate = $false

$activateAction = {
    if ($didActivate) {
        return
    }
    $script:didActivate = $true
    $script:shouldActivate = $true
    Write-NotifyPopupLog -Message 'popup-click'
    Write-NotifyPopupLog -Message ('popup-action activate targetFingerprint={0}' -f (Get-NotifyPopupContextFingerprint -Value $targetHost))
    $form.Close()
}

$closeAction = {
    Write-NotifyPopupLog -Message 'popup-close-button'
    Write-NotifyPopupLog -Message 'popup-action dismiss source="close-button"'
    $form.Close()
}

foreach ($control in @($form, $panel, $appLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
    $control.Add_Click($activateAction)
}
$closeLabel.Add_Click($closeAction)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(3000, ($TimeoutSeconds * 1000))
$timer.Add_Tick({
    Write-NotifyPopupLog -Message 'popup-timeout-close'
    Write-NotifyPopupLog -Message 'popup-action dismiss source="timeout"'
    $timer.Stop()
    $form.Close()
})

$focusWatchTimer = New-Object System.Windows.Forms.Timer
$focusWatchTimer.Interval = 800
$focusWatchTimer.Add_Tick({
    if (Test-NotifyPopupDedupeSuperseded) {
        Write-NotifyPopupLog -Message 'popup-action dismiss source="dedupe-superseded"'
        $focusWatchTimer.Stop()
        $timer.Stop()
        $form.Close()
        return
    }

    if (Test-NotifyPopupForegroundTarget -CurrentDirBase $targetCwdBase -SourceTabTitleValue $targetSourceTabTitle) {
        Write-NotifyPopupLog -Message 'popup-action dismiss source="foreground-target"'
        $focusWatchTimer.Stop()
        $timer.Stop()
        $form.Close()
    }
})

function Get-NotifyPopupWorkingArea {
    param([string]$Placement)

    if ($Placement -eq 'cursor') {
        try { return [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea } catch {}
    }
    if ($Placement -eq 'right') {
        try {
            $screens = @([System.Windows.Forms.Screen]::AllScreens)
            $rightScreen = @($screens | Sort-Object { $_.WorkingArea.Right } -Descending | Select-Object -First 1)
            if ($rightScreen.Count -gt 0) { return $rightScreen[0].WorkingArea }
        }
        catch {
        }
    }

    return [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
}

$workingArea = Get-NotifyPopupWorkingArea -Placement $PopupPlacement
$margin = 16
$gap = 12
$slot = [Math]::Max(0, $StackIndex)
$x = [Math]::Max($workingArea.Left, $workingArea.Right - $form.Width - $margin)
$bottomY = $workingArea.Bottom - $form.Height - $margin
$stackY = $bottomY - ($slot * ($form.Height + $gap))
$y = [Math]::Max($workingArea.Top + $margin, $stackY)
$form.Location = New-Object System.Drawing.Point($x, $y)
$roundedRect = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
$roundedPath = New-NotifyPopupRoundedPath -Rectangle $roundedRect -Radius 14
$form.Region = New-Object System.Drawing.Region($roundedPath)
$roundedPath.Dispose()

$form.Add_Shown({
    [void][PiNotifyPopupUser32]::SetWindowPos($form.Handle, $script:NotifyPopupHwndTopMost, $form.Left, $form.Top, $form.Width, $form.Height, $script:NotifyPopupSwpShowNoActivate)
    Write-NotifyPopupLog -Message ('popup-shown-noactivate x={0} y={1} w={2} h={3} stackIndex={4} placement={5}' -f $x, $y, $form.Width, $form.Height, $slot, $PopupPlacement)
    $timer.Start()
    $focusWatchTimer.Start()
})

$form.Add_FormClosed({
    Write-NotifyPopupLog -Message ('popup-closed shouldActivate={0}' -f $shouldActivate)
    Remove-NotifyPopupLiveState
    try {
        $timer.Stop()
        $timer.Dispose()
        $focusWatchTimer.Stop()
        $focusWatchTimer.Dispose()
        if ($null -ne $script:NotifyPopupWallpaperImage) {
            $script:NotifyPopupWallpaperImage.Dispose()
            $script:NotifyPopupWallpaperImage = $null
        }
    }
    catch {
    }
})

[System.Windows.Forms.Application]::Run($form)

if ($shouldActivate) {
    Invoke-NotifyPopupActivation -TargetHost $targetHost -CurrentDirBase $targetCwdBase -SourceTabTitleValue $targetSourceTabTitle
}
