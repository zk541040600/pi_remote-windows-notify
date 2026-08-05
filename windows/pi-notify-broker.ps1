[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once
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

public static class PiNotifyBrokerUser32 {
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

# Broker loads config and initializes paths and logs
$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
$config = Ensure-NotifyBridgeConfig @configArgs
$ConfigPath = $config.ConfigPath
$brokerPort = [int]$config.BrokerPort
$PopupPlacement = if ([string]::IsNullOrWhiteSpace([string]$config.PopupPlacement)) { 'cursor' } else { [string]$config.PopupPlacement }
$popupWallpaperPath = if ($config.PSObject.Properties['PopupWallpaperPath']) { [string]$config.PopupWallpaperPath } else { '' }
$script:NotifyBrokerWallpaperOffsetYPixels = 0
if ($config.PSObject.Properties['PopupWallpaperOffsetYPixels']) {
    try { $script:NotifyBrokerWallpaperOffsetYPixels = [int]$config.PopupWallpaperOffsetYPixels } catch { }
}
$script:NotifyBrokerLogPath = Join-Path (Get-NotifyBridgeLogDir) 'broker.log'
$script:NotifyBrokerPidPath = Join-Path (Get-NotifyBridgeBaseDir) 'broker.pid'
$script:NotifyBrokerMutex = $null
$script:NotifyBrokerHasLock = $false
# Share one lock between UI and background runspaces while keeping log files short-lived and readable.
$script:NotifyBrokerLogLock = [System.Object]::new()
try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyBrokerLogPath) | Out-Null
}
catch {
    # Logging is best-effort and must never prevent the broker from starting.
}

# Request queue: background listener thread enqueues /popup and /close; UI timer consumes on main thread
$script:NotifyBrokerPopupQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
# Active popup dictionary: popupId -> object with Form/labels/state; accessed only on UI thread
$script:NotifyBrokerActivePopups = @{}
$script:NotifyBrokerSequenceId = 0
# In-memory tab cache: conservative TTL to avoid full UIAutomation scan on every click
$script:NotifyBrokerTabCache = $null
$script:NotifyBrokerTabCacheByTarget = @{}
$script:NotifyBrokerTabCacheAt = [DateTime]::MinValue
$script:NotifyBrokerTabCacheTtlSeconds = 120
$script:NotifyBrokerHwndTopMost = [IntPtr](-1)
$script:NotifyBrokerSwpShowNoActivate = [uint32](0x0010 -bor 0x0040)
$script:NotifyBrokerPopupMaxVisible = 4
$script:NotifyBrokerActivationQueue = $null
$script:NotifyBrokerActivationTimer = $null
$script:NotifyBrokerExactWorkers = @{}
$script:NotifyBrokerExactWorkerSequence = 0
$script:NotifyBrokerExactWorkerTimer = $null
$script:NotifyBrokerExactWorkerMax = 32
$script:NotifyBrokerFailureCloseDelayMs = 2500
$script:NotifyBrokerActivationRecoveryWaitMs = 10000
$script:NotifyBrokerRecoveringActivationWatchdogMs = 12000
$script:NotifyBrokerReadyActivationWatchdogMs = 20000
$script:NotifyBrokerDeferredActivations = @{}
$script:NotifyBrokerDeferredActivationSequence = 0
$script:NotifyBrokerDeferredActivationMax = 32
$script:NotifyBrokerPrewarmQueue = $null
$script:NotifyBrokerPrewarmTimer = $null
$script:NotifyBrokerPrewarmLastScanByTarget = @{}
$script:NotifyBrokerPrewarmMinIntervalSeconds = 15
$script:NotifyBrokerPrewarmDelayMs = 10000
$script:NotifyBrokerPrewarmMaxQueue = 4
if ($config.PSObject.Properties['PopupMaxVisible']) {
    try { $script:NotifyBrokerPopupMaxVisible = [Math]::Max(1, [Math]::Min(8, [int]$config.PopupMaxVisible)) } catch { $script:NotifyBrokerPopupMaxVisible = 4 }
}

# Append one broker log line without allowing diagnostic I/O to interrupt notification work.
function Write-NotifyBrokerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $lockTaken = $false
    try {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
        [System.Threading.Monitor]::Enter($script:NotifyBrokerLogLock, [ref]$lockTaken)
        [System.IO.File]::AppendAllText(
            $script:NotifyBrokerLogPath,
            ($line + [System.Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Logging is best-effort and must never escape WinForms callbacks.
    }
    finally {
        if ($lockTaken) { [System.Threading.Monitor]::Exit($script:NotifyBrokerLogLock) }
    }
}

# Fingerprint helper: logs may only contain fingerprints/booleans/timing, never raw title/body/cwd/tab/session
function Get-NotifyBrokerContextFingerprint {
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

# Preload wallpaper: avoid re-reading and decoding the file for each popup
function Get-NotifyBrokerWallpaperImage {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    try {
        $resolved = [System.IO.Path]::GetFullPath($Path.Trim())
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            Write-NotifyBrokerLog -Message 'broker-wallpaper-missing'
            return $null
        }

        $bytes = [System.IO.File]::ReadAllBytes($resolved)
        $stream = [System.IO.MemoryStream]::new($bytes)
        $loaded = $null
        $graphics = $null
        try {
            $loaded = [System.Drawing.Image]::FromStream($stream, $true, $true)
            $bitmap = [System.Drawing.Bitmap]::new($loaded.Width, $loaded.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.DrawImage($loaded, 0, 0, $loaded.Width, $loaded.Height)
            Write-NotifyBrokerLog -Message ('broker-wallpaper-loaded {0}x{1}' -f $bitmap.Width, $bitmap.Height)
            return $bitmap
        }
        finally {
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $loaded) { $loaded.Dispose() }
            $stream.Dispose()
        }
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-wallpaper-error "{0}"' -f $_.Exception.Message)
        return $null
    }
}

$script:NotifyBrokerWallpaperImage = Get-NotifyBrokerWallpaperImage -Path $popupWallpaperPath
$script:NotifyBrokerWallpaperCardCache = @{}

function Get-NotifyBrokerCoverSourceRectangle {
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

function Get-NotifyBrokerWallpaperCardImage {
    param(
        [int]$Width,
        [int]$Height
    )

    if ($null -eq $script:NotifyBrokerWallpaperImage -or $Width -le 0 -or $Height -le 0) { return $null }
    $cacheKey = ('{0}x{1}:{2}' -f $Width, $Height, $script:NotifyBrokerWallpaperOffsetYPixels)
    if ($script:NotifyBrokerWallpaperCardCache.ContainsKey($cacheKey)) {
        return $script:NotifyBrokerWallpaperCardCache[$cacheKey]
    }

    $bitmap = $null
    $graphics = $null
    $overlay = $null
    try {
        $bitmap = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dest = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
        $source = Get-NotifyBrokerCoverSourceRectangle -Image $script:NotifyBrokerWallpaperImage -TargetWidth $Width -TargetHeight $Height -VerticalOffsetPixels $script:NotifyBrokerWallpaperOffsetYPixels
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($script:NotifyBrokerWallpaperImage, $dest, $source, [System.Drawing.GraphicsUnit]::Pixel)
        $overlay = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            $dest,
            [System.Drawing.Color]::FromArgb(170, 0, 0, 0),
            [System.Drawing.Color]::FromArgb(70, 0, 0, 0),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        $graphics.FillRectangle($overlay, $dest)
        $script:NotifyBrokerWallpaperCardCache[$cacheKey] = $bitmap
        Write-NotifyBrokerLog -Message ('broker-wallpaper-card-rendered {0}x{1}' -f $Width, $Height)
        return $bitmap
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-wallpaper-card-error "{0}"' -f $_.Exception.Message)
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        return $null
    }
    finally {
        if ($null -ne $overlay) { $overlay.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
    }
}

[void](Get-NotifyBrokerWallpaperCardImage -Width 420 -Height 154)

function New-NotifyBrokerRoundedPath {
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

# Live-state file for active popups, used by pi-notify-hotkey.ps1 to identify and activate oldest popup
function Get-NotifyBrokerLiveStatePath {
    param([Parameter(Mandatory = $true)][string]$PopupId)

    return (Join-Path (Get-NotifyBridgeLogDir) ('popup-live.{0}.{1}.json' -f $PID, $PopupId))
}

function Save-NotifyBrokerLiveState {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [string]$TargetHostValue,
        [string]$CwdBaseValue,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprintValue,
        [int]$StackIndexValue,
        [int]$TimeoutSecondsValue
    )

    $path = Get-NotifyBrokerLiveStatePath -PopupId $PopupId
    try {
        $ttlSeconds = [Math]::Max(300, ([Math]::Max(3, $TimeoutSecondsValue) + 60))
        $payload = @{
            processId         = $PID
            brokerManaged     = $true
            popupId           = $PopupId
            configFingerprint = Get-NotifyBrokerContextFingerprint -Value $config.ConfigPath
            targetFingerprint = $TargetFingerprintValue
            stackIndex        = $StackIndexValue
            startedAtTicks    = [DateTime]::UtcNow.Ticks
            createdAtUtc      = [DateTime]::UtcNow.ToString('o')
            expiresAtTicks    = [DateTime]::UtcNow.AddSeconds($ttlSeconds).Ticks
        }
        [System.IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-live-state-write-error popupId={0} "{1}"' -f $PopupId, $_.Exception.Message)
    }
}

function Remove-NotifyBrokerLiveState {
    param([Parameter(Mandatory = $true)][string]$PopupId)

    try {
        Remove-Item -LiteralPath (Get-NotifyBrokerLiveStatePath -PopupId $PopupId) -Force -ErrorAction SilentlyContinue
    }
    catch {
    }
}

# Window/tab scan helpers: consistent with pi-notify-popup.ps1 / pi-notify-activate.ps1
function Get-NotifyBrokerWindows {
    param(
        [switch]$TerminalOnly
    )

    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PiNotifyBrokerUser32+EnumWindowsProc]{
        param([IntPtr]$Handle, [IntPtr]$LParam)

        if (-not [PiNotifyBrokerUser32]::IsWindowVisible($Handle)) {
            return $true
        }

        $length = [PiNotifyBrokerUser32]::GetWindowTextLength($Handle)
        if ($length -le 0) {
            return $true
        }

        $builder = New-Object System.Text.StringBuilder ($length + 1)
        [void][PiNotifyBrokerUser32]::GetWindowText($Handle, $builder, $builder.Capacity)
        $title = $builder.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $processId = [uint32]0
        [void][PiNotifyBrokerUser32]::GetWindowThreadProcessId($Handle, [ref]$processId)
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

    [void][PiNotifyBrokerUser32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows.ToArray())
}

function Get-NotifyBrokerTabs {
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
        Write-NotifyBrokerLog -Message ('broker-tabs-error "{0}"' -f $_.Exception.Message)
    }

    return @($rows.ToArray())
}

function Select-NotifyBrokerTab {
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

# Terminal/legacy only: WT title/cwd foreground auto-dismiss must not run for pi-web or unknown origins.
function Test-NotifyForegroundDismissAllowed {
    param([string]$OriginKind = '')

    $kind = if ($null -eq $OriginKind) { '' } else { $OriginKind.Trim() }
    return ([string]::IsNullOrWhiteSpace($kind) -or $kind -eq 'terminal')
}

# Foreground target detection: auto-close popup when user switches to the target tab
function Test-NotifyBrokerForegroundTarget {
    param(
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint = ''
    )

    if ([string]::IsNullOrWhiteSpace($CurrentDirBase) -and [string]::IsNullOrWhiteSpace($SourceTabTitleValue)) {
        return $false
    }

    try {
        $handle = [PiNotifyBrokerUser32]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) {
            return $false
        }

        $processId = [uint32]0
        [void][PiNotifyBrokerUser32]::GetWindowThreadProcessId($handle, [ref]$processId)
        $process = Get-Process -Id $processId -ErrorAction Stop
        if ($process.ProcessName -notmatch 'WindowsTerminal|Terminal') {
            return $false
        }

        $titleLength = [PiNotifyBrokerUser32]::GetWindowTextLength($handle)
        $windowTitle = ''
        if ($titleLength -gt 0) {
            $builder = New-Object System.Text.StringBuilder ($titleLength + 1)
            [void][PiNotifyBrokerUser32]::GetWindowText($handle, $builder, $builder.Capacity)
            $windowTitle = $builder.ToString().Trim()
        }

        $selectedTab = @(Get-NotifyBrokerTabs -Handle $handle | Where-Object { $_.IsSelected } | Select-Object -First 1)
        $selectedTitle = if ($selectedTab.Count -gt 0) { [string]$selectedTab[0].Name } else { '' }
        $haystack = @($selectedTitle, $windowTitle) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        if (-not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)) {
            foreach ($value in $haystack) {
                if ($value.IndexOf($SourceTabTitleValue, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Write-NotifyBrokerLog -Message ('broker-foreground-target-match sourceTabFingerprint={0} selectedTabFingerprint={1} windowFingerprint={2}' -f (Get-NotifyBrokerContextFingerprint -Value $SourceTabTitleValue), (Get-NotifyBrokerContextFingerprint -Value $selectedTitle), (Get-NotifyBrokerContextFingerprint -Value $windowTitle))
                    if ($selectedTab.Count -gt 0) {
                        $windowObj = [pscustomobject]@{ Handle = $handle; Title = $windowTitle; ProcessId = [int]$processId; ProcessName = $process.ProcessName }
                        $best = [pscustomobject]@{ Window = $windowObj; Score = 1; Tab = $selectedTab[0].Element; TabName = $selectedTitle; TabIndex = $selectedTab[0].Index }
                        Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint -SourceTabTitleValue $SourceTabTitleValue
                    }
                    return $true
                }
            }

            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
            foreach ($value in $haystack) {
                if ($value.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Write-NotifyBrokerLog -Message ('broker-foreground-target-match cwdFingerprint={0} selectedTabFingerprint={1} windowFingerprint={2}' -f (Get-NotifyBrokerContextFingerprint -Value $CurrentDirBase), (Get-NotifyBrokerContextFingerprint -Value $selectedTitle), (Get-NotifyBrokerContextFingerprint -Value $windowTitle))
                    if ($selectedTab.Count -gt 0) {
                        $windowObj = [pscustomobject]@{ Handle = $handle; Title = $windowTitle; ProcessId = [int]$processId; ProcessName = $process.ProcessName }
                        $best = [pscustomobject]@{ Window = $windowObj; Score = 1; Tab = $selectedTab[0].Element; TabName = $selectedTitle; TabIndex = $selectedTab[0].Index }
                        Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint
                    }
                    return $true
                }
            }
        }
    }
    catch {
    }

    return $false
}

# Click activation: keep both a global recent cache and target-specific caches to avoid
# repeating expensive UIAutomation scans when several popup cards are visible.
function Update-NotifyBrokerTabCache {
    param(
        [Parameter(Mandatory = $true)]
        $Best,
        [string]$TargetFingerprint = '',
        [string]$SourceTabTitleValue = ''
    )

    if (-not (Test-NotifyBrokerSessionTaggedTitle -Value $SourceTabTitleValue)) { return }

    $entry = [pscustomobject]@{
        WindowHandle  = $Best.Window.Handle
        WindowTitle   = $Best.Window.Title
        ProcessId     = $Best.Window.ProcessId
        TabName       = $Best.TabName
        TabIndex      = $Best.TabIndex
        Tab           = $Best.Tab
        UpdatedAtUtc  = [DateTime]::UtcNow
    }
    $script:NotifyBrokerTabCache = $entry
    $script:NotifyBrokerTabCacheAt = $entry.UpdatedAtUtc
    if (-not [string]::IsNullOrWhiteSpace($TargetFingerprint)) {
        $script:NotifyBrokerTabCacheByTarget[$TargetFingerprint] = $entry
    }
    Write-NotifyBrokerLog -Message ('broker-cache-updated windowFingerprint={0} tabFingerprint={1} tabIndex={2} targetFingerprint={3}' -f (Get-NotifyBrokerContextFingerprint -Value $Best.Window.Title), (Get-NotifyBrokerContextFingerprint -Value $Best.TabName), $Best.TabIndex, $TargetFingerprint)
}

function Test-NotifyBrokerSessionTaggedTitle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim() -match ' \u00B7 #[0-9a-f]{12}$'
}

function Test-NotifyBrokerTabCacheEntryValid {
    param(
        $CacheEntry,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue
    )

    if (-not (Test-NotifyBrokerSessionTaggedTitle -Value $SourceTabTitleValue)) { return $false }
    if ($null -eq $CacheEntry) { return $false }
    if (([DateTime]::UtcNow - $CacheEntry.UpdatedAtUtc).TotalSeconds -gt $script:NotifyBrokerTabCacheTtlSeconds) { return $false }
    $handle = $CacheEntry.WindowHandle
    if ($null -eq $handle -or $handle -eq [IntPtr]::Zero) { return $false }
    if ($null -eq $CacheEntry.Tab) { return $false }
    $processId = [uint32]0
    [void][PiNotifyBrokerUser32]::GetWindowThreadProcessId($handle, [ref]$processId)
    if ($processId -eq 0) { return $false }
    try { Get-Process -Id $processId -ErrorAction Stop | Out-Null } catch { return $false }

    try {
        $cachedTabName = ([string]$CacheEntry.Tab.Current.Name).Trim()
    }
    catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($cachedTabName)) { return $false }
    $CacheEntry.TabName = $cachedTabName
    $cachedWindowTitle = [string]$CacheEntry.WindowTitle
    if (-not [string]::IsNullOrWhiteSpace($SourceTabTitleValue) -and $cachedTabName.IndexOf($SourceTabTitleValue, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentDirBase) -and $cachedTabName.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and $cachedWindowTitle.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $false
    }
    return $true
}

function Get-NotifyBrokerTabCacheCandidate {
    param(
        [string]$TargetFingerprint,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue
    )

    if (-not (Test-NotifyBrokerSessionTaggedTitle -Value $SourceTabTitleValue)) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($TargetFingerprint) -and $script:NotifyBrokerTabCacheByTarget.ContainsKey($TargetFingerprint)) {
        $targetEntry = $script:NotifyBrokerTabCacheByTarget[$TargetFingerprint]
        if (Test-NotifyBrokerTabCacheEntryValid -CacheEntry $targetEntry -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue) {
            return [pscustomobject]@{ Entry = $targetEntry; Source = 'target' }
        }
        $script:NotifyBrokerTabCacheByTarget.Remove($TargetFingerprint)
    }

    if (Test-NotifyBrokerTabCacheEntryValid -CacheEntry $script:NotifyBrokerTabCache -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue) {
        return [pscustomobject]@{ Entry = $script:NotifyBrokerTabCache; Source = 'global' }
    }

    return $null
}

function Update-NotifyBrokerTabCacheForTarget {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint
    )

    $startedAt = [DateTime]::UtcNow
    try {
        if (-not (Test-NotifyBrokerSessionTaggedTitle -Value $SourceTabTitleValue)) {
            Write-NotifyBrokerLog -Message ('broker-prewarm-skip untagged-source targetFingerprint={0}' -f $TargetFingerprint)
            return
        }

        $cacheCandidate = Get-NotifyBrokerTabCacheCandidate -TargetFingerprint $TargetFingerprint -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue
        if ($null -ne $cacheCandidate) {
            Write-NotifyBrokerLog -Message ('broker-prewarm-cache-hit source={0} targetFingerprint={1} elapsedMs={2}' -f $cacheCandidate.Source, $TargetFingerprint, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
        }

        $requiresCwdMatch = -not [string]::IsNullOrWhiteSpace($CurrentDirBase)
        $hasPreciseSourceTitle = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
        if (-not $requiresCwdMatch -and -not $hasPreciseSourceTitle) {
            Write-NotifyBrokerLog -Message ('broker-prewarm-skip missing-target-metadata targetFingerprint={0}' -f $TargetFingerprint)
            return
        }

        $prewarmKey = if ([string]::IsNullOrWhiteSpace($TargetFingerprint)) { Get-NotifyBrokerContextFingerprint -Value ('{0}|{1}|{2}' -f $TargetHost, $CurrentDirBase, $SourceTabTitleValue) } else { $TargetFingerprint }
        if ($script:NotifyBrokerPrewarmLastScanByTarget.ContainsKey($prewarmKey)) {
            $ageSeconds = ([DateTime]::UtcNow - $script:NotifyBrokerPrewarmLastScanByTarget[$prewarmKey]).TotalSeconds
            if ($ageSeconds -lt $script:NotifyBrokerPrewarmMinIntervalSeconds) {
                Write-NotifyBrokerLog -Message ('broker-prewarm-skip recent-scan targetFingerprint={0} ageMs={1}' -f $TargetFingerprint, [int]($ageSeconds * 1000))
                return
            }
        }
        $script:NotifyBrokerPrewarmLastScanByTarget[$prewarmKey] = [DateTime]::UtcNow

        $keywords = @($SourceTabTitleValue, $CurrentDirBase, $TargetHost) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique

        $best = $null
        $eligibleCount = 0
        $windows = @(Get-NotifyBrokerWindows -TerminalOnly)
        Write-NotifyBrokerLog -Message ('broker-prewarm-scan windows={0} targetFingerprint={1}' -f $windows.Count, $TargetFingerprint)
        foreach ($window in $windows) {
            $baseScore = 0
            foreach ($keyword in $keywords) {
                if ($window.Title.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $baseScore += 20 }
            }
            $tabs = @(Get-NotifyBrokerTabs -Handle $window.Handle)
            if ($tabs.Count -eq 0) { continue }
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
                if ($sourceTabTitleMatch) { $score += 300 }
                $cwdKeywordMatch = $requiresCwdMatch -and ($matchedKeywords -contains $CurrentDirBase)
                if ($hasPreciseSourceTitle -and -not $sourceTabTitleMatch) { $score = 0 }
                elseif ($requiresCwdMatch -and -not $cwdKeywordMatch) { $score = 0 }
                if ($score -le 0) { continue }
                $eligibleCount += 1
                $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name; TabIndex = $tab.Index }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) { $best = $candidate }
            }
        }

        if ($eligibleCount -gt 1) {
            if (-not [string]::IsNullOrWhiteSpace($TargetFingerprint)) {
                $script:NotifyBrokerTabCacheByTarget.Remove($TargetFingerprint)
            }
            Write-NotifyBrokerLog -Message ('broker-prewarm-ambiguous targetFingerprint={0} candidateCount={1} bestScore={2} elapsedMs={3}' -f $TargetFingerprint, $eligibleCount, $best.Score, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }

        if ($null -ne $best) {
            Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint -SourceTabTitleValue $SourceTabTitleValue
            Write-NotifyBrokerLog -Message ('broker-prewarm-cache-updated tabFingerprint={0} targetFingerprint={1} elapsedMs={2}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName), $TargetFingerprint, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
        }
        else {
            Write-NotifyBrokerLog -Message ('broker-prewarm-miss targetFingerprint={0} elapsedMs={1}' -f $TargetFingerprint, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
        }
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-prewarm-error targetFingerprint={0} "{1}"' -f $TargetFingerprint, $_.Exception.Message)
    }
}

function Queue-NotifyBrokerPrewarm {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint,
        [string]$PopupId = ''
    )

    if ($null -eq $script:NotifyBrokerPrewarmQueue) { $script:NotifyBrokerPrewarmQueue = [System.Collections.Generic.Queue[object]]::new() }
    if ($null -eq $script:NotifyBrokerPrewarmTimer) {
        $script:NotifyBrokerPrewarmTimer = New-Object System.Windows.Forms.Timer
        $script:NotifyBrokerPrewarmTimer.Interval = $script:NotifyBrokerPrewarmDelayMs
        $script:NotifyBrokerPrewarmTimer.Add_Tick({
            $this.Stop()
            if ($null -eq $script:NotifyBrokerPrewarmQueue -or $script:NotifyBrokerPrewarmQueue.Count -le 0) { return }
            $request = $script:NotifyBrokerPrewarmQueue.Dequeue()
            if (-not [string]::IsNullOrWhiteSpace($request.PopupId) -and -not $script:NotifyBrokerActivePopups.ContainsKey($request.PopupId)) {
                Write-NotifyBrokerLog -Message ('broker-prewarm-skip closed-popup popupId={0} targetFingerprint={1}' -f $request.PopupId, $request.TargetFingerprint)
                if ($script:NotifyBrokerPrewarmQueue.Count -gt 0) { $this.Start() }
                return
            }
            Write-NotifyBrokerLog -Message ('broker-prewarm-start popupId={0} targetFingerprint={1}' -f $request.PopupId, $request.TargetFingerprint)
            Update-NotifyBrokerTabCacheForTarget -TargetHost $request.TargetHost -CurrentDirBase $request.CurrentDirBase -SourceTabTitleValue $request.SourceTabTitleValue -TargetFingerprint $request.TargetFingerprint
            if ($script:NotifyBrokerPrewarmQueue.Count -gt 0) { $this.Start() }
        })
    }

    $request = [pscustomobject]@{
        TargetHost = $TargetHost
        CurrentDirBase = $CurrentDirBase
        SourceTabTitleValue = $SourceTabTitleValue
        TargetFingerprint = $TargetFingerprint
        PopupId = $PopupId
    }
    $existing = @($script:NotifyBrokerPrewarmQueue.ToArray())
    $script:NotifyBrokerPrewarmQueue.Clear()
    foreach ($queued in $existing) {
        if ([string]::IsNullOrWhiteSpace($TargetFingerprint) -or $queued.TargetFingerprint -ne $TargetFingerprint) {
            if ($script:NotifyBrokerPrewarmQueue.Count -lt $script:NotifyBrokerPrewarmMaxQueue) {
                $script:NotifyBrokerPrewarmQueue.Enqueue($queued)
            }
        }
        else {
            Write-NotifyBrokerLog -Message ('broker-prewarm-dedupe popupId={0} replacedBy={1} targetFingerprint={2}' -f $queued.PopupId, $PopupId, $TargetFingerprint)
        }
    }
    if ($script:NotifyBrokerPrewarmQueue.Count -ge $script:NotifyBrokerPrewarmMaxQueue) {
        Write-NotifyBrokerLog -Message ('broker-prewarm-drop queue-full popupId={0} targetFingerprint={1}' -f $PopupId, $TargetFingerprint)
        return
    }
    $script:NotifyBrokerPrewarmQueue.Enqueue($request)
    Write-NotifyBrokerLog -Message ('broker-prewarm-queued popupId={0} targetFingerprint={1} queue={2}' -f $PopupId, $TargetFingerprint, $script:NotifyBrokerPrewarmQueue.Count)
    $script:NotifyBrokerPrewarmTimer.Start()
}

function Invoke-NotifyBrokerOldestPopupActivation {
    $entries = @($script:NotifyBrokerActivePopups.Values | Sort-Object { if ($_.PSObject.Properties['CreatedAtUtc']) { $_.CreatedAtUtc } else { [DateTime]::MinValue } }, { if ($_.PSObject.Properties['StackIndex']) { [int]$_.StackIndex } else { 0 } })
    if ($entries.Count -eq 0) {
        Write-NotifyBrokerLog -Message 'broker-activate-oldest no-active-popups'
        return $false
    }
    foreach ($entry in $entries) {
        $tag = $entry.Form.Tag
        if ($null -eq $tag) {
            Write-NotifyBrokerLog -Message ('broker-activate-oldest skip missing-tag popupId={0}' -f $entry.PopupId)
            continue
        }
        if (($tag.ContainsKey('TerminalState') -and $tag.TerminalState.Value) -or
            ($tag.ContainsKey('OriginKind') -and
             [string]$tag.OriginKind -eq 'pi-web' -and
             $tag.ContainsKey('RecoveryState') -and
             [string]$tag.RecoveryState -eq 'unavailable')) {
            Write-NotifyBrokerLog -Message ('broker-activate-oldest skip terminal-or-unavailable popupId={0}' -f $tag.PopupId)
            continue
        }

        if (-not (Set-NotifyBrokerPopupActivating -Tag $tag)) {
            Write-NotifyBrokerLog -Message ('broker-activate-oldest skip activation-rejected popupId={0}' -f $tag.PopupId)
            continue
        }
        Write-NotifyBrokerLog -Message ('broker-activate-oldest popupId={0} targetFingerprint={1}' -f $tag.PopupId, $tag.TargetFingerprint)
        $tag.ShouldActivate.Value = $true
        if ($tag.ContainsKey('DidActivate')) { $tag.DidActivate.Value = $true }
        $tag.ActivationQueued.Value = $true
        $originKind = if ($tag.ContainsKey('OriginKind')) { [string]$tag.OriginKind } else { '' }
        $notificationId = if ($tag.ContainsKey('NotificationId')) { [string]$tag.NotificationId } else { '' }
        $snapshotId = if ($tag.ContainsKey('SnapshotId')) { [string]$tag.SnapshotId } else { '' }
        $recoveryTicketId = if ($tag.ContainsKey('RecoveryTicketId')) { [string]$tag.RecoveryTicketId } else { '' }
        [void](Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -FormToClose $tag.Form -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId)
        return $true
    }

    Write-NotifyBrokerLog -Message 'broker-activate-oldest no-eligible-popups'
    return $false
}

function Get-NotifyBrokerRecoveryUiText {
    param([Parameter(Mandatory = $true)][ValidateSet('recovering-title', 'recovering-body', 'opening-title', 'opening-body', 'unavailable-title', 'unavailable-body')][string]$Name)

    $points = switch ($Name) {
        'recovering-title' { @(0x6b63,0x5728,0x6062,0x590d,0x4f1a,0x8bdd,0x2026) }
        'recovering-body' { @(0x8fde,0x63a5,0x6062,0x590d,0x540e,0x5373,0x53ef,0x70b9,0x51fb,0x3002) }
        'opening-title' { @(0x6b63,0x5728,0x6253,0x5f00,0x4f1a,0x8bdd,0x2026) }
        'opening-body' { @(0x6b63,0x5728,0x6253,0x5f00,0x7ed1,0x5b9a,0x4f1a,0x8bdd,0xff0c,0x8bf7,0x7a0d,0x5019,0x3002) }
        'unavailable-title' { @(0x76ee,0x6807,0x6682,0x65f6,0x4e0d,0x53ef,0x7528) }
        default { @(0x4e3a,0x907f,0x514d,0x8df3,0x9519,0x4f1a,0x8bdd,0xff0c,0x6b64,0x901a,0x77e5,0x5df2,0x505c,0x7528,0x3002) }
    }
    return -join @($points | ForEach-Object { [char]$_ })
}

function Reset-NotifyBrokerPopupFeedbackVisuals {
    param([Parameter(Mandatory = $true)][hashtable]$Tag)

    if ($null -ne $Tag.Form) {
        $Tag.Form.Opacity = $Tag.OriginalOpacity
        $Tag.Form.BackColor = $Tag.OriginalCardColor
        $Tag.Form.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
    if ($null -ne $Tag.Panel) {
        $Tag.Panel.BackColor = $Tag.OriginalPanelColor
        $Tag.Panel.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
    if ($null -ne $Tag.AppLabel) {
        $Tag.AppLabel.Text = $Tag.OriginalAppText
        $Tag.AppLabel.ForeColor = $Tag.OriginalAppForeColor
        $Tag.AppLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
    if ($null -ne $Tag.SessionLabel) {
        $Tag.SessionLabel.Text = $Tag.OriginalSessionText
        $Tag.SessionLabel.ForeColor = $Tag.OriginalSessionForeColor
        $Tag.SessionLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
    if ($null -ne $Tag.TitleLabel) { $Tag.TitleLabel.ForeColor = $Tag.OriginalTitleForeColor }
    if ($null -ne $Tag.BodyLabel) { $Tag.BodyLabel.ForeColor = $Tag.OriginalBodyForeColor }
    if ($null -ne $Tag.CloseLabel) {
        $Tag.CloseLabel.Text = $Tag.OriginalCloseText
        $Tag.CloseLabel.ForeColor = $Tag.OriginalCloseForeColor
        $Tag.CloseLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
}

function Set-NotifyBrokerRecoveryUiState {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Tag,
        [Parameter(Mandatory = $true)][ValidateSet('recovering', 'ready', 'unavailable')][string]$State
    )

    $Tag.RecoveryState = $State
    if ($State -eq 'recovering') {
        $Tag.TitleLabel.Text = Get-NotifyBrokerRecoveryUiText -Name 'recovering-title'
        $Tag.BodyLabel.Text = Get-NotifyBrokerRecoveryUiText -Name 'recovering-body'
        foreach ($control in @($Tag.Form, $Tag.Panel, $Tag.AppLabel, $Tag.SessionLabel, $Tag.TitleLabel, $Tag.BodyLabel)) {
            $control.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        return
    }
    if ($State -eq 'ready') {
        Reset-NotifyBrokerPopupFeedbackVisuals -Tag $Tag
        $Tag.TitleLabel.Text = $Tag.OriginalTitle
        $Tag.BodyLabel.Text = $Tag.OriginalBody
        foreach ($control in @($Tag.Form, $Tag.Panel, $Tag.AppLabel, $Tag.SessionLabel, $Tag.TitleLabel, $Tag.BodyLabel)) {
            $control.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        return
    }

    Reset-NotifyBrokerPopupFeedbackVisuals -Tag $Tag
    $Tag.TitleLabel.Text = Get-NotifyBrokerRecoveryUiText -Name 'unavailable-title'
    $Tag.BodyLabel.Text = Get-NotifyBrokerRecoveryUiText -Name 'unavailable-body'
    foreach ($control in @($Tag.Form, $Tag.Panel, $Tag.AppLabel, $Tag.SessionLabel, $Tag.TitleLabel, $Tag.BodyLabel)) {
        $control.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Complete-NotifyBrokerPopupLifecycle {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Tag,
        [Parameter(Mandatory = $true)][ValidateSet('focused', 'handled', 'failed', 'dismissed')][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    if ($null -eq $Tag -or $null -eq $Tag.Form -or $Tag.Form.IsDisposed) { return $false }
    $alreadyTerminal = $Tag.TerminalState.Value
    if (-not $alreadyTerminal) {
        $Tag.TerminalState.Value = $true
        $Tag.TerminalOutcome = $Outcome
        $Tag.TerminalReason = $Reason
        $Tag.Activating.Value = $false
        $Tag.Timer.Stop()
        $Tag.FocusWatchTimer.Stop()
        $Tag.ActivationWatchdogTimer.Stop()
        Write-NotifyBrokerLog -Message ('broker-popup-terminal popupId={0} outcome={1} reason={2}' -f $Tag.PopupId, $Outcome, $Reason)
    }

    if ($Outcome -eq 'failed') {
        if ($alreadyTerminal) { return $false }
        Set-NotifyBrokerRecoveryUiState -Tag $Tag -State 'unavailable'
        $Tag.FailureCloseTimer.Stop()
        $Tag.FailureCloseTimer.Start()
        return $true
    }

    $Tag.FailureCloseTimer.Stop()
    if (-not $Tag.CloseRequested.Value) {
        $Tag.CloseRequested.Value = $true
        $Tag.Form.Close()
        return $true
    }
    return $false
}

function Invoke-NotifyBrokerActivationWatchdog {
    param([Parameter(Mandatory = $true)][hashtable]$Tag)

    if ($Tag.TerminalState.Value) { return $false }
    Write-NotifyBrokerLog -Message ('broker-activation-watchdog popupId={0}' -f $Tag.PopupId)
    [void](Complete-NotifyBrokerPopupLifecycle -Tag $Tag -Outcome 'failed' -Reason 'activation-watchdog')
    [void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $Tag.PopupId)
    Stop-NotifyBrokerExactWorkersForPopup -PopupId $Tag.PopupId -Reason 'activation-watchdog'
    return $true
}

function Set-NotifyBrokerExactWorkerFailClosed {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    Write-NotifyBrokerLog -Message ('broker-exact-worker-rejected popupId={0} reason={1} active={2} max={3}' -f $PopupId, $Reason, $script:NotifyBrokerExactWorkers.Count, $script:NotifyBrokerExactWorkerMax)
    if (-not $script:NotifyBrokerActivePopups.ContainsKey($PopupId)) { return }

    $entry = $script:NotifyBrokerActivePopups[$PopupId]
    if ($null -eq $entry -or $null -eq $entry.Form -or $entry.Form.IsDisposed -or $null -eq $entry.Form.Tag) { return }

    $tag = $entry.Form.Tag
    [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason $Reason)
}

function Close-NotifyBrokerExactWorkerResources {
    param([Parameter(Mandatory = $true)]$Worker)

    try { $Worker.PowerShell.Dispose() } catch {}
    try { $Worker.Runspace.Close() } catch {}
    try { $Worker.Runspace.Dispose() } catch {}
}

function Request-NotifyBrokerExactWorkerStop {
    param(
        [Parameter(Mandatory = $true)]$Worker,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    # Cancellation ownership is first-writer-wins. Deferred activations are
    # deliberately stored separately, so a worker never owns another popup's
    # user intent.
    if (-not [string]::IsNullOrWhiteSpace([string]$Worker.CancelReason) -or
        $null -ne $Worker.StopAsync) {
        return $true
    }

    $Worker.CancelReason = $Reason
    if ($Worker.Async.IsCompleted) { return $true }

    try {
        $Worker.StopAsync = $Worker.PowerShell.BeginStop($null, $null)
        Write-NotifyBrokerLog -Message ('broker-exact-worker-cancel-requested popupId={0} mode={1} reason={2}' -f $Worker.PopupId, $Worker.Mode, $Reason)
        return $true
    }
    catch {
        $Worker.CancelReason = ''
        Write-NotifyBrokerLog -Message ('broker-exact-worker-cancel-error popupId={0} mode={1} reason={2}' -f $Worker.PopupId, $Worker.Mode, $Reason)
        return $false
    }
}

function Add-NotifyBrokerDeferredActivation {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    if ($script:NotifyBrokerDeferredActivations.ContainsKey($PopupId)) {
        return $true
    }
    if ($script:NotifyBrokerDeferredActivations.Count -ge $script:NotifyBrokerDeferredActivationMax) {
        Write-NotifyBrokerLog -Message ('broker-deferred-activation-rejected popupId={0} pending={1} max={2}' -f $PopupId, $script:NotifyBrokerDeferredActivations.Count, $script:NotifyBrokerDeferredActivationMax)
        return $false
    }

    $script:NotifyBrokerDeferredActivationSequence += 1
    $script:NotifyBrokerDeferredActivations[$PopupId] = [pscustomobject]@{
        PopupId = $PopupId
        NotificationId = $NotificationId
        SnapshotId = $SnapshotId
        RecoveryTicketId = $RecoveryTicketId
        Sequence = $script:NotifyBrokerDeferredActivationSequence
    }
    Write-NotifyBrokerLog -Message ('broker-deferred-activation-queued popupId={0} pending={1} max={2}' -f $PopupId, $script:NotifyBrokerDeferredActivations.Count, $script:NotifyBrokerDeferredActivationMax)
    return $true
}

function Remove-NotifyBrokerDeferredActivationForPopup {
    param([Parameter(Mandatory = $true)][string]$PopupId)

    if (-not $script:NotifyBrokerDeferredActivations.ContainsKey($PopupId)) {
        return $false
    }
    [void]$script:NotifyBrokerDeferredActivations.Remove($PopupId)
    Write-NotifyBrokerLog -Message ('broker-deferred-activation-suppressed popupId={0} pending={1}' -f $PopupId, $script:NotifyBrokerDeferredActivations.Count)
    return $true
}

function Take-NotifyBrokerDeferredActivation {
    if ($script:NotifyBrokerDeferredActivations.Count -eq 0) {
        return $null
    }

    $next = @($script:NotifyBrokerDeferredActivations.Values |
        Sort-Object Sequence |
        Select-Object -First 1)
    if ($next.Count -eq 0) {
        return $null
    }

    $deferred = $next[0]
    [void]$script:NotifyBrokerDeferredActivations.Remove([string]$deferred.PopupId)
    return $deferred
}

function Test-NotifyBrokerActivationIntent {
    param([Parameter(Mandatory = $true)][string]$PopupId)

    if ($script:NotifyBrokerDeferredActivations.ContainsKey($PopupId)) {
        return $true
    }
    return @($script:NotifyBrokerExactWorkers.Values | Where-Object {
        $_.PopupId -eq $PopupId -and $_.Mode -eq 'activate'
    }).Count -gt 0
}

function Start-NotifyBrokerNextDeferredActivation {
    if ($script:NotifyBrokerExactWorkers.Count -ge $script:NotifyBrokerExactWorkerMax) {
        return
    }

    # Skip intents whose popup closed while they were waiting. Only one live
    # intent is launched per reclaimed worker slot.
    while ($script:NotifyBrokerDeferredActivations.Count -gt 0) {
        $deferred = Take-NotifyBrokerDeferredActivation
        if ($null -eq $deferred) { return }
        if (-not $script:NotifyBrokerActivePopups.ContainsKey([string]$deferred.PopupId)) {
            Write-NotifyBrokerLog -Message ('broker-deferred-activation-stale popupId={0}' -f $deferred.PopupId)
            continue
        }

        [void](Start-NotifyBrokerExactWorker -PopupId $deferred.PopupId -Mode 'activate' -NotificationId $deferred.NotificationId -SnapshotId $deferred.SnapshotId -RecoveryTicketId $deferred.RecoveryTicketId)
        return
    }
}

function Stop-NotifyBrokerExactWorkersForPopup {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [string]$Reason = 'popup-closed'
    )

    foreach ($worker in @($script:NotifyBrokerExactWorkers.Values | Where-Object { $_.PopupId -eq $PopupId })) {
        [void](Request-NotifyBrokerExactWorkerStop -Worker $worker -Reason $Reason)
    }
    if ($script:NotifyBrokerExactWorkers.Count -gt 0 -and $null -ne $script:NotifyBrokerExactWorkerTimer) {
        $script:NotifyBrokerExactWorkerTimer.Start()
    }
}

function Stop-NotifyBrokerAllExactWorkers {
    param([string]$Reason = 'broker-exit')

    $script:NotifyBrokerDeferredActivations.Clear()
    foreach ($id in @($script:NotifyBrokerExactWorkers.Keys)) {
        $worker = $script:NotifyBrokerExactWorkers[$id]
        if ($null -eq $worker) { continue }
        $worker.CancelReason = $Reason
        try {
            if (-not $worker.Async.IsCompleted) { $worker.PowerShell.Stop() }
        }
        catch {
        }
        try {
            if ($null -ne $worker.StopAsync -and $worker.StopAsync.IsCompleted) { $worker.PowerShell.EndStop($worker.StopAsync) }
        }
        catch {
        }
        try {
            if ($worker.Async.IsCompleted) { [void]$worker.PowerShell.EndInvoke($worker.Async) }
        }
        catch {
        }
        Close-NotifyBrokerExactWorkerResources -Worker $worker
        [void]$script:NotifyBrokerExactWorkers.Remove($id)
    }
}

function Start-NotifyBrokerExactWorker {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [Parameter(Mandatory = $true)][ValidateSet('resolve', 'activate')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    $existing = @($script:NotifyBrokerExactWorkers.Values | Where-Object { $_.PopupId -eq $PopupId -and $_.Mode -eq $Mode })
    if ($existing.Count -gt 0) {
        return $true
    }

    if ($Mode -eq 'activate') {
        if ($script:NotifyBrokerDeferredActivations.ContainsKey($PopupId)) {
            return $true
        }

        $resolvers = @($script:NotifyBrokerExactWorkers.Values | Where-Object {
            $_.PopupId -eq $PopupId -and
            $_.Mode -eq 'resolve' -and
            [string]::IsNullOrWhiteSpace([string]$_.CancelReason) -and
            $null -eq $_.StopAsync
        } | Select-Object -First 1)
        if ($resolvers.Count -gt 0) {
            if (-not (Add-NotifyBrokerDeferredActivation -PopupId $PopupId -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId)) {
                Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-queue-cap-reached'
                return $false
            }
            if (-not (Request-NotifyBrokerExactWorkerStop -Worker $resolvers[0] -Reason 'superseded-by-activation')) {
                [void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $PopupId)
                Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-cancel-error'
                return $false
            }
            Write-NotifyBrokerLog -Message ('broker-exact-worker-activation-deferred popupId={0} active={1} max={2}' -f $PopupId, $script:NotifyBrokerExactWorkers.Count, $script:NotifyBrokerExactWorkerMax)
            return $true
        }
    }

    if ($script:NotifyBrokerExactWorkers.Count -ge $script:NotifyBrokerExactWorkerMax) {
        if ($Mode -eq 'activate') {
            # Activation is user intent and outranks passive auto-resolution.
            # Reclaim one resolver asynchronously; it continues to count
            # against the hard cap until the timer confirms it has stopped.
            $resolverVictim = @($script:NotifyBrokerExactWorkers.Values |
                Where-Object { $_.Mode -eq 'resolve' -and [string]::IsNullOrWhiteSpace([string]$_.CancelReason) } |
                Sort-Object StartedAtUtc |
                Select-Object -First 1)
            if ($resolverVictim.Count -gt 0) {
                if (-not (Add-NotifyBrokerDeferredActivation -PopupId $PopupId -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId)) {
                    Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-queue-cap-reached'
                    return $false
                }
                if (Request-NotifyBrokerExactWorkerStop -Worker $resolverVictim[0] -Reason 'preempted-by-activation') {
                    Write-NotifyBrokerLog -Message ('broker-exact-worker-activation-preempt popupId={0} victimPopupId={1} active={2} max={3}' -f $PopupId, $resolverVictim[0].PopupId, $script:NotifyBrokerExactWorkers.Count, $script:NotifyBrokerExactWorkerMax)
                    return $true
                }
                [void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $PopupId)
            }
        }

        $reason = if ($Mode -eq 'resolve') { 'resolve-cap-reached' } else { 'activate-cap-reached' }
        Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason $reason
        return $false
    }

    $script:NotifyBrokerExactWorkerSequence += 1
    $workerId = ('exact-{0}' -f $script:NotifyBrokerExactWorkerSequence)
    $runspace = $null
    $powerShell = $null
    $workerScript = @'
param($CommonPath, $ConfigPath, $Mode, $NotificationId, $SnapshotId, $RecoveryTicketId, $ActivationRecoveryWaitMs)
$ErrorActionPreference = 'Stop'
. $CommonPath
$configArgs = @{}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $configArgs.ConfigPath = $ConfigPath }
$workerConfig = Ensure-NotifyBridgeConfig @configArgs
if ($Mode -eq 'resolve') {
    $outcome = Wait-NotifyExactRouteRecovery -NotificationId $NotificationId -RecoveryTicketId $RecoveryTicketId -Config $workerConfig -WaitMs 125000
    $decision = $outcome.Decision
}
else {
    $outcome = Invoke-NotifyExactRouteRecoveryAndActivate -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId -Config $workerConfig -RecoveryWaitMs $ActivationRecoveryWaitMs -ActivateWaitMs 45000 -ActivateTimeoutMs 48000
    $decision = $outcome.Decision
}
[pscustomobject]@{
    Decision = [string]$decision.Decision
    Result = [string]$decision.Result
    Reason = [string]$decision.Reason
    SnapshotId = if ($outcome.PSObject.Properties['SnapshotId']) { [string]$outcome.SnapshotId } elseif ($decision.PSObject.Properties['SnapshotId']) { [string]$decision.SnapshotId } else { '' }
    RecoveryTicketId = $RecoveryTicketId
}
'@
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $powerShell = [System.Management.Automation.PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript($workerScript)
        [void]$powerShell.AddParameter('CommonPath', (Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'))
        [void]$powerShell.AddParameter('ConfigPath', $ConfigPath)
        [void]$powerShell.AddParameter('Mode', $Mode)
        [void]$powerShell.AddParameter('NotificationId', $NotificationId)
        [void]$powerShell.AddParameter('SnapshotId', $SnapshotId)
        [void]$powerShell.AddParameter('RecoveryTicketId', $RecoveryTicketId)
        [void]$powerShell.AddParameter('ActivationRecoveryWaitMs', $script:NotifyBrokerActivationRecoveryWaitMs)
        $async = $powerShell.BeginInvoke()
    }
    catch {
        if ($null -ne $powerShell) { try { $powerShell.Dispose() } catch {} }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch {}
            try { $runspace.Dispose() } catch {}
        }
        Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'worker-start-error'
        return $false
    }
    $script:NotifyBrokerExactWorkers[$workerId] = [pscustomobject]@{
        WorkerId = $workerId
        PopupId = $PopupId
        Mode = $Mode
        PowerShell = $powerShell
        Runspace = $runspace
        Async = $async
        StartedAtUtc = [DateTime]::UtcNow
        StopAsync = $null
        CancelReason = ''
    }

    if ($null -eq $script:NotifyBrokerExactWorkerTimer) {
        $script:NotifyBrokerExactWorkerTimer = New-Object System.Windows.Forms.Timer
        $script:NotifyBrokerExactWorkerTimer.Interval = 100
        $script:NotifyBrokerExactWorkerTimer.Add_Tick({
            foreach ($id in @($script:NotifyBrokerExactWorkers.Keys)) {
                $worker = $script:NotifyBrokerExactWorkers[$id]
                if ($null -eq $worker) { continue }
                $completionReady = if ($null -ne $worker.StopAsync) { $worker.StopAsync.IsCompleted } else { $worker.Async.IsCompleted }
                if (-not $completionReady) { continue }

                $cancelReason = [string]$worker.CancelReason
                $result = $null
                try {
                    if ($null -ne $worker.StopAsync) { $worker.PowerShell.EndStop($worker.StopAsync) }
                    if ($worker.Async.IsCompleted) {
                        $rows = @($worker.PowerShell.EndInvoke($worker.Async))
                        if ($rows.Count -gt 0) { $result = $rows[-1] }
                    }
                }
                catch {
                    if ([string]::IsNullOrWhiteSpace($cancelReason)) {
                        $result = [pscustomobject]@{ Decision = 'fail-closed'; Result = 'adapter-unavailable'; Reason = 'worker-error'; SnapshotId = '' }
                    }
                }
                finally {
                    Close-NotifyBrokerExactWorkerResources -Worker $worker
                    [void]$script:NotifyBrokerExactWorkers.Remove($id)
                }

                if (-not [string]::IsNullOrWhiteSpace($cancelReason)) {
                    $elapsedMs = [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds
                    Write-NotifyBrokerLog -Message ('broker-exact-worker-cancelled popupId={0} mode={1} reason={2} elapsedMs={3}' -f $worker.PopupId, $worker.Mode, $cancelReason, $elapsedMs)
                    if ($cancelReason -eq 'preempted-by-activation' -and
                        -not (Test-NotifyBrokerActivationIntent -PopupId $worker.PopupId)) {
                        Set-NotifyBrokerExactWorkerFailClosed -PopupId $worker.PopupId -Reason $cancelReason
                    }
                    Start-NotifyBrokerNextDeferredActivation
                    continue
                }

                if ($null -eq $result) {
                    $result = [pscustomobject]@{ Decision = 'fail-closed'; Result = 'adapter-unavailable'; Reason = 'worker-empty'; SnapshotId = '' }
                }

                $elapsedMs = [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds
                Write-NotifyBrokerLog -Message ('broker-exact-worker-complete popupId={0} mode={1} decision={2} result={3} reason={4} snapshotFp={5} elapsedMs={6}' -f $worker.PopupId, $worker.Mode, $result.Decision, $result.Result, $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'none' } else { [string]$result.Reason }), (Get-NotifyRouteFingerprint -Value ([string]$result.SnapshotId)), $elapsedMs)
                Start-NotifyBrokerNextDeferredActivation
                if (-not $script:NotifyBrokerActivePopups.ContainsKey($worker.PopupId)) { continue }
                $entry = $script:NotifyBrokerActivePopups[$worker.PopupId]
                $tag = $entry.Form.Tag
                if ($worker.Mode -eq 'resolve') {
                    if ($result.Decision -eq 'exact-ready' -and -not [string]::IsNullOrWhiteSpace([string]$result.SnapshotId)) {
                        $tag.SnapshotId = [string]$result.SnapshotId
                        if (-not $tag.TerminalState.Value) {
                            Set-NotifyBrokerRecoveryUiState -Tag $tag -State 'ready'
                        }
                    }
                    else {
                        [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'resolve-failed' } else { [string]$result.Reason }))
                    }
                }
                elseif ($result.Decision -eq 'focused') {
                    [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'focused' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'background-proof-pending' } else { [string]$result.Reason }))
                }
                elseif ($result.Decision -eq 'handled') {
                    [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'handled' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Result)) { 'activation-handled' } else { [string]$result.Result }))
                }
                else {
                    [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'activation-failed' } else { [string]$result.Reason }))
                }
            }
            if ($script:NotifyBrokerExactWorkers.Count -eq 0) { $this.Stop() }
        })
    }
    $script:NotifyBrokerExactWorkerTimer.Start()
    return $true
}

function Queue-NotifyBrokerActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint,
        [string]$PopupId = '',
        [System.Windows.Forms.Form]$FormToClose,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    if ($OriginKind -eq 'pi-web') {
        return Start-NotifyBrokerExactWorker -PopupId $PopupId -Mode 'activate' -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId
    }

    if ($null -eq $script:NotifyBrokerActivationQueue) {
        $script:NotifyBrokerActivationQueue = [System.Collections.Generic.Queue[object]]::new()
    }
    if ($null -eq $script:NotifyBrokerActivationTimer) {
        $script:NotifyBrokerActivationTimer = New-Object System.Windows.Forms.Timer
        $script:NotifyBrokerActivationTimer.Interval = 1
        $script:NotifyBrokerActivationTimer.Add_Tick({
            $this.Stop()
            if ($null -eq $script:NotifyBrokerActivationQueue -or $script:NotifyBrokerActivationQueue.Count -le 0) {
                return
            }
            $request = $script:NotifyBrokerActivationQueue.Dequeue()
            try {
                Invoke-NotifyBrokerActivation -TargetHost $request.TargetHost -CurrentDirBase $request.CurrentDirBase -SourceTabTitleValue $request.SourceTabTitleValue -TargetFingerprint $request.TargetFingerprint -OriginKind $request.OriginKind -NotificationId $request.NotificationId -SnapshotId $request.SnapshotId
            }
            finally {
                if ($null -ne $request.FormToClose -and -not $request.FormToClose.IsDisposed) {
                    try {
                        Write-NotifyBrokerLog -Message ('broker-activation-feedback-close popupId={0}' -f $request.PopupId)
                        [void](Complete-NotifyBrokerPopupLifecycle -Tag $request.FormToClose.Tag -Outcome 'handled' -Reason 'legacy-activation-complete')
                    }
                    catch {
                        Write-NotifyBrokerLog -Message ('broker-activation-feedback-close-error popupId={0} "{1}"' -f $request.PopupId, $_.Exception.Message)
                    }
                }
            }
            if ($script:NotifyBrokerActivationQueue.Count -gt 0) {
                $this.Start()
            }
        })
    }

    $script:NotifyBrokerActivationQueue.Enqueue([pscustomobject]@{
        TargetHost = $TargetHost
        CurrentDirBase = $CurrentDirBase
        SourceTabTitleValue = $SourceTabTitleValue
        TargetFingerprint = $TargetFingerprint
        PopupId = $PopupId
        FormToClose = $FormToClose
        OriginKind = $OriginKind
        NotificationId = $NotificationId
        SnapshotId = $SnapshotId
        RecoveryTicketId = $RecoveryTicketId
    })
    $script:NotifyBrokerActivationTimer.Start()
}

function Invoke-NotifyBrokerActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint = '',
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    try {
        $startedAt = [DateTime]::UtcNow
        $requiresCwdMatch = -not [string]::IsNullOrWhiteSpace($CurrentDirBase)
        $hasPreciseSourceTitle = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
        Write-NotifyBrokerLog -Message ('broker-activate targetFingerprint={0} cwdFingerprint={1} sourceTabFingerprint={2} originKind={3} notificationFp={4} snapshotFp={5}' -f (Get-NotifyBrokerContextFingerprint -Value $TargetHost), (Get-NotifyBrokerContextFingerprint -Value $CurrentDirBase), (Get-NotifyBrokerContextFingerprint -Value $SourceTabTitleValue), $(if ([string]::IsNullOrWhiteSpace($OriginKind)) { 'none' } else { $OriginKind }), (Get-NotifyRouteFingerprint -Value $NotificationId), (Get-NotifyRouteFingerprint -Value $SnapshotId))

        if ($OriginKind -eq 'pi-web') {
            Write-NotifyBrokerLog -Message 'broker-route-activate-invariant exact-route-must-use-background-worker'
            return
        }

        if (-not $requiresCwdMatch -and -not $hasPreciseSourceTitle) {
            Write-NotifyBrokerLog -Message ('broker-focus-miss missing-target-metadata no-target-open-skipped targetFingerprint={0} elapsedMs={1}' -f (Get-NotifyBrokerContextFingerprint -Value $TargetHost), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }
        Write-NotifyBrokerLog -Message ('broker-focus-policy requiresCwdMatch={0} requiresSourceTabTitle={1}' -f $requiresCwdMatch, $hasPreciseSourceTitle)

        $keywords = @($SourceTabTitleValue, $CurrentDirBase, $TargetHost) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
        Write-NotifyBrokerLog -Message ('broker-keywords count={0}' -f @($keywords).Count)

        $best = $null
        $eligibleCount = 0
        $cacheHit = $false
        $cacheSource = 'none'
        $cacheCandidate = Get-NotifyBrokerTabCacheCandidate -TargetFingerprint $TargetFingerprint -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue
        if ($null -ne $cacheCandidate) {
            $cached = $cacheCandidate.Entry
            $cacheHit = $true
            $cacheSource = $cacheCandidate.Source
            Write-NotifyBrokerLog -Message ('broker-cache-hit source={0} windowFingerprint={1} tabFingerprint={2} tabIndex={3} targetFingerprint={4}' -f $cacheSource, (Get-NotifyBrokerContextFingerprint -Value $cached.WindowTitle), (Get-NotifyBrokerContextFingerprint -Value $cached.TabName), $cached.TabIndex, $TargetFingerprint)
        }

        if ($null -eq $best) {
            $windows = @(Get-NotifyBrokerWindows -TerminalOnly)
            Write-NotifyBrokerLog -Message ('broker-terminal-window-count {0} cacheHit={1}' -f $windows.Count, $cacheHit)
            foreach ($window in $windows) {
                $baseScore = 0
                foreach ($keyword in $keywords) {
                    if ($window.Title.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $baseScore += 20
                    }
                }

                $tabs = @(Get-NotifyBrokerTabs -Handle $window.Handle)
                Write-NotifyBrokerLog -Message ('broker-window titleFingerprint={0} processFingerprint={1} tabs={2} baseScore={3}' -f (Get-NotifyBrokerContextFingerprint -Value $window.Title), (Get-NotifyBrokerContextFingerprint -Value $window.ProcessName), $tabs.Count, $baseScore)
                if ($tabs.Count -eq 0) {
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
                    $cwdKeywordMatch = $requiresCwdMatch -and ($matchedKeywords -contains $CurrentDirBase)
                    if ($hasPreciseSourceTitle -and -not $sourceTabTitleMatch) {
                        $score = 0
                    }
                    elseif ($requiresCwdMatch -and -not $cwdKeywordMatch) {
                        $score = 0
                    }
                    Write-NotifyBrokerLog -Message ('broker-tab index={0} nameFingerprint={1} selected={2} score={3} matchedKeywordCount={4} sourceTabTitleMatch={5}' -f $tab.Index, (Get-NotifyBrokerContextFingerprint -Value $tab.Name), $tab.IsSelected, $score, @($matchedKeywords).Count, $sourceTabTitleMatch)
                    if ($score -le 0) {
                        continue
                    }

                    $eligibleCount += 1
                    $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name; TabIndex = $tab.Index }
                    if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                        $best = $candidate
                    }
                }
            }
        }

        if ($eligibleCount -gt 1) {
            Write-NotifyBrokerLog -Message ('broker-focus-ambiguous targetFingerprint={0} sourceTabFingerprint={1} candidateCount={2} bestScore={3} cacheHit={4} elapsedMs={5}' -f (Get-NotifyBrokerContextFingerprint -Value $TargetHost), (Get-NotifyBrokerContextFingerprint -Value $SourceTabTitleValue), $eligibleCount, $best.Score, $cacheHit, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }

        if ($null -eq $best) {
            Write-NotifyBrokerLog -Message ('broker-focus-miss no-target-open-skipped targetFingerprint={0} cwdFingerprint={1} keywordCount={2} cacheHit={3} elapsedMs={4}' -f (Get-NotifyBrokerContextFingerprint -Value $TargetHost), (Get-NotifyBrokerContextFingerprint -Value $CurrentDirBase), @($keywords).Count, $cacheHit, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }

        Write-NotifyBrokerLog -Message ('broker-focus-best windowFingerprint={0} tabFingerprint={1} tabIndex={2} score={3} cacheHit={4} cacheSource={5}' -f (Get-NotifyBrokerContextFingerprint -Value $best.Window.Title), (Get-NotifyBrokerContextFingerprint -Value $best.TabName), $best.TabIndex, $best.Score, $cacheHit, $cacheSource)
        if ([PiNotifyBrokerUser32]::IsIconic($best.Window.Handle)) {
            [void][PiNotifyBrokerUser32]::ShowWindowAsync($best.Window.Handle, 9)
            Start-Sleep -Milliseconds 80
        }

        if ($cacheHit) {
            [void][PiNotifyBrokerUser32]::SetForegroundWindow($best.Window.Handle)
            if ($null -ne $best.Tab -and (Select-NotifyBrokerTab -TabElement $best.Tab)) {
                $scrolledToBottom = Set-NotifyBridgeTerminalScrollToBottom -WindowHandle $best.Window.Handle
                Write-NotifyBrokerLog -Message ('broker-tab-selected tabFingerprint={0} elapsedMs={1} cacheHit=True cacheSource={2} scrolledToBottom={3}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds, $cacheSource, $scrolledToBottom)
                Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint -SourceTabTitleValue $SourceTabTitleValue
                return
            }
            Write-NotifyBrokerLog -Message ('broker-cache-select-failed tabFingerprint={0}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName))
        }

        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.AppActivate($best.Window.ProcessId)
        }
        catch {
            Write-NotifyBrokerLog -Message ('broker-appactivate-error "{0}"' -f $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 40
        [void][PiNotifyBrokerUser32]::SetForegroundWindow($best.Window.Handle)
        Start-Sleep -Milliseconds 40

        if ($null -ne $best.Tab) {
            if (Select-NotifyBrokerTab -TabElement $best.Tab) {
                $scrolledToBottom = Set-NotifyBridgeTerminalScrollToBottom -WindowHandle $best.Window.Handle
                Write-NotifyBrokerLog -Message ('broker-tab-selected tabFingerprint={0} elapsedMs={1} cacheHit={2} cacheSource={3} scrolledToBottom={4}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds, $cacheHit, $cacheSource, $scrolledToBottom)
                Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint -SourceTabTitleValue $SourceTabTitleValue
            }
            else {
                Write-NotifyBrokerLog -Message ('broker-tab-select-failed tabFingerprint={0} elapsedMs={1}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            }
        }
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-activate-error "{0}"' -f $_.Exception.Message)
    }
}

function Get-NotifyBrokerWorkingArea {
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

# Compute popup stack location, consistent with popup.ps1 bottom-right stacking rules
function Get-NotifyBrokerPopupLocation {
    param(
        [Parameter(Mandatory = $true)][int]$StackIndex,
        [Parameter(Mandatory = $true)][int]$FormWidth,
        [Parameter(Mandatory = $true)][int]$FormHeight
    )

    $workingArea = Get-NotifyBrokerWorkingArea -Placement $PopupPlacement
    $margin = 16
    $gap = 12
    $slot = [Math]::Max(0, $StackIndex)
    $x = [Math]::Max($workingArea.Left, $workingArea.Right - $FormWidth - $margin)
    $bottomY = $workingArea.Bottom - $FormHeight - $margin
    $stackY = $bottomY - ($slot * ($FormHeight + $gap))
    $y = [Math]::Max($workingArea.Top + $margin, $stackY)
    return [pscustomobject]@{ X = $x; Y = $y }
}

# Extract session display name from tabTitle, consistent with popup.ps1
function Get-NotifyBrokerSessionDisplayName {
    param(
        [string]$SessionName,
        [string]$SourceTabTitle,
        [string]$CwdBase
    )

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
    return $sessionDisplayName
}

function Set-NotifyBrokerPopupActivating {
    param([hashtable]$Tag)

    if ($null -eq $Tag) { return $false }
    try {
        if (($Tag.ContainsKey('TerminalState') -and $Tag.TerminalState.Value) -or $Tag.Activating.Value) { return $false }
        $Tag.Activating.Value = $true
        $Tag.Timer.Stop()
        $Tag.FocusWatchTimer.Stop()

        $inactiveCardColor = [System.Drawing.Color]::FromArgb(48, 52, 60)
        $inactiveTextColor = [System.Drawing.Color]::FromArgb(190, 198, 210)
        $inactiveAccentColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $jumpingText = (-join @([char]0x8df3, [char]0x8f6c, [char]0x4e2d, '.', '.', '.'))
        if ($null -ne $Tag.Form) {
            $Tag.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $Tag.Form.Opacity = 0.90
            $Tag.Form.BackColor = $inactiveCardColor
        }
        if ($null -ne $Tag.Panel) {
            $Tag.Panel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $Tag.Panel.BackColor = $inactiveCardColor
        }
        if ($null -ne $Tag.AppLabel) {
            $Tag.AppLabel.Text = ('Pi Remote - {0}' -f $jumpingText)
            $Tag.AppLabel.ForeColor = $inactiveTextColor
            $Tag.AppLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        if ($null -ne $Tag.SessionLabel) {
            $Tag.SessionLabel.Text = $jumpingText
            $Tag.SessionLabel.ForeColor = $inactiveAccentColor
            $Tag.SessionLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        if ($null -ne $Tag.TitleLabel) {
            $Tag.TitleLabel.Text = Get-NotifyBrokerRecoveryUiText -Name 'opening-title'
            $Tag.TitleLabel.ForeColor = $inactiveTextColor
            $Tag.TitleLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        if ($null -ne $Tag.BodyLabel) {
            $Tag.BodyLabel.Text = Get-NotifyBrokerRecoveryUiText -Name 'opening-body'
            $Tag.BodyLabel.ForeColor = $inactiveTextColor
            $Tag.BodyLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        $watchdogMs = if ([string]::IsNullOrWhiteSpace([string]$Tag.SnapshotId)) { $script:NotifyBrokerRecoveringActivationWatchdogMs } else { $script:NotifyBrokerReadyActivationWatchdogMs }
        $Tag.ActivationWatchdogTimer.Stop()
        $Tag.ActivationWatchdogTimer.Interval = $watchdogMs
        $Tag.ActivationWatchdogTimer.Start()
        Write-NotifyBrokerLog -Message ('broker-activation-feedback popupId={0} watchdogMs={1}' -f $Tag.PopupId, $watchdogMs)
        if ($null -ne $Tag.Form) {
            $Tag.Form.Invalidate($true)
            $Tag.Form.Refresh()
        }
        [System.Windows.Forms.Application]::DoEvents()
        return $true
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-activation-feedback-error popupId={0} "{1}"' -f $Tag.PopupId, $_.Exception.Message)
        [void](Complete-NotifyBrokerPopupLifecycle -Tag $Tag -Outcome 'failed' -Reason 'activation-feedback-error')
        return $false
    }
}

# Create and show a popup card on the UI thread; close older popups with the same targetFingerprint first
function Show-NotifyBrokerPopup {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$SourceTabTitle,
        [string]$SessionName,
        [string]$TargetFingerprint,
        [int]$StackIndex,
        [int]$TimeoutSeconds,
        [string]$PopupPlacementValue,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    $usedSlots = @{}
    $reuseSlot = -1

    # Replace older popups with the same target and keep enough slot state to avoid overlap.
    foreach ($existingId in @($script:NotifyBrokerActivePopups.Keys)) {
        $existing = $script:NotifyBrokerActivePopups[$existingId]
        $existingSlot = -1
        try { $existingSlot = [int]$existing.StackIndex } catch { $existingSlot = -1 }
        if ($existing.TargetFingerprint -eq $TargetFingerprint -and $existing.PopupId -ne $PopupId) {
            if ($existingSlot -ge 0 -and ($reuseSlot -lt 0 -or $existingSlot -lt $reuseSlot)) {
                $reuseSlot = $existingSlot
            }
            Write-NotifyBrokerLog -Message ('broker-popup-replace-same-target popupId={0} oldPopupId={1} targetFingerprint={2}' -f $PopupId, $existingId, $TargetFingerprint)
            try {
                if ($null -ne $existing.Form.Tag -and $existing.Form.Tag.ContainsKey('TerminalState')) {
                    [void](Complete-NotifyBrokerPopupLifecycle -Tag $existing.Form.Tag -Outcome 'dismissed' -Reason 'same-target-replaced')
                }
                else { $existing.Form.Close() }
            }
            catch {}
            continue
        }

        if ($existingSlot -ge 0) {
            $usedSlots[[string]$existingSlot] = $true
        }
    }

    if ($script:NotifyBrokerPopupMaxVisible -gt 0) {
        $activeEntries = @($script:NotifyBrokerActivePopups.Values | Where-Object { $_.TargetFingerprint -ne $TargetFingerprint } | Sort-Object { if ($_.PSObject.Properties['CreatedAtUtc']) { $_.CreatedAtUtc } else { [DateTime]::MinValue } })
        $dropIndex = 0
        while ($usedSlots.Count -ge $script:NotifyBrokerPopupMaxVisible -and $dropIndex -lt $activeEntries.Count) {
            $drop = $activeEntries[$dropIndex]
            $dropIndex += 1
            $dropSlot = -1
            try { $dropSlot = [int]$drop.StackIndex } catch { $dropSlot = -1 }
            Write-NotifyBrokerLog -Message ('broker-popup-drop-overflow popupId={0} maxVisible={1}' -f $drop.PopupId, $script:NotifyBrokerPopupMaxVisible)
            try {
                if ($null -ne $drop.Form.Tag -and $drop.Form.Tag.ContainsKey('TerminalState')) {
                    [void](Complete-NotifyBrokerPopupLifecycle -Tag $drop.Form.Tag -Outcome 'dismissed' -Reason 'overflow')
                }
                else { $drop.Form.Close() }
            }
            catch {}
            if ($dropSlot -ge 0) { $usedSlots.Remove([string]$dropSlot) }
        }
    }

    # Compute stack index from active popup slots (broker owns stacking).
    if ($StackIndex -lt 0) {
        if ($reuseSlot -ge 0 -and -not $usedSlots.ContainsKey([string]$reuseSlot)) {
            $StackIndex = $reuseSlot
        }
        else {
            for ($slot = 0; $slot -lt 64; $slot++) {
                if (-not $usedSlots.ContainsKey([string]$slot)) {
                    $StackIndex = $slot
                    break
                }
            }
        }
    }
    if ($StackIndex -gt 63) { $StackIndex = 63 }
    if ($StackIndex -lt 0) { $StackIndex = 63 }

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
    # Do not use Form.TopMost: WinForms may activate the form while changing z-order.
    # The Shown handler applies topmost with SWP_NOACTIVATE instead.
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
            $paintPanel = [System.Windows.Forms.Panel]$this
            $graphics = $_.Graphics
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $rect = New-Object System.Drawing.Rectangle(0, 0, ($paintPanel.Width - 1), ($paintPanel.Height - 1))
            $paintBorderColor = [System.Drawing.Color]::FromArgb(74, 80, 96)
            $paintAccentColor = [System.Drawing.Color]::FromArgb(94, 234, 212)

            if ($null -ne $script:NotifyBrokerWallpaperImage) {
                $cardImage = Get-NotifyBrokerWallpaperCardImage -Width $paintPanel.Width -Height $paintPanel.Height
                if ($null -ne $cardImage) {
                    $graphics.DrawImageUnscaled($cardImage, 0, 0)
                }
            }

            $path = New-NotifyBrokerRoundedPath -Rectangle $rect -Radius 14
            $pen = New-Object System.Drawing.Pen($paintBorderColor, 1)
            $accentBrush = New-Object System.Drawing.SolidBrush($paintAccentColor)
            $graphics.DrawPath($pen, $path)
            $graphics.FillRectangle($accentBrush, 0, 0, 5, $paintPanel.Height)
            $accentBrush.Dispose()
            $pen.Dispose()
            $path.Dispose()
        }
        catch {
            Write-NotifyBrokerLog -Message ('broker-paint-error "{0}"' -f $_.Exception.Message)
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

    $sessionDisplayName = Get-NotifyBrokerSessionDisplayName -SessionName $SessionName -SourceTabTitle $SourceTabTitle -CwdBase $CwdBase

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

    if ($null -ne $script:NotifyBrokerWallpaperImage) {
        foreach ($label in @($appLabel, $closeLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
            $label.BackColor = [System.Drawing.Color]::Transparent
        }
    }

    $targetHost = $FocusTarget
    $targetCwdBase = $CwdBase
    $targetSourceTabTitle = $SourceTabTitle
    $targetOriginKind = $OriginKind
    $targetNotificationId = $NotificationId
    $targetSnapshotId = $SnapshotId
    $targetRecoveryTicketId = $RecoveryTicketId
    $didActivate = $false
    $shouldActivate = $false
    $terminalState = $false
    $closeRequested = $false

    $timer = New-Object System.Windows.Forms.Timer
    $focusWatchTimer = New-Object System.Windows.Forms.Timer
    $failureCloseTimer = New-Object System.Windows.Forms.Timer
    $activationWatchdogTimer = New-Object System.Windows.Forms.Timer
    $popupCreatedAtUtc = [DateTime]::UtcNow

    # Pass closure variables via form.Tag to event handlers to survive function scope exit
    $popupTag = @{
        PopupId           = $PopupId
        TargetHost        = $targetHost
        TargetCwdBase     = $targetCwdBase
        TargetSourceTabTitle = $targetSourceTabTitle
        TargetFingerprint = $TargetFingerprint
        OriginKind        = $targetOriginKind
        NotificationId    = $targetNotificationId
        SnapshotId        = $targetSnapshotId
        RecoveryTicketId  = $targetRecoveryTicketId
        RecoveryState     = if ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId) -and -not [string]::IsNullOrWhiteSpace($targetRecoveryTicketId)) { 'recovering' } elseif ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } else { 'ready' }
        OriginalTitle     = $Title
        OriginalBody      = $Body
        OriginalAppText   = $appLabel.Text
        OriginalSessionText = $sessionLabel.Text
        OriginalCloseText = $closeLabel.Text
        OriginalOpacity   = $form.Opacity
        OriginalCardColor = $form.BackColor
        OriginalPanelColor = $panel.BackColor
        OriginalAppForeColor = $appLabel.ForeColor
        OriginalSessionForeColor = $sessionLabel.ForeColor
        OriginalTitleForeColor = $titleLabel.ForeColor
        OriginalBodyForeColor = $bodyLabel.ForeColor
        OriginalCloseForeColor = $closeLabel.ForeColor
        StackIndex        = $StackIndex
        PopupPlacement    = $PopupPlacementValue
        CreatedAtUtc      = $popupCreatedAtUtc
        DidActivate       = [ref]$didActivate
        ShouldActivate    = [ref]$shouldActivate
        Activating        = [ref]$false
        ActivationQueued  = [ref]$false
        TerminalState     = [ref]$terminalState
        CloseRequested    = [ref]$closeRequested
        TerminalOutcome   = ''
        TerminalReason    = ''
        Timer             = $timer
        FocusWatchTimer   = $focusWatchTimer
        FailureCloseTimer = $failureCloseTimer
        ActivationWatchdogTimer = $activationWatchdogTimer
        Form              = $form
        Panel             = $panel
        AppLabel          = $appLabel
        CloseLabel        = $closeLabel
        SessionLabel      = $sessionLabel
        TitleLabel        = $titleLabel
        BodyLabel         = $bodyLabel
    }
    $form.Tag = $popupTag
    # Timer has no Tag property; attach popupTag as NoteProperty for Tick events to read
    Add-Member -InputObject $timer -NotePropertyName 'PopupTag' -NotePropertyValue $popupTag
    Add-Member -InputObject $focusWatchTimer -NotePropertyName 'PopupTag' -NotePropertyValue $popupTag
    Add-Member -InputObject $failureCloseTimer -NotePropertyName 'PopupTag' -NotePropertyValue $popupTag
    Add-Member -InputObject $activationWatchdogTimer -NotePropertyName 'PopupTag' -NotePropertyValue $popupTag

    $activateAction = {
        $tag = $this.FindForm().Tag
        if ($tag.TerminalState.Value -or $tag.DidActivate.Value) {
            return
        }
        if ([string]$tag.OriginKind -eq 'pi-web' -and [string]$tag.RecoveryState -eq 'unavailable') {
            Write-NotifyBrokerLog -Message ('broker-popup-click-ignored exact-route-unavailable popupId={0}' -f $tag.PopupId)
            return
        }
        Write-NotifyBrokerLog -Message ('broker-popup-click popupId={0}' -f $tag.PopupId)
        Write-NotifyBrokerLog -Message ('broker-action activate popupId={0} targetFingerprint={1} originKind={2} notificationFp={3} snapshotFp={4}' -f $tag.PopupId, $tag.TargetFingerprint, $(if ([string]::IsNullOrWhiteSpace($tag.OriginKind)) { 'none' } else { $tag.OriginKind }), (Get-NotifyRouteFingerprint -Value $tag.NotificationId), (Get-NotifyRouteFingerprint -Value $tag.SnapshotId))
        if (-not (Set-NotifyBrokerPopupActivating -Tag $tag)) { return }
        $tag.DidActivate.Value = $true
        $tag.ShouldActivate.Value = $true
        $tag.ActivationQueued.Value = $true
        [void](Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -FormToClose $tag.Form -OriginKind $tag.OriginKind -NotificationId $tag.NotificationId -SnapshotId $tag.SnapshotId -RecoveryTicketId $tag.RecoveryTicketId)
    }

    $closeAction = {
        $tag = $this.FindForm().Tag
        Write-NotifyBrokerLog -Message ('broker-close-button popupId={0}' -f $tag.PopupId)
        Write-NotifyBrokerLog -Message ('broker-action dismiss source="close-button" popupId={0}' -f $tag.PopupId)
        [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'dismissed' -Reason 'close-button')
    }

    foreach ($control in @($form, $panel, $appLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
        $control.Add_Click($activateAction)
    }
    $closeLabel.Add_Click($closeAction)

    $timer.Interval = [Math]::Max(3000, ($TimeoutSeconds * 1000))
    $timer.Add_Tick({
        $tag = $this.PopupTag
        Write-NotifyBrokerLog -Message ('broker-timeout-close popupId={0}' -f $tag.PopupId)
        Write-NotifyBrokerLog -Message ('broker-action dismiss source="timeout" popupId={0}' -f $tag.PopupId)
        [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'dismissed' -Reason 'timeout')
    })

    $focusWatchTimer.Interval = 800
    $focusWatchTimer.Add_Tick({
        $tag = $this.PopupTag
        if (-not (Test-NotifyForegroundDismissAllowed -OriginKind $tag.OriginKind)) {
            return
        }
        if (Test-NotifyBrokerForegroundTarget -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint) {
            Write-NotifyBrokerLog -Message ('broker-action dismiss source="foreground-target" popupId={0}' -f $tag.PopupId)
            [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'dismissed' -Reason 'foreground-target')
        }
    })

    $failureCloseTimer.Interval = $script:NotifyBrokerFailureCloseDelayMs
    $failureCloseTimer.Add_Tick({
        $tag = $this.PopupTag
        $this.Stop()
        [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'dismissed' -Reason 'failure-auto-close')
    })

    $activationWatchdogTimer.Interval = $script:NotifyBrokerReadyActivationWatchdogMs
    $activationWatchdogTimer.Add_Tick({
        $tag = $this.PopupTag
        $this.Stop()
        [void](Invoke-NotifyBrokerActivationWatchdog -Tag $tag)
    })

    $form.Add_Shown({
        $tag = $this.Tag
        [void][PiNotifyBrokerUser32]::SetWindowPos($this.Handle, $script:NotifyBrokerHwndTopMost, $this.Left, $this.Top, $this.Width, $this.Height, $script:NotifyBrokerSwpShowNoActivate)
        Write-NotifyBrokerLog -Message ('broker-shown popupId={0} stackIndex={1} placement={2} targetFingerprint={3} elapsedMs={4}' -f $tag.PopupId, $tag.StackIndex, $tag.PopupPlacement, $tag.TargetFingerprint, [int]([DateTime]::UtcNow - $tag.CreatedAtUtc).TotalMilliseconds)
        Queue-NotifyBrokerPrewarm -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId
        $tag.Timer.Start()
        $tag.FocusWatchTimer.Start()
        if ($tag.RecoveryState -eq 'recovering') {
            Set-NotifyBrokerRecoveryUiState -Tag $tag -State 'recovering'
            [void](Start-NotifyBrokerExactWorker -PopupId $tag.PopupId -Mode 'resolve' -NotificationId $tag.NotificationId -RecoveryTicketId $tag.RecoveryTicketId)
        }
        elseif ($tag.RecoveryState -eq 'unavailable') {
            [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason 'exact-route-unavailable')
        }
    })

    $form.Add_FormClosed({
        $tag = $this.Tag
        $tag.CloseRequested.Value = $true
        if (-not $tag.TerminalState.Value) {
            $tag.TerminalState.Value = $true
            $tag.TerminalOutcome = 'dismissed'
            $tag.TerminalReason = 'form-closed'
        }
        Write-NotifyBrokerLog -Message ('broker-closed popupId={0} shouldActivate={1}' -f $tag.PopupId, $tag.ShouldActivate.Value)
        # Deferred activation belongs to its target popup, independently of
        # whichever resolver worker was reclaimed to make room for it.
        [void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $tag.PopupId)
        Stop-NotifyBrokerExactWorkersForPopup -PopupId $tag.PopupId -Reason 'popup-closed'
        try {
            $tag.Timer.Stop()
            $tag.Timer.Dispose()
            $tag.FocusWatchTimer.Stop()
            $tag.FocusWatchTimer.Dispose()
            $tag.FailureCloseTimer.Stop()
            $tag.FailureCloseTimer.Dispose()
            $tag.ActivationWatchdogTimer.Stop()
            $tag.ActivationWatchdogTimer.Dispose()
        }
        catch {
        }
        Remove-NotifyBrokerLiveState -PopupId $tag.PopupId
        $script:NotifyBrokerActivePopups.Remove($tag.PopupId) | Out-Null

        if ($tag.ShouldActivate.Value -and -not $tag.ActivationQueued.Value) {
            Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -OriginKind $tag.OriginKind -NotificationId $tag.NotificationId -SnapshotId $tag.SnapshotId -RecoveryTicketId $tag.RecoveryTicketId
        }
    })

    $location = Get-NotifyBrokerPopupLocation -StackIndex $StackIndex -FormWidth $form.Width -FormHeight $form.Height
    $form.Location = New-Object System.Drawing.Point($location.X, $location.Y)
    $roundedRect = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
    $roundedPath = New-NotifyBrokerRoundedPath -Rectangle $roundedRect -Radius 14
    $form.Region = New-Object System.Drawing.Region($roundedPath)
    $roundedPath.Dispose()

    Save-NotifyBrokerLiveState -PopupId $PopupId -TargetHostValue $targetHost -CwdBaseValue $targetCwdBase -SourceTabTitleValue $targetSourceTabTitle -TargetFingerprintValue $TargetFingerprint -StackIndexValue $StackIndex -TimeoutSecondsValue $TimeoutSeconds
    $script:NotifyBrokerActivePopups[$PopupId] = [pscustomobject]@{
        PopupId           = $PopupId
        Form              = $form
        TargetFingerprint = $TargetFingerprint
        StackIndex        = $StackIndex
        CreatedAtUtc      = $popupCreatedAtUtc
    }
    Write-NotifyBrokerLog -Message ('broker-popup-start popupId={0} targetFingerprint={1} hasCwd={2} hasTab={3} timeout={4} stackIndex={5}' -f $PopupId, $TargetFingerprint, (-not [string]::IsNullOrWhiteSpace($CwdBase)), (-not [string]::IsNullOrWhiteSpace($SourceTabTitle)), $TimeoutSeconds, $StackIndex)
    $form.Show()
}

# Close the popup with the given popupId (triggered by hotkey /close)
function Close-NotifyBrokerPopup {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [bool]$Activate = $false
    )

    if ($script:NotifyBrokerActivePopups.ContainsKey($PopupId)) {
        $entry = $script:NotifyBrokerActivePopups[$PopupId]
        Write-NotifyBrokerLog -Message ('broker-close-by-id popupId={0} activate={1}' -f $PopupId, $Activate)
        try {
            if ($Activate -and $entry.Form.Tag -and $entry.Form.Tag.ShouldActivate) {
                $tag = $entry.Form.Tag
                if ($tag.TerminalState.Value -or
                    ([string]$tag.OriginKind -eq 'pi-web' -and [string]$tag.RecoveryState -eq 'unavailable')) {
                    Write-NotifyBrokerLog -Message ('broker-close-by-id ignored terminal-or-unavailable popupId={0}' -f $PopupId)
                    return
                }
                if (-not (Set-NotifyBrokerPopupActivating -Tag $tag)) { return }
                $tag.ShouldActivate.Value = $true
                if ($tag.ContainsKey('DidActivate')) { $tag.DidActivate.Value = $true }
                $tag.ActivationQueued.Value = $true
                $originKind = if ($tag.ContainsKey('OriginKind')) { [string]$tag.OriginKind } else { '' }
                $notificationId = if ($tag.ContainsKey('NotificationId')) { [string]$tag.NotificationId } else { '' }
                $snapshotId = if ($tag.ContainsKey('SnapshotId')) { [string]$tag.SnapshotId } else { '' }
                $recoveryTicketId = if ($tag.ContainsKey('RecoveryTicketId')) { [string]$tag.RecoveryTicketId } else { '' }
                [void](Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -FormToClose $tag.Form -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId)
            }
            else {
                [void](Complete-NotifyBrokerPopupLifecycle -Tag $entry.Form.Tag -Outcome 'dismissed' -Reason 'close-by-id')
            }
        } catch {}
    }
    else {
        Write-NotifyBrokerLog -Message ('broker-close-by-id-miss popupId={0}' -f $PopupId)
        Remove-NotifyBrokerLiveState -PopupId $PopupId
    }
}

# Singleton guard: prevent multiple broker processes binding the same port
function Enter-NotifyBrokerSingleton {
    $mutexName = 'Global\PiNotifyBroker_{0}' -f $brokerPort
    $script:NotifyBrokerMutex = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        $script:NotifyBrokerHasLock = $script:NotifyBrokerMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $script:NotifyBrokerHasLock = $true
    }

    if (-not $script:NotifyBrokerHasLock) {
        Write-NotifyBrokerLog -Message ('broker-singleton-exit port={0} pid={1}' -f $brokerPort, $PID)
        exit 0
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyBrokerPidPath) | Out-Null
    Set-Content -LiteralPath $script:NotifyBrokerPidPath -Value ([string]$PID) -Encoding ASCII
}

function Exit-NotifyBrokerSingleton {
    try {
        if (Test-Path -LiteralPath $script:NotifyBrokerPidPath) {
            $current = [string](Get-Content -LiteralPath $script:NotifyBrokerPidPath -Raw -ErrorAction SilentlyContinue)
            if ($current.Trim() -eq [string]$PID) {
                Remove-Item -LiteralPath $script:NotifyBrokerPidPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
    }

    # Clean up leftover live-state files
    try {
        $logDir = Get-NotifyBridgeLogDir
        if (Test-Path -LiteralPath $logDir) {
            foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter ('popup-live.{0}.*.json' -f $PID) -File -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
    }

    if ($script:NotifyBrokerHasLock -and $null -ne $script:NotifyBrokerMutex) {
        try { $script:NotifyBrokerMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $script:NotifyBrokerMutex) {
        $script:NotifyBrokerMutex.Dispose()
    }
}

# Background listener runspace: handle HTTP requests and enqueue /popup and /close
function Start-NotifyBrokerHttpListener {
    $brokerIoTimeoutMs = [Math]::Max(300, [int]$config.BrokerRequestTimeoutMs)
    $script:NotifyBrokerListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $brokerPort)
    $script:NotifyBrokerListener.Server.ReceiveTimeout = $brokerIoTimeoutMs
    $script:NotifyBrokerListener.Server.SendTimeout = $brokerIoTimeoutMs
    $script:NotifyBrokerListener.Start()

    $script:NotifyBrokerListenerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:NotifyBrokerListenerRunspace.Open()
    $script:NotifyBrokerListenerRunspace.SessionStateProxy.SetVariable('NotifyBrokerListener', $script:NotifyBrokerListener)
    $script:NotifyBrokerListenerRunspace.SessionStateProxy.SetVariable('NotifyBrokerPopupQueue', $script:NotifyBrokerPopupQueue)
    $script:NotifyBrokerListenerRunspace.SessionStateProxy.SetVariable('NotifyBrokerIoTimeoutMs', $brokerIoTimeoutMs)

    $scriptText = @'
param($Listener, $Queue, $LogPath, $LogLock, $IoTimeoutMs)
$ErrorActionPreference = 'Stop'
# Append one background log line through the shared lock without stopping the listener.
function Write-BrokerBgLog($Msg) {
    $lockTaken = $false
    try {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Msg)
        [System.Threading.Monitor]::Enter($LogLock, [ref]$lockTaken)
        [System.IO.File]::AppendAllText(
            $LogPath,
            ($line + [System.Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Background logging is best-effort and must not stop the HTTP listener.
    }
    finally {
        if ($lockTaken) { [System.Threading.Monitor]::Exit($LogLock) }
    }
}
function Write-BgResponse($Stream, $StatusCode, $Reason, $Body, $ContentType) {
    try {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
        $header = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
        $Stream.Write($headerBytes, 0, $headerBytes.Length)
        if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
        $Stream.Flush()
    }
    catch {
        try { Write-BrokerBgLog ('broker-client-disconnect stage=response status={0} "{1}"' -f $StatusCode, $_.Exception.Message) } catch {}
    }
}
function Read-BgRequest($Stream) {
    $maxBodyBytes = 65536
    $buffer = [byte[]]::new(4096)
    $memory = [System.IO.MemoryStream]::new()
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $memory.Write($buffer, 0, $read)
        $bytes = $memory.ToArray()
        $startIndex = [Math]::Max(0, $bytes.Length - $read - 3)
        for ($i = $startIndex; $i -le $bytes.Length - 4; $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) {
                $headerEnd = $i + 4
                break
            }
        }
        if ($memory.Length -gt 65536) { throw "HTTP header too large." }
    }
    if ($headerEnd -lt 0) { throw "Incomplete HTTP request header." }
    $allBytes = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = if ($lines.Length -gt 0) { [string]$lines[0] } else { '' }
    $requestLine = $requestLine.Trim()
    if ([string]::IsNullOrWhiteSpace($requestLine)) { throw "Missing HTTP request line." }
    $headers = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($lines.Length -gt 1) {
        foreach ($line in $lines[1..($lines.Length - 1)]) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $index = $line.IndexOf(':')
            if ($index -le 0) { continue }
            $headers[$line.Substring(0, $index).Trim()] = $line.Substring($index + 1).Trim()
        }
    }
    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) { [int]::TryParse([string]$headers['Content-Length'], [ref]$contentLength) | Out-Null }
    if ($contentLength -lt 0) { throw "Invalid HTTP content length." }
    if ($contentLength -gt $maxBodyBytes) { throw "HTTP request body too large." }
    $bodyMemory = [System.IO.MemoryStream]::new()
    $existingBytes = $allBytes.Length - $headerEnd
    if ($existingBytes -gt $maxBodyBytes) { throw "HTTP request body too large." }
    if ($existingBytes -gt 0) { $bodyMemory.Write($allBytes, $headerEnd, $existingBytes) }
    while ($bodyMemory.Length -lt $contentLength) {
        $remaining = [Math]::Min($buffer.Length, $contentLength - [int]$bodyMemory.Length)
        $read = $Stream.Read($buffer, 0, $remaining)
        if ($read -le 0) { break }
        $bodyMemory.Write($buffer, 0, $read)
    }
    $bodyBytes = $bodyMemory.ToArray()
    if ($bodyBytes.Length -gt $contentLength) {
        $trimmed = [byte[]]::new($contentLength)
        [Array]::Copy($bodyBytes, 0, $trimmed, 0, $contentLength)
        $bodyBytes = $trimmed
    }
    return [pscustomobject]@{ RequestLine = $requestLine; Headers = $headers; BodyBytes = $bodyBytes }
}
while ($true) {
    $client = $null
    try {
        $client = $Listener.AcceptTcpClient()
        $client.ReceiveTimeout = $IoTimeoutMs
        $client.SendTimeout = $IoTimeoutMs
        $stream = $client.GetStream()
        $request = Read-BgRequest -Stream $stream
        $parts = $request.RequestLine.Split(' ', 3)
        $method = if ($parts.Length -ge 1) { $parts[0].ToUpperInvariant() } else { '' }
        $path = if ($parts.Length -ge 2) { $parts[1] } else { '/' }
        if ($method -eq 'GET' -and $path -eq '/health') {
            Write-BgResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body '{"ok":true,"broker":true}' -ContentType 'application/json; charset=utf-8'
            continue
        }
        if ($method -ne 'POST') {
            Write-BgResponse -Stream $stream -StatusCode 405 -Reason 'Method Not Allowed' -Body '{"ok":false}' -ContentType 'application/json; charset=utf-8'
            continue
        }
        if ($path -eq '/popup' -or $path -eq '/close' -or $path -eq '/activate-oldest') {
            $bodyText = if ($request.BodyBytes.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($request.BodyBytes) } else { '' }
            $Queue.Enqueue([pscustomobject]@{ Action = $path; Body = $bodyText; ReceivedAt = [DateTime]::UtcNow })
            Write-BgResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body '{"ok":true}' -ContentType 'application/json; charset=utf-8'
            continue
        }
        Write-BgResponse -Stream $stream -StatusCode 404 -Reason 'Not Found' -Body '{"ok":false}' -ContentType 'application/json; charset=utf-8'
    }
    catch {
        try { Write-BrokerBgLog ('broker-bg-error "{0}"' -f $_.Exception.Message) } catch {}
    }
    finally {
        if ($null -ne $client) { try { $client.Close() } catch {} }
    }
}
'@

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $script:NotifyBrokerListenerRunspace
    [void]$ps.AddScript($scriptText)
    [void]$ps.AddParameter('Listener', $script:NotifyBrokerListener)
    [void]$ps.AddParameter('Queue', $script:NotifyBrokerPopupQueue)
    [void]$ps.AddParameter('LogPath', $script:NotifyBrokerLogPath)
    [void]$ps.AddParameter('LogLock', $script:NotifyBrokerLogLock)
    [void]$ps.AddParameter('IoTimeoutMs', $brokerIoTimeoutMs)
    $script:NotifyBrokerListenerHandle = $ps.BeginInvoke()
    Write-NotifyBrokerLog -Message ('broker-listener-start port={0} pid={1}' -f $brokerPort, $PID)
}

# UI timer: consume the request queue on the WinForms main thread, create/close popups
$script:NotifyBrokerDispatchTimer = New-Object System.Windows.Forms.Timer
$script:NotifyBrokerDispatchTimer.Interval = 50
$script:NotifyBrokerDispatchTimer.Add_Tick({
    $item = $null
    while ($script:NotifyBrokerPopupQueue.TryDequeue([ref]$item)) {
        if ($null -eq $item) { continue }
        try {
            if ($item.Action -eq '/popup') {
                $payload = $null
                if (-not [string]::IsNullOrWhiteSpace($item.Body)) {
                    $payload = $item.Body | ConvertFrom-Json
                }
                $title = 'Pi'
                $body = 'Ready for input'
                $focusTarget = [string]$config.RemoteHostAlias
                $cwdBase = ''
                $tabTitle = ''
                $sessionName = ''
                $targetFingerprint = ''
                $stackIndex = 0
                $timeoutSeconds = [int]$config.PopupTimeoutSeconds
                $popupPlacementValue = $PopupPlacement
                $originKind = ''
                $notificationId = ''
                $snapshotId = ''
                $recoveryTicketId = ''
                if ($null -ne $payload) {
                    if ($payload.PSObject.Properties['title'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.title)) { $title = [string]$payload.title }
                    if ($payload.PSObject.Properties['body'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.body)) { $body = [string]$payload.body }
                    if ($payload.PSObject.Properties['focusTarget'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.focusTarget)) { $focusTarget = [string]$payload.focusTarget }
                    if ($payload.PSObject.Properties['cwdBase'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.cwdBase)) { $cwdBase = [string]$payload.cwdBase }
                    if ($payload.PSObject.Properties['tabTitle'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.tabTitle)) { $tabTitle = [string]$payload.tabTitle }
                    if ($payload.PSObject.Properties['sessionName'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.sessionName)) { $sessionName = [string]$payload.sessionName }
                    if ($payload.PSObject.Properties['targetFingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.targetFingerprint)) { $targetFingerprint = [string]$payload.targetFingerprint }
                    if ($payload.PSObject.Properties['stackIndex']) { [int]::TryParse([string]$payload.stackIndex, [ref]$stackIndex) | Out-Null }
                    if ($payload.PSObject.Properties['timeoutSeconds']) { [int]::TryParse([string]$payload.timeoutSeconds, [ref]$timeoutSeconds) | Out-Null }
                    if ($payload.PSObject.Properties['popupPlacement'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.popupPlacement)) { $popupPlacementValue = [string]$payload.popupPlacement }
                    if ($payload.PSObject.Properties['originKind'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.originKind)) { $originKind = ([string]$payload.originKind).Trim() }
                    if ($payload.PSObject.Properties['notificationId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.notificationId)) { $notificationId = ([string]$payload.notificationId).Trim() }
                    if ($payload.PSObject.Properties['snapshotId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.snapshotId)) { $snapshotId = ([string]$payload.snapshotId).Trim() }
                    if ($payload.PSObject.Properties['recoveryTicketId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.recoveryTicketId)) { $recoveryTicketId = ([string]$payload.recoveryTicketId).Trim() }
                }
                $title = if ([string]::IsNullOrWhiteSpace($title)) { 'Pi' } else { $title.Trim() }
                $body = if ([string]::IsNullOrWhiteSpace($body)) { 'Ready for input' } else { $body.Trim() }
                $focusTarget = if ([string]::IsNullOrWhiteSpace($focusTarget)) { [string]$config.RemoteHostAlias } else { $focusTarget.Trim() }
                if (([string]$cwdBase).Trim() -match '^\{[^}]+\}$') { $cwdBase = '' }
                if (([string]$tabTitle).Trim() -match '^\{[^}]+\}$') { $tabTitle = '' }
                $hasExactRoute = ($originKind -eq 'pi-web') -and (-not [string]::IsNullOrWhiteSpace($notificationId))
                if ([string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle) -and -not $hasExactRoute) {
                    Write-NotifyBrokerLog -Message ('broker-popup-drop missing-target-metadata targetFingerprint={0}' -f (Get-NotifyBrokerContextFingerprint -Value $focusTarget))
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($targetFingerprint)) {
                    $targetFingerprint = Get-NotifyBrokerContextFingerprint -Value $focusTarget
                }

                $script:NotifyBrokerSequenceId += 1
                $popupId = ('{0}' -f $script:NotifyBrokerSequenceId)
                $elapsedMs = [int]([DateTime]::UtcNow - $item.ReceivedAt).TotalMilliseconds
                Write-NotifyBrokerLog -Message ('broker-popup-queue-dequeue popupId={0} targetFingerprint={1} queueDelayMs={2} originKind={3} notificationFp={4} snapshotFp={5}' -f $popupId, $targetFingerprint, $elapsedMs, $(if ([string]::IsNullOrWhiteSpace($originKind)) { 'none' } else { $originKind }), (Get-NotifyRouteFingerprint -Value $notificationId), (Get-NotifyRouteFingerprint -Value $snapshotId))
                Show-NotifyBrokerPopup -PopupId $popupId -Title $title -Body $body -FocusTarget $focusTarget -CwdBase $cwdBase -SourceTabTitle $tabTitle -SessionName $sessionName -TargetFingerprint $targetFingerprint -StackIndex $stackIndex -TimeoutSeconds $timeoutSeconds -PopupPlacementValue $popupPlacementValue -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId
            }
            elseif ($item.Action -eq '/close') {
                $payload = $null
                if (-not [string]::IsNullOrWhiteSpace($item.Body)) {
                    $payload = $item.Body | ConvertFrom-Json
                }
                $closePopupId = ''
                $closeActivate = $false
                if ($null -ne $payload -and $payload.PSObject.Properties['popupId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.popupId)) {
                    $closePopupId = [string]$payload.popupId
                }
                if ($null -ne $payload -and $payload.PSObject.Properties['activate']) {
                    try { $closeActivate = [bool]$payload.activate } catch { $closeActivate = $false }
                }
                if (-not [string]::IsNullOrWhiteSpace($closePopupId)) {
                    Close-NotifyBrokerPopup -PopupId $closePopupId -Activate $closeActivate
                }
            }
            elseif ($item.Action -eq '/activate-oldest') {
                [void](Invoke-NotifyBrokerOldestPopupActivation)
            }
        }
        catch {
            Write-NotifyBrokerLog -Message ('broker-dispatch-error "{0}"' -f $_.Exception.Message)
        }
    }
})

# Hide console window
try {
    $consoleHandle = [PiNotifyConsoleWindow]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][PiNotifyConsoleWindow]::ShowWindow($consoleHandle, 0)
    }
}
catch {
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:NotifyBrokerStartedAt = [DateTime]::UtcNow

Enter-NotifyBrokerSingleton
try {
    Start-NotifyBrokerHttpListener
    Write-NotifyBrokerLog -Message ('broker-start port={0} pid={1} placement={2}' -f $brokerPort, $PID, $PopupPlacement)

    # Create a hidden invisible main form to host the WinForms message loop and timers
    $script:NotifyBrokerMainForm = New-Object PiNotifyNoActivateForm
    $script:NotifyBrokerMainForm.Text = 'PiNotifyBroker'
    $script:NotifyBrokerMainForm.Size = New-Object System.Drawing.Size(0, 0)
    $script:NotifyBrokerMainForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:NotifyBrokerMainForm.Location = New-Object System.Drawing.Point(-32000, -32000)
    $script:NotifyBrokerMainForm.ShowInTaskbar = $false
    $script:NotifyBrokerMainForm.Opacity = 0
    $script:NotifyBrokerMainForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $script:NotifyBrokerMainForm.Add_Shown({
        $script:NotifyBrokerDispatchTimer.Start()
        Write-NotifyBrokerLog -Message 'broker-main-form-shown'
    })
    $script:NotifyBrokerMainForm.Add_FormClosing({
        $_.Cancel = $false
    })

    [System.Windows.Forms.Application]::Run($script:NotifyBrokerMainForm)
}
finally {
    try {
        $script:NotifyBrokerDispatchTimer.Stop()
        $script:NotifyBrokerDispatchTimer.Dispose()
    }
    catch {
    }
    try {
        if ($null -ne $script:NotifyBrokerExactWorkerTimer) {
            $script:NotifyBrokerExactWorkerTimer.Stop()
            $script:NotifyBrokerExactWorkerTimer.Dispose()
        }
        Stop-NotifyBrokerAllExactWorkers -Reason 'broker-exit'
    }
    catch {
    }
    try {
        if ($null -ne $script:NotifyBrokerListener) {
            $script:NotifyBrokerListener.Stop()
        }
    }
    catch {
    }
    try {
        if ($null -ne $script:NotifyBrokerListenerHandle) {
            $script:NotifyBrokerListenerRunspace.Stop()
            $script:NotifyBrokerListenerRunspace.Close()
        }
    }
    catch {
    }
    try {
        foreach ($cachedImage in @($script:NotifyBrokerWallpaperCardCache.Values)) {
            if ($null -ne $cachedImage) { $cachedImage.Dispose() }
        }
        if ($null -ne $script:NotifyBrokerWallpaperImage) { $script:NotifyBrokerWallpaperImage.Dispose() }
    }
    catch {
    }
    Exit-NotifyBrokerSingleton
    Write-NotifyBrokerLog -Message 'broker-exit'
}
