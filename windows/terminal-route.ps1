# Shared Windows Terminal activation adapter.
# Load after NotifyBridge.Common.ps1. Owns WT discovery, pure candidate selection,
# activation, and foreground/selected-tab final proof. No popup or Route Host knowledge.

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'Set-NotifyBridgeTerminalScrollToBottom' -ErrorAction SilentlyContinue)) {
    throw 'terminal-route.ps1 must be dot-sourced after NotifyBridge.Common.ps1'
}

Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue

if (-not ('PiNotifyTerminalUser32' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PiNotifyTerminalUser32 {
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
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@
}

# True when a process name is on the established Windows Terminal allowlist.
function Test-NotifyTerminalProcessName {
    param([string]$ProcessName)

    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    return ($ProcessName -match 'WindowsTerminal|Terminal')
}

# Build a stable terminal-route result object with required fields.
function New-NotifyTerminalRouteResult {
    param(
        [Parameter(Mandatory = $true)][string]$Result,
        [bool]$Retryable = $false,
        [string]$Reason = '',
        [int]$ElapsedMs = 0,
        [bool]$AlreadyActive = $false,
        [bool]$ScrollAttempted = $false,
        [bool]$ScrolledToBottom = $false
    )

    $normalized = if ([string]::IsNullOrWhiteSpace($Result)) { 'controller-error' } else { $Result.Trim() }
    $finalResult = if ($AlreadyActive -and $normalized -eq 'activated') { 'already-active' } else { $normalized }
    return [pscustomobject]@{
        Decision   = if ($finalResult -in @('activated', 'already-active')) { 'handled' } else { 'fail-closed' }
        OriginKind = 'terminal'
        Result     = $finalResult
        Reason     = if ($null -eq $Reason) { '' } else { [string]$Reason }
        Retryable  = [bool]$Retryable
        ProofState = if ($finalResult -in @('activated', 'already-active')) { 'final' } else { 'none' }
        ScrollAttempted = [bool]$ScrollAttempted
        ScrolledToBottom = [bool]($ScrollAttempted -and $ScrolledToBottom)
        ElapsedMs  = [Math]::Max(0, [int]$ElapsedMs)
    }
}

# Pure authority match for one tab/window title pair against request fields.
function Test-NotifyTerminalAuthorityMatch {
    param(
        [string]$TabName = '',
        [string]$WindowTitle = '',
        [string]$TabTitle = '',
        [string]$CwdBase = ''
    )

    $tab = if ($null -eq $TabName) { '' } else { $TabName.Trim() }
    $window = if ($null -eq $WindowTitle) { '' } else { $WindowTitle.Trim() }
    $requiredTitle = if ($null -eq $TabTitle) { '' } else { $TabTitle.Trim() }
    $requiredCwd = if ($null -eq $CwdBase) { '' } else { $CwdBase.Trim() }

    if (-not [string]::IsNullOrWhiteSpace($requiredTitle)) {
        if ([string]::IsNullOrWhiteSpace($tab)) { return $false }
        if ($tab.IndexOf($requiredTitle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($requiredCwd)) {
            $haystack = @($tab, $window) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $cwdOk = $false
            foreach ($value in $haystack) {
                if ($value.IndexOf($requiredCwd, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $cwdOk = $true
                    break
                }
            }
            if (-not $cwdOk) { return $false }
        }
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($requiredCwd)) { return $false }
    $haystack = @($tab, $window) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($value in $haystack) {
        if ($value.IndexOf($requiredCwd, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

# Pure candidate selection from injected window/tab snapshots. Cache may order only.
function Select-NotifyTerminalCandidates {
    param(
        [string]$TabTitle = '',
        [string]$CwdBase = '',
        [string]$TargetHost = '',
        $Windows = @(),
        $CachedCandidate = $null
    )

    $requiredTitle = if ($null -eq $TabTitle) { '' } else { $TabTitle.Trim() }
    $requiredCwd = if ($null -eq $CwdBase) { '' } else { $CwdBase.Trim() }

    if ([string]::IsNullOrWhiteSpace($requiredTitle) -and [string]::IsNullOrWhiteSpace($requiredCwd)) {
        return [pscustomobject]@{
            Result     = 'missing-target-metadata'
            Retryable  = $false
            Candidates = @()
            Selected   = $null
        }
    }

    $eligible = New-Object System.Collections.Generic.List[object]
    foreach ($window in @($Windows)) {
        if ($null -eq $window) { continue }
        $windowTitle = if ($window.PSObject.Properties['Title']) { [string]$window.Title } else { '' }
        $processName = if ($window.PSObject.Properties['ProcessName']) { [string]$window.ProcessName } else { '' }
        if (-not (Test-NotifyTerminalProcessName -ProcessName $processName)) { continue }

        $tabs = @()
        if ($window.PSObject.Properties['Tabs'] -and $null -ne $window.Tabs) {
            $tabs = @($window.Tabs)
        }
        foreach ($tab in $tabs) {
            if ($null -eq $tab) { continue }
            $tabName = if ($tab.PSObject.Properties['Name']) { [string]$tab.Name } else { '' }
            if (-not (Test-NotifyTerminalAuthorityMatch -TabName $tabName -WindowTitle $windowTitle -TabTitle $requiredTitle -CwdBase $requiredCwd)) {
                continue
            }
            $tabIndex = if ($tab.PSObject.Properties['Index']) { [int]$tab.Index } else { -1 }
            $isSelected = if ($tab.PSObject.Properties['IsSelected']) { [bool]$tab.IsSelected } else { $false }
            $handle = if ($window.PSObject.Properties['Handle']) { $window.Handle } else { [IntPtr]::Zero }
            $processId = if ($window.PSObject.Properties['ProcessId']) { [int]$window.ProcessId } else { 0 }
            $element = if ($tab.PSObject.Properties['Element']) { $tab.Element } else { $null }
            $eligible.Add([pscustomobject]@{
                WindowHandle = $handle
                WindowTitle  = $windowTitle
                ProcessId    = $processId
                ProcessName  = $processName
                TabName      = $tabName
                TabIndex     = $tabIndex
                IsSelected   = $isSelected
                TabElement   = $element
            }) | Out-Null
        }
    }

    $candidates = @($eligible.ToArray())
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Result     = 'target-missing'
            Retryable  = $true
            Candidates = @()
            Selected   = $null
        }
    }
    if ($candidates.Count -gt 1) {
        return [pscustomobject]@{
            Result     = 'ambiguous'
            Retryable  = $true
            Candidates = $candidates
            Selected   = $null
        }
    }

    $selected = $candidates[0]
    # Cache may only prefer an already unique candidate after revalidation.
    if ($null -ne $CachedCandidate) {
        $cacheTab = if ($CachedCandidate.PSObject.Properties['TabName']) { [string]$CachedCandidate.TabName } else { '' }
        $cacheHandle = if ($CachedCandidate.PSObject.Properties['WindowHandle']) { $CachedCandidate.WindowHandle } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($cacheTab) -and
            $cacheTab -eq [string]$selected.TabName -and
            $null -ne $cacheHandle -and
            $cacheHandle -eq $selected.WindowHandle) {
            # Keep selected as the unique candidate; cache does not change identity.
        }
    }

    return [pscustomobject]@{
        Result     = 'unique'
        Retryable  = $false
        Candidates = $candidates
        Selected   = $selected
    }
}

# Pure post-check for foreground HWND plus exact selected-tab authority.
function Test-NotifyTerminalActivationProof {
    param(
        [string]$TabTitle = '',
        [string]$CwdBase = '',
        $TargetHandle = $null,
        $ForegroundHandle = $null,
        $SelectedTabs = @()
    )

    if ($null -eq $TargetHandle -or $TargetHandle -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ Ok = $false; Result = 'foreground-proof-failed'; Reason = 'missing-target-handle' }
    }
    if ($null -eq $ForegroundHandle -or $ForegroundHandle -eq [IntPtr]::Zero -or $ForegroundHandle -ne $TargetHandle) {
        return [pscustomobject]@{ Ok = $false; Result = 'foreground-proof-failed'; Reason = 'foreground-mismatch' }
    }

    $selected = @($SelectedTabs | Where-Object { $null -ne $_ })
    if ($selected.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Result = 'selected-tab-proof-failed'; Reason = 'no-selected-tab' }
    }
    if ($selected.Count -gt 1) {
        return [pscustomobject]@{ Ok = $false; Result = 'selected-tab-proof-failed'; Reason = 'multiple-selected-tabs' }
    }

    $tab = $selected[0]
    $tabName = if ($tab.PSObject.Properties['Name']) { [string]$tab.Name } else { '' }
    $windowTitle = if ($tab.PSObject.Properties['WindowTitle']) { [string]$tab.WindowTitle } else { '' }
    if (-not (Test-NotifyTerminalAuthorityMatch -TabName $tabName -WindowTitle $windowTitle -TabTitle $TabTitle -CwdBase $CwdBase)) {
        return [pscustomobject]@{ Ok = $false; Result = 'selected-tab-proof-failed'; Reason = 'selected-tab-mismatch' }
    }

    return [pscustomobject]@{ Ok = $true; Result = 'activated'; Reason = '' }
}

# Read the current native window title for live authority checks.
function Get-NotifyTerminalWindowTitle {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    if ($Handle -eq [IntPtr]::Zero) { return '' }
    $titleLength = [PiNotifyTerminalUser32]::GetWindowTextLength($Handle)
    if ($titleLength -le 0) { return '' }
    $builder = New-Object System.Text.StringBuilder ($titleLength + 1)
    [void][PiNotifyTerminalUser32]::GetWindowText($Handle, $builder, $builder.Capacity)
    return $builder.ToString().Trim()
}

# Discover visible top-level Windows Terminal windows.
function Get-NotifyTerminalWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PiNotifyTerminalUser32+EnumWindowsProc]{
        param([IntPtr]$Handle, [IntPtr]$LParam)

        if (-not [PiNotifyTerminalUser32]::IsWindowVisible($Handle)) {
            return $true
        }

        $titleLength = [PiNotifyTerminalUser32]::GetWindowTextLength($Handle)
        if ($titleLength -le 0) {
            return $true
        }

        $builder = New-Object System.Text.StringBuilder ($titleLength + 1)
        [void][PiNotifyTerminalUser32]::GetWindowText($Handle, $builder, $builder.Capacity)
        $title = $builder.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return $true
        }

        $processId = [uint32]0
        [void][PiNotifyTerminalUser32]::GetWindowThreadProcessId($Handle, [ref]$processId)
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        if (-not (Test-NotifyTerminalProcessName -ProcessName $process.ProcessName)) {
            return $true
        }

        $windows.Add([pscustomobject]@{
            Handle      = $Handle
            Title       = $title
            ProcessId   = [int]$process.Id
            ProcessName = [string]$process.ProcessName
        }) | Out-Null
        return $true
    }

    [void][PiNotifyTerminalUser32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows.ToArray())
}

# Enumerate TabItem elements under a window handle.
function Get-NotifyTerminalTabs {
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
        return @()
    }

    return @($rows.ToArray())
}

# Select a terminal tab via SelectionItem or Invoke fallback.
function Select-NotifyTerminalTab {
    param(
        [Parameter(Mandatory = $true)]
        $TabElement
    )

    if ($null -eq $TabElement) { return $false }

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

# Collect selected tabs for post-check, attaching window title for cwd checks.
function Get-NotifyTerminalSelectedTabs {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,
        [string]$WindowTitle = ''
    )

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($tab in @(Get-NotifyTerminalTabs -Handle $Handle)) {
        if (-not [bool]$tab.IsSelected) { continue }
        $selected.Add([pscustomobject]@{
            Name        = [string]$tab.Name
            WindowTitle = $WindowTitle
            Index       = [int]$tab.Index
            Element     = $tab.Element
        }) | Out-Null
    }
    return @($selected.ToArray())
}

# Capture live Terminal windows and tabs for one all-candidate authority pass.
function Get-NotifyTerminalWindowSnapshots {
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($window in @(Get-NotifyTerminalWindows)) {
        $tabs = @(Get-NotifyTerminalTabs -Handle $window.Handle)
        $snapshots.Add([pscustomobject]@{
            Handle      = $window.Handle
            Title       = Get-NotifyTerminalWindowTitle -Handle $window.Handle
            ProcessId   = $window.ProcessId
            ProcessName = $window.ProcessName
            Tabs        = $tabs
        }) | Out-Null
    }
    return @($snapshots.ToArray())
}

# Activate the unique Terminal tab and require foreground + selected-tab proof.
function Invoke-NotifyTerminalRouteActivate {
    param(
        [string]$TabTitle = '',
        [string]$CwdBase = '',
        [string]$TargetHost = '',
        [string]$TargetFingerprint = '',
        $CachedCandidate = $null,
        [int]$TimeoutMs = 3000,
        [scriptblock]$Log = $null
    )

    $startedAt = [DateTime]::UtcNow
    $scrollAttempted = $false
    $scrolledToBottom = $false
    $writeLog = {
        param([string]$Message)
        if ($null -ne $Log) {
            try { & $Log $Message } catch {}
        }
    }

    try {
        $requiredTitle = if ($null -eq $TabTitle) { '' } else { $TabTitle.Trim() }
        $requiredCwd = if ($null -eq $CwdBase) { '' } else { $CwdBase.Trim() }
        if ([string]::IsNullOrWhiteSpace($requiredTitle) -and [string]::IsNullOrWhiteSpace($requiredCwd)) {
            return (New-NotifyTerminalRouteResult -Result 'missing-target-metadata' -Retryable:$false -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        $snapshots = @(Get-NotifyTerminalWindowSnapshots)

        # Cache cannot skip full uniqueness enumeration.
        $selection = Select-NotifyTerminalCandidates -TabTitle $requiredTitle -CwdBase $requiredCwd -TargetHost $TargetHost -Windows $snapshots -CachedCandidate $CachedCandidate
        if ($selection.Result -ne 'unique' -or $null -eq $selection.Selected) {
            $retryable = [bool]$selection.Retryable
            & $writeLog ('terminal-route-select result={0} candidateCount={1}' -f $selection.Result, @($selection.Candidates).Count)
            return (New-NotifyTerminalRouteResult -Result $selection.Result -Retryable:$retryable -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        # Discovery objects are hints only. Reacquire all live candidates before any focus/select side effect.
        $liveSelection = Select-NotifyTerminalCandidates -TabTitle $requiredTitle -CwdBase $requiredCwd -TargetHost $TargetHost -Windows @(Get-NotifyTerminalWindowSnapshots)
        if ($liveSelection.Result -ne 'unique' -or $null -eq $liveSelection.Selected) {
            return (New-NotifyTerminalRouteResult -Result $liveSelection.Result -Retryable:([bool]$liveSelection.Retryable) -Reason 'live-authority-revalidation-failed' -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        $best = $liveSelection.Selected
        $handle = $best.WindowHandle
        if ($null -eq $handle -or $handle -eq [IntPtr]::Zero) {
            return (New-NotifyTerminalRouteResult -Result 'target-missing' -Retryable:$true -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        $alreadyActive = $false
        try {
            $foregroundBefore = [PiNotifyTerminalUser32]::GetForegroundWindow()
            $currentTitleBefore = Get-NotifyTerminalWindowTitle -Handle $handle
            $selectedBefore = @(Get-NotifyTerminalSelectedTabs -Handle $handle -WindowTitle $currentTitleBefore)
            if ($foregroundBefore -eq $handle -and $selectedBefore.Count -eq 1) {
                $proofBefore = Test-NotifyTerminalActivationProof -TabTitle $requiredTitle -CwdBase $requiredCwd -TargetHandle $handle -ForegroundHandle $foregroundBefore -SelectedTabs $selectedBefore
                if ($proofBefore.Ok) {
                    $alreadyActive = $true
                }
            }
        }
        catch {
        }

        if ([PiNotifyTerminalUser32]::IsIconic($handle)) {
            [void][PiNotifyTerminalUser32]::ShowWindowAsync($handle, 9)
            Start-Sleep -Milliseconds 80
        }

        $focusOk = $false
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.AppActivate([int]$best.ProcessId)
            $focusOk = $true
        }
        catch {
            & $writeLog 'terminal-route-appactivate-error'
        }
        Start-Sleep -Milliseconds 40
        if (-not [PiNotifyTerminalUser32]::SetForegroundWindow($handle)) {
            & $writeLog 'terminal-route-setforeground-failed'
        }
        else {
            $focusOk = $true
        }
        Start-Sleep -Milliseconds 40

        if (-not $focusOk) {
            return (New-NotifyTerminalRouteResult -Result 'window-focus-failed' -Retryable:$true -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        # Reacquire the live element by authority. Never reuse discovery UIA objects or tab indices.
        $currentWindowTitle = Get-NotifyTerminalWindowTitle -Handle $handle
        $liveTabMatches = @(@(Get-NotifyTerminalTabs -Handle $handle) | Where-Object {
            Test-NotifyTerminalAuthorityMatch -TabName ([string]$_.Name) -WindowTitle $currentWindowTitle -TabTitle $requiredTitle -CwdBase $requiredCwd
        })
        if ($liveTabMatches.Count -eq 0) {
            return (New-NotifyTerminalRouteResult -Result 'tab-select-failed' -Retryable:$true -Reason 'live-tab-missing' -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }
        if ($liveTabMatches.Count -gt 1) {
            return (New-NotifyTerminalRouteResult -Result 'ambiguous' -Retryable:$true -Reason 'live-tab-ambiguous' -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }
        $tabElement = $liveTabMatches[0].Element

        if ($null -eq $tabElement) {
            return (New-NotifyTerminalRouteResult -Result 'tab-select-failed' -Retryable:$true -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }

        $needsSelect = $true
        try {
            $patternObj = $null
            if ($tabElement.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObj)) {
                if (([System.Windows.Automation.SelectionItemPattern]$patternObj).Current.IsSelected) {
                    $needsSelect = $false
                }
            }
        }
        catch {
        }

        if ($needsSelect) {
            if (-not (Select-NotifyTerminalTab -TabElement $tabElement)) {
                return (New-NotifyTerminalRouteResult -Result 'tab-select-failed' -Retryable:$true -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
        }

        # Scroll is best effort and outside identity proof, but keep its result observable.
        $scrollAttempted = $true
        try {
            $scrolledToBottom = [bool](Set-NotifyBridgeTerminalScrollToBottom -WindowHandle $handle)
        }
        catch {
            $scrolledToBottom = $false
        }
        & $writeLog ('terminal-route-scroll scrollAttempted=True scrolledToBottom={0}' -f $scrolledToBottom)

        $budgetMs = [Math]::Max(200, [Math]::Min(5000, [int]$TimeoutMs))
        $deadline = [DateTime]::UtcNow.AddMilliseconds($budgetMs)
        $lastProof = $null
        do {
            $foreground = [PiNotifyTerminalUser32]::GetForegroundWindow()
            $currentWindowTitle = Get-NotifyTerminalWindowTitle -Handle $handle
            $selectedTabs = @(Get-NotifyTerminalSelectedTabs -Handle $handle -WindowTitle $currentWindowTitle)
            $lastProof = Test-NotifyTerminalActivationProof -TabTitle $requiredTitle -CwdBase $requiredCwd -TargetHandle $handle -ForegroundHandle $foreground -SelectedTabs $selectedTabs
            if ($lastProof.Ok) {
                return (New-NotifyTerminalRouteResult -Result 'activated' -Retryable:$false -AlreadyActive:$alreadyActive -ScrollAttempted:$scrollAttempted -ScrolledToBottom:$scrolledToBottom -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
            }
            Start-Sleep -Milliseconds 40
        } while ([DateTime]::UtcNow -lt $deadline)

        $failResult = if ($null -ne $lastProof -and -not [string]::IsNullOrWhiteSpace([string]$lastProof.Result)) {
            [string]$lastProof.Result
        } else {
            'foreground-proof-failed'
        }
        $failReason = if ($null -ne $lastProof -and -not [string]::IsNullOrWhiteSpace([string]$lastProof.Reason)) {
            [string]$lastProof.Reason
        } else {
            'post-check-timeout'
        }
        return (New-NotifyTerminalRouteResult -Result $failResult -Retryable:$true -Reason $failReason -ScrollAttempted:$scrollAttempted -ScrolledToBottom:$scrolledToBottom -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'UIAutomation|AutomationElement|UI Automation') {
            return (New-NotifyTerminalRouteResult -Result 'uia-unavailable' -Retryable:$true -Reason 'uia-exception' -ScrollAttempted:$scrollAttempted -ScrolledToBottom:$scrolledToBottom -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
        }
        return (New-NotifyTerminalRouteResult -Result 'controller-error' -Retryable:$true -Reason 'terminal-route-exception' -ScrollAttempted:$scrollAttempted -ScrolledToBottom:$scrolledToBottom -ElapsedMs ([int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds))
    }
}
