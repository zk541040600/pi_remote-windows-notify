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

public static class PiNotifyPopupUser32 {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

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
$popupWallpaperPath = if ($config.PSObject.Properties['PopupWallpaperPath']) { [string]$config.PopupWallpaperPath } else { '' }
$script:NotifyPopupWallpaperOffsetYPixels = 0
if ($config.PSObject.Properties['PopupWallpaperOffsetYPixels']) {
    try { $script:NotifyPopupWallpaperOffsetYPixels = [int]$config.PopupWallpaperOffsetYPixels } catch { }
}
try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyPopupLogPath) | Out-Null } catch {}

function Write-NotifyPopupLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
        Add-Content -LiteralPath $script:NotifyPopupLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Diagnostic I/O must not interrupt notification delivery or a UI callback.
    }
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
    if (-not $script:NotifyPopupTerminalState) { Remove-NotifyPopupLiveState }
    $remainingMs = Get-NotifyActivationRemainingMs -ExpiresAtUtc $script:NotifyPopupExpiresAtUtc
    if ($Outcome -ne 'dismissed' -and $remainingMs -le 0) {
        $script:NotifyPopupTerminalState = $true
        $script:NotifyPopupTerminalOutcome = 'dismissed'
        $script:NotifyPopupTerminalReason = 'expired'
        $script:NotifyPopupActivating = $false
        $script:NotifyPopupTimer.Stop()
        $script:NotifyPopupFocusWatchTimer.Stop()
        $script:NotifyPopupFailureCloseTimer.Stop()
        $script:NotifyPopupActivationWatchdogTimer.Stop()
        Write-NotifyPopupLog -Message ('popup-expired ignoredOutcome={0} reason={1}' -f $Outcome, $Reason)
        if (-not $script:NotifyPopupCloseRequested) {
            $script:NotifyPopupCloseRequested = $true
            $script:NotifyPopupForm.Close()
        }
        return $true
    }

    $originKind = if ($null -eq $script:NotifyPopupTargetOriginKind) { '' } else { ([string]$script:NotifyPopupTargetOriginKind).Trim() }
    $retryAllowed = $Reason -notin @('expired', 'invalid', 'activation-missing', 'foreign-owner', 'non-loopback', 'ambiguous')
    if ($null -ne $Retryable) { $retryAllowed = [bool]$Retryable }
    $supportsRetry = ($originKind -eq 'paseo') -or ($originKind -eq 'terminal') -or [string]::IsNullOrWhiteSpace($originKind)
    $isRetryableFailure = ($Outcome -eq 'failed') -and $supportsRetry -and $retryAllowed
    $keepPaseoExpiryTimer = ($Outcome -eq 'failed') -and ($originKind -eq 'paseo') -and ($isRetryableFailure -or $Reason -in @('expired', 'invalid', 'activation-missing'))
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
        if ($isRetryableFailure) {
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
            $remainingMs = Get-NotifyActivationRemainingMs -ExpiresAtUtc $script:NotifyPopupExpiresAtUtc
            if ($remainingMs -le 0) {
                $script:NotifyPopupTerminalState = $true
                $script:NotifyPopupTerminalOutcome = 'dismissed'
                $script:NotifyPopupTerminalReason = 'expired'
                if (-not $script:NotifyPopupCloseRequested) {
                    $script:NotifyPopupCloseRequested = $true
                    $script:NotifyPopupForm.Close()
                }
                return $true
            }
            $script:NotifyPopupTimer.Stop()
            $script:NotifyPopupTimer.Interval = $remainingMs
            $script:NotifyPopupTimer.Start()
            $script:NotifyPopupFocusWatchTimer.Start()
            Save-NotifyPopupLiveState
            Write-NotifyPopupLog -Message ('popup-retry-ready originKind={0} reason={1} remainingMs={2}' -f $(if ([string]::IsNullOrWhiteSpace($originKind)) { 'terminal' } else { $originKind }), $Reason, $remainingMs)
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
        $script:NotifyPopupFailureCloseTimer.Interval = [Math]::Max(1, [Math]::Min([int]$script:NotifyPopupFailureCloseDelayMs, $remainingMs))
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
    if ($null -eq $script:NotifyPopupForm -or $script:NotifyPopupForm.IsDisposed -or $script:NotifyPopupForm.Disposing -or
        $script:NotifyPopupCloseRequested -or $script:NotifyPopupTerminalState -or $script:NotifyPopupActivating) { return $false }
    if ((Get-NotifyActivationRemainingMs -ExpiresAtUtc $script:NotifyPopupExpiresAtUtc) -le 0) {
        [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'expired')
        return $false
    }

    try {
        $script:NotifyPopupActivating = $true
        Remove-NotifyPopupLiveState
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
        $script:NotifyPopupSessionLabel.Text = $script:NotifyPopupOriginalSessionText
        $script:NotifyPopupSessionLabel.ForeColor = $inactiveAccentColor
        $script:NotifyPopupSessionLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupTitleLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'opening-title'
        $script:NotifyPopupTitleLabel.ForeColor = $inactiveTextColor
        $script:NotifyPopupTitleLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $script:NotifyPopupBodyLabel.Text = Get-NotifyPopupRecoveryUiText -Name 'opening-body'
        $script:NotifyPopupBodyLabel.ForeColor = $inactiveTextColor
        $script:NotifyPopupBodyLabel.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $watchdogMs = if ([string]$script:NotifyPopupTargetOriginKind -eq 'pi-web') {
            Get-NotifyPiWebActivationWatchdogMs -ExpiresAtUtc $script:NotifyPopupExpiresAtUtc
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$script:NotifyPopupTargetSnapshotId)) {
            $script:NotifyPopupRecoveringActivationWatchdogMs
        }
        else {
            $script:NotifyPopupReadyActivationWatchdogMs
        }
        $remainingMs = Get-NotifyActivationRemainingMs -ExpiresAtUtc $script:NotifyPopupExpiresAtUtc
        if ($remainingMs -le 0) {
            [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'expired')
            return $false
        }
        $watchdogMs = [Math]::Min($watchdogMs, $remainingMs)
        $script:NotifyPopupActivationWatchdogTimer.Stop()
        $script:NotifyPopupActivationWatchdogTimer.Interval = $watchdogMs
        $script:NotifyPopupActivationWatchdogTimer.Start()
        Write-NotifyPopupLog -Message ('popup-activation-feedback watchdogMs={0}' -f $watchdogMs)
        $script:NotifyPopupForm.Invalidate($true)
        $script:NotifyPopupForm.Refresh()
        return (-not ($script:NotifyPopupForm.IsDisposed -or $script:NotifyPopupCloseRequested -or $script:NotifyPopupTerminalState))
    }
    catch {
        Write-NotifyPopupLog -Message ('popup-activation-feedback-error "{0}"' -f $_.Exception.Message)
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'activation-feedback-error')
        return $false
    }
}

function Close-NotifyPopupExactWorkerResources {
    param([Parameter(Mandatory = $true)]$Worker)

    if ($Worker.PSObject.Properties['ResourcesClosed'] -and [bool]$Worker.ResourcesClosed) { return }
    if ($Worker.PSObject.Properties['ResourcesClosed']) {
        $Worker.ResourcesClosed = $true
    }
    try { $Worker.PowerShell.Dispose() } catch {}
    try { $Worker.Runspace.Close() } catch {}
    try { $Worker.Runspace.Dispose() } catch {}
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
        $failure = New-NotifyActivationWorkerFailureOutcome -Operation $worker.Operation -OriginKind $worker.OriginKind -Reason 'worker-cancel-error'
        Write-NotifyPopupLog -Message ('popup-exact-worker-cancel-error mode={0} reason={1} result={2}' -f $worker.Mode, $Reason, $failure.Result)
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $failure.Reason -Retryable $failure.Retryable)
        return $false
    }
}

function Invoke-NotifyPopupActivationWatchdog {
    if ($script:NotifyPopupTerminalState) { return $false }
    $failure = New-NotifyActivationWorkerFailureOutcome -Operation 'activate' -OriginKind $script:NotifyPopupTargetOriginKind -Reason 'activation-watchdog'
    Write-NotifyPopupLog -Message ('popup-activation-watchdog result={0}' -f $failure.Result)
    [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $failure.Reason -Retryable $failure.Retryable)
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

    return (Start-NotifyPopupExactWorker -Mode 'activate' -OriginKind 'paseo' -SnapshotId $ActivationId)
}

function Start-NotifyPopupExactWorker {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('resolve', 'activate')][string]$Mode,
        [string]$OriginKind = '',
        [string]$SnapshotId = ''
    )

    if ($script:NotifyPopupTerminalState -or $null -ne $script:NotifyPopupExactWorker) { return $false }
    $runspace = $null
    $powerShell = $null
    $workerScript = Get-NotifyActivationWorkerScript
    $operation = if ($Mode -eq 'resolve') { 'resolve' } else { 'activate' }
    $resolvedOrigin = if (-not [string]::IsNullOrWhiteSpace($OriginKind)) {
        $OriginKind.Trim()
    } elseif ($Mode -eq 'resolve') {
        'pi-web'
    } else {
        [string]$script:NotifyPopupTargetOriginKind
    }
    $resolvedSnapshot = if (-not [string]::IsNullOrWhiteSpace($SnapshotId)) { $SnapshotId } else { [string]$script:NotifyPopupTargetSnapshotId }
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
        [void]$powerShell.AddParameter('NotificationId', $script:NotifyPopupTargetNotificationId)
        [void]$powerShell.AddParameter('SnapshotId', $resolvedSnapshot)
        [void]$powerShell.AddParameter('RecoveryTicketId', $script:NotifyPopupTargetRecoveryTicketId)
        [void]$powerShell.AddParameter('TargetHost', $script:NotifyPopupTargetHost)
        [void]$powerShell.AddParameter('CwdBase', $script:NotifyPopupTargetCwdBase)
        [void]$powerShell.AddParameter('TabTitle', $script:NotifyPopupTargetSourceTabTitle)
        [void]$powerShell.AddParameter('TargetFingerprint', $script:NotifyPopupTargetFingerprint)
        [void]$powerShell.AddParameter('TimeoutMs', 3000)
        [void]$powerShell.AddParameter('ActivationRecoveryWaitMs', $script:NotifyPopupActivationRecoveryWaitMs)
        $async = $powerShell.BeginInvoke()
        $script:NotifyPopupExactWorker = [pscustomobject]@{
            Mode = $Mode
            Operation = $operation
            OriginKind = $resolvedOrigin
            PowerShell = $powerShell
            Runspace = $runspace
            Async = $async
            StartedAtUtc = [DateTime]::UtcNow
            StopAsync = $null
            CancelReason = ''
            ResourcesClosed = $false
        }
    }
    catch {
        if ($null -ne $powerShell) { try { $powerShell.Dispose() } catch {} }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch {}
            try { $runspace.Dispose() } catch {}
        }
        $failure = New-NotifyActivationWorkerFailureOutcome -Operation $operation -OriginKind $resolvedOrigin -Reason 'worker-start-error'
        Write-NotifyPopupLog -Message ('popup-exact-worker-start-error mode={0} result={1} reason={2}' -f $Mode, $failure.Result, $failure.Reason)
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $failure.Reason -Retryable $failure.Retryable)
        return $false
    }
    Write-NotifyPopupLog -Message ('popup-exact-worker-start mode={0} originKind={1}' -f $Mode, $(if ([string]::IsNullOrWhiteSpace($resolvedOrigin)) { 'terminal' } else { $resolvedOrigin }))
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

function Get-NotifyPopupLiveStatePath {
    return (Join-Path (Get-NotifyBridgeLogDir) ('popup-live.{0}.json' -f $PID))
}

function Save-NotifyPopupLiveState {
    $path = Get-NotifyPopupLiveStatePath
    try {
        if (-not $script:NotifyPopupHasShown -or $null -eq $script:NotifyPopupForm -or
            $script:NotifyPopupForm.IsDisposed -or $script:NotifyPopupForm.Disposing -or
            $script:NotifyPopupCloseRequested -or $script:NotifyPopupTerminalState -or $script:NotifyPopupActivating -or
            $script:NotifyPopupRecoveryState -notin @('ready', 'recovering') -or $null -eq $script:NotifyPopupActivationEvent -or
            (Get-NotifyActivationRemainingMs -ExpiresAtUtc $script:NotifyPopupExpiresAtUtc) -le 0) {
            Remove-NotifyPopupLiveState
            return
        }
        $payload = @{
            processId         = $PID
            configFingerprint = Get-NotifyPopupContextFingerprint -Value $config.ConfigPath
            targetFingerprint = $script:NotifyPopupTargetFingerprint
            stackIndex        = $StackIndex
            startedAtTicks    = $script:NotifyPopupCreatedAtUtc.Ticks
            createdAtUtc      = $script:NotifyPopupCreatedAtUtc.ToString('o')
            expiresAtTicks    = $script:NotifyPopupExpiresAtUtc.Ticks
            activationKey     = $script:NotifyPopupActivationKey
        }
        Write-NotifyPopupLiveJson -Path $path -Payload $payload
        Write-NotifyPopupLog -Message ('popup-live-state pid={0} targetFingerprint={1} stackIndex={2} pathFingerprint={3}' -f $PID, $script:NotifyPopupTargetFingerprint, $StackIndex, (Get-NotifyPopupContextFingerprint -Value $path))
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

try {
    $consoleHandle = [PiNotifyConsoleWindow]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][PiNotifyConsoleWindow]::ShowWindow($consoleHandle, 0)
    }
}
catch {
}

Write-NotifyPopupLog -Message ('popup-start targetFingerprint={0} hasCwd={1} hasTab={2} timeout={3} stackIndex={4}' -f (Get-NotifyPopupContextFingerprint -Value $FocusTarget), (-not [string]::IsNullOrWhiteSpace($CwdBase)), (-not [string]::IsNullOrWhiteSpace($SourceTabTitle)), $TimeoutSeconds, $StackIndex)
$script:NotifyPopupActivationKey = [Guid]::NewGuid().ToString('N')
$script:NotifyPopupActivationEvent = $null
try {
    $eventName = Get-NotifyPopupActivationEventName -ProcessId $PID -ActivationKey $script:NotifyPopupActivationKey
    $script:NotifyPopupActivationEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $eventName)
}
catch {
    Write-NotifyPopupLog -Message 'popup-hotkey-signal-unavailable'
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
        if (Test-NotifyPopupForegroundIdentity -SelectedTabTitle $selectedTitle -WindowTitle $windowTitle -SourceTabTitle $SourceTabTitleValue -CwdBase $CurrentDirBase) {
            Write-NotifyPopupLog -Message ('popup-foreground-target-match sourceTabFingerprint={0} cwdFingerprint={1} selectedTabFingerprint={2} windowFingerprint={3}' -f (Get-NotifyPopupContextFingerprint -Value $SourceTabTitleValue), (Get-NotifyPopupContextFingerprint -Value $CurrentDirBase), (Get-NotifyPopupContextFingerprint -Value $selectedTitle), (Get-NotifyPopupContextFingerprint -Value $windowTitle))
            return $true
        }
    }
    catch {
    }

    return $false
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

foreach ($label in @($appLabel, $closeLabel, $sessionLabel, $titleLabel, $bodyLabel)) {
    $label.UseMnemonic = $false
    if ($null -ne $script:NotifyPopupWallpaperImage) {
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
$script:NotifyPopupTargetHost = $targetHost
$script:NotifyPopupTargetCwdBase = $targetCwdBase
$script:NotifyPopupTargetSourceTabTitle = $targetSourceTabTitle
$script:NotifyPopupTargetOriginKind = $targetOriginKind
$script:NotifyPopupTargetFingerprint = if ([string]::IsNullOrWhiteSpace($TargetFingerprint)) { Get-NotifyPopupContextFingerprint -Value $targetHost } else { $TargetFingerprint }
$script:NotifyPopupTargetNotificationId = $targetNotificationId
$script:NotifyPopupTargetSnapshotId = $targetSnapshotId
$script:NotifyPopupTargetRecoveryTicketId = $targetRecoveryTicketId
$script:NotifyPopupRecoveryState = if ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId) -and -not [string]::IsNullOrWhiteSpace($targetRecoveryTicketId)) { 'recovering' } elseif ($targetOriginKind -eq 'pi-web' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } elseif ($targetOriginKind -eq 'paseo' -and [string]::IsNullOrWhiteSpace($targetSnapshotId)) { 'unavailable' } else { 'ready' }
$script:NotifyPopupExactWorker = $null
$script:NotifyPopupClosingWorker = $null
$script:NotifyPopupActivateAfterResolve = $false
$script:NotifyPopupTerminalState = $false
$script:NotifyPopupTerminalOutcome = ''
$script:NotifyPopupTerminalReason = ''
$script:NotifyPopupCloseRequested = $false
$script:NotifyPopupActivating = $false
$script:NotifyPopupHasShown = $false
$script:NotifyPopupExactWorkerTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupExactWorkerTimer.Interval = 100
$script:NotifyPopupExactWorkerTimer.Add_Tick({
    $worker = $script:NotifyPopupExactWorker
    if ($null -eq $worker) { return }
    $completionReady = if ($null -ne $worker.StopAsync) { $worker.StopAsync.IsCompleted } else { $worker.Async.IsCompleted }
    if (-not $completionReady) { return }
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
        Close-NotifyPopupExactWorkerResources -Worker $worker
        $script:NotifyPopupExactWorker = $null
        $this.Stop()
    }
    $elapsedMs = [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds
    if (-not [string]::IsNullOrWhiteSpace($cancelReason)) {
        $cancelled = New-NotifyActivationWorkerFailureOutcome -Operation $worker.Operation -OriginKind $worker.OriginKind -Reason 'worker-cancelled' -ElapsedMs $elapsedMs
        Write-NotifyPopupLog -Message ('popup-exact-worker-cancelled mode={0} reason={1} result={2} elapsedMs={3}' -f $worker.Mode, $cancelReason, $cancelled.Result, $cancelled.ElapsedMs)
        if ($cancelReason -eq 'superseded-by-activation' -and $script:NotifyPopupActivateAfterResolve -and -not $script:NotifyPopupTerminalState) {
            $script:NotifyPopupActivateAfterResolve = $false
            [void](Start-NotifyPopupExactWorker -Mode 'activate' -OriginKind 'pi-web')
        }
        return
    }
    if ($null -eq $result) {
        $result = Resolve-NotifyActivationWorkerOutput -Rows $rows -Operation $worker.Operation -OriginKind $worker.OriginKind -ElapsedMs $elapsedMs
    }
    $snapshotFp = Get-NotifyRouteFingerprint -Value ([string]$result.SnapshotId)
    Write-NotifyPopupLog -Message ('popup-exact-worker-complete mode={0} decision={1} result={2} reason={3} snapshotFp={4} elapsedMs={5} scrollAttempted={6} scrolledToBottom={7}' -f $worker.Mode, $result.Decision, $result.Result, $(if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { 'none' } else { [string]$result.Reason }), $snapshotFp, [int]([DateTime]::UtcNow - $worker.StartedAtUtc).TotalMilliseconds, $result.ScrollAttempted, $result.ScrolledToBottom)
    if ($script:NotifyPopupTerminalState) { return }
    $ui = ConvertTo-NotifyActivationUiOutcome -Outcome $result -HasDeferredActivateIntent:$script:NotifyPopupActivateAfterResolve
    if ($ui.Action -eq 'store-ready') {
        if (-not [string]::IsNullOrWhiteSpace([string]$ui.SnapshotId)) {
            $script:NotifyPopupTargetSnapshotId = [string]$ui.SnapshotId
        }
        if ($ui.StartActivate) {
            $script:NotifyPopupActivateAfterResolve = $false
            [void](Start-NotifyPopupExactWorker -Mode 'activate' -OriginKind 'pi-web')
        }
        else {
            Set-NotifyPopupRecoveryUiState -State 'ready'
        }
        return
    }
    if ($ui.Action -eq 'close-handled') {
        [void](Complete-NotifyPopupLifecycle -Outcome 'handled' -Reason $(if ([string]::IsNullOrWhiteSpace([string]$ui.Result)) { 'activation-handled' } else { [string]$ui.Result }))
        return
    }
    if ($ui.Action -eq 'keep-focused') {
        # Focused/pending is non-terminal: keep the card in bounded pending
        # feedback instead of closing. The original popup deadline stays
        # authoritative; a later terminal result (or timeout) closes it.
        if (-not $script:NotifyPopupTerminalState) {
            Set-NotifyPopupRecoveryUiState -State 'recovering'
        }
        return
    }
    if ($ui.Action -eq 'restore-retryable') {
        $reason = if (-not [string]::IsNullOrWhiteSpace([string]$ui.Result)) { [string]$ui.Result } elseif (-not [string]::IsNullOrWhiteSpace([string]$ui.Reason)) { [string]$ui.Reason } else { 'activation-failed' }
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $reason -Retryable $true)
        return
    }
    $failReason = if (-not [string]::IsNullOrWhiteSpace([string]$ui.Result)) { [string]$ui.Result } elseif (-not [string]::IsNullOrWhiteSpace([string]$ui.Reason)) { [string]$ui.Reason } else { 'activation-failed' }
    [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason $failReason -Retryable $false)
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
            [void](Start-NotifyPopupExactWorker -Mode 'activate' -OriginKind 'pi-web')
        }
        return
    }

    Write-NotifyPopupLog -Message 'popup-click'
    Write-NotifyPopupLog -Message ('popup-action activate targetFingerprint={0} originKind={1} notificationFp={2} snapshotFp={3}' -f (Get-NotifyPopupContextFingerprint -Value $targetHost), $(if ([string]::IsNullOrWhiteSpace($targetOriginKind)) { 'none' } else { $targetOriginKind }), (Get-NotifyRouteFingerprint -Value $targetNotificationId), (Get-NotifyRouteFingerprint -Value $targetSnapshotId))
    if (-not (Set-NotifyPopupActivating)) { return }
    $script:NotifyPopupDidActivate = $true
    if (-not (Start-NotifyPopupExactWorker -Mode 'activate' -OriginKind $(if ([string]::IsNullOrWhiteSpace($targetOriginKind)) { 'terminal' } else { $targetOriginKind }))) {
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'worker-start-error')
    }
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
$popupLifetimeMs = Get-NotifyPopupLifetimeMs -TimeoutSeconds $TimeoutSeconds
$script:NotifyPopupCreatedAtUtc = [DateTime]::UtcNow
$script:NotifyPopupExpiresAtUtc = $script:NotifyPopupCreatedAtUtc.AddMilliseconds($popupLifetimeMs)
$timer.Interval = $popupLifetimeMs
$timer.Add_Tick({
    Write-NotifyPopupLog -Message 'popup-timeout-close'
    Write-NotifyPopupLog -Message 'popup-action dismiss source="timeout"'
    [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'timeout')
})

# Explicit close and activation signals remain responsive while a worker is running.
$script:NotifyPopupSignalTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupSignalTimer.Interval = 250
$script:NotifyPopupSignalTimer.Add_Tick({
    if ($targetOriginKind -eq 'paseo' -and -not [string]::IsNullOrWhiteSpace($targetNotificationId) -and
        (Test-NotifyPaseoCloseSignal -NotificationId $targetNotificationId -CloseEvent $script:NotifyPopupPaseoCloseEvent)) {
        $this.Stop()
        Write-NotifyPopupLog -Message ('popup-action dismiss source="paseo-close" notificationFp={0}' -f (Get-NotifyRouteFingerprint -Value $targetNotificationId))
        [void](Request-NotifyPopupExactWorkerStop -Reason 'paseo-close')
        $script:NotifyPopupDidActivate = $false
        [void](Complete-NotifyPopupLifecycle -Outcome 'dismissed' -Reason 'paseo-close')
        return
    }
    if ($null -ne $script:NotifyPopupActivationEvent -and $script:NotifyPopupActivationEvent.WaitOne(0)) {
        & $activateAction
    }
})

$focusWatchTimer = New-Object System.Windows.Forms.Timer
$script:NotifyPopupFocusWatchTimer = $focusWatchTimer
$focusWatchTimer.Interval = 800
$focusWatchTimer.Add_Tick({
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

$workingArea = Get-NotifyPopupWorkingArea -Placement $PopupPlacement
$slot = [Math]::Max(0, $StackIndex)
$location = Get-NotifyPopupStackPosition -WorkingArea $workingArea -StackIndex $slot -FormWidth $form.Width -FormHeight $form.Height
$x = $location.X
$y = $location.Y
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
    $script:NotifyPopupSignalTimer.Start()
    if ($script:NotifyPopupRecoveryState -eq 'recovering') {
        Set-NotifyPopupRecoveryUiState -State 'recovering'
        [void](Start-NotifyPopupExactWorker -Mode 'resolve')
    }
    elseif ($script:NotifyPopupRecoveryState -eq 'unavailable') {
        [void](Complete-NotifyPopupLifecycle -Outcome 'failed' -Reason 'exact-route-unavailable' -Retryable $false)
    }
    $script:NotifyPopupHasShown = $true
    Save-NotifyPopupLiveState
})

$form.Add_FormClosed({
    $script:NotifyPopupCloseRequested = $true
    if (-not $script:NotifyPopupTerminalState) {
        $script:NotifyPopupTerminalState = $true
        $script:NotifyPopupTerminalOutcome = 'dismissed'
        $script:NotifyPopupTerminalReason = 'form-closed'
    }
    Write-NotifyPopupLog -Message ('popup-closed didActivate={0}' -f $script:NotifyPopupDidActivate)
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
            $script:NotifyPopupClosingWorker = $script:NotifyPopupExactWorker
            $script:NotifyPopupExactWorker = $null
        }
        $timer.Stop()
        $timer.Dispose()
        $focusWatchTimer.Stop()
        $focusWatchTimer.Dispose()
        if ($null -ne $script:NotifyPopupSignalTimer) {
            $script:NotifyPopupSignalTimer.Stop()
            $script:NotifyPopupSignalTimer.Dispose()
            $script:NotifyPopupSignalTimer = $null
        }
        if ($null -ne $script:NotifyPopupActivationEvent) {
            $script:NotifyPopupActivationEvent.Dispose()
            $script:NotifyPopupActivationEvent = $null
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
    foreach ($worker in @($script:NotifyPopupExactWorker, $script:NotifyPopupClosingWorker)) {
        if ($null -eq $worker) { continue }
        try {
            if ([string]::IsNullOrWhiteSpace([string]$worker.CancelReason) -and -not $worker.Async.IsCompleted) {
                $worker.CancelReason = 'process-teardown'
                $worker.PowerShell.Stop()
            }
        }
        catch {
        }
        Close-NotifyPopupExactWorkerResources -Worker $worker
    }
    $script:NotifyPopupExactWorker = $null
    $script:NotifyPopupClosingWorker = $null
    if ($null -ne $script:NotifyPopupSignalTimer) {
        try { $script:NotifyPopupSignalTimer.Stop() } catch {}
        try { $script:NotifyPopupSignalTimer.Dispose() } catch {}
        $script:NotifyPopupSignalTimer = $null
    }
    if ($null -ne $script:NotifyPopupActivationEvent) {
        try { $script:NotifyPopupActivationEvent.Dispose() } catch {}
        $script:NotifyPopupActivationEvent = $null
    }
    if ($null -ne $script:NotifyPopupPaseoCloseEvent) {
        try { $script:NotifyPopupPaseoCloseEvent.Dispose() } catch {}
        $script:NotifyPopupPaseoCloseEvent = $null
    }
}
