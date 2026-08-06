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
$script:NotifyPopupFailureCloseDelayMs = 2500
$script:NotifyPopupActivationRecoveryWaitMs = 10000
$script:NotifyPopupRecoveringActivationWatchdogMs = 12000
$script:NotifyPopupReadyActivationWatchdogMs = 20000
if ([string]::IsNullOrWhiteSpace($Title) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_TITLE)) { $Title = $env:PI_NOTIFY_TITLE }
if ([string]::IsNullOrWhiteSpace($Body) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_BODY)) { $Body = $env:PI_NOTIFY_BODY }
if ([string]::IsNullOrWhiteSpace($FocusTarget) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_FOCUS_TARGET)) { $FocusTarget = $env:PI_NOTIFY_FOCUS_TARGET }
if ([string]::IsNullOrWhiteSpace($CwdBase) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_CWD_BASE)) { $CwdBase = $env:PI_NOTIFY_CWD_BASE }
if ([string]::IsNullOrWhiteSpace($SourceTabTitle) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_TAB_TITLE)) { $SourceTabTitle = $env:PI_NOTIFY_TAB_TITLE }
if ([string]::IsNullOrWhiteSpace($SessionName) -and -not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_SESSION_NAME)) { $SessionName = $env:PI_NOTIFY_SESSION_NAME }
$OriginKind = if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_ORIGIN_KIND)) { $env:PI_NOTIFY_ORIGIN_KIND.Trim() } else { '' }
$NotificationId = if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_NOTIFICATION_ID)) { $env:PI_NOTIFY_NOTIFICATION_ID.Trim() } else { '' }
$SnapshotId = if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_SNAPSHOT_ID)) { $env:PI_NOTIFY_SNAPSHOT_ID.Trim() } else { '' }
$RecoveryTicketId = if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_RECOVERY_TICKET_ID)) { $env:PI_NOTIFY_RECOVERY_TICKET_ID.Trim() } else { '' }
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

function Get-NotifyPopupRecoveryUiText {
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

function Reset-NotifyPopupFeedbackVisuals {
    $script:NotifyPopupForm.Opacity = $script:NotifyPopupOriginalOpacity
    $script:NotifyPopupForm.BackColor = $script:NotifyPopupOriginalCardColor
    $script:NotifyPopupForm.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:NotifyPopupPanel.BackColor = $script:NotifyPopupOriginalPanelColor
    $script:NotifyPopupPanel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:NotifyPopupAppLabel.Text = $script:NotifyPopupOriginalAppText
    $script:NotifyPopupAppLabel.ForeColor = $script:NotifyPopupOriginalAppForeColor
    $script:NotifyPopupAppLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:NotifyPopupSessionLabel.Text = $script:NotifyPopupOriginalSessionText
    $script:NotifyPopupSessionLabel.ForeColor = $script:NotifyPopupOriginalSessionForeColor
    $script:NotifyPopupSessionLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:NotifyPopupTitleLabel.ForeColor = $script:NotifyPopupOriginalTitleForeColor
    $script:NotifyPopupBodyLabel.ForeColor = $script:NotifyPopupOriginalBodyForeColor
    $script:NotifyPopupCloseLabel.Text = $script:NotifyPopupOriginalCloseText
    $script:NotifyPopupCloseLabel.ForeColor = $script:NotifyPopupOriginalCloseForeColor
    $script:NotifyPopupCloseLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Set-NotifyPopupRecoveryUiState {
    param([Parameter(Mandatory = $true)][ValidateSet('recovering', 'ready', 'unavailable')][string]$State)

    $script:NotifyPopupRecoveryState = $State
    if ($State -eq 'recovering') {
        $script:NotifyPopupTitleLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'recovering-title'
        $script:NotifyPopupBodyLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'recovering-body'
        foreach ($control in @($script:NotifyPopupForm, $script:NotifyPopupPanel, $script:NotifyPopupAppLabel, $script:NotifyPopupSessionLabel, $script:NotifyPopupTitleLabel, $script:NotifyPopupBodyLabel)) {
            $control.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        return
    }
    if ($State -eq 'ready') {
        Reset-NotifyPopupFeedbackVisuals
        $script:NotifyPopupTitleLabel.Text = $script:NotifyPopupOriginalTitle
        $script:NotifyPopupBodyLabel.Text = $script:NotifyPopupOriginalBody
        foreach ($control in @($script:NotifyPopupForm, $script:NotifyPopupPanel, $script:NotifyPopupAppLabel, $script:NotifyPopupSessionLabel, $script:NotifyPopupTitleLabel, $script:NotifyPopupBodyLabel)) {
            $control.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        return
    }

    Reset-NotifyPopupFeedbackVisuals
    $script:NotifyPopupTitleLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'unavailable-title'
    $script:NotifyPopupBodyLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'unavailable-body'
    foreach ($control in @($script:NotifyPopupForm, $script:NotifyPopupPanel, $script:NotifyPopupAppLabel, $script:NotifyPopupSessionLabel, $script:NotifyPopupTitleLabel, $script:NotifyPopupBodyLabel)) {
        $control.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Complete-NotifyPopupLifecycle {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('focused', 'handled', 'failed', 'dismissed')][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$Reason,
        $Retryable = $null
    )

    if ($null -eq $script:NotifyPopupForm -or $script:NotifyPopupForm.IsDisposed) { return $false }
    $paseoRetryAllowed = $Reason -notin @('expired', 'invalid', 'activation-missing', 'foreign-owner', 'non-loopback', 'ambiguous')
    if ($null -ne $Retryable) { $paseoRetryAllowed = [bool]$Retryable }
    $isPaseoRetryable = ($Outcome -eq 'failed') -and ([string]$script:NotifyPopupTargetOriginKind -eq 'paseo') -and $paseoRetryAllowed
    $keepPaseoExpiryTimer = ($Outcome -eq 'failed') -and ([string]$script:NotifyPopupTargetOriginKind -eq 'paseo') -and ($isPaseoRetryable -or $Reason -in @('expired', 'invalid', 'activation-missing'))
    $alreadyTerminal = $script:NotifyPopupTerminalState
    if (-not $alreadyTerminal) {
        $script:NotifyPopupTerminalState = $true
        $script:NotifyPopupTerminalOutcome = $Outcome
        $script:NotifyPopupTerminalReason = $Reason
        $script:NotifyPopupActivating = $false
        if (-not $keepPaseoExpiryTimer) { $script:NotifyPopupTimer.Stop() }
        $script:NotifyPopupFocusWatchTimer.Stop()
        $script:NotifyPopupActivationWatchdogTimer.Stop()
        Write-NotifyPopupLog -Message ('popup-terminal outcome={0} reason={1}' -f $Outcome, $Reason)
    }

    if ($Outcome -eq 'failed') {
        if ($alreadyTerminal) { return $false }
        if ($isPaseoRetryable) {
            $script:NotifyPopupTerminalState = $false
            $script:NotifyPopupTerminalOutcome = ''
            $script:NotifyPopupTerminalReason = ''
            $script:NotifyPopupActivating = $false
            $script:NotifyPopupDidActivate = $false
            Set-NotifyPopupRecoveryUiState -State 'ready'
            $retryText = -join @([char]0x8df3, [char]0x8f6c, [char]0x5931, [char]0x8d25, [char]0xff0c, [char]0x70b9, [char]0x51fb, [char]0x91cd, [char]0x8bd5)
            $script:NotifyPopupTitleLabel.Text = $retryText
            $script:NotifyPopupBodyLabel.Text = $script:NotifyPopupOriginalBody
            $script:NotifyPopupFailureCloseTimer.Stop()
            # Keep the original expiry timer running so retries cannot extend activation lifetime.
            Write-NotifyPopupLog -Message ('popup-paseo-retry-ready reason={0}' -f $Reason)
            return $true
        }
        if (([string]$script:NotifyPopupTargetOriginKind -eq 'paseo') -and ($Reason -in @('expired', 'invalid', 'activation-missing'))) {
            $expiredText = -join @([char]0x901a, [char]0x77e5, [char]0x5df2, [char]0x5931, [char]0x6548)
            Set-NotifyPopupRecoveryUiState -State 'unavailable'
            $script:NotifyPopupTitleLabel.Text = $expiredText
            $script:NotifyPopupFailureCloseTimer.Stop()
            return $true
        }
        Set-NotifyPopupRecoveryUiState -State 'unavailable'
        $script:NotifyPopupFailureCloseTimer.Stop()
        $script:NotifyPopupFailureCloseTimer.Start()
        return $true
    }

    $script:NotifyPopupFailureCloseTimer.Stop()
    if (-not $script:NotifyPopupCloseRequested) {
        $script:NotifyPopupCloseRequested = $true
        $script:NotifyPopupForm.Close()
        return $true
    }
    return $false
}

function Set-NotifyPopupActivating {
    if ($script:NotifyPopupTerminalState -or $script:NotifyPopupActivating) { return $false }

    try {
        $script:NotifyPopupActivating = $true
        if ([string]$script:NotifyPopupTargetOriginKind -ne 'paseo') { $script:NotifyPopupTimer.Stop() }
        $script:NotifyPopupFocusWatchTimer.Stop()
        $inactiveCardColor = [System.Drawing.Color]::FromArgb(48, 52, 60)
        $inactiveTextColor = [System.Drawing.Color]::FromArgb(190, 198, 210)
        $inactiveAccentColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $jumpingText = (-join @([char]0x8df3, [char]0x8f6c, [char]0x4e2d, '.', '.', '.'))

        $script:NotifyPopupForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupForm.Opacity = 0.90
        $script:NotifyPopupForm.BackColor = $inactiveCardColor
        $script:NotifyPopupPanel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupPanel.BackColor = $inactiveCardColor
        $baseApp = if (-not [string]::IsNullOrWhiteSpace([string]$script:NotifyPopupOriginalAppText)) { [string]$script:NotifyPopupOriginalAppText } else { Get-NotifyAppLabel -OriginKind $script:NotifyPopupTargetOriginKind }
        $script:NotifyPopupAppLabel.Text = ('{0} - {1}' -f $baseApp, $jumpingText)
        $script:NotifyPopupAppLabel.ForeColor = $inactiveTextColor
        $script:NotifyPopupAppLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupSessionLabel.Text = $jumpingText
        $script:NotifyPopupSessionLabel.ForeColor = $inactiveAccentColor
        $script:NotifyPopupSessionLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupTitleLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'opening-title'
        $script:NotifyPopupTitleLabel.ForeColor = $inactiveTextColor
        $script:NotifyPopupTitleLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupBodyLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'opening-body'
        $script:NotifyPopupBodyLabel.ForeColor = $inactiveTextColor
        $script:NotifyPopupBodyLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $watchdogMs = if ([string]::IsNullOrWhiteSpace([string]$script:NotifyPopupTargetSnapshotId)) { $script:NotifyPopupRecoveringActivationWatchdogMs } else { $script:NotifyPopupReadyActivationWatchdogMs }
        $script:NotifyPopupActivationWatchdogTimer.Stop()
        $script:NotifyPopupActivationWatchdogTimer.Interval = $watchdogMs
        $script:NotifyPopupActivationWatchdogTimer.Start()
        Write-NotifyPopupLog -Message ('popup-activation-feedback watchdogMs={0}' -f $watchdogMs)
        $script:NotifyPopupForm.Invalidate($true)
        $script:NotifyPopupForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        return $true
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-activation-feedback-error "{0}"' -f $_.Exception.Message)
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'activation-feedback-error')
        return $false
    }
}

function Request-NotifyPopupExactWorkerStop {
    param([Parameter(Mandatory = $true)][string]$Reason)

    $worker = $script:NotifyPopupExactWorker
    if ($null -eq $worker) { return $true }
    if (-not [string]::IsNullOrWhiteSpace([string]$worker.CancelReason) -or $null -ne $worker.StopAsync) { return $true }
    $worker.CancelReason = $Reason
    if ($worker.Async.IsCompleted) { return $true }
    try {
        $worker.StopAsync = $worker.PowerShell.BeginStop($null, $null)
        $script:NotifyPopupExactWorkerTimer.Start()
        Write-NotifyPopupLog -Message ('popup-exact-worker-cancel-requested mode={0} reason={1}' -f $worker.Mode, $Reason)
        return $true
    }
    catch {
        $worker.CancelReason = ''
        Write-NotifyPopupLog -Message ('popup-exact-worker-cancel-error mode={0} reason={1}' -f $worker.Mode, $Reason)
        return $false
    }
}

function Invoke-NotifyPopupActivationWatchdog {
    if ($script:NotifyPopupTerminalState) { return $false }
    Write-NotifyPopupLog -Message 'popup-activation-watchdog'
    [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'activation-watchdog')
    [void](Request-NotifyPopupExactWorkerStop -Reason 'activation-watchdog')
    return $true
}

function Start-NotifyPopupPaseoWorker {
    param([string]$ActivationId = '')

    if ($script:NotifyPopupTerminalState -or $null -ne $script:NotifyPopupExactWorker) { return $false }
    if ([string]::IsNullOrWhiteSpace($ActivationId)) {
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'activation-missing')
        return $false
    }

    $runspace = $null
    $powerShell = $null
    $workerScript = @'
param($CommonPath, $ConfigPath, $ActivationId)
$ErrorActionPreference = 'Stop'
. $CommonPath
$configArgs = @{}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $configArgs.ConfigPath = $ConfigPath }
$workerConfig = Ensure-NotifyBridgeConfig @configArgs
$outcome = Invoke-NotifyPaseoRouteActivate -ActivationId $ActivationId -Config $workerConfig -TimeoutMs 20000
[pscustomobject]@{
    Decision = [string]$outcome.Decision
    Result = [string]$outcome.Result
    Reason = [string]$outcome.Reason
    Retryable = [bool]$outcome.Retryable
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
        [void]$powerShell.AddParameter('ActivationId', $ActivationId)
        $async = $powerShell.BeginInvoke()
        $script:NotifyPopupExactWorker = [pscustomobject]@{
            Mode = 'paseo-activate'
            PowerShell = $powerShell
            Runspace = $runspace
            Async = $async
            StartedAtUtc = [DateTime]::UtcNow
            StopAsync = $null
            CancelReason = ''
        }
        $script:NotifyPopupExactWorkerTimer.Start()
        return $true
    }
    catch {
        if ($null -ne $powerShell) { try { $powerShell.Dispose() } catch {} }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch {}
            try { $runspace.Dispose() } catch {}
        }
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'worker-start-error')
        return $false
    }
}

function Start-NotifyPopupExactWorker {
    param([Parameter(Mandatory = $true)][ValidateSet('resolve', 'activate')][string]$Mode)

    if ($script:NotifyPopupTerminalState -or $null -ne $script:NotifyPopupExactWorker) { return $false }
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
        [void]$powerShell.AddParameter('NotificationId', $script:NotifyPopupTargetNotificationId)
        [void]$powerShell.AddParameter('SnapshotId', $script:NotifyPopupTargetSnapshotId)
        [void]$powerShell.AddParameter('RecoveryTicketId', $script:NotifyPopupTargetRecoveryTicketId)
        [void]$powerShell.AddParameter('ActivationRecoveryWaitMs', $script:NotifyPopupActivationRecoveryWaitMs)
        $async = $powerShell.BeginInvoke()
        $script:NotifyPopupExactWorker = [pscustomobject]@{
            Mode = $Mode
            PowerShell = $powerShell
            Runspace = $runspace
            Async = $async
            StartedAtUtc = [DateTime]::UtcNow
            StopAsync = $null
            CancelReason = ''
        }
    }
    catch {
        if ($null -ne $powerShell) { try { $powerShell.Dispose() } catch {} }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch {}
            try { $runspace.Dispose() } catch {}
        }
        Write-NotifyPopupLog -Message ('popup-exact-worker-start-error mode={0} "{1}"' -f $Mode, $_.Exception.Message)
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'worker-start-error')
        return $false
    }
    Write-NotifyPopupLog -Message ('popup-exact-worker-start mode={0}' -f $Mode)
    $script:NotifyPopupExactWorkerTimer.Start()
    return $true
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
$hasExactRoute = (($OriginKind -eq 'pi-web') -and (-not [string]::IsNullOrWhiteSpace($NotificationId))) -or (($OriginKind -eq 'paseo') -and (-not [string]::IsNullOrWhiteSpace($SnapshotId)))
if ([string]::IsNullOrWhiteSpace($CwdBase) -and [string]::IsNullOrWhiteSpace($SourceTabTitle) -and -not $hasExactRoute) {
    Write-NotifyPopupLog -Message ('popup-drop missing-target-metadata targetFingerprint={0}' -f (Get-NotifyPopupContextFingerprint -Value $FocusTarget))
    exit 0
}

# Paseo close tombstone: never show a resolved permission, and self-close while alive.
$script:NotifyPopupPaseoCloseEvent = $null
$script:NotifyPopupPaseoCloseFingerprint = ''
if ($OriginKind -eq 'paseo' -and -not [string]::IsNullOrWhiteSpace($NotificationId) -and (Test-NotifyRouteUuid -Value $NotificationId)) {
    if (Test-NotifyPaseoCloseTombstone -NotificationId $NotificationId) {
        Write-NotifyPopupLog -Message ('popup-paseo-tombstone-drop notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $NotificationId))
        exit 0
    }
    try {
        $script:NotifyPopupPaseoCloseFingerprint = Get-NotifyPaseoNotificationFingerprint -NotificationId $NotificationId
        $eventName = Get-NotifyPaseoCloseEventName -NotificationFingerprint $script:NotifyPopupPaseoCloseFingerprint
        if (-not [string]::IsNullOrWhiteSpace($eventName)) {
            $script:NotifyPopupPaseoCloseEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $eventName)
            if (Test-NotifyPaseoCloseSignal -NotificationId $NotificationId -CloseEvent $script:NotifyPopupPaseoCloseEvent) {
                Write-NotifyPopupLog -Message ('popup-paseo-close-event-drop notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $NotificationId))
                try { $script:NotifyPopupPaseoCloseEvent.Dispose() } catch {}
                $script:NotifyPopupPaseoCloseEvent = $null
                exit 0
            }
        }
    }
    catch {
        $script:NotifyPopupPaseoCloseEvent = $null
    }
}

$dedupe = Initialize-NotifyPopupDedupe -TitleValue $Title -BodyValue $Body -FocusTargetValue $FocusTarget -CwdBaseValue $CwdBase -SourceTabTitleValue $SourceTabTitle -PayloadPathValue $PayloadPath
$script:NotifyPopupDedupePath = [string]$dedupe.Path
$script:NotifyPopupIsPrecise = [bool]$dedupe.Precise
if ([bool]$dedupe.Drop) {
    if ($null -ne $script:NotifyPopupPaseoCloseEvent) {
        try { $script:NotifyPopupPaseoCloseEvent.Dispose() } catch {}
        $script:NotifyPopupPaseoCloseEvent = $null
    }
    exit 0
}

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

function Test-NotifyPopupSessionTaggedTitle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim() -match ' \u00B7 #[0-9a-f]{12}$'
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

# Terminal/legacy only: WT title/cwd foreground auto-dismiss must not run for pi-web or unknown origins.
function Test-NotifyForegroundDismissAllowed {
    param([string]$OriginKind = '')

    $kind = if ($null -eq $OriginKind) { '' } else { $OriginKind.Trim() }
    return ([string]::IsNullOrWhiteSpace($kind) -or $kind -eq 'terminal')
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
        [string]$SourceTabTitleValue,
        [string]$OriginKind = '',
        [string]$NotificationId = '',
        [string]$SnapshotId = ''
    )

    try {
        $startedAt = [DateTime]::UtcNow
        $requiresCwdMatch = -not [string]::IsNullOrWhiteSpace($CurrentDirBase)
        $hasPreciseSourceTitle = -not [string]::IsNullOrWhiteSpace($SourceTabTitleValue)
        $allowTargetCache = Test-NotifyPopupSessionTaggedTitle -Value $SourceTabTitleValue
        Write-NotifyPopupLog -Message ('popup-activate targetFingerprint={0} cwdFingerprint={1} sourceTabFingerprint={2} originKind={3} notificationFp={4} snapshotFp={5}' -f (Get-NotifyPopupContextFingerprint -Value $TargetHost), (Get-NotifyPopupContextFingerprint -Value $CurrentDirBase), (Get-NotifyPopupContextFingerprint -Value $SourceTabTitleValue), $(if ([string]::IsNullOrWhiteSpace($OriginKind)) { 'none' } else { $OriginKind }), (Get-NotifyRouteFingerprint -Value $NotificationId), (Get-NotifyRouteFingerprint -Value $SnapshotId))

        if ($OriginKind -eq 'paseo') {
            Write-NotifyPopupLog -Message 'popup-paseo-activate-invariant paseo-must-use-background-worker'
            return
        }

        if ($OriginKind -eq 'pi-web') {
            Write-NotifyPopupLog -Message 'popup-route-activate-invariant exact-route-must-use-background-worker'
            return
        }

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

        $cache = if ($allowTargetCache) { Get-NotifyPopupCache } else { $null }
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
        $eligibleCount = 0
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
                $cacheTabMatch = $allowTargetCache -and $cacheMatches -and $sourceTabTitleMatch -and -not [string]::IsNullOrWhiteSpace($cacheTabFingerprint) -and (Get-NotifyPopupContextFingerprint -Value $tab.Name) -eq $cacheTabFingerprint
                if ($cacheTabMatch) {
                    $score += 200
                }
                $cwdKeywordMatch = $requiresCwdMatch -and ($matchedKeywords -contains $CurrentDirBase)
                if ($hasPreciseSourceTitle -and -not $sourceTabTitleMatch) {
                    $score = 0
                }
                elseif ($requiresCwdMatch -and -not $cwdKeywordMatch) {
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

                $eligibleCount += 1
                $candidate = [pscustomobject]@{ Window = $window; Score = $score; Tab = $tab.Element; TabName = $tab.Name; TabIndex = $tab.Index }
                if ($null -eq $best -or $candidate.Score -gt $best.Score) {
                    $best = $candidate
                }
            }
        }

        if ($eligibleCount -gt 1) {
            Write-NotifyPopupLog -Message ('popup-focus-ambiguous targetFingerprint={0} sourceTabFingerprint={1} candidateCount={2} bestScore={3} elapsedMs={4}' -f (Get-NotifyPopupContextFingerprint -Value $TargetHost), (Get-NotifyPopupContextFingerprint -Value $SourceTabTitleValue), $eligibleCount, $best.Score, [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            return
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
                $scrolledToBottom = Set-NotifyBridgeTerminalScrollToBottom -WindowHandle $best.Window.Handle
                Write-NotifyPopupLog -Message ('popup-tab-selected tabFingerprint={0} elapsedMs={1} scrolledToBottom={2}' -f (Get-NotifyPopupContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds, $scrolledToBottom)
                if ($allowTargetCache -and -not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
                    Save-NotifyPopupCache -TargetHostValue $TargetHost -CwdBaseValue $CurrentDirBase -WindowTitle $best.Window.Title -TabTitle $best.TabName -TabIndex $best.TabIndex
                }
            }
            else {
                Write-NotifyPopupLog -Message ('popup-tab-select-failed tabFingerprint={0} elapsedMs={1}' -f (Get-NotifyPopupContextFingerprint -Value $best.TabName), [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
            }
        }
        else {
            if ($allowTargetCache -and -not [string]::IsNullOrWhiteSpace($CurrentDirBase)) {
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
$appLabel.Text = Get-NotifyAppLabel -OriginKind $OriginKind
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
$targetOriginKind = $OriginKind
$targetNotificationId = $NotificationId
$targetSnapshotId = $SnapshotId
$targetRecoveryTicketId = $RecoveryTicketId
$script:NotifyPopupDidActivate = $false
$shouldActivate = $false

$script:NotifyPopupForm = $form
$script:NotifyPopupPanel = $panel
$script:NotifyPopupAppLabel = $appLabel
$script:NotifyPopupCloseLabel = $closeLabel
$script:NotifyPopupSessionLabel = $sessionLabel
$script:NotifyPopupTitleLabel = $titleLabel
$script:NotifyPopupBodyLabel = $bodyLabel
$script:NotifyPopupOriginalTitle = $Title
$script:NotifyPopupOriginalBody = $Body
$script:NotifyPopupOriginalAppText = $appLabel.Text
$script:NotifyPopupOriginalSessionText = $sessionLabel.Text
$script:NotifyPopupOriginalCloseText = $closeLabel.Text
$script:NotifyPopupOriginalOpacity = $form.Opacity
$script:NotifyPopupOriginalCardColor = $form.BackColor
$script:NotifyPopupOriginalPanelColor = $panel.BackColor
$script:NotifyPopupOriginalAppForeColor = $appLabel.ForeColor
$script:NotifyPopupOriginalSessionForeColor = $sessionLabel.ForeColor
$script:NotifyPopupOriginalTitleForeColor = $titleLabel.ForeColor
$script:NotifyPopupOriginalBodyForeColor = $bodyLabel.ForeColor
$script:NotifyPopupOriginalCloseForeColor = $closeLabel.ForeColor
$script:NotifyPopupTargetNotificationId = $targetNotificationId
$script:NotifyPopupTargetSnapshotId = $targetSnapshotId
$script:NotifyPopupTargetRecoveryTicketId = $targetRecoveryTicketId
$script:NotifyPopupRecoveryState = if ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId) -and -not [string]::IsNullOrWhiteSpace($targetRecoveryTicketId)) { 'recovering' } elseif ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } elseif ($targetOriginKind -eq 'paseo' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } else { 'ready' }
$script:NotifyPopupExactWorker = $null
$script:NotifyPopupActivateAfterResolve = $false
$script:NotifyPopupTerminalState = $false
$script:NotifyPopupTerminalOutcome = ''
$script:NotifyPopupTerminalReason = ''
$script:NotifyPopupCloseRequested = $false
$script:NotifyPopupActivating = $false
$script:NotifyPopupExactWorkerTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupExactWorkerTimer.Interval = 100
$script:NotifyPopupExactWorkerTimer.Add_Tick({
    $worker = $script:NotifyPopupExactWorker
    if ($null -eq $worker) { return }
    $completionReady = if ($null -ne $worker.StopAsync) { $worker.StopAsync.IsCompleted } else { $worker.Async.IsCompleted }
    if (-not $completionReady) { return }
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
        try { $worker.PowerShell.Dispose() } catch {}
        try { $worker.Runspace.Close(); $worker.Runspace.Dispose() } catch {}
        $script:NotifyPopupExactWorker = $null
        $this.Stop()
    }
    if (-not [string]::IsNullOrWhiteSpace($cancelReason)) {
        Write-NotifyPopupLog -Message ('popup-exact-worker-cancelled mode={0} reason={1} elapsedMs={2}' -f $worker.Mode, $cancelReason, [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds)
        if ($cancelReason -eq 'superseded-by-activation' -and $script:NotifyPopupActivateAfterResolve -and -not $script:NotifyPopupTerminalState) {
            $script:NotifyPopupActivateAfterResolve = $false
            [void](Start-NotifyPopupExactWorker -Mode 'activate')
        }
        return
    }
    if ($null -eq $result) {
        $result = [pscustomobject]@{ Decision = 'fail-closed'; Result = 'adapter-unavailable'; Reason = 'worker-empty'; SnapshotId = '' }
    }
    Write-NotifyPopupLog -Message ('popup-exact-worker-complete mode={0} decision={1} result={2} reason={3} snapshotFp={4} elapsedMs={5}' -f $worker.Mode, $result.Decision, $result.Result, $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'none' } else { [string]$result.Reason }), (Get-NotifyRouteFingerprint -Value ([string]$result.SnapshotId)), [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds)
    if ($script:NotifyPopupTerminalState) { return }
    if ($worker.Mode -eq 'paseo-activate') {
        if ($result.Decision -eq 'handled') {
            [void](Complete-NotifyPopupLifecycle -Outcome 'handled' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Result)) { 'activated' } else { [string]$result.Result }))
        }
        else {
            $reason = if (-not [string]::IsNullOrWhiteSpace([string]$result.Result)) { [string]$result.Result } elseif (-not [string]::IsNullOrWhiteSpace([string]$result.Reason)) { [string]$result.Reason } else { 'activation-failed' }
            $retryable = if ($result.PSObject.Properties['Retryable']) { [bool]$result.Retryable } else { $null }
            [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $reason -Retryable $retryable)
        }
        return
    }
    if ($worker.Mode -eq 'resolve') {
        if ($result.Decision -eq 'exact-ready' -and -not [string]::IsNullOrWhiteSpace([string]$result.SnapshotId)) {
            $script:NotifyPopupTargetSnapshotId = [string]$result.SnapshotId
            if ($script:NotifyPopupActivateAfterResolve) {
                $script:NotifyPopupActivateAfterResolve = $false
                [void](Start-NotifyPopupExactWorker -Mode 'activate')
            }
            else {
                Set-NotifyPopupRecoveryUiState -State 'ready'
            }
        }
        else {
            [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'resolve-failed' } else { [string]$result.Reason }))
        }
    }
    elseif ($result.Decision -eq 'focused') {
        [void](Complete-NotifyPopupLifecycle -Outcome 'focused' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'background-proof-pending' } else { [string]$result.Reason }))
    }
    elseif ($result.Decision -eq 'handled') {
        [void](Complete-NotifyPopupLifecycle -Outcome 'handled' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Result)) { 'activation-handled' } else { [string]$result.Result }))
    }
    else {
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'activation-failed' } else { [string]$result.Reason }))
    }
})

$activateAction = {
    if ($script:NotifyPopupTerminalState -or $script:NotifyPopupDidActivate) {
        return
    }
    if ($targetOriginKind -eq 'paseo') {
        if ($script:NotifyPopupRecoveryState -eq 'unavailable') {
            Write-NotifyPopupLog -Message 'popup-click-ignored paseo-unavailable'
            return
        }
        Write-NotifyPopupLog -Message 'popup-click originKind=paseo'
        if (-not (Set-NotifyPopupActivating)) { return }
        $script:NotifyPopupDidActivate = $true
        if (-not (Start-NotifyPopupPaseoWorker -ActivationId $targetSnapshotId)) {
            [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'worker-start-error')
        }
        return
    }

    if ($targetOriginKind -eq 'pi-web') {
        if ($script:NotifyPopupRecoveryState -eq 'unavailable') {
            Write-NotifyPopupLog -Message 'popup-click-ignored exact-route-unavailable'
            return
        }
        Write-NotifyPopupLog -Message 'popup-click'
        if (-not (Set-NotifyPopupActivating)) { return }
        $script:NotifyPopupDidActivate = $true
        if ($null -ne $script:NotifyPopupExactWorker -and $script:NotifyPopupExactWorker.Mode -eq 'resolve') {
            $script:NotifyPopupActivateAfterResolve = $true
            if (-not (Request-NotifyPopupExactWorkerStop -Reason 'superseded-by-activation')) {
                $script:NotifyPopupActivateAfterResolve = $false
                [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'activation-cancel-error')
            }
        }
        else {
            [void](Start-NotifyPopupExactWorker -Mode 'activate')
        }
        return
    }
    $script:NotifyPopupDidActivate = $true
    $script:shouldActivate = $true
    Write-NotifyPopupLog -Message 'popup-click'
    Write-NotifyPopupLog -Message ('popup-action activate targetFingerprint={0} originKind={1} notificationFp={2} snapshotFp={3}' -f (Get-NotifyPopupContextFingerprint -Value $targetHost), $(if ([string]::IsNullOrWhiteSpace($targetOriginKind)) { 'none' } else { $targetOriginKind }), (Get-NotifyRouteFingerprint -Value $targetNotificationId), (Get-NotifyRouteFingerprint -Value $targetSnapshotId))
    [void](Complete-NotifyPopupLifecycle -Outcome 'handled' -Reason 'legacy-activation-queued')
}

$closeAction = {
    Write-NotifyPopupLog -Message 'popup-close-button'
    Write-NotifyPopupLog -Message 'popup-action dismiss source="close-button"'
    [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'close-button')
}

foreach ($control in @($form, $panel, $appLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
    $control.Add_Click($activateAction)
}
$closeLabel.Add_Click($closeAction)

$timer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupTimer = $timer
$timer.Interval = [Math]::Max(3000, ($TimeoutSeconds * 1000))
$timer.Add_Tick({
    Write-NotifyPopupLog -Message 'popup-timeout-close'
    Write-NotifyPopupLog -Message 'popup-action dismiss source="timeout"'
    [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'timeout')
})

# Exact Paseo close polling is independent from focus/activation timers. It remains
# active while a click worker runs and is bounded by the popup's existing lifetime.
$script:NotifyPopupPaseoCloseTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupPaseoCloseTimer.Interval = 250
$script:NotifyPopupPaseoCloseTimer.Add_Tick({
    if ($targetOriginKind -ne 'paseo' -or [string]::IsNullOrWhiteSpace($targetNotificationId)) {
        $this.Stop()
        return
    }
    if (-not (Test-NotifyPaseoCloseSignal -NotificationId $targetNotificationId -CloseEvent $script:NotifyPopupPaseoCloseEvent)) {
        return
    }

    $this.Stop()
    Write-NotifyPopupLog -Message ('popup-action dismiss source="paseo-close" notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $targetNotificationId))
    [void](Request-NotifyPopupExactWorkerStop -Reason 'paseo-close')
    $script:NotifyPopupDidActivate = $false
    $script:shouldActivate = $false
    [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'paseo-close')
})

$focusWatchTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupFocusWatchTimer = $focusWatchTimer
$focusWatchTimer.Interval = 800
$focusWatchTimer.Add_Tick({
    if (Test-NotifyPopupDedupeSuperseded) {
        Write-NotifyPopupLog -Message 'popup-action dismiss source="dedupe-superseded"'
        [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'dedupe-superseded')
        return
    }

    if (-not (Test-NotifyForegroundDismissAllowed -OriginKind $targetOriginKind)) {
        return
    }

    if (Test-NotifyPopupForegroundTarget -CurrentDirBase $targetCwdBase -SourceTabTitleValue $targetSourceTabTitle) {
        Write-NotifyPopupLog -Message 'popup-action dismiss source="foreground-target"'
        [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'foreground-target')
    }
})

$script:NotifyPopupFailureCloseTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupFailureCloseTimer.Interval = $script:NotifyPopupFailureCloseDelayMs
$script:NotifyPopupFailureCloseTimer.Add_Tick({
    $this.Stop()
    [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'failure-auto-close')
})

$script:NotifyPopupActivationWatchdogTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupActivationWatchdogTimer.Interval = $script:NotifyPopupReadyActivationWatchdogMs
$script:NotifyPopupActivationWatchdogTimer.Add_Tick({
    $this.Stop()
    [void](Invoke-NotifyPopupActivationWatchdog)
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
    if ($targetOriginKind -eq 'paseo' -and -not [string]::IsNullOrWhiteSpace($targetNotificationId)) {
        $script:NotifyPopupPaseoCloseTimer.Start()
    }
    if ($script:NotifyPopupRecoveryState -eq 'recovering') {
        Set-NotifyPopupRecoveryUiState -State 'recovering'
        [void](Start-NotifyPopupExactWorker -Mode 'resolve')
    }
    elseif ($script:NotifyPopupRecoveryState -eq 'unavailable') {
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'exact-route-unavailable')
    }
})

$form.Add_FormClosed({
    $script:NotifyPopupCloseRequested = $true
    if (-not $script:NotifyPopupTerminalState) {
        $script:NotifyPopupTerminalState = $true
        $script:NotifyPopupTerminalOutcome = 'dismissed'
        $script:NotifyPopupTerminalReason = 'form-closed'
    }
    Write-NotifyPopupLog -Message ('popup-closed shouldActivate={0}' -f $shouldActivate)
    Remove-NotifyPopupLiveState
    try {
        if ($null -ne $script:NotifyPopupPaseoCloseEvent) {
            try { $script:NotifyPopupPaseoCloseEvent.Dispose() } catch {}
            $script:NotifyPopupPaseoCloseEvent = $null
        }
        if ($null -ne $script:NotifyPopupExactWorker) {
            # FormClosed runs on the UI thread. Signal cancellation, then let
            # process teardown reclaim the runspace instead of synchronously
            # waiting in Stop/Dispose/Close while the popup is trying to exit.
            [void](Request-NotifyPopupExactWorkerStop -Reason 'popup-closed')
            $script:NotifyPopupExactWorker = $null
        }
        $timer.Stop()
        $timer.Dispose()
        $focusWatchTimer.Stop()
        $focusWatchTimer.Dispose()
        if ($null -ne $script:NotifyPopupPaseoCloseTimer) {
            $script:NotifyPopupPaseoCloseTimer.Stop()
            $script:NotifyPopupPaseoCloseTimer.Dispose()
            $script:NotifyPopupPaseoCloseTimer = $null
        }
        $script:NotifyPopupFailureCloseTimer.Stop()
        $script:NotifyPopupFailureCloseTimer.Dispose()
        $script:NotifyPopupActivationWatchdogTimer.Stop()
        $script:NotifyPopupActivationWatchdogTimer.Dispose()
        $script:NotifyPopupExactWorkerTimer.Stop()
        $script:NotifyPopupExactWorkerTimer.Dispose()
        if ($null -ne $script:NotifyPopupWallpaperImage) {
            $script:NotifyPopupWallpaperImage.Dispose()
            $script:NotifyPopupWallpaperImage = $null
        }
    }
    catch {
    }
})

try {
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    if ($null -ne $script:NotifyPopupPaseoCloseTimer) {
        try { $script:NotifyPopupPaseoCloseTimer.Stop() } catch {}
        try { $script:NotifyPopupPaseoCloseTimer.Dispose() } catch {}
        $script:NotifyPopupPaseoCloseTimer = $null
    }
    if ($null -ne $script:NotifyPopupPaseoCloseEvent) {
        try { $script:NotifyPopupPaseoCloseEvent.Dispose() } catch {}
        $script:NotifyPopupPaseoCloseEvent = $null
    }
}

if ($shouldActivate) {
    Invoke-NotifyPopupActivation -TargetHost $targetHost -CurrentDirBase $targetCwdBase -SourceTabTitleValue $targetSourceTabTitle -OriginKind $targetOriginKind -NotificationId $targetNotificationId -SnapshotId $targetSnapshotId
}
