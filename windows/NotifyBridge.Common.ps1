Set-StrictMode -Version Latest
$script:NotifyBridgeActiveConfigPath = $null
$script:NotifyBridgeActiveBaseDir = $null

function Get-NotifyBridgeDefaultBaseDir {
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

function Set-NotifyBridgeActiveConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $baseDir = Split-Path -Parent $resolvedPath
    if ([string]::IsNullOrWhiteSpace($baseDir)) {
        throw "Unable to resolve notify bridge base directory from config path '$ConfigPath'."
    }
    $script:NotifyBridgeActiveConfigPath = $resolvedPath
    $script:NotifyBridgeActiveBaseDir = $baseDir
    return $resolvedPath
}

function Get-NotifyBridgeBaseDir {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($script:NotifyBridgeActiveBaseDir)) {
        return $script:NotifyBridgeActiveBaseDir
    }
    return Get-NotifyBridgeDefaultBaseDir
}

function Get-NotifyBridgeDefaultConfigPath {
    [CmdletBinding()]
    param()

    return [System.IO.Path]::Combine((Get-NotifyBridgeDefaultBaseDir), 'config.json')
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

# Move the selected Windows Terminal tab to its latest visible output without injecting input.
function Set-NotifyBridgeTerminalScrollToBottom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle
    )

    try {
        Start-Sleep -Milliseconds 40
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
        if ($null -eq $root) { return $false }

        $controlTypeCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ScrollBar
        )
        $automationIdCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            'ScrollBar'
        )
        $condition = New-Object System.Windows.Automation.AndCondition(
            $controlTypeCondition,
            $automationIdCondition
        )
        $scrollBar = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($null -eq $scrollBar) { return $false }

        $patternObj = $null
        if (-not $scrollBar.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern, [ref]$patternObj)) {
            return $false
        }

        $rangeValue = [System.Windows.Automation.RangeValuePattern]$patternObj
        if ($rangeValue.Current.IsReadOnly) { return $false }

        $rangeValue.SetValue([double]$rangeValue.Current.Maximum)
        return $true
    }
    catch {
        return $false
    }
}


function ConvertTo-NotifyBridgeProcessArgument {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return '""' }
    $text = [string]$Value
    if ($text.Length -eq 0) { return '""' }
    if ($text -notmatch '[\s"]') { return $text }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashCount += 1
            continue
        }
        if ($ch -eq '"') {
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
            [void]$builder.Append('\"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-NotifyBridgeProcessArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ArgumentList
    )

    return (@($ArgumentList) | ForEach-Object { ConvertTo-NotifyBridgeProcessArgument -Value ([string]$_) }) -join ' '
}

function Clear-NotifyBridgePopupArtifacts {
    [CmdletBinding()]
    param(
        [switch]$Aggressive,
        [int]$MaxAgeMinutes = 10
    )

    $logDir = Get-NotifyBridgeLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { return }

    foreach ($legacyName in @('popup-payload.json', 'popup-dedupe.json', 'popup-stdout.log', 'popup-stderr.log')) {
        Remove-Item -LiteralPath (Join-Path $logDir $legacyName) -Force -ErrorAction SilentlyContinue
    }

    foreach ($pattern in @('popup-stdout.*.log', 'popup-stderr.*.log')) {
        foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $cutoff = (Get-Date).AddMinutes(-[Math]::Max(1, $MaxAgeMinutes))
    foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue)) {
        if ($Aggressive -or $item.LastWriteTime -lt $cutoff) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'popup-payload.*.json' -File -ErrorAction SilentlyContinue)) {
        if ($Aggressive -or $item.LastWriteTime -lt $cutoff) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'popup-dedupe.*.json' -File -ErrorAction SilentlyContinue)) {
        $remove = [bool]$Aggressive -or $item.LastWriteTime -lt $cutoff
        if (-not $remove) {
            try {
                $state = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                $ticks = [int64]0
                if (-not ($state.PSObject.Properties['expiresAtTicks']) -or -not [int64]::TryParse([string]$state.expiresAtTicks, [ref]$ticks) -or $ticks -lt [DateTime]::UtcNow.Ticks) {
                    $remove = $true
                }
            }
            catch { $remove = $true }
        }
        if ($remove) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Aggressive) {
        Remove-Item -LiteralPath (Join-Path $logDir 'popup-cache.json') -Force -ErrorAction SilentlyContinue
    }
}

function Get-NotifyBridgeProtocolName {
    [CmdletBinding()]
    param()

    return 'pi-notify'
}

function Register-NotifyBridgeProtocolHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExe,
        [Parameter(Mandatory = $true)]
        [string]$ActivationScript,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPathValue
    )

    $protocolName = Get-NotifyBridgeProtocolName
    $protocolRoot = ('Registry::HKEY_CURRENT_USER\Software\Classes\{0}' -f $protocolName)
    $commandKey = Join-Path $protocolRoot 'shell\open\command'
    $commandValue = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -ConfigPath "{2}" "%1"' -f $PowerShellExe, $ActivationScript, $ConfigPathValue)

    New-Item -Path $protocolRoot -Force | Out-Null
    Set-Item -Path $protocolRoot -Value ('URL:{0} Protocol' -f $protocolName)
    New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    New-Item -Path $commandKey -Force | Out-Null
    Set-Item -Path $commandKey -Value $commandValue

    return ('{0}://focus' -f $protocolName)
}

function Add-NotifyBridgeShortcutPropertyStoreType {
    [CmdletBinding()]
    param()

    if ('PiNotifyShortcutProperty' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct PROPERTYKEY
{
    public Guid fmtid;
    public uint pid;

    public PROPERTYKEY(Guid fmtid, uint pid)
    {
        this.fmtid = fmtid;
        this.pid = pid;
    }
}

[StructLayout(LayoutKind.Sequential)]
public struct PROPVARIANT
{
    public ushort vt;
    public ushort wReserved1;
    public ushort wReserved2;
    public ushort wReserved3;
    public IntPtr pwszVal;

    public static PROPVARIANT FromString(string value)
    {
        return new PROPVARIANT
        {
            vt = 31,
            pwszVal = Marshal.StringToCoTaskMemUni(value ?? String.Empty)
        };
    }
}

[ComImport]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
public interface IPropertyStore
{
    void GetCount(out uint cProps);
    void GetAt(uint iProp, out PROPERTYKEY pkey);
    void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    void Commit();
}

public static class PiNotifyShortcutProperty
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHGetPropertyStoreFromParsingName(
        string pszPath,
        IntPtr pbc,
        uint flags,
        ref Guid riid,
        out IPropertyStore propertyStore);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    public static void SetAppUserModelId(string shortcutPath, string appId)
    {
        Guid iidPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore store;
        SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, 0x00000002, ref iidPropertyStore, out store);
        PROPERTYKEY appIdKey = new PROPERTYKEY(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
        PROPVARIANT value = PROPVARIANT.FromString(appId);
        try
        {
            store.SetValue(ref appIdKey, ref value);
            store.Commit();
        }
        finally
        {
            PropVariantClear(ref value);
            if (store != null) Marshal.ReleaseComObject(store);
        }
    }
}
'@
}

function Register-NotifyBridgeToastShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BinDir,
        [string]$ToastAppId = 'Pi Remote'
    )

    $noopScript = Join-Path $BinDir 'pi-notify-noop.ps1'
    if (-not (Test-Path -LiteralPath $noopScript)) {
        $noopScript = Join-Path $PSScriptRoot 'pi-notify-noop.ps1'
    }
    $shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Pi Remote.lnk'
    if (-not (Test-Path -LiteralPath $noopScript)) {
        throw ('Toast noop target not found: {0}' -f $noopScript)
    }

    $shortcutArgs = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $noopScript)
    $shortcutIcon = ('{0},0' -f (Get-NotifyBridgePowerShellExe))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $shortcutPath) | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Get-NotifyBridgePowerShellExe
    $shortcut.Arguments = $shortcutArgs
    $shortcut.WorkingDirectory = Get-NotifyBridgeBaseDir
    $shortcut.IconLocation = $shortcutIcon
    $shortcut.Save()

    Add-NotifyBridgeShortcutPropertyStoreType
    [PiNotifyShortcutProperty]::SetAppUserModelId($shortcutPath, $ToastAppId)
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw ('Toast shortcut/AUMID registration failed: {0}' -f $shortcutPath)
    }
    return $shortcutPath
}

function Register-NotifyBridgePopupHotkeyShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExe,
        [Parameter(Mandatory = $true)]
        [string]$HotkeyScript,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPathValue,
        [string]$HotkeyValue = 'Alt+L',
        [bool]$Enabled = $true
    )

    $programsDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $programsDir | Out-Null
    $shortcutPath = Join-Path $programsDir 'Pi Notify Oldest Popup.lnk'
    if (-not $Enabled) {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
        return ''
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $PowerShellExe
    $shortcut.Arguments = Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $HotkeyScript,
        '-ConfigPath', $ConfigPathValue,
        '-Once'
    )
    $shortcut.WorkingDirectory = Split-Path -Parent $HotkeyScript
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Activate the oldest live Pi popup notification target.'
    $shortcut.Hotkey = (Normalize-NotifyBridgePopupHotkey -Value $HotkeyValue).ToUpperInvariant()
    $shortcut.Save()
    return $shortcutPath
}

function Register-NotifyBridgeSystemToastSupport {
    [CmdletBinding()]
    param(
        [string]$ConfigPathValue,
        [string]$ToastAppId = 'Pi Remote'
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPathValue)) {
        if (-not [string]::IsNullOrWhiteSpace($script:NotifyBridgeActiveConfigPath)) {
            $ConfigPathValue = $script:NotifyBridgeActiveConfigPath
        }
        else {
            $ConfigPathValue = Get-NotifyBridgeDefaultConfigPath
        }
    }

    $binDir = Get-NotifyBridgeBinDir
    $activationScript = Join-Path $binDir 'pi-notify-activate.ps1'
    if (-not (Test-Path -LiteralPath $activationScript)) {
        $activationScript = Join-Path $PSScriptRoot 'pi-notify-activate.ps1'
    }
    $powerShellExe = Get-NotifyBridgePowerShellExe
    $protocolUri = Register-NotifyBridgeProtocolHandler -PowerShellExe $powerShellExe -ActivationScript $activationScript -ConfigPathValue $ConfigPathValue
    $shortcutPath = Register-NotifyBridgeToastShortcut -BinDir $binDir -ToastAppId $ToastAppId
    return [pscustomobject]@{
        ProtocolUri  = $protocolUri
        ShortcutPath = $shortcutPath
        AppId        = $ToastAppId
    }
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

function Resolve-NotifyBridgeExecutableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $trimmed
    }

    $hasDirectory = -not [string]::IsNullOrWhiteSpace([System.IO.Path]::GetDirectoryName($trimmed))
    if ([System.IO.Path]::IsPathRooted($trimmed) -or $hasDirectory) {
        return [System.IO.Path]::GetFullPath($trimmed)
    }

    return $trimmed
}

function Test-NotifyBridgeExecutableAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $resolved = Resolve-NotifyBridgeExecutableValue -Value $Value
    if ([string]::IsNullOrWhiteSpace($resolved)) { return $false }
    $hasDirectory = -not [string]::IsNullOrWhiteSpace([System.IO.Path]::GetDirectoryName($resolved))
    if ([System.IO.Path]::IsPathRooted($resolved) -or $hasDirectory) {
        return (Test-Path -LiteralPath $resolved)
    }

    try {
        $null = Get-Command $resolved -ErrorAction Stop
        return $true
    }
    catch {
        return $false
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

function Normalize-NotifyBridgePopupPlacement {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { '' } else { [string]$Value }
    $normalized = $normalized.Trim().ToLowerInvariant()
    if ($normalized -in @('cursor', 'primary', 'right')) {
        return $normalized
    }
    return 'cursor'
}

function Normalize-NotifyBridgePopupHotkey {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { '' } else { [string]$Value.Trim() }
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return 'Alt+L'
    }
    return $normalized
}

function ConvertTo-NotifyBridgeBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('1', 'true', 'yes', 'on')) { return $true }
    if ($text -in @('0', 'false', 'no', 'off')) { return $false }
    return $Default
}

function New-NotifyBridgeToken {
    [CmdletBinding()]
    param(
        [int]$Bytes = 24
    )

    $buffer = [byte[]]::new($Bytes)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    }
    finally {
        if ($null -ne $rng) { $rng.Dispose() }
    }
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
        [int]$PopupTimeoutSeconds,
        [string]$PopupPlacement,
        [int]$PopupMaxVisible,
        [string]$PopupHotkey,
        [bool]$PopupHotkeyEnabled,
        [string]$PopupWallpaperPath,
        [int]$PopupWallpaperOffsetYPixels,
        [bool]$BrokerEnabled,
        [int]$BrokerPort,
        [int]$BrokerStartupTimeoutMs,
        [int]$BrokerRequestTimeoutMs
    )

    $resolvedPath = Set-NotifyBridgeActiveConfigPath -ConfigPath $ConfigPath
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
        23118
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

    $finalSshExecutable = if ($PSBoundParameters.ContainsKey('SshExecutable') -and -not [string]::IsNullOrWhiteSpace($SshExecutable)) {
        Resolve-NotifyBridgeExecutableValue -Value $SshExecutable
    }
    elseif ($existing.ContainsKey('sshExecutable') -and -not [string]::IsNullOrWhiteSpace([string]$existing['sshExecutable']) -and (Test-NotifyBridgeExecutableAvailable -Value ([string]$existing['sshExecutable']))) {
        Resolve-NotifyBridgeExecutableValue -Value ([string]$existing['sshExecutable'])
    }
    else {
        Resolve-NotifyBridgeSshExecutable
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

    $finalTunnelStartupDelaySeconds = if ($PSBoundParameters.ContainsKey('TunnelStartupDelaySeconds') -and $TunnelStartupDelaySeconds -ge 5) {
        $TunnelStartupDelaySeconds
    }
    elseif ($existing.ContainsKey('tunnelStartupDelaySeconds') -and [int]$existing['tunnelStartupDelaySeconds'] -ge 5) {
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
        1800
    }

    $finalPopupPlacement = if ($PSBoundParameters.ContainsKey('PopupPlacement')) {
        Normalize-NotifyBridgePopupPlacement -Value $PopupPlacement
    }
    elseif ($existing.ContainsKey('popupPlacement')) {
        Normalize-NotifyBridgePopupPlacement -Value ([string]$existing['popupPlacement'])
    }
    else {
        'cursor'
    }

    $finalPopupMaxVisible = if ($PSBoundParameters.ContainsKey('PopupMaxVisible') -and $PopupMaxVisible -ge 1) {
        [Math]::Min(8, $PopupMaxVisible)
    }
    elseif ($existing.ContainsKey('popupMaxVisible') -and [int]$existing['popupMaxVisible'] -ge 1) {
        [Math]::Min(8, [int]$existing['popupMaxVisible'])
    }
    else {
        4
    }

    $finalPopupHotkey = if ($PSBoundParameters.ContainsKey('PopupHotkey')) {
        Normalize-NotifyBridgePopupHotkey -Value $PopupHotkey
    }
    elseif ($existing.ContainsKey('popupHotkey')) {
        Normalize-NotifyBridgePopupHotkey -Value ([string]$existing['popupHotkey'])
    }
    else {
        'Alt+L'
    }

    $finalPopupHotkeyEnabled = if ($PSBoundParameters.ContainsKey('PopupHotkeyEnabled')) {
        [bool]$PopupHotkeyEnabled
    }
    elseif ($existing.ContainsKey('popupHotkeyEnabled')) {
        ConvertTo-NotifyBridgeBoolean -Value $existing['popupHotkeyEnabled'] -Default $true
    }
    else {
        $true
    }

    $finalPopupWallpaperPath = if ($PSBoundParameters.ContainsKey('PopupWallpaperPath')) {
        if ([string]::IsNullOrWhiteSpace($PopupWallpaperPath)) { '' } else { [System.IO.Path]::GetFullPath($PopupWallpaperPath.Trim()) }
    }
    elseif ($existing.ContainsKey('popupWallpaperPath') -and -not [string]::IsNullOrWhiteSpace([string]$existing['popupWallpaperPath'])) {
        [string]$existing['popupWallpaperPath']
    }
    else {
        $bundledWallpaper = Join-Path (Get-NotifyBridgeBinDir) 'popup-wallpaper.png'
        $sourceWallpaper = Join-Path $PSScriptRoot 'popup-wallpaper.png'
        if ((Test-Path -LiteralPath $bundledWallpaper) -or (Test-Path -LiteralPath $sourceWallpaper)) { $bundledWallpaper } else { '' }
    }

    $finalPopupWallpaperOffsetYPixels = if ($PSBoundParameters.ContainsKey('PopupWallpaperOffsetYPixels')) {
        [Math]::Min(200, [Math]::Max(-200, [int]$PopupWallpaperOffsetYPixels))
    }
    elseif ($existing.ContainsKey('popupWallpaperOffsetYPixels')) {
        [Math]::Min(200, [Math]::Max(-200, [int]$existing['popupWallpaperOffsetYPixels']))
    }
    else {
        0
    }

    $finalBrokerEnabled = if ($PSBoundParameters.ContainsKey('BrokerEnabled')) {
        [bool]$BrokerEnabled
    }
    elseif ($existing.ContainsKey('brokerEnabled')) {
        ConvertTo-NotifyBridgeBoolean -Value $existing['brokerEnabled'] -Default $true
    }
    else {
        $true
    }

    $finalBrokerPort = if ($PSBoundParameters.ContainsKey('BrokerPort') -and $BrokerPort -gt 0) {
        $BrokerPort
    }
    elseif ($existing.ContainsKey('brokerPort') -and [int]$existing['brokerPort'] -gt 0) {
        [int]$existing['brokerPort']
    }
    else {
        23119
    }

    $finalBrokerStartupTimeoutMs = if ($PSBoundParameters.ContainsKey('BrokerStartupTimeoutMs') -and $BrokerStartupTimeoutMs -ge 100) {
        $BrokerStartupTimeoutMs
    }
    elseif ($existing.ContainsKey('brokerStartupTimeoutMs') -and [int]$existing['brokerStartupTimeoutMs'] -ge 100) {
        [int]$existing['brokerStartupTimeoutMs']
    }
    else {
        700
    }

    $finalBrokerRequestTimeoutMs = if ($PSBoundParameters.ContainsKey('BrokerRequestTimeoutMs') -and $BrokerRequestTimeoutMs -ge 100) {
        $BrokerRequestTimeoutMs
    }
    elseif ($existing.ContainsKey('brokerRequestTimeoutMs') -and [int]$existing['brokerRequestTimeoutMs'] -ge 100) {
        [int]$existing['brokerRequestTimeoutMs']
    }
    else {
        700
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
        popupPlacement            = $finalPopupPlacement
        popupMaxVisible           = $finalPopupMaxVisible
        popupHotkey               = $finalPopupHotkey
        popupHotkeyEnabled        = $finalPopupHotkeyEnabled
        popupWallpaperPath        = $finalPopupWallpaperPath
        popupWallpaperOffsetYPixels = $finalPopupWallpaperOffsetYPixels
        brokerEnabled              = $finalBrokerEnabled
        brokerPort                 = $finalBrokerPort
        brokerStartupTimeoutMs     = $finalBrokerStartupTimeoutMs
        brokerRequestTimeoutMs     = $finalBrokerRequestTimeoutMs
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
        PopupPlacement            = $config.popupPlacement
        PopupMaxVisible           = $config.popupMaxVisible
        PopupHotkey               = $config.popupHotkey
        PopupHotkeyEnabled        = $config.popupHotkeyEnabled
        PopupWallpaperPath        = $config.popupWallpaperPath
        PopupWallpaperOffsetYPixels = $config.popupWallpaperOffsetYPixels
        BrokerEnabled              = $config.brokerEnabled
        BrokerPort                 = $config.brokerPort
        BrokerStartupTimeoutMs     = $config.brokerStartupTimeoutMs
        BrokerRequestTimeoutMs     = $config.brokerRequestTimeoutMs
        BrokerUrl                  = ('http://127.0.0.1:{0}' -f $config.brokerPort)
        BrokerHealthUrl            = ('http://127.0.0.1:{0}/health' -f $config.brokerPort)
        BrokerPopupUrl             = ('http://127.0.0.1:{0}/popup' -f $config.brokerPort)
        BrokerCloseUrl             = ('http://127.0.0.1:{0}/close' -f $config.brokerPort)
    }
}
