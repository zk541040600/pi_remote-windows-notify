# Explicit deployment helper for Paseo desktop CDP routing.
# Never auto-run by install/refresh. Does not terminate or restart Paseo.
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Enable', Mandatory = $true)]
    [switch]$Enable,

    [Parameter(ParameterSetName = 'Disable', Mandatory = $true)]
    [switch]$Disable,

    [string]$ConfigPath = '',
    [int]$CdpPort = 0,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"
. "$PSScriptRoot/paseo-desktop-route.ps1"

function Get-NotifyUserEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-NotifyUserEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Value
    )
    if ($null -eq $Value) {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    }
}

function Get-NotifyPaseoElectronFlagTokens {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Set-NotifyPaseoElectronRemoteDebuggingFlag {
    param(
        [string]$ExistingFlags,
        [Parameter(Mandatory = $true)][int]$Port,
        [switch]$Remove
    )

    $tokens = @(Get-NotifyPaseoElectronFlagTokens -Value $ExistingFlags)
    $filtered = @()
    foreach ($token in $tokens) {
        if ($token -match '^--remote-debugging-port(=|$)') { continue }
        if ($token -match '^--remote-debugging-address(=|$)') { continue }
        $filtered += $token
    }
    if (-not $Remove) {
        $filtered += ('--remote-debugging-port={0}' -f $Port)
        $filtered += '--remote-debugging-address=127.0.0.1'
    }
    return (($filtered -join ' ').Trim())
}

$configArgs = @{}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $configArgs.ConfigPath = $ConfigPath
}
$config = Ensure-NotifyBridgeConfig @configArgs
$configPathResolved = [string]$config.ConfigPath
$rawConfig = @{}
if (Test-Path -LiteralPath $configPathResolved) {
    $raw = Get-Content -Raw -LiteralPath $configPathResolved
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $rawConfig = ConvertTo-NotifyBridgeHashtable ($raw | ConvertFrom-Json)
    }
}

$targetPort = if ($CdpPort -gt 0) { $CdpPort } else { [int]$config.PaseoCdpPort }
if ($targetPort -lt 1024 -or $targetPort -gt 65535 -or $targetPort -eq [int]$config.Port -or $targetPort -eq [int]$config.BrokerPort) {
    throw ('Invalid paseo CDP port {0}; must be a high port and not equal listener/broker ports.' -f $targetPort)
}

$backupKey = 'paseoElectronFlagsBackup'
$currentFlags = Get-NotifyUserEnvironmentValue -Name 'PASEO_ELECTRON_FLAGS'
if ($null -eq $currentFlags) { $currentFlags = '' }

if ($Enable) {
    if (-not $Force) {
        Write-Host 'This helper will persist user-level PASEO_ELECTRON_FLAGS for loopback CDP only.'
        Write-Host 'It will NOT terminate or restart Paseo. Restart Paseo manually after enable.'
        Write-Host ('CDP port: {0}' -f $targetPort)
        $answer = Read-Host 'Type ENABLE to continue'
        if ($answer -ne 'ENABLE') {
            throw 'Enable cancelled.'
        }
    }

    if (-not $rawConfig.ContainsKey($backupKey)) {
        $rawConfig[$backupKey] = $currentFlags
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    $paseoExecutablePath = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\Paseo\Paseo.exe'))
    if (-not (Test-Path -LiteralPath $paseoExecutablePath -PathType Leaf)) {
        throw 'Standard Paseo executable was not found.'
    }

    # A free port must be proven empty. Probe/cmdlet/access uncertainty fails closed;
    # an occupied port is allowed only for the exact loopback standard Paseo binary.
    $owner = Get-NotifyPaseoCdpOwnerSnapshot -Port $targetPort -Config @{ paseoExecutablePath = $paseoExecutablePath }
    if (-not $owner.Available -and [string]$owner.Reason -ne 'no-listener') {
        throw ('Paseo CDP port {0} failed loopback/owner verification ({1}).' -f $targetPort, $owner.Result)
    }

    $updatedFlags = Set-NotifyPaseoElectronRemoteDebuggingFlag -ExistingFlags $currentFlags -Port $targetPort
    try {
        Set-NotifyUserEnvironmentValue -Name 'PASEO_ELECTRON_FLAGS' -Value $updatedFlags
        $rawConfig['paseoDesktopRoutingEnabled'] = $true
        $rawConfig['paseoCdpPort'] = $targetPort
        $rawConfig['paseoExecutablePath'] = $paseoExecutablePath
        [void](Save-NotifyBridgeConfig -ConfigPath $configPathResolved -Config $rawConfig)
    }
    catch {
        Set-NotifyUserEnvironmentValue -Name 'PASEO_ELECTRON_FLAGS' -Value $currentFlags
        throw
    }

    Write-Host ('OK paseo desktop routing enabled port={0}' -f $targetPort)
    Write-Host 'Restart Paseo manually for flags to take effect. Notification clicks never set flags.'
    exit 0
}

if ($Disable) {
    if (-not $Force) {
        Write-Host 'This helper will disable paseo desktop routing and restore prior PASEO_ELECTRON_FLAGS when known.'
        Write-Host 'It will NOT terminate or restart Paseo.'
        $answer = Read-Host 'Type DISABLE to continue'
        if ($answer -ne 'DISABLE') {
            throw 'Disable cancelled.'
        }
    }

    $restore = ''
    if ($rawConfig.ContainsKey($backupKey)) {
        $restore = [string]$rawConfig[$backupKey]
        $rawConfig.Remove($backupKey)
    }
    else {
        $restore = Set-NotifyPaseoElectronRemoteDebuggingFlag -ExistingFlags $currentFlags -Port $targetPort -Remove
    }

    try {
        if ([string]::IsNullOrWhiteSpace($restore)) {
            Set-NotifyUserEnvironmentValue -Name 'PASEO_ELECTRON_FLAGS' -Value $null
        }
        else {
            Set-NotifyUserEnvironmentValue -Name 'PASEO_ELECTRON_FLAGS' -Value $restore
        }

        $rawConfig['paseoDesktopRoutingEnabled'] = $false
        if (-not $rawConfig.ContainsKey('paseoCdpPort')) {
            $rawConfig['paseoCdpPort'] = 29318
        }
        [void](Save-NotifyBridgeConfig -ConfigPath $configPathResolved -Config $rawConfig)
    }
    catch {
        Set-NotifyUserEnvironmentValue -Name 'PASEO_ELECTRON_FLAGS' -Value $currentFlags
        throw
    }

    Write-Host 'OK paseo desktop routing disabled'
    Write-Host 'Restart Paseo manually if a previous CDP flag was active.'
    exit 0
}

throw 'Specify -Enable or -Disable.'
