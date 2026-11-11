[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"
. "$PSScriptRoot/terminal-route.ps1"
. "$PSScriptRoot/NotifyBridge.Activation.ps1"

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
$script:NotifyBrokerHwndTopMost = [IntPtr](-1)
$script:NotifyBrokerSwpShowNoActivate = [uint32](0x0010 -bor 0x0040)
$script:NotifyBrokerPopupMaxVisible = 4
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
        $ttlSeconds = [Math]::Max(300, ([Math]::Ceiling((Get-NotifyPopupLifetimeMs -TimeoutSeconds $TimeoutSecondsValue) / 1000) + 60))
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
                    return $true
                }
            }

            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
            foreach ($value in $haystack) {
                if ($value.IndexOf($CurrentDirBase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Write-NotifyBrokerLog -Message ('broker-foreground-target-match cwdFingerprint={0} selectedTabFingerprint={1} windowFingerprint={2}' -f (Get-NotifyBrokerContextFingerprint -Value $CurrentDirBase), (Get-NotifyBrokerContextFingerprint -Value $selectedTitle), (Get-NotifyBrokerContextFingerprint -Value $windowTitle))
                    return $true
                }
            }
        }
    }
    catch {
    }

    return $false
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
             (([string]$tag.OriginKind -eq 'pi-web') -or ([string]$tag.OriginKind -eq 'paseo')) -and
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
        [void](Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId)
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
        [Parameter(Mandatory = $true)][string]$Reason,
        $Retryable = $null
    )

    if ($null -eq $Tag -or $null -eq $Tag.Form -or $Tag.Form.IsDisposed) { return $false }
    $remainingMs = Get-NotifyActivationRemainingMs -ExpiresAtUtc ([DateTime]$Tag.ExpiresAtUtc)
    if ($Outcome -ne 'dismissed' -and $remainingMs -le 0) {
        $Tag.TerminalState.Value = $true
        $Tag.TerminalOutcome = 'dismissed'
        $Tag.TerminalReason = 'expired'
        $Tag.Activating.Value = $false
        $Tag.Timer.Stop()
        $Tag.FocusWatchTimer.Stop()
        $Tag.FailureCloseTimer.Stop()
        $Tag.ActivationWatchdogTimer.Stop()
        Write-NotifyBrokerLog -Message ('broker-popup-expired popupId={0} ignoredOutcome={1} reason={2}' -f $Tag.PopupId, $Outcome, $Reason)
        if (-not $Tag.CloseRequested.Value) {
            $Tag.CloseRequested.Value = $true
            $Tag.Form.Close()
        }
        return $true
    }

    $originKind = if ($null -eq $Tag.OriginKind) { '' } else { ([string]$Tag.OriginKind).Trim() }
    $retryAllowed = $Reason -notin @('expired', 'invalid', 'activation-missing', 'foreign-owner', 'non-loopback', 'ambiguous')
    if ($null -ne $Retryable) { $retryAllowed = [bool]$Retryable }
    $supportsRetry = ($originKind -eq 'paseo') -or ($originKind -eq 'terminal') -or [string]::IsNullOrWhiteSpace($originKind)
    $isRetryableFailure = ($Outcome -eq 'failed') -and $supportsRetry -and $retryAllowed
    $keepPaseoExpiryTimer = ($Outcome -eq 'failed') -and ($originKind -eq 'paseo') -and ($isRetryableFailure -or $Reason -in @('expired', 'invalid', 'activation-missing'))
    $alreadyTerminal = $Tag.TerminalState.Value
    if (-not $alreadyTerminal) {
        $Tag.TerminalState.Value = $true
        $Tag.TerminalOutcome = $Outcome
        $Tag.TerminalReason = $Reason
        $Tag.Activating.Value = $false
        if (-not $keepPaseoExpiryTimer) { $Tag.Timer.Stop() }
        $Tag.FocusWatchTimer.Stop()
        $Tag.ActivationWatchdogTimer.Stop()
        Write-NotifyBrokerLog -Message ('broker-popup-terminal popupId={0} outcome={1} reason={2}' -f $Tag.PopupId, $Outcome, $Reason)
    }

    if ($Outcome -eq 'failed') {
        if ($alreadyTerminal) { return $false }
        if ($isRetryableFailure) {
            # Temporary failures restore clickable retry UI without extending original expiry.
            $Tag.TerminalState.Value = $false
            $Tag.TerminalOutcome = ''
            $Tag.TerminalReason = ''
            $Tag.DidActivate.Value = $false
            $Tag.ShouldActivate.Value = $false
            $Tag.ActivationQueued.Value = $false
            $Tag.Activating.Value = $false
            Set-NotifyBrokerRecoveryUiState -Tag $Tag -State 'ready'
            $retryText = -join @([char]0x8df3, [char]0x8f6c, [char]0x5931, [char]0x8d25, [char]0xff0c, [char]0x70b9, [char]0x51fb, [char]0x91cd, [char]0x8bd5)
            $Tag.TitleLabel.Text = $retryText
            $Tag.BodyLabel.Text = $Tag.OriginalBody
            $Tag.FailureCloseTimer.Stop()
            $remainingMs = Get-NotifyActivationRemainingMs -ExpiresAtUtc ([DateTime]$Tag.ExpiresAtUtc)
            if ($remainingMs -le 0) {
                $Tag.TerminalState.Value = $true
                $Tag.TerminalOutcome = 'dismissed'
                $Tag.TerminalReason = 'expired'
                if (-not $Tag.CloseRequested.Value) {
                    $Tag.CloseRequested.Value = $true
                    $Tag.Form.Close()
                }
                return $true
            }
            $Tag.Timer.Stop()
            $Tag.Timer.Interval = $remainingMs
            $Tag.Timer.Start()
            $Tag.FocusWatchTimer.Start()
            Write-NotifyBrokerLog -Message ('broker-retry-ready popupId={0} originKind={1} reason={2} remainingMs={3}' -f $Tag.PopupId, $(if ([string]::IsNullOrWhiteSpace($originKind)) { 'terminal' } else { $originKind }), $Reason, $remainingMs)
            return $true
        }
        Remove-NotifyBrokerLiveState -PopupId ([string]$Tag.PopupId)
        if (([string]$Tag.OriginKind -eq 'paseo') -and ($Reason -in @('expired', 'invalid', 'activation-missing'))) {
            $expiredText = -join @([char]0x901a, [char]0x77e5, [char]0x5df2, [char]0x5931, [char]0x6548)
            Set-NotifyBrokerRecoveryUiState -Tag $Tag -State 'unavailable'
            $Tag.TitleLabel.Text = $expiredText
            $Tag.FailureCloseTimer.Stop()
            # Keep disabled card until popup timeout; do not auto-close immediately.
            return $true
        }
        Set-NotifyBrokerRecoveryUiState -Tag $Tag -State 'unavailable'
        $Tag.FailureCloseTimer.Stop()
        $Tag.FailureCloseTimer.Interval = [Math]::Max(1, [Math]::Min([int]$script:NotifyBrokerFailureCloseDelayMs, $remainingMs))
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
    $originKind = if ($Tag.ContainsKey('OriginKind')) { [string]$Tag.OriginKind } else { '' }
    $failure = New-NotifyActivationWorkerFailureOutcome -Operation 'activate' -OriginKind $originKind -Reason 'activation-watchdog'
    Write-NotifyBrokerLog -Message ('broker-activation-watchdog popupId={0} result={1}' -f $Tag.PopupId, $failure.Result)
    [void](Complete-NotifyBrokerPopupLifecycle -Tag $Tag -Outcome 'failed' -Reason $failure.Reason -Retryable $failure.Retryable)
    [void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $Tag.PopupId)
    Stop-NotifyBrokerExactWorkersForPopup -PopupId $Tag.PopupId -Reason 'activation-watchdog'
    return $true
}

function Set-NotifyBrokerExactWorkerFailClosed {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$Operation = 'activate',
        [string]$OriginKind = ''
    )

    $failure = New-NotifyActivationWorkerFailureOutcome -Operation $Operation -OriginKind $OriginKind -Reason $Reason
    Write-NotifyBrokerLog -Message ('broker-exact-worker-rejected popupId={0} result={1} reason={2} active={3} max={4}' -f $PopupId, $failure.Result, $failure.Reason, $script:NotifyBrokerExactWorkers.Count, $script:NotifyBrokerExactWorkerMax)
    if (-not $script:NotifyBrokerActivePopups.ContainsKey($PopupId)) { return }

    $entry = $script:NotifyBrokerActivePopups[$PopupId]
    if ($null -eq $entry -or $null -eq $entry.Form -or $entry.Form.IsDisposed -or $null -eq $entry.Form.Tag) { return }

    $tag = $entry.Form.Tag
    [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason $failure.Reason -Retryable $failure.Retryable)
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
        $failure = New-NotifyActivationWorkerFailureOutcome -Operation $Worker.Operation -OriginKind $Worker.OriginKind -Reason 'worker-cancel-error'
        Write-NotifyBrokerLog -Message ('broker-exact-worker-cancel-error popupId={0} mode={1} reason={2} result={3}' -f $Worker.PopupId, $Worker.Mode, $Reason, $failure.Result)
        Set-NotifyBrokerExactWorkerFailClosed -PopupId $Worker.PopupId -Reason $failure.Reason -Operation $Worker.Operation -OriginKind $Worker.OriginKind
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

        $originKind = 'pi-web'
        $targetHost = ''
        $cwdBase = ''
        $tabTitle = ''
        $targetFingerprint = ''
        if ($script:NotifyBrokerActivePopups.ContainsKey([string]$deferred.PopupId)) {
            $deferredTag = $script:NotifyBrokerActivePopups[[string]$deferred.PopupId].Form.Tag
            if ($null -ne $deferredTag) {
                if ($deferredTag.ContainsKey('OriginKind') -and -not [string]::IsNullOrWhiteSpace([string]$deferredTag.OriginKind)) {
                    $originKind = [string]$deferredTag.OriginKind
                }
                if ($deferredTag.ContainsKey('TargetHost')) { $targetHost = [string]$deferredTag.TargetHost }
                if ($deferredTag.ContainsKey('TargetCwdBase')) { $cwdBase = [string]$deferredTag.TargetCwdBase }
                if ($deferredTag.ContainsKey('TargetSourceTabTitle')) { $tabTitle = [string]$deferredTag.TargetSourceTabTitle }
                if ($deferredTag.ContainsKey('TargetFingerprint')) { $targetFingerprint = [string]$deferredTag.TargetFingerprint }
            }
        }
        [void](Start-NotifyBrokerExactWorker -PopupId $deferred.PopupId -Mode 'activate' -OriginKind $originKind -NotificationId $deferred.NotificationId -SnapshotId $deferred.SnapshotId -RecoveryTicketId $deferred.RecoveryTicketId -TargetHost $targetHost -CurrentDirBase $cwdBase -SourceTabTitleValue $tabTitle -TargetFingerprint $targetFingerprint)
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

function Ensure-NotifyBrokerExactWorkerTimer {
    if ($null -ne $script:NotifyBrokerExactWorkerTimer) {
        return
    }

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
            $rows = @()
            try {
                if ($null -ne $worker.StopAsync) { $worker.PowerShell.EndStop($worker.StopAsync) }
                if ($worker.Async.IsCompleted) {
                    $rows = @($worker.PowerShell.EndInvoke($worker.Async))
                }
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($cancelReason)) {
                    $result = New-NotifyActivationWorkerFailureOutcome -Operation $worker.Operation -OriginKind $worker.OriginKind -Reason 'worker-endinvoke-error' -ElapsedMs ([int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds)
                }
            }
            finally {
                Close-NotifyBrokerExactWorkerResources -Worker $worker
                [void]$script:NotifyBrokerExactWorkers.Remove($id)
            }

            $elapsedMs = [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds
            if (-not [string]::IsNullOrWhiteSpace($cancelReason)) {
                $cancelled = New-NotifyActivationWorkerFailureOutcome -Operation $worker.Operation -OriginKind $worker.OriginKind -Reason 'worker-cancelled' -ElapsedMs $elapsedMs
                Write-NotifyBrokerLog -Message ('broker-exact-worker-cancelled popupId={0} mode={1} reason={2} result={3} elapsedMs={4}' -f $worker.PopupId, $worker.Mode, $cancelReason, $cancelled.Result, $cancelled.ElapsedMs)
                if ($cancelReason -eq 'preempted-by-activation' -and
                    -not (Test-NotifyBrokerActivationIntent -PopupId $worker.PopupId)) {
                    Set-NotifyBrokerExactWorkerFailClosed -PopupId $worker.PopupId -Reason $cancelReason -Operation $worker.Operation -OriginKind $worker.OriginKind
                }
                Start-NotifyBrokerNextDeferredActivation
                continue
            }

            if ($null -eq $result) {
                $result = Resolve-NotifyActivationWorkerOutput -Rows $rows -Operation $worker.Operation -OriginKind $worker.OriginKind -ElapsedMs $elapsedMs
            }

            $snapshotFp = Get-NotifyRouteFingerprint -Value ([string]$result.SnapshotId)
            Write-NotifyBrokerLog -Message ('broker-exact-worker-complete popupId={0} mode={1} decision={2} result={3} reason={4} snapshotFp={5} elapsedMs={6} scrollAttempted={7} scrolledToBottom={8}' -f $worker.PopupId, $worker.Mode, $result.Decision, $result.Result, $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'none' } else { [string]$result.Reason }), $snapshotFp, $elapsedMs, $result.ScrollAttempted, $result.ScrolledToBottom)
            Start-NotifyBrokerNextDeferredActivation
            if (-not $script:NotifyBrokerActivePopups.ContainsKey($worker.PopupId)) { continue }
            $entry = $script:NotifyBrokerActivePopups[$worker.PopupId]
            $tag = $entry.Form.Tag
            $deferredIntent = Test-NotifyBrokerActivationIntent -PopupId $worker.PopupId
            $ui = ConvertTo-NotifyActivationUiOutcome -Outcome $result -HasDeferredActivateIntent:$deferredIntent
            if ($ui.Action -eq 'store-ready') {
                if (-not [string]::IsNullOrWhiteSpace([string]$ui.SnapshotId)) {
                    $tag.SnapshotId = [string]$ui.SnapshotId
                }
                if (-not $tag.TerminalState.Value) {
                    Set-NotifyBrokerRecoveryUiState -Tag $tag -State 'ready'
                }
                if ($ui.StartActivate) {
                    [void](Start-NotifyBrokerExactWorker -PopupId $worker.PopupId -Mode 'activate' -OriginKind 'pi-web' -NotificationId $tag.NotificationId -SnapshotId $tag.SnapshotId -RecoveryTicketId $tag.RecoveryTicketId)
                }
                continue
            }
            if ($ui.Action -eq 'close-handled') {
                [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'handled' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$ui.Result)) { 'activation-handled' } else { [string]$ui.Result }))
                continue
            }
            if ($ui.Action -eq 'keep-focused') {
                # Focused/pending is non-terminal: keep the card in bounded
                # pending feedback instead of closing. The original popup
                # deadline stays authoritative; a later terminal result (or
                # timeout) closes it.
                if (-not $tag.TerminalState.Value) {
                    Set-NotifyBrokerRecoveryUiState -Tag $tag -State 'recovering'
                }
                continue
            }
            if ($ui.Action -eq 'restore-retryable') {
                $reason = if (-not [string]::IsNullOrWhiteSpace([string]$ui.Result)) { [string]$ui.Result } elseif (-not [string]::IsNullOrWhiteSpace([string]$ui.Reason)) { [string]$ui.Reason } else { 'activation-failed' }
                [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason $reason -Retryable $true)
                continue
            }
            $failReason = if (-not [string]::IsNullOrWhiteSpace([string]$ui.Result)) { [string]$ui.Result } elseif (-not [string]::IsNullOrWhiteSpace([string]$ui.Reason)) { [string]$ui.Reason } else { 'activation-failed' }
            [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'failed' -Reason $failReason -Retryable $false)
        }
        if ($script:NotifyBrokerExactWorkers.Count -eq 0) { $this.Stop() }
    })
}

function Start-NotifyBrokerExactWorker {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [Parameter(Mandatory = $true)][ValidateSet('resolve', 'activate')][string]$Mode,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        [string]$TargetHost = '',
        [string]$CurrentDirBase = '',
        [string]$SourceTabTitleValue = '',
        [string]$TargetFingerprint = ''
    )

    $resolvedOrigin = if ([string]::IsNullOrWhiteSpace($OriginKind)) {
        if ($Mode -eq 'resolve') { 'pi-web' } else { '' }
    } else {
        $OriginKind.Trim()
    }
    $operation = if ($Mode -eq 'resolve') { 'resolve' } else { 'activate' }

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
                Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-queue-cap-reached' -Operation $operation -OriginKind $resolvedOrigin
                return $false
            }
            if (-not (Request-NotifyBrokerExactWorkerStop -Worker $resolvers[0] -Reason 'superseded-by-activation')) {
                [void](Remove-NotifyBrokerDeferredActivationForPopup -PopupId $PopupId)
                Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-cancel-error' -Operation $operation -OriginKind $resolvedOrigin
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
                    Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-queue-cap-reached' -Operation $operation -OriginKind $resolvedOrigin
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
        Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason $reason -Operation $operation -OriginKind $resolvedOrigin
        return $false
    }

    $script:NotifyBrokerExactWorkerSequence += 1
    $workerId = ('exact-{0}' -f $script:NotifyBrokerExactWorkerSequence)
    $runspace = $null
    $powerShell = $null
    $workerScript = Get-NotifyActivationWorkerScript
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $powerShell = [System.Management.Automation.PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript($workerScript)
        [void]$powerShell.AddParameter('CommonPath', (Join-Path $PSScriptRoot 'NotifyBridge.Common.ps1'))
        [void]$powerShell.AddParameter('TerminalRoutePath', (Join-Path $PSScriptRoot 'terminal-route.ps1'))
        [void]$powerShell.AddParameter('ActivationPath', (Join-Path $PSScriptRoot 'NotifyBridge.Activation.ps1'))
        [void]$powerShell.AddParameter('ConfigPath', $ConfigPath)
        [void]$powerShell.AddParameter('Operation', $operation)
        [void]$powerShell.AddParameter('OriginKind', $resolvedOrigin)
        [void]$powerShell.AddParameter('NotificationId', $NotificationId)
        [void]$powerShell.AddParameter('SnapshotId', $SnapshotId)
        [void]$powerShell.AddParameter('RecoveryTicketId', $RecoveryTicketId)
        [void]$powerShell.AddParameter('TargetHost', $TargetHost)
        [void]$powerShell.AddParameter('CwdBase', $CurrentDirBase)
        [void]$powerShell.AddParameter('TabTitle', $SourceTabTitleValue)
        [void]$powerShell.AddParameter('TargetFingerprint', $TargetFingerprint)
        [void]$powerShell.AddParameter('TimeoutMs', 3000)
        [void]$powerShell.AddParameter('ActivationRecoveryWaitMs', $script:NotifyBrokerActivationRecoveryWaitMs)
        $async = $powerShell.BeginInvoke()
    }
    catch {
        if ($null -ne $powerShell) { try { $powerShell.Dispose() } catch {} }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch {}
            try { $runspace.Dispose() } catch {}
        }
        Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'worker-start-error' -Operation $operation -OriginKind $resolvedOrigin
        return $false
    }
    $script:NotifyBrokerExactWorkers[$workerId] = [pscustomobject]@{
        WorkerId = $workerId
        PopupId = $PopupId
        Mode = $Mode
        Operation = $operation
        OriginKind = $resolvedOrigin
        PowerShell = $powerShell
        Runspace = $runspace
        Async = $async
        StartedAtUtc = [DateTime]::UtcNow
        StopAsync = $null
        CancelReason = ''
    }

    Ensure-NotifyBrokerExactWorkerTimer
    $script:NotifyBrokerExactWorkerTimer.Start()
    return $true
}

function Start-NotifyBrokerPaseoWorker {
    param(
        [Parameter(Mandatory = $true)][string]$PopupId,
        [string]$ActivationId = ''
    )

    if ([string]::IsNullOrWhiteSpace($ActivationId)) {
        Set-NotifyBrokerExactWorkerFailClosed -PopupId $PopupId -Reason 'activation-missing' -Operation 'activate' -OriginKind 'paseo'
        return $false
    }

    return (Start-NotifyBrokerExactWorker -PopupId $PopupId -Mode 'activate' -OriginKind 'paseo' -SnapshotId $ActivationId)
}

function Queue-NotifyBrokerActivation {
    param(
        [string]$TargetHost,
        [string]$CurrentDirBase,
        [string]$SourceTabTitleValue,
        [string]$TargetFingerprint,
        [string]$PopupId = '',
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = ''
    )

    if ($OriginKind -eq 'paseo') {
        return Start-NotifyBrokerPaseoWorker -PopupId $PopupId -ActivationId $SnapshotId
    }

    return (Start-NotifyBrokerExactWorker -PopupId $PopupId -Mode 'activate' -OriginKind $OriginKind -NotificationId $NotificationId -SnapshotId $SnapshotId -RecoveryTicketId $RecoveryTicketId -TargetHost $TargetHost -CurrentDirBase $CurrentDirBase -SourceTabTitleValue $SourceTabTitleValue -TargetFingerprint $TargetFingerprint)
}

function Get-NotifyBrokerWorkingArea {
    param([string]$Placement)
    return (Get-NotifyPopupWorkingArea -Placement $Placement)
}

function Get-NotifyBrokerPopupLocation {
    param(
        [Parameter(Mandatory = $true)][int]$StackIndex,
        [Parameter(Mandatory = $true)][int]$FormWidth,
        [Parameter(Mandatory = $true)][int]$FormHeight,
        [string]$Placement = 'cursor',
        $WorkingArea = $null
    )

    if ($null -eq $WorkingArea) {
        $WorkingArea = Get-NotifyBrokerWorkingArea -Placement (Normalize-NotifyBridgePopupPlacement -Value $Placement)
    }
    return (Get-NotifyPopupStackPosition -WorkingArea $WorkingArea -StackIndex $StackIndex -FormWidth $FormWidth -FormHeight $FormHeight)
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

    if ($null -eq $Tag -or $null -eq $Tag.Form -or $Tag.Form.IsDisposed -or $Tag.Form.Disposing -or
        $Tag.CloseRequested.Value -or $Tag.TerminalState.Value -or $Tag.Activating.Value) { return $false }
    if ((Get-NotifyActivationRemainingMs -ExpiresAtUtc ([DateTime]$Tag.ExpiresAtUtc)) -le 0) {
        [void](Complete-NotifyBrokerPopupLifecycle -Tag $Tag -Outcome 'dismissed' -Reason 'expired')
        return $false
    }
    try {
        $Tag.Activating.Value = $true
        if ([string]$Tag.OriginKind -ne 'paseo') { $Tag.Timer.Stop() }
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
            $baseApp = if ($Tag.ContainsKey('OriginalAppText') -and -not [string]::IsNullOrWhiteSpace([string]$Tag.OriginalAppText)) { [string]$Tag.OriginalAppText } else { 'Pi Remote' }
            $Tag.AppLabel.Text = ('{0} - {1}' -f $baseApp, $jumpingText)
            $Tag.AppLabel.ForeColor = $inactiveTextColor
            $Tag.AppLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        if ($null -ne $Tag.SessionLabel) {
            $Tag.SessionLabel.Text = $Tag.OriginalSessionText
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
        $watchdogMs = if ([string]$Tag.OriginKind -eq 'pi-web') {
            Get-NotifyPiWebActivationWatchdogMs -ExpiresAtUtc ([DateTime]$Tag.ExpiresAtUtc)
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$Tag.SnapshotId)) {
            $script:NotifyBrokerRecoveringActivationWatchdogMs
        }
        else {
            $script:NotifyBrokerReadyActivationWatchdogMs
        }
        $remainingMs = Get-NotifyActivationRemainingMs -ExpiresAtUtc ([DateTime]$Tag.ExpiresAtUtc)
        if ($remainingMs -le 0) {
            [void](Complete-NotifyBrokerPopupLifecycle -Tag $Tag -Outcome 'dismissed' -Reason 'expired')
            return $false
        }
        $watchdogMs = [Math]::Min($watchdogMs, $remainingMs)
        $Tag.ActivationWatchdogTimer.Stop()
        $Tag.ActivationWatchdogTimer.Interval = $watchdogMs
        $Tag.ActivationWatchdogTimer.Start()
        Write-NotifyBrokerLog -Message ('broker-activation-feedback popupId={0} watchdogMs={1}' -f $Tag.PopupId, $watchdogMs)
        if ($null -ne $Tag.Form) {
            $Tag.Form.Invalidate($true)
            $Tag.Form.Refresh()
        }
        return (-not ($Tag.Form.IsDisposed -or $Tag.CloseRequested.Value -or $Tag.TerminalState.Value))
    }
    catch {
        Write-NotifyBrokerLog -Message ('broker-activation-feedback-error popupId={0} "{1}"' -f $Tag.PopupId, $_.Exception.Message)
        [void](Complete-NotifyBrokerPopupLifecycle -Tag $Tag -Outcome 'failed' -Reason 'activation-feedback-error')
        return $false
    }
}

function Get-NotifyBrokerPopupSlot {
    param([string]$PopupId, [string]$TargetFingerprint, [int]$StackIndex = -1, [int]$MaxVisible = 4)

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
            if ($script:NotifyBrokerActivePopups.ContainsKey($existingId)) { return -1 }
            continue
        }

        if ($existingSlot -ge $maxVisible) {
            [void](Complete-NotifyBrokerPopupLifecycle -Tag $existing.Form.Tag -Outcome 'dismissed' -Reason 'screen-overflow')
            if ($script:NotifyBrokerActivePopups.ContainsKey($existingId)) { return -1 }
            continue
        }
        if ($existingSlot -ge 0) {
            $usedSlots[[string]$existingSlot] = $true
        }
    }

    if ($maxVisible -gt 0) {
        $activeEntries = @($script:NotifyBrokerActivePopups.Values | Where-Object { $_.TargetFingerprint -ne $TargetFingerprint } | Sort-Object { if ($_.PSObject.Properties['CreatedAtUtc']) { $_.CreatedAtUtc } else { [DateTime]::MinValue } })
        $dropIndex = 0
        while ($usedSlots.Count -ge $maxVisible -and $dropIndex -lt $activeEntries.Count) {
            $drop = $activeEntries[$dropIndex]
            $dropIndex += 1
            $dropSlot = -1
            try { $dropSlot = [int]$drop.StackIndex } catch { $dropSlot = -1 }
            Write-NotifyBrokerLog -Message ('broker-popup-drop-overflow popupId={0} maxVisible={1}' -f $drop.PopupId, $maxVisible)
            try {
                if ($null -ne $drop.Form.Tag -and $drop.Form.Tag.ContainsKey('TerminalState')) {
                    [void](Complete-NotifyBrokerPopupLifecycle -Tag $drop.Form.Tag -Outcome 'dismissed' -Reason 'overflow')
                }
                else { $drop.Form.Close() }
            }
            catch {}
            if ($dropSlot -ge 0 -and -not $script:NotifyBrokerActivePopups.ContainsKey($drop.PopupId)) { $usedSlots.Remove([string]$dropSlot) }
        }
    }

    # The broker owns slots; a stale caller hint must never overlap a live card.
    if ($StackIndex -ge $maxVisible -or $usedSlots.ContainsKey([string]$StackIndex)) { $StackIndex = -1 }
    if ($StackIndex -lt 0) {
        if ($reuseSlot -ge 0 -and $reuseSlot -lt $maxVisible -and -not $usedSlots.ContainsKey([string]$reuseSlot)) {
            $StackIndex = $reuseSlot
        }
        else {
            for ($slot = 0; $slot -lt $maxVisible; $slot++) {
                if (-not $usedSlots.ContainsKey([string]$slot)) {
                    $StackIndex = $slot
                    break
                }
            }
        }
    }
    if ($StackIndex -lt 0) {
        Write-NotifyBrokerLog -Message 'broker-popup-drop no-free-screen-slot'
        return -1
    }
    return $StackIndex
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

    $workingArea = Get-NotifyBrokerWorkingArea -Placement (Normalize-NotifyBridgePopupPlacement -Value $PopupPlacementValue)
    $maxVisible = Get-NotifyPopupStackCapacity -WorkingAreaHeight $workingArea.Height -MaxVisible $script:NotifyBrokerPopupMaxVisible
    $StackIndex = Get-NotifyBrokerPopupSlot -PopupId $PopupId -TargetFingerprint $TargetFingerprint -StackIndex $StackIndex -MaxVisible $maxVisible
    if ($StackIndex -lt 0) { return }

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
    Set-NotifyAppHeader -Label $appLabel -OriginKind $OriginKind
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

    foreach ($label in @($appLabel, $closeLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
        $label.UseMnemonic = $false
        if ($null -ne $script:NotifyBrokerWallpaperImage) {
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
    $popupLifetimeMs = Get-NotifyPopupLifetimeMs -TimeoutSeconds $TimeoutSeconds
    $popupExpiresAtUtc = $popupCreatedAtUtc.AddMilliseconds($popupLifetimeMs)

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
        RecoveryState     = if ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId) -and -not [string]::IsNullOrWhiteSpace($targetRecoveryTicketId)) { 'recovering' } elseif ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } elseif ($targetOriginKind -eq 'paseo' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } else { 'ready' }
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
        ExpiresAtUtc      = $popupExpiresAtUtc
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
        if ((([string]$tag.OriginKind -eq 'pi-web') -or ([string]$tag.OriginKind -eq 'paseo')) -and [string]$tag.RecoveryState -eq 'unavailable') {
            Write-NotifyBrokerLog -Message ('broker-popup-click-ignored exact-route-unavailable popupId={0}' -f $tag.PopupId)
            return
        }
        Write-NotifyBrokerLog -Message ('broker-popup-click popupId={0}' -f $tag.PopupId)
        Write-NotifyBrokerLog -Message ('broker-action activate popupId={0} targetFingerprint={1} originKind={2} notificationFp={3} snapshotFp={4}' -f $tag.PopupId, $tag.TargetFingerprint, $(if ([string]::IsNullOrWhiteSpace($tag.OriginKind)) { 'none' } else { $tag.OriginKind }), (Get-NotifyRouteFingerprint -Value $tag.NotificationId), (Get-NotifyRouteFingerprint -Value $tag.SnapshotId))
        if (-not (Set-NotifyBrokerPopupActivating -Tag $tag)) { return }
        $tag.DidActivate.Value = $true
        $tag.ShouldActivate.Value = $true
        $tag.ActivationQueued.Value = $true
        [void](Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -OriginKind $tag.OriginKind -NotificationId $tag.NotificationId -SnapshotId $tag.SnapshotId -RecoveryTicketId $tag.RecoveryTicketId)
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

    $timer.Interval = $popupLifetimeMs
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

    $location = Get-NotifyBrokerPopupLocation -StackIndex $StackIndex -FormWidth $form.Width -FormHeight $form.Height -Placement $PopupPlacementValue -WorkingArea $workingArea
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

# Close matching Paseo cards by originKind + notification UUID (idempotent).
function Close-NotifyBrokerPaseoByNotificationId {
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId
    )

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        Write-NotifyBrokerLog -Message 'broker-paseo-close-invalid reason=notification-id'
        return $false
    }

    $targetId = $NotificationId.Trim()
    $closed = 0
    $keys = @($script:NotifyBrokerActivePopups.Keys)
    foreach ($popupId in $keys) {
        if (-not $script:NotifyBrokerActivePopups.ContainsKey($popupId)) { continue }
        $entry = $script:NotifyBrokerActivePopups[$popupId]
        try {
            $tag = $entry.Form.Tag
            if ($null -eq $tag) { continue }
            $originKind = if ($tag.ContainsKey('OriginKind')) { [string]$tag.OriginKind } else { '' }
            $notificationId = if ($tag.ContainsKey('NotificationId')) { [string]$tag.NotificationId } else { '' }
            if ($originKind -ne 'paseo') { continue }
            if ([string]::IsNullOrWhiteSpace($notificationId)) { continue }
            if (-not $notificationId.Trim().Equals($targetId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Write-NotifyBrokerLog -Message ('broker-paseo-close-by-notification popupId={0} notificationFp={1}' -f $popupId, (Get-NotifyRouteFingerprint -Value $notificationId))
            [void](Complete-NotifyBrokerPopupLifecycle -Tag $tag -Outcome 'dismissed' -Reason 'paseo-close')
            $closed += 1
        }
        catch {
            Write-NotifyBrokerLog -Message ('broker-paseo-close-error popupId={0}' -f $popupId)
        }
    }
    Write-NotifyBrokerLog -Message ('broker-paseo-close-complete notificationFp={0} closed={1}' -f (Get-NotifyRouteFingerprint -Value $targetId), $closed)
    return $true
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
                    (([string]$tag.OriginKind -in @('pi-web', 'paseo')) -and [string]$tag.RecoveryState -eq 'unavailable')) {
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
                [void](Queue-NotifyBrokerActivation -TargetHost $tag.TargetHost -CurrentDirBase $tag.TargetCwdBase -SourceTabTitleValue $tag.TargetSourceTabTitle -TargetFingerprint $tag.TargetFingerprint -PopupId $tag.PopupId -OriginKind $originKind -NotificationId $notificationId -SnapshotId $snapshotId -RecoveryTicketId $recoveryTicketId)
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
    # Yield back to WinForms after a small batch so clicks and close timers stay responsive.
    for ($processed = 0; $processed -lt 8 -and $script:NotifyBrokerPopupQueue.TryDequeue([ref]$item); $processed++) {
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
                $hasExactRoute = (($originKind -eq 'pi-web') -and (-not [string]::IsNullOrWhiteSpace($notificationId))) -or (($originKind -eq 'paseo') -and (-not [string]::IsNullOrWhiteSpace($snapshotId)))
                if ([string]::IsNullOrWhiteSpace($cwdBase) -and [string]::IsNullOrWhiteSpace($tabTitle) -and -not $hasExactRoute) {
                    Write-NotifyBrokerLog -Message ('broker-popup-drop missing-target-metadata targetFingerprint={0}' -f (Get-NotifyBrokerContextFingerprint -Value $focusTarget))
                    continue
                }
                # A queued popup must re-check the exact UUID after a close request races its display.
                if ($originKind -eq 'paseo' -and (Test-NotifyPaseoCloseTombstone -NotificationId $notificationId)) {
                    Write-NotifyBrokerLog -Message ('broker-popup-drop paseo-close-tombstone notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $notificationId))
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
                $closeOriginKind = ''
                $closeNotificationId = ''
                if ($null -ne $payload -and $payload.PSObject.Properties['popupId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.popupId)) {
                    $closePopupId = [string]$payload.popupId
                }
                if ($null -ne $payload -and $payload.PSObject.Properties['activate']) {
                    try { $closeActivate = [bool]$payload.activate } catch { $closeActivate = $false }
                }
                if ($null -ne $payload -and $payload.PSObject.Properties['originKind'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.originKind)) {
                    $closeOriginKind = ([string]$payload.originKind).Trim()
                }
                if ($null -ne $payload -and $payload.PSObject.Properties['notificationId'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.notificationId)) {
                    $closeNotificationId = ([string]$payload.notificationId).Trim()
                }
                if ($closeOriginKind -eq 'paseo' -and -not [string]::IsNullOrWhiteSpace($closeNotificationId)) {
                    [void](Close-NotifyBrokerPaseoByNotificationId -NotificationId $closeNotificationId)
                }
                elseif (-not [string]::IsNullOrWhiteSpace($closePopupId)) {
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
