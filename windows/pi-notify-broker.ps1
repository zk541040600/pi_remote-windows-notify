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
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyBrokerLogPath) | Out-Null

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
$script:NotifyBrokerPrewarmQueue = $null
$script:NotifyBrokerPrewarmTimer = $null
if ($config.PSObject.Properties['PopupMaxVisible']) {
    try { $script:NotifyBrokerPopupMaxVisible = [Math]::Max(1, [Math]::Min(8, [int]$config.PopupMaxVisible)) } catch { $script:NotifyBrokerPopupMaxVisible = 4 }
}

function Write-NotifyBrokerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyBrokerLogPath -Value $line -Encoding UTF8
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

function Protect-NotifyBrokerLiveValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
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
            protectedHost     = Protect-NotifyBrokerLiveValue -Value $TargetHostValue
            protectedCwd      = Protect-NotifyBrokerLiveValue -Value $CwdBaseValue
            protectedTab      = Protect-NotifyBrokerLiveValue -Value $SourceTabTitleValue
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

function Get-NotifyBrokerSelectedTerminalTarget {
    foreach ($window in @(Get-NotifyBrokerWindows -TerminalOnly)) {
        foreach ($tab in @(Get-NotifyBrokerTabs -Handle $window.Handle)) {
            if ($tab.IsSelected) {
                return [pscustomobject]@{
                    WindowTitle = $window.Title
                    TabTitle    = $tab.Name
                    TabIndex    = $tab.Index
                    WindowHandle = $window.Handle
                }
            }
        }
    }

    return $null
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
                        Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint
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
        [string]$TargetFingerprint = ''
    )

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

function Test-NotifyBrokerTabCacheEntryValid {
    param(
        $CacheEntry,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue
    )

    if ($null -eq $CacheEntry) { return $false }
    if (([DateTime]::UtcNow - $CacheEntry.UpdatedAtUtc).TotalSeconds -gt $script:NotifyBrokerTabCacheTtlSeconds) { return $false }
    $handle = $CacheEntry.WindowHandle
    if ($null -eq $handle -or $handle -eq [IntPtr]::Zero) { return $false }
    if ($null -eq $CacheEntry.Tab) { return $false }
    $processId = [uint32]0
    [void][PiNotifyBrokerUser32]::GetWindowThreadProcessId($handle, [ref]$processId)
    if ($processId -eq 0) { return $false }
    try { Get-Process -Id $processId -ErrorAction Stop | Out-Null } catch { return $false }

    $cachedTabName = [string]$CacheEntry.TabName
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
        $cacheCandidate = Get-NotifyBrokerTabCacheCandidate -TargetFingerprint $TargetFingerprint -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue
        if ($null -ne $cacheCandidate) {
            Write-NotifyBrokerLog -Message ('broker-prewarm-cache-hit source={0} targetFingerprint={1} elapsedMs={2}' -f $cacheCandidate.Source, $TargetFingerprint, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
        }

        $requiresCwdMatch = -not [string]::IsNullOrWhiteSpace($CurrentDirBase)
        $hasPreciseSourceTitle = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
        if (-not $requiresCwdMatch -and -not $hasPreciseSourceTitle) {
            Write-NotifyBrokerLog -Message ('broker-prewarm-skip missing-target-metadata targetFingerprint={0}' -f $TargetFingerprint)
            return
        }

        $keywords = @($SourceTabTitleValue, $CurrentDirBase, $TargetHost) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique

        $best = $null
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
                $windowCwdMatch = $requiresCwdMatch -and $window.Title.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                $cwdKeywordMatch = $requiresCwdMatch -and (($matchedKeywords -contains $CurrentDirBase) -or $windowCwdMatch)
                if ($hasPreciseSourceTitle -and -not $sourceTabTitleMatch -and -not $cwdKeywordMatch) { $score = 0 }
                elseif ($requiresCwdMatch -and -not $sourceTabTitleMatch -and -not $cwdKeywordMatch) { $score = 0 }
                if ($score -le 0) { continue }
                $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name; TabIndex = $tab.Index }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) { $best = $candidate }
            }
        }

        if ($null -ne $best) {
            Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint
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
        $script:NotifyBrokerPrewarmTimer.Interval = 150
        $script:NotifyBrokerPrewarmTimer.Add_Tick({
            $this.Stop()
            if ($null -eq $script:NotifyBrokerPrewarmQueue -or $script:NotifyBrokerPrewarmQueue.Count -le 0) { return }
            $request = $script:NotifyBrokerPrewarmQueue.Dequeue()
            Write-NotifyBrokerLog -Message ('broker-prewarm-start popupId={0} targetFingerprint={1}' -f $request.PopupId, $request.TargetFingerprint)
            Update-NotifyBrokerTabCacheForTarget -TargetHost $request.TargetHost -CurrentDirBase $request.CurrentDirBase -SourceTabTitleValue $request.SourceTabTitleValue -TargetFingerprint $request.TargetFingerprint
            if ($script:NotifyBrokerPrewarmQueue.Count -gt 0) { $this.Start() }
        })
    }

    $script:NotifyBrokerPrewarmQueue.Enqueue([pscustomobject]@{
        TargetHost = $TargetHost
        CurrentDirBase = $CurrentDirBase
        SourceTabTitleValue = $SourceTabTitleValue
        TargetFingerprint = $TargetFingerprint
        PopupId = $PopupId
    })
    Write-NotifyBrokerLog -Message ('broker-prewarm-queued popupId={0} targetFingerprint={1}' -f $PopupId, $TargetFingerprint)
    $script:NotifyBrokerPrewarmTimer.Start()
}

function Invoke-NotifyBrokerOldestPopupActivation {
    $entries = @($script:NotifyBrokerActivePopups.Values | Sort-Object { if ($_.PSObject.Properties['CreatedAtUtc']) { $_.CreatedAtUtc } else { [DateTime]::MinValue } }, { if ($_.PSObject.Properties['StackIndex']) { [int]$_.StackIndex } else { 0 } })
    if ($entries.Count -eq 0) {
        Write-NotifyBrokerLog -Message 'broker-activate-oldest no-active-popups'
        return $false
    }
    $entry = $entries[0]
    $tag = $entry.Form.Tag
    if ($null -eq $tag) {
        Write-NotifyBrokerLog -Message ('broker-activate-oldest missing-tag popupId={0}' -f $entry.PopupId)
        return $false
    }
    Write-NotifyBrokerLog -Message ('broker-activate-oldest popupId={0} targetFingerprint={1}' -f $tag.PopupId, $tag.TargetFingerprint)
    $tag.ShouldActivate.Value = $true
    if ($tag.ContainsKey('DidActivate')) { $tag.DidActivate.Value = $true }
    Set-NotifyBrokerPopupActivating -Tag $tag
    $tag.ActivationQueued.Value = $true
    Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -FormToClose $tag.Form
    return $true
}

function Queue-NotifyBrokerActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint,
        [string]$PopupId = '',
        [System.Windows.Forms.Form]$FormToClose
    )

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
                Invoke-NotifyBrokerActivation -TargetHost $request.TargetHost -CurrentDirBase $request.CurrentDirBase -SourceTabTitleValue $request.SourceTabTitleValue -TargetFingerprint $request.TargetFingerprint
            }
            finally {
                if ($null -ne $request.FormToClose -and -not $request.FormToClose.IsDisposed) {
                    try {
                        Write-NotifyBrokerLog -Message ('broker-activation-feedback-close popupId={0}' -f $request.PopupId)
                        $request.FormToClose.Close()
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
    })
    $script:NotifyBrokerActivationTimer.Start()
}

function Invoke-NotifyBrokerActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint = ''
    )

    try {
        $startedAt = [DateTime]::UtcNow
        $requiresCwdMatch = -not [string]::IsNullOrWhiteSpace($CurrentDirBase)
        $hasPreciseSourceTitle = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
        Write-NotifyBrokerLog -Message ('broker-activate targetFingerprint={0} cwdFingerprint={1} sourceTabFingerprint={2}' -f (Get-NotifyBrokerContextFingerprint -Value $TargetHost), (Get-NotifyBrokerContextFingerprint -Value $CurrentDirBase), (Get-NotifyBrokerContextFingerprint -Value $SourceTabTitleValue))
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
        $cacheHit = $false
        $cacheSource = 'none'
        $cacheCandidate = Get-NotifyBrokerTabCacheCandidate -TargetFingerprint $TargetFingerprint -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue
        if ($null -ne $cacheCandidate) {
            $cached = $cacheCandidate.Entry
            $cacheHit = $true
            $cacheSource = $cacheCandidate.Source
            Write-NotifyBrokerLog -Message ('broker-cache-hit source={0} windowFingerprint={1} tabFingerprint={2} tabIndex={3} targetFingerprint={4}' -f $cacheSource, (Get-NotifyBrokerContextFingerprint -Value $cached.WindowTitle), (Get-NotifyBrokerContextFingerprint -Value $cached.TabName), $cached.TabIndex, $TargetFingerprint)
            $windowObj = [pscustomobject]@{
                Handle      = $cached.WindowHandle
                Title       = $cached.WindowTitle
                ProcessId   = $cached.ProcessId
                ProcessName = ''
            }
            $best = [pscustomobject]@{ Window = $windowObj; Score = 1; TabName = $cached.TabName; TabIndex = $cached.TabIndex; Tab = $cached.Tab }
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
                    $windowCwdMatch = $requiresCwdMatch -and $window.Title.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                    $cwdKeywordMatch = $requiresCwdMatch -and (($matchedKeywords -contains $CurrentDirBase) -or $windowCwdMatch)
                    if ($hasPreciseSourceTitle -and -not $sourceTabTitleMatch -and -not $cwdKeywordMatch) {
                        $score = 0
                    }
                    elseif ($requiresCwdMatch -and -not $sourceTabTitleMatch -and -not $cwdKeywordMatch) {
                        $score = 0
                    }
                    Write-NotifyBrokerLog -Message ('broker-tab index={0} nameFingerprint={1} selected={2} score={3} matchedKeywordCount={4} sourceTabTitleMatch={5}' -f $tab.Index, (Get-NotifyBrokerContextFingerprint -Value $tab.Name), $tab.IsSelected, $score, @($matchedKeywords).Count, $sourceTabTitleMatch)
                    if ($score -le 0) {
                        continue
                    }

                    $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name; TabIndex = $tab.Index }
                    if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                        $best = $candidate
                    }
                }
            }
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
                Write-NotifyBrokerLog -Message ('broker-tab-selected tabFingerprint={0} elapsedMs={1} cacheHit=True cacheSource={2}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds, $cacheSource)
                Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint
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
                Write-NotifyBrokerLog -Message ('broker-tab-selected tabFingerprint={0} elapsedMs={1} cacheHit={2} cacheSource={3}' -f (Get-NotifyBrokerContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds, $cacheHit, $cacheSource)
                Update-NotifyBrokerTabCache -Best $best -TargetFingerprint $TargetFingerprint
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

    if ($null -eq $Tag) { return }
    try {
        if ($Tag.Activating.Value) { return }
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
            $Tag.TitleLabel.Text = 'Switching to the target terminal tab'
            $Tag.TitleLabel.ForeColor = $inactiveTextColor
            $Tag.TitleLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        if ($null -ne $Tag.BodyLabel) {
            $Tag.BodyLabel.Text = 'Please wait if window scanning is slow. This popup will close automatically.'
            $Tag.BodyLabel.ForeColor = $inactiveTextColor
            $Tag.BodyLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        if ($null -ne $Tag.CloseLabel) {
            $Tag.CloseLabel.Text = '...'
            $Tag.CloseLabel.ForeColor = $inactiveTextColor
        }
        Write-NotifyBrokerLog -Message ('broker-activation-feedback popupId={0}' -f $Tag.PopupId)
        if ($null -ne $Tag.Form) {
            $Tag.Form.Invalidate($true)
            $Tag.Form.Refresh()
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-activation-feedback-error popupId={0} "{1}"' -f $Tag.PopupId, $_.Exception.Message)
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
        [string]$PopupPlacementValue
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
            try { $existing.Form.Close() } catch {}
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
            try { $drop.Form.Close() } catch {}
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
                $dest = New-Object System.Drawing.Rectangle(0, 0, $paintPanel.Width, $paintPanel.Height)
                $source = Get-NotifyBrokerCoverSourceRectangle -Image $script:NotifyBrokerWallpaperImage -TargetWidth $paintPanel.Width -TargetHeight $paintPanel.Height -VerticalOffsetPixels $script:NotifyBrokerWallpaperOffsetYPixels
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($script:NotifyBrokerWallpaperImage, $dest, $source, [System.Drawing.GraphicsUnit]::Pixel)
                $overlay = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
                    $dest,
                    [System.Drawing.Color]::FromArgb(170, 0, 0, 0),
                    [System.Drawing.Color]::FromArgb(70, 0, 0, 0),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
                try { $graphics.FillRectangle($overlay, $dest) } finally { $overlay.Dispose() }
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
    $didActivate = $false
    $shouldActivate = $false

    $timer = New-Object System.Windows.Forms.Timer
    $focusWatchTimer = New-Object System.Windows.Forms.Timer
    $popupCreatedAtUtc = [DateTime]::UtcNow

    # Pass closure variables via form.Tag to event handlers to survive function scope exit
    $popupTag = @{
        PopupId           = $PopupId
        TargetHost        = $targetHost
        TargetCwdBase     = $targetCwdBase
        TargetSourceTabTitle = $targetSourceTabTitle
        TargetFingerprint = $TargetFingerprint
        StackIndex        = $StackIndex
        PopupPlacement    = $PopupPlacementValue
        CreatedAtUtc      = $popupCreatedAtUtc
        DidActivate       = [ref]$didActivate
        ShouldActivate    = [ref]$shouldActivate
        Activating        = [ref]$false
        ActivationQueued  = [ref]$false
        Timer             = $timer
        FocusWatchTimer   = $focusWatchTimer
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

    $activateAction = {
        $tag = $this.FindForm().Tag
        if ($tag.DidActivate.Value) {
            return
        }
        $tag.DidActivate.Value = $true
        $tag.ShouldActivate.Value = $true
        Write-NotifyBrokerLog -Message ('broker-popup-click popupId={0}' -f $tag.PopupId)
        Write-NotifyBrokerLog -Message ('broker-action activate popupId={0} targetFingerprint={1}' -f $tag.PopupId, $tag.TargetFingerprint)
        Set-NotifyBrokerPopupActivating -Tag $tag
        $tag.ActivationQueued.Value = $true
        Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -FormToClose $tag.Form
    }

    $closeAction = {
        $tag = $this.FindForm().Tag
        Write-NotifyBrokerLog -Message ('broker-close-button popupId={0}' -f $tag.PopupId)
        Write-NotifyBrokerLog -Message ('broker-action dismiss source="close-button" popupId={0}' -f $tag.PopupId)
        $this.FindForm().Close()
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
        $this.Stop()
        $tag.FocusWatchTimer.Stop()
        $tag.Form.Close()
    })

    $focusWatchTimer.Interval = 800
    $focusWatchTimer.Add_Tick({
        $tag = $this.PopupTag
        if (Test-NotifyBrokerForegroundTarget -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint) {
            Write-NotifyBrokerLog -Message ('broker-action dismiss source="foreground-target" popupId={0}' -f $tag.PopupId)
            $this.Stop()
            $tag.Timer.Stop()
            $tag.Form.Close()
        }
    })

    $form.Add_Shown({
        $tag = $this.Tag
        [void][PiNotifyBrokerUser32]::SetWindowPos($this.Handle, $script:NotifyBrokerHwndTopMost, $this.Left, $this.Top, $this.Width, $this.Height, $script:NotifyBrokerSwpShowNoActivate)
        Write-NotifyBrokerLog -Message ('broker-shown popupId={0} stackIndex={1} placement={2} targetFingerprint={3} elapsedMs={4}' -f $tag.PopupId, $tag.StackIndex, $tag.PopupPlacement, $tag.TargetFingerprint, [int]([DateTime]::UtcNow - $tag.CreatedAtUtc).TotalMilliseconds)
        Queue-NotifyBrokerPrewarm -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId
        $tag.Timer.Start()
        $tag.FocusWatchTimer.Start()
    })

    $form.Add_FormClosed({
        $tag = $this.Tag
        Write-NotifyBrokerLog -Message ('broker-closed popupId={0} shouldActivate={1}' -f $tag.PopupId, $tag.ShouldActivate.Value)
        try {
            $tag.Timer.Stop()
            $tag.Timer.Dispose()
            $tag.FocusWatchTimer.Stop()
            $tag.FocusWatchTimer.Dispose()
        }
        catch {
        }
        Remove-NotifyBrokerLiveState -PopupId $tag.PopupId
        $script:NotifyBrokerActivePopups.Remove($tag.PopupId) | Out-Null

        if ($tag.ShouldActivate.Value -and -not $tag.ActivationQueued.Value) {
            Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId
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
                $tag.ShouldActivate.Value = $true
                if ($tag.ContainsKey('DidActivate')) { $tag.DidActivate.Value = $true }
                Set-NotifyBrokerPopupActivating -Tag $tag
                $tag.ActivationQueued.Value = $true
                Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -FormToClose $tag.Form
            }
            else {
                $entry.Form.Close()
            }
        } catch {}
    }
    else {
        Write-NotifyBrokerLog -Message ('broker-close-by-id-miss popupId={0}' -f $PopupId)
        Remove-NotifyBrokerLiveState -PopupId $PopupId
    }
}

# HTTP response helper
function Write-NotifyBrokerHttpResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [string]$Body = "",
        [string]$ContentType = "application/json; charset=utf-8"
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
    $header = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Read-NotifyBrokerHttpRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream
    )

    $maxBodyBytes = 65536
    $buffer = [byte[]]::new(4096)
    $memory = [System.IO.MemoryStream]::new()
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }

        $memory.Write($buffer, 0, $read)
        $bytes = $memory.ToArray()
        $startIndex = [Math]::Max(0, $bytes.Length - $read - 3)
        for ($i = $startIndex; $i -le $bytes.Length - 4; $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) {
                $headerEnd = $i + 4
                break
            }
        }

        if ($memory.Length -gt 65536) {
            throw "HTTP header too large."
        }
    }

    if ($headerEnd -lt 0) {
        throw "Incomplete HTTP request header."
    }

    $allBytes = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = if ($lines.Length -gt 0) { [string]$lines[0] } else { '' }
    $requestLine = $requestLine.Trim()
    if ([string]::IsNullOrWhiteSpace($requestLine)) {
        throw "Missing HTTP request line."
    }

    $headers = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($lines.Length -gt 1) {
        foreach ($line in $lines[1..($lines.Length - 1)]) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $index = $line.IndexOf(':')
            if ($index -le 0) {
                continue
            }
            $headers[$line.Substring(0, $index).Trim()] = $line.Substring($index + 1).Trim()
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) {
        [int]::TryParse([string]$headers['Content-Length'], [ref]$contentLength) | Out-Null
    }
    if ($contentLength -lt 0) {
        throw "Invalid HTTP content length."
    }
    if ($contentLength -gt $maxBodyBytes) {
        throw "HTTP request body too large."
    }

    $bodyMemory = [System.IO.MemoryStream]::new()
    $existingBytes = $allBytes.Length - $headerEnd
    if ($existingBytes -gt $maxBodyBytes) {
        throw "HTTP request body too large."
    }
    if ($existingBytes -gt 0) {
        $bodyMemory.Write($allBytes, $headerEnd, $existingBytes)
    }

    while ($bodyMemory.Length -lt $contentLength) {
        $remaining = [Math]::Min($buffer.Length, $contentLength - [int]$bodyMemory.Length)
        $read = $Stream.Read($buffer, 0, $remaining)
        if ($read -le 0) {
            break
        }
        $bodyMemory.Write($buffer, 0, $read)
    }

    $bodyBytes = $bodyMemory.ToArray()
    if ($bodyBytes.Length -gt $contentLength) {
        $trimmed = [byte[]]::new($contentLength)
        [Array]::Copy($bodyBytes, 0, $trimmed, 0, $contentLength)
        $bodyBytes = $trimmed
    }

    return [pscustomobject]@{
        RequestLine = $requestLine
        Headers     = $headers
        BodyBytes   = $bodyBytes
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
param($Listener, $Queue, $LogPath, $IoTimeoutMs)
$ErrorActionPreference = 'Stop'
function Write-BrokerBgLog($Msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Msg)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}
function Write-BgResponse($Stream, $StatusCode, $Reason, $Body, $ContentType) {
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
    $header = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
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
                }
                $title = if ([string]::IsNullOrWhiteSpace($title)) { 'Pi' } else { $title.Trim() }
                $body = if ([string]::IsNullOrWhiteSpace($body)) { 'Ready for input' } else { $body.Trim() }
                $focusTarget = if ([string]::IsNullOrWhiteSpace($focusTarget)) { [string]$config.RemoteHostAlias } else { $focusTarget.Trim() }
                if (([string]$cwdBase).Trim() -match '^\{[^}]+\}$') { $cwdBase = '' }
                if (([string]$tabTitle).Trim() -match '^\{[^}]+\}$') { $tabTitle = '' }
                if ([string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle)) {
                    Write-NotifyBrokerLog -Message ('broker-popup-drop missing-target-metadata targetFingerprint={0}' -f (Get-NotifyBrokerContextFingerprint -Value $focusTarget))
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($targetFingerprint)) {
                    $targetFingerprint = Get-NotifyBrokerContextFingerprint -Value $focusTarget
                }

                $script:NotifyBrokerSequenceId += 1
                $popupId = ('{0}' -f $script:NotifyBrokerSequenceId)
                $elapsedMs = [int]([DateTime]::UtcNow - $item.ReceivedAt).TotalMilliseconds
                Write-NotifyBrokerLog -Message ('broker-popup-queue-dequeue popupId={0} targetFingerprint={1} queueDelayMs={2}' -f $popupId, $targetFingerprint, $elapsedMs)
                Show-NotifyBrokerPopup -PopupId $popupId -Title $title -Body $body -FocusTarget $focusTarget -CwdBase $cwdBase -SourceTabTitle $tabTitle -SessionName $sessionName -TargetFingerprint $targetFingerprint -StackIndex $stackIndex -TimeoutSeconds $timeoutSeconds -PopupPlacementValue $popupPlacementValue
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
    Exit-NotifyBrokerSingleton
    Write-NotifyBrokerLog -Message 'broker-exit'
}
