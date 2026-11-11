# Exercise real hotkey state selection with isolated files and a mocked process query.
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/test-popup-hotkey.ps1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0

function Assert-Hotkey {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}

function Read-HotkeyTestFunctions {
    param([string]$Name, [string[]]$Functions)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $parts = foreach ($functionName in $Functions) {
        $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
        if ($null -eq $found) { throw "Function missing: $functionName" }
        $found.Extent.Text
    }
    return ($parts -join "`n")
}

. ([scriptblock]::Create((Read-HotkeyTestFunctions 'pi-notify-hotkey.ps1' @('Get-NotifyHotkeyLivePopupStates', 'Get-NotifyHotkeyFingerprint'))))
. ([scriptblock]::Create((Read-HotkeyTestFunctions 'NotifyBridge.Common.ps1' @('Get-NotifyPopupActivationEventName', 'Read-NotifyPopupLiveJson'))))

$script:HotkeyTestDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-hotkey-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:HotkeyTestDirectory | Out-Null
$config = [pscustomobject]@{ ConfigPath = (Join-Path $script:HotkeyTestDirectory 'a.json') }
$ownFingerprint = Get-NotifyHotkeyFingerprint -Value $config.ConfigPath
$foreignFingerprint = Get-NotifyHotkeyFingerprint -Value (Join-Path $script:HotkeyTestDirectory 'b.json')
$script:OwnershipQueries = [System.Collections.Generic.List[int]]::new()
$script:OwnedProcessIds = @{ 41001 = $true; 41002 = $true; 41003 = $false }
function Get-NotifyBridgeLogDir { return $script:HotkeyTestDirectory }
function Write-NotifyHotkeyLog { param($Message) }
function Test-NotifyHotkeyPopupProcessOwned {
    param([int]$ProcessId)
    $script:OwnershipQueries.Add($ProcessId)
    return ($script:OwnedProcessIds.ContainsKey($ProcessId) -and $script:OwnedProcessIds[$ProcessId])
}
function Save-HotkeyTestState {
    param([string]$Name, $ProcessId, [string]$Fingerprint, [int64]$StartedAtTicks, [switch]$Expired)
    $path = Join-Path $script:HotkeyTestDirectory ('popup-live.' + $Name + '.json')
    $state = @{
        processId = $ProcessId; configFingerprint = $Fingerprint; brokerManaged = $true
        popupId = $Name; startedAtTicks = $StartedAtTicks; stackIndex = 0; targetFingerprint = $Name
        expiresAtTicks = [DateTime]::UtcNow.AddMinutes($(if ($Expired) { -1 } else { 5 })).Ticks
    }
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    $foreignPaths = @(
        Save-HotkeyTestState 'foreign' 41099 $foreignFingerprint 1
        Save-HotkeyTestState 'foreign-expired' 41098 $foreignFingerprint 2 -Expired
        Save-HotkeyTestState 'foreign-invalid-pid' 'invalid' $foreignFingerprint 3
    )
    [void](Save-HotkeyTestState 'same-3' 41001 $ownFingerprint 30)
    [void](Save-HotkeyTestState 'same-1' 41001 $ownFingerprint 10)
    [void](Save-HotkeyTestState 'same-2' 41001 $ownFingerprint 20)
    $states = @(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey ($states.Count -eq 3) 'only this configuration supplies hotkey candidates'
    Assert-Hotkey (($states.PopupId -join ',') -eq 'same-1,same-2,same-3') 'candidate age ordering is preserved'
    Assert-Hotkey ($script:OwnershipQueries.Count -eq 1 -and $script:OwnershipQueries[0] -eq 41001) 'same-process cards query ownership once and foreign states never query it'
    foreach ($path in $foreignPaths) {
        Assert-Hotkey (Test-Path -LiteralPath $path) ('another configuration retains ' + [System.IO.Path]::GetFileName($path))
    }

    $script:OwnershipQueries.Clear()
    [void](Save-HotkeyTestState 'different-process' 41002 $ownFingerprint 40)
    $states = @(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey ($states.Count -eq 4) 'different owned processes remain selectable'
    Assert-Hotkey ((($script:OwnershipQueries | Sort-Object) -join ',') -eq '41001,41002') 'each distinct process is queried once per enumeration'

    $script:OwnershipQueries.Clear()
    $script:OwnedProcessIds[41001] = $false
    $states = @(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey ($states.Count -eq 1 -and $states[0].ProcessId -eq 41002) 'ownership is refreshed on the next enumeration'
    Assert-Hotkey (@($script:OwnershipQueries | Where-Object { $_ -eq 41001 }).Count -eq 1) 'failed ownership is also cached only within one enumeration'
    Assert-Hotkey (@(Get-ChildItem -LiteralPath $script:HotkeyTestDirectory -Filter 'popup-live.same-*.json').Count -eq 0) 'stale records from this configuration are removed'
    foreach ($path in $foreignPaths) {
        Assert-Hotkey (Test-Path -LiteralPath $path) ('ownership cleanup preserves ' + [System.IO.Path]::GetFileName($path))
    }

    $script:OwnershipQueries.Clear()
    $firstDeadPath = Save-HotkeyTestState 'dead-1' 41003 $ownFingerprint 50
    $secondDeadPath = Save-HotkeyTestState 'dead-2' 41003 $ownFingerprint 60
    [void]@(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey (@($script:OwnershipQueries | Where-Object { $_ -eq 41003 }).Count -eq 1) 'several dead-process cards perform one ownership query'
    Assert-Hotkey (-not (Test-Path -LiteralPath $firstDeadPath) -and -not (Test-Path -LiteralPath $secondDeadPath)) 'all dead-process cards from this configuration are cleaned'
}
finally {
    Remove-Item -LiteralPath $script:HotkeyTestDirectory -Recurse -Force
}

Write-Output ("Popup hotkey tests passed: {0}" -f $script:PassCount)
