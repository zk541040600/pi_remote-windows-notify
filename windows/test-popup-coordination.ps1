# Exercise actual scheduling functions with isolated cards, without desktop activation.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0
function Assert-Coordination {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}
function Read-CoordinationAst {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
function Get-CoordinationFunctions {
    param($Ast, [string[]]$Names)
    $parts = foreach ($name in $Names) {
        $found = $Ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $found) { throw "Function missing: $name" }
        $found.Extent.Text
    }
    return ($parts -join "`n")
}
$brokerAst = Read-CoordinationAst 'pi-notify-broker.ps1'
function Write-NotifyBrokerLog { param($Message) }
. ([scriptblock]::Create((Get-CoordinationFunctions $brokerAst @('Get-NotifyBrokerPopupSlot'))))

# A failed eviction must not sacrifice a second, unrelated card.
foreach ($closeFails in @($true, $false)) {
    $script:ClosedIds = [System.Collections.Generic.List[string]]::new()
    $script:EvictionFails = $closeFails
    $script:NotifyBrokerActivePopups = @{}
    foreach ($id in @('oldest', 'newer')) {
        $tag = @{ PopupId = $id; TerminalState = [ref]$false }
        $script:NotifyBrokerActivePopups[$id] = [pscustomobject]@{
            PopupId = $id; TargetFingerprint = $id; StackIndex = $script:NotifyBrokerActivePopups.Count
            CreatedAtUtc = [DateTime]::UtcNow.AddSeconds($(if ($id -eq 'oldest') { -2 } else { -1 }))
            Form = [pscustomobject]@{ Tag = $tag }
        }
    }
    function Complete-NotifyBrokerPopupLifecycle {
        param($Tag, $Outcome, $Reason)
        $script:ClosedIds.Add([string]$Tag.PopupId)
        if ($script:EvictionFails -and $Tag.PopupId -eq 'oldest') { return $false }
        $script:NotifyBrokerActivePopups.Remove([string]$Tag.PopupId)
        return $true
    }
    $slot = Get-NotifyBrokerPopupSlot -PopupId 'incoming' -TargetFingerprint 'incoming' -MaxVisible 2
    Assert-Coordination ($slot -eq $(if ($closeFails) { -1 } else { 0 })) "overflow allocation respects eviction result failure=$closeFails"
    Assert-Coordination ($script:ClosedIds.Count -eq 1 -and $script:ClosedIds[0] -eq 'oldest') "overflow attempts only the oldest card failure=$closeFails"
    Assert-Coordination ($script:NotifyBrokerActivePopups.ContainsKey('newer')) "overflow preserves unrelated newer card failure=$closeFails"
}

Write-Output "Popup coordination tests passed: $script:PassCount"
