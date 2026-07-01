Set-StrictMode -Version Latest

function Get-NotifyBridgeBaseDir {
    [CmdletBinding()]
    param()

    $base = if ($env:USERPROFILE) {
        $env:USERPROFILE
    }
    elseif ($HOME) {
        $HOME
    }
    else {
        throw "Unable to resolve USERPROFILE/HOME for notify bridge config."
    }

    return [System.IO.Path]::Combine($base, '.pi-notify')
}

function Get-NotifyBridgeDefaultConfigPath {
    [CmdletBinding()]
    param()

    return [System.IO.Path]::Combine((Get-NotifyBridgeBaseDir), 'config.json')
}

function Get-NotifyBridgeBinDir {
    [CmdletBinding()]
    param()

    return [System.IO.Path]::Combine((Get-NotifyBridgeBaseDir), 'bin')
}

function Get-NotifyBridgeLogDir {
    [CmdletBinding()]
    param()

    return [System.IO.Path]::Combine((Get-NotifyBridgeBaseDir), 'logs')
}

function Get-NotifyBridgePowerShellExe {
    [CmdletBinding()]
    param()

    $paths = @(
        [System.IO.Path]::Combine($env:WINDIR, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        'powershell.exe'
    )

    foreach ($candidate in $paths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    try {
        return (Get-Command powershell.exe -ErrorAction Stop).Source
    }
    catch {
        throw 'Unable to locate powershell.exe for Pi notify bridge startup.'
    }
}

function Get-NotifyBridgeProtocolName {
    [CmdletBinding()]
    param()

    return 'pi-notify'
}

function Resolve-NotifyBridgeWtExecutable {
    [CmdletBinding()]
    param()

    try {
        $command = Get-Command wt.exe -ErrorAction Stop
        if ($command.Source) {
            return $command.Source
        }
    }
    catch {
    }

    return 'wt.exe'
}

function Resolve-NotifyBridgeSshExecutable {
    [CmdletBinding()]
    param()

    $candidates = @(
        [System.IO.Path]::Combine($env:WINDIR, 'System32', 'OpenSSH', 'ssh.exe'),
        [System.IO.Path]::Combine($env:ProgramFiles, 'Git', 'usr', 'bin', 'ssh.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs', 'Git', 'usr', 'bin', 'ssh.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Atlassian', 'SourceTree', 'git_local', 'usr', 'bin', 'ssh.exe')
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    try {
        return (Get-Command ssh.exe -ErrorAction Stop).Source
    }
    catch {
        throw 'Unable to locate ssh.exe for Pi notify bridge tunnel.'
    }
}

function Normalize-NotifyBridgeDisplayMode {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { '' } else { [string]$Value }
    $normalized = $normalized.Trim().ToLowerInvariant()
    if ($normalized -eq 'popup-focus') {
        return 'popup-focus'
    }
    return 'system-toast'
}

function New-NotifyBridgeToken {
    [CmdletBinding()]
    param(
        [int]$Bytes = 24
    )

    $buffer = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    return ([Convert]::ToBase64String($buffer).TrimEnd('=' )).Replace('+', '-').Replace('/', '_')
}

function ConvertTo-NotifyBridgeHashtable {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return @{}
    }

    $table = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }
    return $table
}

function Save-NotifyBridgeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $directory = Split-Path -Parent $resolvedPath
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($resolvedPath, $json, [System.Text.UTF8Encoding]::new($false))
    return $resolvedPath
}

function Ensure-NotifyBridgeConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Get-NotifyBridgeDefaultConfigPath),
        [string]$ListenHost,
        [int]$Port,
        [string]$Token,
        [string]$RemoteHostAlias,
        [string]$SshExecutable,
        [int]$TunnelRetryDelaySeconds,
        [int]$TunnelStartupDelaySeconds,
        [string]$DisplayMode,
        [int]$PopupTimeoutSeconds
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $existing = @{}

    if (Test-Path -LiteralPath $resolvedPath) {
        $raw = Get-Content -Raw -LiteralPath $resolvedPath
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $existing = ConvertTo-NotifyBridgeHashtable ($raw | ConvertFrom-Json)
            }
            catch {
                throw "Failed to parse notify bridge config '$resolvedPath': $($_.Exception.Message)"
            }
        }
    }

    $finalHost = if ($PSBoundParameters.ContainsKey('ListenHost') -and -not [string]::IsNullOrWhiteSpace($ListenHost)) {
        $ListenHost.Trim()
    }
    elseif ($existing.ContainsKey('listenHost') -and -not [string]::IsNullOrWhiteSpace([string]$existing['listenHost'])) {
        [string]$existing['listenHost']
    }
    else {
        '127.0.0.1'
    }

    $finalPort = if ($PSBoundParameters.ContainsKey('Port') -and $Port -gt 0) {
        $Port
    }
    elseif ($existing.ContainsKey('port') -and [int]$existing['port'] -gt 0) {
        [int]$existing['port']
    }
    else {
        23117
    }

    $finalToken = if ($PSBoundParameters.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace($Token)) {
        $Token.Trim()
    }
    elseif ($existing.ContainsKey('token') -and -not [string]::IsNullOrWhiteSpace([string]$existing['token'])) {
        [string]$existing['token']
    }
    else {
        New-NotifyBridgeToken
    }

    $finalRemoteHostAlias = if ($PSBoundParameters.ContainsKey('RemoteHostAlias') -and -not [string]::IsNullOrWhiteSpace($RemoteHostAlias)) {
        $RemoteHostAlias.Trim()
    }
    elseif ($existing.ContainsKey('remoteHostAlias') -and -not [string]::IsNullOrWhiteSpace([string]$existing['remoteHostAlias'])) {
        [string]$existing['remoteHostAlias']
    }
    else {
        'my'
    }

    $detectedSsh = Resolve-NotifyBridgeSshExecutable
    $finalSshExecutable = if ($PSBoundParameters.ContainsKey('SshExecutable') -and -not [string]::IsNullOrWhiteSpace($SshExecutable)) {
        [System.IO.Path]::GetFullPath($SshExecutable)
    }
    elseif ($existing.ContainsKey('sshExecutable') -and -not [string]::IsNullOrWhiteSpace([string]$existing['sshExecutable']) -and (Test-Path -LiteralPath ([string]$existing['sshExecutable']))) {
        [System.IO.Path]::GetFullPath([string]$existing['sshExecutable'])
    }
    else {
        $detectedSsh
    }

    $finalTunnelRetryDelaySeconds = if ($PSBoundParameters.ContainsKey('TunnelRetryDelaySeconds') -and $TunnelRetryDelaySeconds -ge 1) {
        $TunnelRetryDelaySeconds
    }
    elseif ($existing.ContainsKey('tunnelRetryDelaySeconds') -and [int]$existing['tunnelRetryDelaySeconds'] -ge 1) {
        [int]$existing['tunnelRetryDelaySeconds']
    }
    else {
        5
    }

    $finalTunnelStartupDelaySeconds = if ($PSBoundParameters.ContainsKey('TunnelStartupDelaySeconds') -and $TunnelStartupDelaySeconds -ge 0) {
        $TunnelStartupDelaySeconds
    }
    elseif ($existing.ContainsKey('tunnelStartupDelaySeconds') -and [int]$existing['tunnelStartupDelaySeconds'] -ge 0) {
        [int]$existing['tunnelStartupDelaySeconds']
    }
    else {
        15
    }

    $finalDisplayMode = if ($PSBoundParameters.ContainsKey('DisplayMode')) {
        Normalize-NotifyBridgeDisplayMode -Value $DisplayMode
    }
    elseif ($existing.ContainsKey('displayMode')) {
        Normalize-NotifyBridgeDisplayMode -Value ([string]$existing['displayMode'])
    }
    else {
        'system-toast'
    }

    $finalPopupTimeoutSeconds = if ($PSBoundParameters.ContainsKey('PopupTimeoutSeconds') -and $PopupTimeoutSeconds -ge 3) {
        $PopupTimeoutSeconds
    }
    elseif ($existing.ContainsKey('popupTimeoutSeconds') -and [int]$existing['popupTimeoutSeconds'] -ge 3) {
        [int]$existing['popupTimeoutSeconds']
    }
    else {
        18
    }

    $config = @{
        listenHost                = $finalHost
        port                      = $finalPort
        token                     = $finalToken
        localUrl                  = ('http://{0}:{1}/notify' -f $finalHost, $finalPort)
        remoteUrl                 = ('http://127.0.0.1:{0}/notify' -f $finalPort)
        remoteHostAlias           = $finalRemoteHostAlias
        sshExecutable             = $finalSshExecutable
        tunnelRetryDelaySeconds   = $finalTunnelRetryDelaySeconds
        tunnelStartupDelaySeconds = $finalTunnelStartupDelaySeconds
        displayMode               = $finalDisplayMode
        popupTimeoutSeconds       = $finalPopupTimeoutSeconds
        updatedAtUtc              = [DateTime]::UtcNow.ToString('o')
    }

    $savedPath = Save-NotifyBridgeConfig -ConfigPath $resolvedPath -Config $config

    return [pscustomobject]@{
        ConfigPath                = $savedPath
        ListenHost                = $config.listenHost
        Port                      = $config.port
        Token                     = $config.token
        LocalUrl                  = $config.localUrl
        RemoteUrl                 = $config.remoteUrl
        RemoteHostAlias           = $config.remoteHostAlias
        SshExecutable             = $config.sshExecutable
        TunnelRetryDelaySeconds   = $config.tunnelRetryDelaySeconds
        TunnelStartupDelaySeconds = $config.tunnelStartupDelaySeconds
        DisplayMode               = $config.displayMode
        PopupTimeoutSeconds       = $config.popupTimeoutSeconds
    }
}
