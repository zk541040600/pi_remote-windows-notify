# Explicit manual helper for Paseo built-in Windows notifications.
# Never auto-run by install/refresh/check. Does not touch services, SSH, or CDP.
# Production registry: HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\electron.app.Paseo
# Production backup:  %USERPROFILE%\.pi-notify\paseo-built-in-notification-state.json
[CmdletBinding(DefaultParameterSetName = 'None')]
param(
    [Parameter(ParameterSetName = 'Disable', Mandatory = $true)]
    [switch]$Disable,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch]$Restore,

    [switch]$Force,

    # Test-only: must stay under HKCU:\ and never allow HKLM / remote hosts.
    [string]$RegistryPath = '',

    # Test-only: optional explicit state path (temp file under user profile/temp).
    [string]$StatePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProductionRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\electron.app.Paseo'
$script:ProductionStateFileName = 'paseo-built-in-notification-state.json'
$script:StateSchemaVersion = 1

function Get-NotifyPaseoBuiltInDefaultStatePath {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is unavailable.'
    }
    return [System.IO.Path]::Combine($env:USERPROFILE, '.pi-notify', $script:ProductionStateFileName)
}

function Assert-NotifyPaseoBuiltInRegistryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $trimmed = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'RegistryPath is empty.'
    }
    if ($trimmed -match '[\\/]{2}') {
        throw 'Remote/UNC registry paths are forbidden.'
    }
    if ($trimmed -match '(?i)^(HKLM|HKEY_LOCAL_MACHINE|HKCR|HKEY_CLASSES_ROOT|HKU|HKEY_USERS|HKCC|HKEY_CURRENT_CONFIG):') {
        throw 'Only HKCU registry paths are allowed.'
    }
    if ($trimmed -notmatch '(?i)^(HKCU|HKEY_CURRENT_USER):\\') {
        throw 'RegistryPath must be an absolute HKCU path.'
    }
    if ($trimmed -match '(?i)HKEY_LOCAL_MACHINE|HKLM:') {
        throw 'HKLM registry paths are forbidden.'
    }
    return $trimmed
}

function Resolve-NotifyPaseoBuiltInRegistryPath {
    param([string]$Override)

    if ([string]::IsNullOrWhiteSpace($Override)) {
        return $script:ProductionRegistryPath
    }
    return (Assert-NotifyPaseoBuiltInRegistryPath -Path $Override)
}

function Resolve-NotifyPaseoBuiltInStatePath {
    param([string]$Override)

    if ([string]::IsNullOrWhiteSpace($Override)) {
        return (Get-NotifyPaseoBuiltInDefaultStatePath)
    }
    $full = [System.IO.Path]::GetFullPath($Override.Trim())
    if ($full -match '(?i)^\\\\') {
        throw 'Remote state paths are forbidden.'
    }

    $allowed = $false
    foreach ($root in @($env:USERPROFILE, $env:TEMP)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootFull = [System.IO.Path]::GetFullPath($root.Trim()).TrimEnd('\')
        if ($full.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) {
        throw 'StatePath override must stay under USERPROFILE or TEMP.'
    }
    return $full
}

function Write-NotifyPaseoBuiltInStateAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    $dir = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw 'State path directory is unavailable.'
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $json = $Payload | ConvertTo-Json -Compress -Depth 4
    $tempPath = $Path + ('.tmp-{0}' -f [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            # PS5.1 converts $null to empty string; File.Replace then throws illegal path.
            [System.IO.File]::Replace($tempPath, $Path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
        $tempPath = ''
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempPath)) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Read-NotifyPaseoBuiltInState {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj) { return $null }
        $version = 0
        if ($obj.PSObject.Properties.Name -contains 'version') {
            $version = [int]$obj.version
        }
        if ($version -ne $script:StateSchemaVersion) {
            throw ('Unsupported built-in notification state version: {0}' -f $version)
        }
        $hadEnabled = $false
        if ($obj.PSObject.Properties.Name -contains 'hadEnabled') {
            $hadEnabled = [bool]$obj.hadEnabled
        }
        $enabledValue = 0
        if ($hadEnabled -and ($obj.PSObject.Properties.Name -contains 'enabledValue')) {
            $enabledValue = [int]$obj.enabledValue
        }
        $registryPath = if ($obj.PSObject.Properties.Name -contains 'registryPath') { [string]$obj.registryPath } else { '' }
        if ([string]::IsNullOrWhiteSpace($registryPath)) {
            throw 'Backup registryPath is missing.'
        }
        return @{
            version = $version
            hadEnabled = $hadEnabled
            enabledValue = $enabledValue
            registryPath = $registryPath
            savedAt = if ($obj.PSObject.Properties.Name -contains 'savedAt') { [string]$obj.savedAt } else { '' }
        }
    }
    catch {
        throw ('Built-in notification backup is unreadable or invalid: {0}' -f $_.Exception.Message)
    }
}

function Get-NotifyPaseoBuiltInEnabledProperty {
    param([Parameter(Mandatory = $true)][string]$RegistryPath)

    $item = Get-Item -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return @{
            KeyExists = $false
            HadEnabled = $false
            EnabledValue = 0
        }
    }

    $names = @($item.GetValueNames())
    $had = $false
    foreach ($name in $names) {
        if ($name -eq 'Enabled') {
            $had = $true
            break
        }
    }
    $value = 0
    if ($had) {
        try {
            $raw = $item.GetValue('Enabled', $null, 'DoNotExpandEnvironmentNames')
            if ($null -ne $raw) {
                $value = [int]$raw
            }
        }
        catch {
            throw ('Unable to read Enabled DWORD under target HKCU key: {0}' -f $_.Exception.Message)
        }
    }
    return @{
        KeyExists = $true
        HadEnabled = $had
        EnabledValue = $value
    }
}

function Ensure-NotifyPaseoBuiltInRegistryKey {
    param([Parameter(Mandatory = $true)][string]$RegistryPath)

    if (Test-Path -LiteralPath $RegistryPath) {
        return
    }
    New-Item -Path $RegistryPath -Force | Out-Null
}

function Save-NotifyPaseoBuiltInOriginalStateOnce {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][hashtable]$Snapshot
    )

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        # Idempotent Disable: never overwrite an existing original backup with 0.
        return (Read-NotifyPaseoBuiltInState -Path $StatePath)
    }

    $payload = @{
        version = $script:StateSchemaVersion
        hadEnabled = [bool]$Snapshot.HadEnabled
        enabledValue = if ([bool]$Snapshot.HadEnabled) { [int]$Snapshot.EnabledValue } else { 0 }
        registryPath = $RegistryPath
        savedAt = (Get-Date).ToUniversalTime().ToString('o')
        origin = 'paseo-built-in-notifications'
    }
    Write-NotifyPaseoBuiltInStateAtomic -Path $StatePath -Payload $payload
    return $payload
}

function Disable-NotifyPaseoBuiltInNotifications {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [switch]$Force
    )

    if (-not $Force) {
        Write-Host 'This helper will disable Paseo built-in Windows notifications (HKCU Enabled=0).'
        Write-Host 'The first Disable call saves the original Enabled presence/value for later Restore.'
        Write-Host 'Install/refresh/check never run this helper. Type DISABLE to continue.'
        $answer = Read-Host 'Confirmation'
        if ($answer -ne 'DISABLE') {
            throw 'Disable cancelled.'
        }
    }

    $before = Get-NotifyPaseoBuiltInEnabledProperty -RegistryPath $RegistryPath
    $backup = Save-NotifyPaseoBuiltInOriginalStateOnce -StatePath $StatePath -RegistryPath $RegistryPath -Snapshot $before
    if (-not ([string]$backup.registryPath).Equals($RegistryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Disable fail-closed: backup belongs to a different registry path.'
    }
    Ensure-NotifyPaseoBuiltInRegistryKey -RegistryPath $RegistryPath
    New-ItemProperty -LiteralPath $RegistryPath -Name 'Enabled' -PropertyType DWord -Value 0 -Force | Out-Null

    $after = Get-NotifyPaseoBuiltInEnabledProperty -RegistryPath $RegistryPath
    if (-not $after.HadEnabled -or [int]$after.EnabledValue -ne 0) {
        throw 'Disable failed: Enabled DWORD is not 0 after write.'
    }

    Write-Host ('OK paseo built-in notifications disabled hadEnabledBackup={0} enabledValueBackup={1}' -f $backup.hadEnabled, $backup.enabledValue)
}

function Restore-NotifyPaseoBuiltInNotifications {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [switch]$Force
    )

    $backup = Read-NotifyPaseoBuiltInState -Path $StatePath
    if ($null -eq $backup) {
        throw 'Restore fail-closed: no built-in notification backup state exists. Registry was not modified.'
    }
    if (-not ([string]$backup.registryPath).Equals($RegistryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Restore fail-closed: backup belongs to a different registry path.'
    }

    if (-not $Force) {
        Write-Host 'This helper will restore Paseo built-in Windows notifications from the saved backup.'
        Write-Host 'Type RESTORE to continue.'
        $answer = Read-Host 'Confirmation'
        if ($answer -ne 'RESTORE') {
            throw 'Restore cancelled.'
        }
    }

    if ([bool]$backup.hadEnabled) {
        Ensure-NotifyPaseoBuiltInRegistryKey -RegistryPath $RegistryPath
        New-ItemProperty -LiteralPath $RegistryPath -Name 'Enabled' -PropertyType DWord -Value ([int]$backup.enabledValue) -Force | Out-Null
        $after = Get-NotifyPaseoBuiltInEnabledProperty -RegistryPath $RegistryPath
        if (-not $after.HadEnabled -or [int]$after.EnabledValue -ne [int]$backup.enabledValue) {
            throw 'Restore failed: Enabled DWORD does not match backup value.'
        }
    }
    else {
        if (Test-Path -LiteralPath $RegistryPath) {
            $current = Get-NotifyPaseoBuiltInEnabledProperty -RegistryPath $RegistryPath
            if ($current.HadEnabled) {
                Remove-ItemProperty -LiteralPath $RegistryPath -Name 'Enabled' -ErrorAction Stop
            }
        }
        $after = Get-NotifyPaseoBuiltInEnabledProperty -RegistryPath $RegistryPath
        if ($after.HadEnabled) {
            throw 'Restore failed: Enabled property still present after remove.'
        }
    }

    try {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
    }
    catch {
        throw ('Registry restored but backup state could not be deleted: {0}' -f $_.Exception.Message)
    }

    Write-Host ('OK paseo built-in notifications restored hadEnabled={0} enabledValue={1}' -f $backup.hadEnabled, $backup.enabledValue)
}

$hasRegistryOverride = -not [string]::IsNullOrWhiteSpace($RegistryPath)
$hasStateOverride = -not [string]::IsNullOrWhiteSpace($StatePath)
if ($hasRegistryOverride -ne $hasStateOverride) {
    throw 'RegistryPath and StatePath test overrides must be provided together.'
}

$resolvedRegistryPath = Resolve-NotifyPaseoBuiltInRegistryPath -Override $RegistryPath
$resolvedStatePath = Resolve-NotifyPaseoBuiltInStatePath -Override $StatePath

if ($Disable) {
    Disable-NotifyPaseoBuiltInNotifications -RegistryPath $resolvedRegistryPath -StatePath $resolvedStatePath -Force:$Force
    return
}

if ($Restore) {
    Restore-NotifyPaseoBuiltInNotifications -RegistryPath $resolvedRegistryPath -StatePath $resolvedStatePath -Force:$Force
    return
}

throw 'Specify -Disable or -Restore.'
