Set-StrictMode -Version Latest
$script:NotifyBridgeActiveConfigPath = $null
$script:NotifyBridgeActiveBaseDir = $null

# DPAPI helpers (Paseo activation cache) require System.Security on Windows PowerShell 5.1.
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch {}

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
        [int]$BrokerRequestTimeoutMs,
        [bool]$QqNotifyEnabled,
        [string]$QqNodeExecutable,
        [string]$QqSenderScript,
        [int]$QqSendTimeoutSeconds,
        [int]$QqMaxConcurrent
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

    $finalQqNotifyEnabled = if ($PSBoundParameters.ContainsKey('QqNotifyEnabled')) {
        [bool]$QqNotifyEnabled
    }
    elseif ($existing.ContainsKey('qqNotifyEnabled')) {
        ConvertTo-NotifyBridgeBoolean -Value $existing['qqNotifyEnabled'] -Default $false
    }
    else {
        $false
    }

    $finalQqNodeExecutable = if ($PSBoundParameters.ContainsKey('QqNodeExecutable') -and -not [string]::IsNullOrWhiteSpace($QqNodeExecutable)) {
        Resolve-NotifyBridgeExecutableValue -Value $QqNodeExecutable
    }
    elseif ($existing.ContainsKey('qqNodeExecutable') -and -not [string]::IsNullOrWhiteSpace([string]$existing['qqNodeExecutable'])) {
        Resolve-NotifyBridgeExecutableValue -Value ([string]$existing['qqNodeExecutable'])
    }
    else {
        'node.exe'
    }

    $finalQqSenderScript = if ($PSBoundParameters.ContainsKey('QqSenderScript') -and -not [string]::IsNullOrWhiteSpace($QqSenderScript)) {
        $QqSenderScript.Trim()
    }
    elseif ($existing.ContainsKey('qqSenderScript') -and -not [string]::IsNullOrWhiteSpace([string]$existing['qqSenderScript'])) {
        ([string]$existing['qqSenderScript']).Trim()
    }
    else {
        ''
    }

    $finalQqSendTimeoutSeconds = if ($PSBoundParameters.ContainsKey('QqSendTimeoutSeconds') -and $QqSendTimeoutSeconds -ge 1) {
        [Math]::Min(120, $QqSendTimeoutSeconds)
    }
    elseif ($existing.ContainsKey('qqSendTimeoutSeconds') -and [int]$existing['qqSendTimeoutSeconds'] -ge 1) {
        [Math]::Min(120, [int]$existing['qqSendTimeoutSeconds'])
    }
    else {
        20
    }

    $finalQqMaxConcurrent = if ($PSBoundParameters.ContainsKey('QqMaxConcurrent') -and $QqMaxConcurrent -ge 1) {
        [Math]::Min(8, $QqMaxConcurrent)
    }
    elseif ($existing.ContainsKey('qqMaxConcurrent') -and [int]$existing['qqMaxConcurrent'] -ge 1) {
        [Math]::Min(8, [int]$existing['qqMaxConcurrent'])
    }
    else {
        2
    }

    $finalRouteHostExe = ''
    if ($existing.ContainsKey('routeHostExe') -and -not [string]::IsNullOrWhiteSpace([string]$existing['routeHostExe'])) {
        $finalRouteHostExe = [string]$existing['routeHostExe']
    }
    elseif ($existing.ContainsKey('RouteHostExe') -and -not [string]::IsNullOrWhiteSpace([string]$existing['RouteHostExe'])) {
        $finalRouteHostExe = [string]$existing['RouteHostExe']
    }

    $finalPaseoDesktopRoutingEnabled = if ($existing.ContainsKey('paseoDesktopRoutingEnabled')) {
        ConvertTo-NotifyBridgeBoolean -Value $existing['paseoDesktopRoutingEnabled'] -Default $false
    }
    else {
        $false
    }

    $finalPaseoExecutablePath = ''
    if ($existing.ContainsKey('paseoExecutablePath') -and -not [string]::IsNullOrWhiteSpace([string]$existing['paseoExecutablePath'])) {
        $finalPaseoExecutablePath = ([string]$existing['paseoExecutablePath']).Trim()
    }

    $defaultPaseoCdpPort = 29318
    $finalPaseoCdpPort = if ($existing.ContainsKey('paseoCdpPort') -and [int]$existing['paseoCdpPort'] -gt 0) {
        [int]$existing['paseoCdpPort']
    }
    else {
        $defaultPaseoCdpPort
    }
    # Keep CDP out of the listener/broker public ports and well-known privileged range.
    if ($finalPaseoCdpPort -lt 1024 -or $finalPaseoCdpPort -gt 65535 -or $finalPaseoCdpPort -eq $finalPort -or $finalPaseoCdpPort -eq $finalBrokerPort) {
        $finalPaseoCdpPort = @(@($defaultPaseoCdpPort, 29319, 29320) | Where-Object { $_ -ne $finalPort -and $_ -ne $finalBrokerPort } | Select-Object -First 1)[0]
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
        qqNotifyEnabled            = $finalQqNotifyEnabled
        qqNodeExecutable           = $finalQqNodeExecutable
        qqSenderScript             = $finalQqSenderScript
        qqSendTimeoutSeconds       = $finalQqSendTimeoutSeconds
        qqMaxConcurrent            = $finalQqMaxConcurrent
        paseoDesktopRoutingEnabled = $finalPaseoDesktopRoutingEnabled
        paseoExecutablePath        = $finalPaseoExecutablePath
        paseoCdpPort               = $finalPaseoCdpPort
        updatedAtUtc               = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($key in $existing.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $existing[$key]
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($finalRouteHostExe)) {
        $config['routeHostExe'] = $finalRouteHostExe
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
        QqNotifyEnabled            = $config.qqNotifyEnabled
        QqNodeExecutable           = $config.qqNodeExecutable
        QqSenderScript             = $config.qqSenderScript
        QqSendTimeoutSeconds       = $config.qqSendTimeoutSeconds
        QqMaxConcurrent            = $config.qqMaxConcurrent
        RouteHostExe               = $finalRouteHostExe
        PaseoDesktopRoutingEnabled = [bool]$config.paseoDesktopRoutingEnabled
        PaseoExecutablePath        = [string]$config.paseoExecutablePath
        PaseoCdpPort               = [int]$config.paseoCdpPort
        PaseoLeaseGateEnabled      = if ($config.ContainsKey('paseoLeaseGateEnabled')) { ConvertTo-NotifyBridgeBoolean -Value $config.paseoLeaseGateEnabled -Default $false } else { $false }
        PaseoLeasePath             = if ($config.ContainsKey('paseoLeasePath')) { [string]$config.paseoLeasePath } else { '' }
        BrokerUrl                  = ('http://127.0.0.1:{0}' -f $config.brokerPort)
        BrokerHealthUrl            = ('http://127.0.0.1:{0}/health' -f $config.brokerPort)
        BrokerPopupUrl             = ('http://127.0.0.1:{0}/popup' -f $config.brokerPort)
        BrokerCloseUrl             = ('http://127.0.0.1:{0}/close' -f $config.brokerPort)
    }
}

# --- Exact-route helpers (PiNotifyRouteHost client) ---------------------------------

if (-not (Get-Variable -Name NotifyRouteHostClientMock -Scope Script -ErrorAction SilentlyContinue)) {
    $script:NotifyRouteHostClientMock = $null
}

function Get-NotifyRouteFingerprint {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Value))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant().Substring(0, 16))
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NotifyUnixTimeMilliseconds {
    [CmdletBinding()]
    param()

    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-NotifyRouteHostExe {
    [CmdletBinding()]
    param($Config = $null)

    if (-not [string]::IsNullOrWhiteSpace($env:PI_NOTIFY_ROUTE_HOST_EXE)) {
        return $env:PI_NOTIFY_ROUTE_HOST_EXE.Trim()
    }
    if ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('routeHostExe') -and -not [string]::IsNullOrWhiteSpace([string]$Config['routeHostExe'])) {
                return [string]$Config['routeHostExe']
            }
            if ($Config.ContainsKey('RouteHostExe') -and -not [string]::IsNullOrWhiteSpace([string]$Config['RouteHostExe'])) {
                return [string]$Config['RouteHostExe']
            }
        }
        elseif ($Config.PSObject -and $Config.PSObject.Properties['RouteHostExe'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.RouteHostExe)) {
            return [string]$Config.RouteHostExe
        }
        elseif ($Config.PSObject -and $Config.PSObject.Properties['routeHostExe'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.routeHostExe)) {
            return [string]$Config.routeHostExe
        }
    }
    $localApp = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localApp)) {
        $localApp = [System.IO.Path]::Combine((Get-NotifyBridgeDefaultBaseDir), '..')
    }
    return [System.IO.Path]::Combine($localApp, 'PiNotifyRouteHost', 'PiNotifyRouteHost.exe')
}

function Test-NotifyRouteUuid {
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function Test-NotifyRouteHexKey {
    [CmdletBinding()]
    param(
        [string]$Value,
        [int]$Length = 64
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -ne $Length) { return $false }
    return ($Value -match '^[0-9a-fA-F]+$')
}

function Test-NotifyRouteInstanceKey {
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -lt 8 -or $Value.Length -gt 128) { return $false }
    return ($Value -match '^[A-Za-z0-9._+-]+$')
}

function Resolve-NotifyBridgePiWebInstanceKey {
    [CmdletBinding()]
    param(
        [string]$InstanceKey,
        [string]$RouteConfigPath
    )

    if (-not [string]::IsNullOrEmpty($InstanceKey)) {
        $normalized = $InstanceKey -replace '^[\x09-\x0D\x20]+|[\x09-\x0D\x20]+$', ''
        if (-not (Test-NotifyRouteInstanceKey -Value $normalized)) {
            throw 'Pi Web instanceKey is invalid.'
        }
        return $normalized
    }

    if ([string]::IsNullOrWhiteSpace($RouteConfigPath)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            return ''
        }
        $RouteConfigPath = [System.IO.Path]::Combine(
            $env:LOCALAPPDATA,
            'PiWebDesktop',
            'route-config.json')
    }

    if (-not (Test-Path -LiteralPath $RouteConfigPath -PathType Leaf)) {
        return ''
    }

    try {
        $routeConfig = [System.IO.File]::ReadAllText($RouteConfigPath) |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "PiWebDesktop route config is unreadable: $RouteConfigPath"
    }

    if ($null -eq $routeConfig -or
        -not $routeConfig.PSObject.Properties['instanceKey'] -or
        -not (Test-NotifyRouteInstanceKey -Value ([string]$routeConfig.instanceKey))) {
        throw 'PiWebDesktop route config contains an invalid instanceKey.'
    }

    return [string]$routeConfig.instanceKey
}

function New-NotifyBridgeRemoteConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$RemoteHostAlias,
        [string]$PiWebInstanceKey
    )

    $remoteConfig = [ordered]@{
        enabled         = $true
        endpoint        = $Endpoint
        token           = $Token
        timeoutMs       = 4000
        title           = 'Pi'
        bodyTemplate    = 'host: {host} | cwd: {cwdBase}'
        messageMode     = 'dynamic'
        remoteHostAlias = $RemoteHostAlias
    }

    if (-not [string]::IsNullOrWhiteSpace($PiWebInstanceKey)) {
        if (-not (Test-NotifyRouteInstanceKey -Value $PiWebInstanceKey)) {
            throw 'Pi Web instanceKey is invalid.'
        }
        $remoteConfig['originKind'] = 'pi-web'
        $remoteConfig['instanceKey'] = $PiWebInstanceKey
    }

    return $remoteConfig
}

function Get-NotifyPayloadStringField {
    [CmdletBinding()]
    param(
        $Payload,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Payload) { return '' }
    if (-not $Payload.PSObject.Properties[$Name]) { return '' }
    $text = [string]$Payload.$Name
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    return $text.Trim()
}

<#
.SYNOPSIS
  Validate optional exact-route fields from a notify payload.
.OUTPUTS
  PSCustomObject with:
    HasAnyRouteField, IsValidPiWebExact, OriginKind, NotificationId, NotificationKind,
    InstanceKey, RoutingKey, RouteVersion, InvalidReason
#>
function Resolve-NotifyExactRouteMetadata {
    [CmdletBinding()]
    param($Payload)

    $routeVersionRaw = Get-NotifyPayloadStringField -Payload $Payload -Name 'routeVersion'
    $notificationId = Get-NotifyPayloadStringField -Payload $Payload -Name 'notificationId'
    $notificationKind = Get-NotifyPayloadStringField -Payload $Payload -Name 'notificationKind'
    $originKind = Get-NotifyPayloadStringField -Payload $Payload -Name 'originKind'
    $instanceKey = Get-NotifyPayloadStringField -Payload $Payload -Name 'instanceKey'
    $routingKey = Get-NotifyPayloadStringField -Payload $Payload -Name 'routingKey'

    # Also accept numeric routeVersion from JSON
    if ([string]::IsNullOrWhiteSpace($routeVersionRaw) -and $null -ne $Payload -and $Payload.PSObject.Properties['routeVersion']) {
        try { $routeVersionRaw = [string]$Payload.routeVersion } catch { $routeVersionRaw = '' }
    }

    $hasAny = -not (
        [string]::IsNullOrWhiteSpace($routeVersionRaw) -and
        [string]::IsNullOrWhiteSpace($notificationId) -and
        [string]::IsNullOrWhiteSpace($notificationKind) -and
        [string]::IsNullOrWhiteSpace($originKind) -and
        [string]::IsNullOrWhiteSpace($instanceKey) -and
        [string]::IsNullOrWhiteSpace($routingKey)
    )

    $result = [pscustomobject]@{
        HasAnyRouteField   = $hasAny
        IsValidPiWebExact  = $false
        OriginKind         = $originKind
        NotificationId     = $notificationId
        NotificationKind   = $notificationKind
        InstanceKey        = $instanceKey
        RoutingKey         = $routingKey
        RouteVersion       = $routeVersionRaw
        InvalidReason      = ''
    }

    if (-not $hasAny) {
        return $result
    }

    $routeVersion = 0
    if (-not [int]::TryParse($routeVersionRaw, [ref]$routeVersion) -or $routeVersion -ne 1) {
        $result.InvalidReason = 'route-version'
        return $result
    }
    $result.RouteVersion = '1'

    if (-not [string]::IsNullOrWhiteSpace($notificationKind) -and $notificationKind -notin @('ask-user', 'turn-complete')) {
        $result.InvalidReason = 'notification-kind'
        return $result
    }

    if ($originKind -eq 'terminal') {
        # Terminal may carry notificationId for logging; not an exact web route.
        if (-not [string]::IsNullOrWhiteSpace($notificationId) -and -not (Test-NotifyRouteUuid -Value $notificationId)) {
            $result.InvalidReason = 'notification-id'
        }
        return $result
    }

    if ($originKind -ne 'pi-web') {
        $result.InvalidReason = 'origin-kind'
        return $result
    }

    if (-not (Test-NotifyRouteUuid -Value $notificationId)) {
        $result.InvalidReason = 'notification-id'
        return $result
    }
    if (-not (Test-NotifyRouteInstanceKey -Value $instanceKey)) {
        $result.InvalidReason = 'instance-key'
        return $result
    }
    if (-not (Test-NotifyRouteHexKey -Value $routingKey -Length 64)) {
        $result.InvalidReason = 'routing-key'
        return $result
    }

    $result.IsValidPiWebExact = $true
    return $result
}

function New-NotifyRouteRequestEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [hashtable]$Fields = @{},
        [int]$TtlMs = 5000
    )

    $now = Get-NotifyUnixTimeMilliseconds
    $ttl = [Math]::Max(1000, [Math]::Min(30000, $TtlMs))
    $envelope = [ordered]@{
        protocolVersion = 1
        type            = $Type
        requestId       = [Guid]::NewGuid().ToString('N')
        issuedAtMs      = $now
        expiresAtMs     = ($now + $ttl)
    }
    foreach ($key in $Fields.Keys) {
        if ($null -eq $Fields[$key]) { continue }
        $envelope[$key] = $Fields[$key]
    }
    return $envelope
}

<#
.SYNOPSIS
  Invoke PiNotifyRouteHost.exe --client with a JSON request.
  Uses a temp file; never logs full keys. Returns structured result.
#>
function Invoke-NotifyRouteHostClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Request,

        [int]$WaitMs = 0,
        [int]$TimeoutMs = 8000,
        $Config = $null,
        [string]$ExePath = '',
        [switch]$ReturnOnProgress,
        [int]$RetryAttempt = 0
    )

    $typeName = if ($Request.ContainsKey('type')) { [string]$Request['type'] } else { '' }
    $typeFp = Get-NotifyRouteFingerprint -Value $typeName

    if ($script:NotifyRouteHostClientMock -is [scriptblock]) {
        return & $script:NotifyRouteHostClientMock $Request $WaitMs $ReturnOnProgress.IsPresent
    }

    $exe = if (-not [string]::IsNullOrWhiteSpace($ExePath)) { $ExePath.Trim() } else { Get-NotifyRouteHostExe -Config $Config }
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{
            Available           = $false
            ExitCode            = -1
            Result              = 'adapter-unavailable'
            Reason              = 'route-host-missing'
            SnapshotId          = ''
            ActivationRequestId = ''
            ActivationPhase     = ''
            RawLength           = 0
            TypeFingerprint     = $typeFp
        }
    }

    $tempPath = $null
    try {
        $json = ($Request | ConvertTo-Json -Depth 6 -Compress)
        if ([string]::IsNullOrWhiteSpace($json)) {
            return [pscustomobject]@{
                Available           = $false
                ExitCode            = -1
                Result              = 'rejected'
                Reason              = 'empty-request'
                SnapshotId          = ''
                ActivationRequestId = ''
                ActivationPhase     = ''
                RawLength           = 0
                TypeFingerprint     = $typeFp
            }
        }
        $jsonBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        if ($jsonBytes -gt (32 * 1024)) {
            return [pscustomobject]@{
                Available           = $false
                ExitCode            = -1
                Result              = 'oversized'
                Reason              = 'oversized'
                SnapshotId          = ''
                ActivationRequestId = ''
                ActivationPhase     = ''
                RawLength           = $jsonBytes
                TypeFingerprint     = $typeFp
            }
        }

        $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('pi-notify-route-{0}.json' -f [Guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))

        $argList = @('--client', '--json', $tempPath)
        if ($WaitMs -gt 0) {
            $argList += @('--wait-ms', ([string][int]$WaitMs))
        }
        if ($ReturnOnProgress.IsPresent) {
            $argList += '--return-on-progress'
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        # ArgumentList is not on all PS versions; build Arguments carefully with quoting
        $quoted = foreach ($a in $argList) {
            if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
        }
        $psi.Arguments = [string]::Join(' ', $quoted)

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Prefer async reads before WaitForExit to avoid stdout/stderr pipe deadlocks on Windows PowerShell 5.1.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit([Math]::Max(200, $TimeoutMs))
        if (-not $exited) {
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(2000) } catch {}
            return [pscustomobject]@{
                Available           = $true
                ExitCode            = -1
                Result              = 'timeout'
                Reason              = 'client-timeout'
                SnapshotId          = ''
                ActivationRequestId = ''
                ActivationPhase     = ''
                RawLength           = 0
                TypeFingerprint     = $typeFp
            }
        }
        $stdout = ''
        try {
            if ($stdoutTask.IsCompleted) {
                $stdout = [string]$stdoutTask.Result
            }
            else {
                $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            }
        }
        catch {
            try { $stdout = $proc.StandardOutput.ReadToEnd() } catch { $stdout = '' }
        }
        $stderr = ''
        try {
            if ($stderrTask.IsCompleted) { $stderr = [string]$stderrTask.Result }
            else { $stderr = [string]$stderrTask.GetAwaiter().GetResult() }
        }
        catch {
            $stderr = ''
        }

        $result = 'rejected'
        $reason = 'malformed-response'
        $snapshotId = ''
        $recoveryTicketId = ''
        $activationRequestId = ''
        $activationPhase = ''
        $rawLen = if ($null -eq $stdout) { 0 } else { $stdout.Length }

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $line = ($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
            try {
                $parsed = $line | ConvertFrom-Json
                if ($parsed.PSObject.Properties['result'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.result)) {
                    $result = ([string]$parsed.result).Trim()
                }
                if ($parsed.PSObject.Properties['reason'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.reason)) {
                    $reason = ([string]$parsed.reason).Trim()
                }
                elseif ($result -ne 'rejected') {
                    $reason = ''
                }
                if ($parsed.PSObject.Properties['snapshotId'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.snapshotId)) {
                    $snapshotId = ([string]$parsed.snapshotId).Trim()
                }
                if ($parsed.PSObject.Properties['recoveryTicketId'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.recoveryTicketId)) {
                    $recoveryTicketId = ([string]$parsed.recoveryTicketId).Trim()
                }
                if ($parsed.PSObject.Properties['activationRequestId'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.activationRequestId)) {
                    $activationRequestId = ([string]$parsed.activationRequestId).Trim()
                }
                if ($parsed.PSObject.Properties['activationPhase'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.activationPhase)) {
                    $activationPhase = ([string]$parsed.activationPhase).Trim()
                }
            }
            catch {
                $result = 'rejected'
                $reason = 'malformed-response'
            }
        }
        else {
            if ([int]$proc.ExitCode -ne 0 -and $RetryAttempt -lt 2) {
                Start-Sleep -Milliseconds (50 * ($RetryAttempt + 1))
                return Invoke-NotifyRouteHostClient `
                    -Request $Request `
                    -WaitMs $WaitMs `
                    -TimeoutMs $TimeoutMs `
                    -Config $Config `
                    -ExePath $ExePath `
                    -ReturnOnProgress:$ReturnOnProgress.IsPresent `
                    -RetryAttempt ($RetryAttempt + 1)
            }
            $result = 'adapter-unavailable'
            $failureKind = ''
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $failureMatch = [regex]::Match($stderr, '(?:^|\s)reason=([A-Za-z0-9_.-]+)')
                if ($failureMatch.Success) {
                    $failureKind = $failureMatch.Groups[1].Value
                }
            }
            $reason = if ([string]::IsNullOrWhiteSpace($failureKind)) { 'empty-response' } else { 'client-' + $failureKind }
        }

        return [pscustomobject]@{
            Available           = $true
            ExitCode            = [int]$proc.ExitCode
            Result              = $result
            Reason              = $reason
            SnapshotId          = $snapshotId
            RecoveryTicketId    = $recoveryTicketId
            ActivationRequestId = $activationRequestId
            ActivationPhase     = $activationPhase
            RawLength           = $rawLen
            TypeFingerprint     = $typeFp
        }
    }
    catch {
        return [pscustomobject]@{
            Available           = $false
            ExitCode            = -1
            Result              = 'adapter-unavailable'
            Reason              = 'client-error'
            SnapshotId          = ''
            RecoveryTicketId    = ''
            ActivationRequestId = ''
            ActivationPhase     = ''
            RawLength           = 0
            TypeFingerprint     = $typeFp
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempPath)) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Get-NotifyRouteFreezeDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ClientResult,
        [string]$NotificationId = ''
    )

    # Pi Web exact routing never falls back across origins. Any non-ready result fails closed.
    $resultName = if ($null -ne $ClientResult -and $ClientResult.PSObject.Properties['Result']) { [string]$ClientResult.Result } else { '' }
    $snapshotId = if ($null -ne $ClientResult -and $ClientResult.PSObject.Properties['SnapshotId']) { [string]$ClientResult.SnapshotId } else { '' }
    $recoveryTicketId = if ($null -ne $ClientResult -and $ClientResult.PSObject.Properties['RecoveryTicketId']) { [string]$ClientResult.RecoveryTicketId } else { '' }
    $available = if ($null -ne $ClientResult -and $ClientResult.PSObject.Properties['Available']) { [bool]$ClientResult.Available } else { $false }
    $reason = if ($null -ne $ClientResult -and $ClientResult.PSObject.Properties['Reason']) { [string]$ClientResult.Reason } else { '' }

    if (-not $available -or $resultName -in @('adapter-unavailable') -or $reason -in @('route-host-missing', 'client-error', 'empty-response')) {
        return [pscustomobject]@{
            Decision       = 'fail-closed'
            OriginKind     = 'pi-web'
            NotificationId = $NotificationId
            SnapshotId     = ''
            RecoveryTicketId = ''
            Result         = if ($resultName) { $resultName } else { 'adapter-unavailable' }
            Reason         = if ($reason) { $reason } else { 'adapter-unavailable' }
        }
    }

    if ($resultName -eq 'ready' -and -not [string]::IsNullOrWhiteSpace($snapshotId)) {
        return [pscustomobject]@{
            Decision       = 'exact-ready'
            OriginKind     = 'pi-web'
            NotificationId = $NotificationId
            SnapshotId     = $snapshotId
            RecoveryTicketId = ''
            Result         = 'ready'
            Reason         = $reason
        }
    }

    if ($resultName -in @('miss', 'adapter-unavailable', 'owner-unresolved')) {
        return [pscustomobject]@{
            Decision       = 'fail-closed'
            OriginKind     = 'pi-web'
            NotificationId = $NotificationId
            SnapshotId     = ''
            RecoveryTicketId = ''
            Result         = $resultName
            Reason         = $reason
        }
    }

    if ($resultName -eq 'recovering' -and -not [string]::IsNullOrWhiteSpace($recoveryTicketId)) {
        return [pscustomobject]@{
            Decision         = 'exact-recovering'
            OriginKind       = 'pi-web'
            NotificationId   = $NotificationId
            SnapshotId       = ''
            RecoveryTicketId = $recoveryTicketId
            Result           = 'recovering'
            Reason           = $reason
        }
    }

    # ambiguous/stale/replay/expired/protocol-mismatch/timeout/select-failed/foreground-denied/malformed
    return [pscustomobject]@{
        Decision       = 'fail-closed'
        OriginKind     = 'pi-web'
        NotificationId = $NotificationId
        SnapshotId     = ''
        RecoveryTicketId = ''
        Result         = if ($resultName) { $resultName } else { 'rejected' }
        Reason         = $reason
    }
}

function Get-NotifyRouteActivateDecision {
    [CmdletBinding()]
    param(
        [string]$OriginKind,
        [string]$NotificationId,
        [string]$SnapshotId,
        $ClientResult = $null
    )

    $origin = if ([string]::IsNullOrWhiteSpace($OriginKind)) { '' } else { $OriginKind.Trim() }
    if ($origin -ne 'pi-web') {
        return [pscustomobject]@{
            Decision = 'terminal'
            Result   = ''
            Reason   = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($NotificationId) -or [string]::IsNullOrWhiteSpace($SnapshotId)) {
        return [pscustomobject]@{
            Decision = 'fail-closed'
            Result   = 'owner-unresolved'
            Reason   = 'missing-snapshot'
        }
    }

    if ($null -eq $ClientResult) {
        return [pscustomobject]@{
            Decision = 'fail-closed'
            Result   = 'adapter-unavailable'
            Reason   = 'no-client-result'
        }
    }

    $resultName = if ($ClientResult.PSObject.Properties['Result']) { [string]$ClientResult.Result } else { '' }
    $reason = if ($ClientResult.PSObject.Properties['Reason']) { [string]$ClientResult.Reason } else { '' }
    $available = if ($ClientResult.PSObject.Properties['Available']) { [bool]$ClientResult.Available } else { $false }
    $returnedSnapshotId = if ($ClientResult.PSObject.Properties['SnapshotId']) { [string]$ClientResult.SnapshotId } else { '' }
    $activationRequestId = if ($ClientResult.PSObject.Properties['ActivationRequestId']) { [string]$ClientResult.ActivationRequestId } else { '' }
    $activationPhase = if ($ClientResult.PSObject.Properties['ActivationPhase']) { [string]$ClientResult.ActivationPhase } else { '' }

    if (-not $available -or $resultName -eq 'adapter-unavailable' -or $reason -in @('route-host-missing', 'client-error', 'empty-response')) {
        return [pscustomobject]@{
            Decision = 'fail-closed'
            Result   = if ($resultName) { $resultName } else { 'adapter-unavailable' }
            Reason   = if ($reason) { $reason } else { 'adapter-unavailable' }
        }
    }

    if ($resultName -eq 'pending' -and
        $activationPhase -eq 'desktop-row-focused-awaiting-proof' -and
        $returnedSnapshotId -eq $SnapshotId -and
        $activationRequestId -match '^[A-Za-z0-9._-]{8,128}$') {
        return [pscustomobject]@{
            Decision            = 'focused'
            Result              = 'pending'
            Reason              = 'background-proof-pending'
            ActivationPhase     = $activationPhase
            ActivationRequestId = $activationRequestId
        }
    }

    if ($resultName -in @('session-url-confirmed', 'session-confirmed', 'already-active')) {
        return [pscustomobject]@{
            Decision = 'handled'
            Result   = $resultName
            Reason   = $reason
        }
    }

    if ($resultName -in @('miss', 'adapter-unavailable', 'owner-unresolved')) {
        return [pscustomobject]@{
            Decision = 'fail-closed'
            Result   = $resultName
            Reason   = $reason
        }
    }

    return [pscustomobject]@{
        Decision = 'fail-closed'
        Result   = if ($resultName) { $resultName } else { 'rejected' }
        Reason   = if ($reason) { $reason } else { 'activate-failed' }
    }
}

function Invoke-NotifyExactRouteFreeze {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [string]$NotificationKind = '',
        [Parameter(Mandatory = $true)][string]$InstanceKey,
        [Parameter(Mandatory = $true)][string]$RoutingKey,
        $Config = $null,
        [int]$TimeoutMs = 5000
    )

    $fields = @{
        notificationId = $NotificationId
        instanceKey    = $InstanceKey
        routingKey     = $RoutingKey
        recoveryTtlMs  = 120000
    }
    if (-not [string]::IsNullOrWhiteSpace($NotificationKind)) {
        $fields['notificationKind'] = $NotificationKind
    }
    $envelope = New-NotifyRouteRequestEnvelope -Type 'freeze' -Fields $fields -TtlMs 5000
    $request = @{}
    foreach ($k in $envelope.Keys) { $request[$k] = $envelope[$k] }

    $clientResult = Invoke-NotifyRouteHostClient -Request $request -WaitMs 0 -TimeoutMs $TimeoutMs -Config $Config
    return Get-NotifyRouteFreezeDecision -ClientResult $clientResult -NotificationId $NotificationId
}

function Get-NotifyRouteRecoveryDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ClientResult,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$RecoveryTicketId
    )

    $resultName = if ($ClientResult.PSObject.Properties['Result']) { [string]$ClientResult.Result } else { '' }
    $reason = if ($ClientResult.PSObject.Properties['Reason']) { [string]$ClientResult.Reason } else { '' }
    $available = if ($ClientResult.PSObject.Properties['Available']) { [bool]$ClientResult.Available } else { $false }
    $snapshotId = if ($ClientResult.PSObject.Properties['SnapshotId']) { [string]$ClientResult.SnapshotId } else { '' }
    $ticketId = if ($ClientResult.PSObject.Properties['RecoveryTicketId']) { [string]$ClientResult.RecoveryTicketId } else { '' }

    if ($resultName -eq 'ready' -and
        -not [string]::IsNullOrWhiteSpace($snapshotId) -and
        $ticketId -eq $RecoveryTicketId) {
        return [pscustomobject]@{
            Decision         = 'exact-ready'
            NotificationId   = $NotificationId
            SnapshotId       = $snapshotId
            RecoveryTicketId = $RecoveryTicketId
            Result           = 'ready'
            Reason           = $reason
        }
    }

    if ($resultName -eq 'recovering' -and $ticketId -eq $RecoveryTicketId) {
        return [pscustomobject]@{
            Decision         = 'exact-recovering'
            NotificationId   = $NotificationId
            SnapshotId       = ''
            RecoveryTicketId = $RecoveryTicketId
            Result           = 'recovering'
            Reason           = $reason
        }
    }

    if (-not $available -or
        $resultName -eq 'adapter-unavailable' -or
        $reason -in @('client-error', 'empty-response', 'client-timeout')) {
        return [pscustomobject]@{
            Decision         = 'retry'
            NotificationId   = $NotificationId
            SnapshotId       = ''
            RecoveryTicketId = $RecoveryTicketId
            Result           = if ($resultName) { $resultName } else { 'adapter-unavailable' }
            Reason           = if ($reason) { $reason } else { 'adapter-unavailable' }
        }
    }

    return [pscustomobject]@{
        Decision         = 'fail-closed'
        NotificationId   = $NotificationId
        SnapshotId       = ''
        RecoveryTicketId = $RecoveryTicketId
        Result           = if ($resultName) { $resultName } else { 'rejected' }
        Reason           = if ($reason) { $reason } else { 'recovery-failed' }
    }
}

function Invoke-NotifyExactRouteRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$RecoveryTicketId,
        $Config = $null,
        [int]$TimeoutMs = 3000
    )

    $envelope = New-NotifyRouteRequestEnvelope -Type 'resolve-recovery' -Fields @{
        notificationId   = $NotificationId
        recoveryTicketId = $RecoveryTicketId
    } -TtlMs 5000
    $request = @{}
    foreach ($key in $envelope.Keys) { $request[$key] = $envelope[$key] }
    $clientResult = Invoke-NotifyRouteHostClient -Request $request -WaitMs 0 -TimeoutMs $TimeoutMs -Config $Config
    return [pscustomobject]@{
        ClientResult = $clientResult
        Decision = Get-NotifyRouteRecoveryDecision -ClientResult $clientResult -NotificationId $NotificationId -RecoveryTicketId $RecoveryTicketId
    }
}

function Wait-NotifyExactRouteRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$RecoveryTicketId,
        $Config = $null,
        [int]$WaitMs = 125000,
        [int]$PollMs = 500
    )

    $started = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($started.ElapsedMilliseconds -lt $WaitMs) {
            $remaining = [Math]::Max(250, $WaitMs - [int]$started.ElapsedMilliseconds)
            $outcome = Invoke-NotifyExactRouteRecovery -NotificationId $NotificationId -RecoveryTicketId $RecoveryTicketId -Config $Config -TimeoutMs ([Math]::Min(3000, $remaining))
            if ($outcome.Decision.Decision -eq 'exact-ready' -or
                $outcome.Decision.Decision -eq 'fail-closed') {
                return $outcome
            }
            Start-Sleep -Milliseconds ([Math]::Max(100, [Math]::Min($PollMs, $remaining)))
        }
    }
    finally {
        $started.Stop()
    }

    $decision = [pscustomobject]@{
        Decision         = 'fail-closed'
        NotificationId   = $NotificationId
        SnapshotId       = ''
        RecoveryTicketId = $RecoveryTicketId
        Result           = 'expired'
        Reason           = 'recovery-expired'
    }
    return [pscustomobject]@{ ClientResult = $null; Decision = $decision }
}

function Invoke-NotifyExactRouteRecoveryAndActivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [string]$SnapshotId = '',
        [string]$RecoveryTicketId = '',
        $Config = $null,
        [int]$RecoveryWaitMs = 125000,
        [int]$ActivateWaitMs = 45000,
        [int]$ActivateTimeoutMs = 48000
    )

    $resolvedSnapshotId = $SnapshotId
    if ([string]::IsNullOrWhiteSpace($resolvedSnapshotId)) {
        if ([string]::IsNullOrWhiteSpace($RecoveryTicketId)) {
            return [pscustomobject]@{
                Decision = [pscustomobject]@{ Decision = 'fail-closed'; Result = 'owner-unresolved'; Reason = 'missing-recovery-ticket' }
                SnapshotId = ''
                RecoveryTicketId = ''
            }
        }
        $recovery = Wait-NotifyExactRouteRecovery -NotificationId $NotificationId -RecoveryTicketId $RecoveryTicketId -Config $Config -WaitMs $RecoveryWaitMs
        if ($recovery.Decision.Decision -ne 'exact-ready') {
            return [pscustomobject]@{
                Decision = $recovery.Decision
                SnapshotId = ''
                RecoveryTicketId = $RecoveryTicketId
            }
        }
        $resolvedSnapshotId = [string]$recovery.Decision.SnapshotId
    }

    $activation = Invoke-NotifyExactRouteActivate -NotificationId $NotificationId -SnapshotId $resolvedSnapshotId -Config $Config -WaitMs $ActivateWaitMs -TimeoutMs $ActivateTimeoutMs
    return [pscustomobject]@{
        Decision = $activation.Decision
        SnapshotId = $resolvedSnapshotId
        RecoveryTicketId = $RecoveryTicketId
        ClientResult = $activation.ClientResult
    }
}

function Invoke-NotifyExactRouteActivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$SnapshotId,
        $Config = $null,
        [int]$WaitMs = 45000,
        [int]$TimeoutMs = 48000
    )

    $now = Get-NotifyUnixTimeMilliseconds
    $fields = @{
        notificationId = $NotificationId
        snapshotId     = $SnapshotId
        deadlineMs     = ($now + [Math]::Max(500, $WaitMs))
    }
    # Transport freshness stays short even though the accepted activation may
    # execute against its independent, longer deadline.
    $envelope = New-NotifyRouteRequestEnvelope -Type 'activate' -Fields $fields -TtlMs 5000
    $request = @{}
    foreach ($k in $envelope.Keys) { $request[$k] = $envelope[$k] }

    $clientResult = Invoke-NotifyRouteHostClient -Request $request -WaitMs $WaitMs -TimeoutMs $TimeoutMs -Config $Config
    # Wait for the terminal activation result: a focused/pending intermediate
    # must never close the popup early (the worker/UI owner treats it as
    # non-terminal and keeps the card in bounded pending feedback).
    return [pscustomobject]@{
        ClientResult = $clientResult
        Decision     = (Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId $NotificationId -SnapshotId $SnapshotId -ClientResult $clientResult)
    }
}


# --- Paseo desktop route helpers (opaque activation + loopback CDP contract) ---------

function Get-NotifyAppLabel {
    [CmdletBinding()]
    param([string]$OriginKind = '')

    $kind = if ($null -eq $OriginKind) { '' } else { $OriginKind.Trim() }
    if ($kind -eq 'paseo') { return 'Paseo' }
    return 'Pi Remote'
}

function Test-NotifyPaseoRouteId {
    [CmdletBinding()]
    param(
        [string]$Value,
        [int]$MinLength = 1,
        [int]$MaxLength = 256
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $text = $Value.Trim()
    if ($text.Length -lt $MinLength -or $text.Length -gt $MaxLength) { return $false }
    # Paseo IDs are opaque. Reject controls, but do not invent URL/token character rules.
    if ($text -match '[\x00-\x1F\x7F-\x9F]') { return $false }
    return $true
}

function Test-NotifyPaseoNotificationKind {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim() -in @('finished', 'permission'))
}

function Get-NotifyPaseoRouteObject {
    [CmdletBinding()]
    param($Payload)

    if ($null -eq $Payload -or -not $Payload.PSObject.Properties['paseoRoute']) {
        return $null
    }
    return $Payload.paseoRoute
}

function Get-NotifyPaseoActivationTtlSeconds {
    [CmdletBinding()]
    param(
        $Config = $null,
        [int]$PopupTimeoutSeconds = 0
    )

    $timeout = 0
    if ($PopupTimeoutSeconds -ge 3) {
        $timeout = $PopupTimeoutSeconds
    }
    elseif ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('popupTimeoutSeconds')) {
                try { $timeout = [int]$Config['popupTimeoutSeconds'] } catch { $timeout = 0 }
            }
            elseif ($Config.ContainsKey('PopupTimeoutSeconds')) {
                try { $timeout = [int]$Config['PopupTimeoutSeconds'] } catch { $timeout = 0 }
            }
        }
        elseif ($Config.PSObject.Properties['PopupTimeoutSeconds']) {
            try { $timeout = [int]$Config.PopupTimeoutSeconds } catch { $timeout = 0 }
        }
        elseif ($Config.PSObject.Properties['popupTimeoutSeconds']) {
            try { $timeout = [int]$Config.popupTimeoutSeconds } catch { $timeout = 0 }
        }
    }
    if ($timeout -lt 3) { $timeout = 1800 }
    return [Math]::Min(1800, [Math]::Max(3, $timeout))
}

function Get-NotifyPaseoTargetFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$AgentId
    )

    $material = "paseo`0$($ServerId.Trim())`0$($AgentId.Trim())"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

<#
.SYNOPSIS
  Validate originKind=paseo metadata and route triple from a notify payload.
.OUTPUTS
  PSCustomObject with HasAnyPaseoField, IsValidPaseoExact, OriginKind, NotificationId,
  NotificationKind, ServerId, WorkspaceId, AgentId, RouteVersion, InvalidReason
#>
function Resolve-NotifyPaseoRouteMetadata {
    [CmdletBinding()]
    param($Payload)

    $originKind = Get-NotifyPayloadStringField -Payload $Payload -Name 'originKind'
    $notificationId = Get-NotifyPayloadStringField -Payload $Payload -Name 'notificationId'
    $notificationKind = Get-NotifyPayloadStringField -Payload $Payload -Name 'notificationKind'
    $routeObj = Get-NotifyPaseoRouteObject -Payload $Payload

    $serverId = ''
    $workspaceId = ''
    $agentId = ''
    $serverIdIsString = $false
    $workspaceIdIsString = $false
    $agentIdIsString = $false
    $routeVersionRaw = ''
    if ($null -ne $routeObj) {
        if ($routeObj.PSObject.Properties['serverId']) {
            $serverIdIsString = $routeObj.serverId -is [string]
            if ($serverIdIsString) { $serverId = Get-NotifyPayloadStringField -Payload $routeObj -Name 'serverId' }
        }
        if ($routeObj.PSObject.Properties['workspaceId']) {
            $workspaceIdIsString = $routeObj.workspaceId -is [string]
            if ($workspaceIdIsString) { $workspaceId = Get-NotifyPayloadStringField -Payload $routeObj -Name 'workspaceId' }
        }
        if ($routeObj.PSObject.Properties['agentId']) {
            $agentIdIsString = $routeObj.agentId -is [string]
            if ($agentIdIsString) { $agentId = Get-NotifyPayloadStringField -Payload $routeObj -Name 'agentId' }
        }
        if ($routeObj.PSObject.Properties['version']) {
            try { $routeVersionRaw = [string]$routeObj.version } catch { $routeVersionRaw = '' }
            if ([string]::IsNullOrWhiteSpace($routeVersionRaw)) {
                $routeVersionRaw = Get-NotifyPayloadStringField -Payload $routeObj -Name 'version'
            }
        }
    }

    $hasAny = ($originKind -eq 'paseo') -or ($null -ne $routeObj) -or (
        -not [string]::IsNullOrWhiteSpace($serverId) -or
        -not [string]::IsNullOrWhiteSpace($workspaceId) -or
        -not [string]::IsNullOrWhiteSpace($agentId)
    )

    $result = [pscustomobject]@{
        HasAnyPaseoField  = [bool]$hasAny
        IsValidPaseoExact = $false
        OriginKind        = $originKind
        NotificationId    = $notificationId
        NotificationKind  = $notificationKind
        ServerId          = $serverId
        WorkspaceId       = $workspaceId
        AgentId           = $agentId
        RouteVersion      = $routeVersionRaw
        InvalidReason     = ''
    }

    if (-not $hasAny) {
        return $result
    }

    if ($originKind -ne 'paseo') {
        $result.InvalidReason = 'origin-kind'
        return $result
    }

    if (-not (Test-NotifyRouteUuid -Value $notificationId)) {
        $result.InvalidReason = 'notification-id'
        return $result
    }

    if (-not (Test-NotifyPaseoNotificationKind -Value $notificationKind)) {
        # error and other kinds must never create a Paseo desktop popup route.
        $result.InvalidReason = 'notification-kind'
        return $result
    }
    $result.NotificationKind = $notificationKind.Trim()

    if (($routeVersionRaw + '').Trim() -ne '1') {
        $result.InvalidReason = 'route-version'
        return $result
    }
    $result.RouteVersion = '1'

    if (-not $serverIdIsString -or -not (Test-NotifyPaseoRouteId -Value $serverId)) {
        $result.InvalidReason = 'server-id'
        return $result
    }
    if (-not $workspaceIdIsString -or -not (Test-NotifyPaseoRouteId -Value $workspaceId)) {
        $result.InvalidReason = 'workspace-id'
        return $result
    }
    if (-not $agentIdIsString -or -not (Test-NotifyPaseoRouteId -Value $agentId)) {
        $result.InvalidReason = 'agent-id'
        return $result
    }

    $result.ServerId = $serverId.Trim()
    $result.WorkspaceId = $workspaceId.Trim()
    $result.AgentId = $agentId.Trim()
    $result.IsValidPaseoExact = $true
    return $result
}

function Protect-NotifyBridgeValue {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-NotifyBridgeValue {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-NotifyPaseoActivationCacheDir {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-NotifyBridgeBaseDir) 'paseo-activation')
}

function Get-NotifyPaseoActivationCachePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ActivationId)

    return (Join-Path (Get-NotifyPaseoActivationCacheDir) ('activation-{0}.json' -f $ActivationId))
}

function Enter-NotifyPaseoActivationCacheLock {
    [CmdletBinding()]
    param([int]$TimeoutMs = 5000)

    $mutex = [System.Threading.Mutex]::new($false, 'Local\PiRemotePaseoActivationCache')
    try {
        if (-not $mutex.WaitOne([Math]::Max(100, $TimeoutMs), $false)) {
            $mutex.Dispose()
            return $null
        }
        return $mutex
    }
    catch [System.Threading.AbandonedMutexException] {
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-NotifyPaseoActivationCacheLock {
    [CmdletBinding()]
    param($Mutex)

    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Clear-NotifyPaseoActivationCache {
    [CmdletBinding()]
    param(
        [int]$MaxAgeSeconds = 1800,
        [int]$MaxCount = 96
    )

    $dir = Get-NotifyPaseoActivationCacheDir
    if (-not (Test-Path -LiteralPath $dir)) { return }

    # Writes are serialized by the cache mutex, so abandoned encrypted temp files are never live.
    foreach ($tempItem in @(Get-ChildItem -LiteralPath $dir -Filter 'activation-*.json.tmp-*' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $tempItem.FullName -Force -ErrorAction SilentlyContinue
    }

    $cutoff = (Get-Date).AddSeconds(-[Math]::Max(3, $MaxAgeSeconds))
    $items = @(Get-ChildItem -LiteralPath $dir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($item in $items) {
        $remove = $item.LastWriteTime -lt $cutoff
        if (-not $remove) {
            try {
                $payload = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                $expiresAtTicks = [int64]0
                if ($payload.PSObject.Properties['expiresAtTicks']) {
                    [void][int64]::TryParse([string]$payload.expiresAtTicks, [ref]$expiresAtTicks)
                }
                if ($expiresAtTicks -gt 0 -and $expiresAtTicks -le [DateTime]::UtcNow.Ticks) {
                    $remove = $true
                }
            }
            catch {
                $remove = $true
            }
        }
        if ($remove) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $remaining = @(Get-ChildItem -LiteralPath $dir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    while ($remaining.Count -gt $MaxCount) {
        try { Remove-Item -LiteralPath $remaining[0].FullName -Force -ErrorAction SilentlyContinue } catch {}
        if ($remaining.Count -gt 0) { $remaining = @($remaining | Select-Object -Skip 1) } else { break }
    }
}

function Save-NotifyPaseoActivationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$NotificationKind,
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$AgentId,
        [int]$TtlSeconds = 1800
    )

    $mutex = Enter-NotifyPaseoActivationCacheLock
    if ($null -eq $mutex) { throw 'Paseo activation cache is busy.' }
    try {
        $ttl = [Math]::Max(3, [Math]::Min(1800, $TtlSeconds))
        $dir = Get-NotifyPaseoActivationCacheDir
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # Reserve one slot before writing so the cache never exceeds its hard bound.
        Clear-NotifyPaseoActivationCache -MaxAgeSeconds 1800 -MaxCount 95

        $payload = @{
            activationId              = $ActivationId
            originKind                = 'paseo'
            routeVersion              = 1
            state                     = 'ready'
            leaseId                   = ''
            leaseExpiresAtTicks       = 0
            protectedNotificationId   = Protect-NotifyBridgeValue -Value $NotificationId
            protectedNotificationKind = Protect-NotifyBridgeValue -Value $NotificationKind
            protectedPaseoServerId    = Protect-NotifyBridgeValue -Value $ServerId
            protectedPaseoWorkspaceId = Protect-NotifyBridgeValue -Value $WorkspaceId
            protectedPaseoAgentId     = Protect-NotifyBridgeValue -Value $AgentId
            expiresAtTicks            = [DateTime]::UtcNow.AddSeconds($ttl).Ticks
        }

        [void](Write-NotifyPaseoActivationPayload -ActivationId $ActivationId -Payload $payload)
        return @((Get-NotifyPaseoActivationCachePath -ActivationId $ActivationId))
    }
    finally {
        Exit-NotifyPaseoActivationCacheLock -Mutex $mutex
    }
}

function Read-NotifyPaseoActivationPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ActivationId)

    if ([string]::IsNullOrWhiteSpace($ActivationId)) { return $null }
    if ($ActivationId -notmatch '^[0-9a-fA-F]{32}$' -and -not (Test-NotifyRouteUuid -Value $ActivationId)) {
        return $null
    }

    $path = Get-NotifyPaseoActivationCachePath -ActivationId $ActivationId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-NotifyPaseoActivationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [Parameter(Mandatory = $true)]$Payload
    )

    $path = Get-NotifyPaseoActivationCachePath -ActivationId $ActivationId
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tempPath = $path + ('.tmp-{0}' -f [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tempPath, ($Payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) {
            [System.IO.File]::Replace($tempPath, $path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($tempPath, $path)
        }
        $tempPath = ''
        return $true
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempPath)) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function ConvertFrom-NotifyPaseoActivationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [string]$ActivationId = ''
    )

    $originKind = if ($Payload.PSObject.Properties['originKind']) { ([string]$Payload.originKind).Trim() } else { '' }
    if ($originKind -ne 'paseo') {
        return [pscustomobject]@{
            Available        = $false
            Result           = 'invalid'
            Reason           = 'origin-kind'
            State            = 'invalid'
            ActivationId     = $ActivationId
            NotificationId   = ''
            NotificationKind = ''
            ServerId         = ''
            WorkspaceId      = ''
            AgentId          = ''
        }
    }

    $expiresAtTicks = [int64]0
    if ($Payload.PSObject.Properties['expiresAtTicks']) {
        [void][int64]::TryParse([string]$Payload.expiresAtTicks, [ref]$expiresAtTicks)
    }
    if ($expiresAtTicks -le [DateTime]::UtcNow.Ticks) {
        return [pscustomobject]@{
            Available        = $false
            Result           = 'expired'
            Reason           = 'expired'
            State            = 'expired'
            ActivationId     = $ActivationId
            NotificationId   = ''
            NotificationKind = ''
            ServerId         = ''
            WorkspaceId      = ''
            AgentId          = ''
        }
    }

    $routeVersion = 0
    $routeVersionRaw = if ($Payload.PSObject.Properties['routeVersion']) { [string]$Payload.routeVersion } else { '' }
    if (-not [int]::TryParse(($routeVersionRaw + '').Trim(), [ref]$routeVersion) -or $routeVersion -ne 1) {
        return [pscustomobject]@{
            Available        = $false
            Result           = 'invalid'
            Reason           = 'route-version'
            State            = 'invalid'
            ActivationId     = $ActivationId
            NotificationId   = ''
            NotificationKind = ''
            ServerId         = ''
            WorkspaceId      = ''
            AgentId          = ''
        }
    }

    $stateName = if ($Payload.PSObject.Properties['state']) { ([string]$Payload.state).Trim().ToLowerInvariant() } else { 'ready' }
    $leaseExpiresAtTicks = [int64]0
    if ($Payload.PSObject.Properties['leaseExpiresAtTicks']) {
        [void][int64]::TryParse([string]$Payload.leaseExpiresAtTicks, [ref]$leaseExpiresAtTicks)
    }
    if ($stateName -eq 'consumed') {
        return [pscustomobject]@{
            Available = $false; Result = 'invalid'; Reason = 'already-consumed'; State = 'consumed'; ActivationId = $ActivationId
            NotificationId = ''; NotificationKind = ''; ServerId = ''; WorkspaceId = ''; AgentId = ''
        }
    }
    if ($stateName -notin @('ready', 'in-flight')) {
        return [pscustomobject]@{
            Available = $false; Result = 'invalid'; Reason = 'state-invalid'; State = 'invalid'; ActivationId = $ActivationId
            NotificationId = ''; NotificationKind = ''; ServerId = ''; WorkspaceId = ''; AgentId = ''
        }
    }
    if ($stateName -eq 'in-flight' -and $leaseExpiresAtTicks -gt 0 -and $leaseExpiresAtTicks -le [DateTime]::UtcNow.Ticks) {
        $stateName = 'ready'
    }

    try {
        $notificationId = if ($Payload.PSObject.Properties['protectedNotificationId']) { Unprotect-NotifyBridgeValue -Value ([string]$Payload.protectedNotificationId) } else { '' }
        $notificationKind = if ($Payload.PSObject.Properties['protectedNotificationKind']) { Unprotect-NotifyBridgeValue -Value ([string]$Payload.protectedNotificationKind) } else { '' }
        $serverId = if ($Payload.PSObject.Properties['protectedPaseoServerId']) { Unprotect-NotifyBridgeValue -Value ([string]$Payload.protectedPaseoServerId) } else { '' }
        $workspaceId = if ($Payload.PSObject.Properties['protectedPaseoWorkspaceId']) { Unprotect-NotifyBridgeValue -Value ([string]$Payload.protectedPaseoWorkspaceId) } else { '' }
        $agentId = if ($Payload.PSObject.Properties['protectedPaseoAgentId']) { Unprotect-NotifyBridgeValue -Value ([string]$Payload.protectedPaseoAgentId) } else { '' }
    }
    catch {
        return [pscustomobject]@{
            Available        = $false
            Result           = 'invalid'
            Reason           = 'decrypt-failed'
            State            = 'invalid'
            ActivationId     = $ActivationId
            NotificationId   = ''
            NotificationKind = ''
            ServerId         = ''
            WorkspaceId      = ''
            AgentId          = ''
        }
    }

    if (-not (Test-NotifyRouteUuid -Value $notificationId) -or
        -not (Test-NotifyPaseoNotificationKind -Value $notificationKind) -or
        -not (Test-NotifyPaseoRouteId -Value $serverId) -or
        -not (Test-NotifyPaseoRouteId -Value $workspaceId) -or
        -not (Test-NotifyPaseoRouteId -Value $agentId)) {
        return [pscustomobject]@{
            Available        = $false
            Result           = 'invalid'
            Reason           = 'incomplete-context'
            State            = 'invalid'
            ActivationId     = $ActivationId
            NotificationId   = ''
            NotificationKind = ''
            ServerId         = ''
            WorkspaceId      = ''
            AgentId          = ''
        }
    }

    return [pscustomobject]@{
        Available        = $true
        Result           = $(if ($stateName -eq 'in-flight') { 'busy' } else { 'ready' })
        Reason           = ''
        State            = $stateName
        ActivationId     = $ActivationId
        NotificationId   = $notificationId.Trim()
        NotificationKind = $notificationKind.Trim()
        ServerId         = $serverId.Trim()
        WorkspaceId      = $workspaceId.Trim()
        AgentId          = $agentId.Trim()
        LeaseId         = if ($Payload.PSObject.Properties['leaseId']) { [string]$Payload.leaseId } else { '' }
        LeaseExpiresAtTicks = $leaseExpiresAtTicks
        ExpiresAtTicks   = $expiresAtTicks
    }
}

function Resolve-NotifyPaseoActivationState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ActivationId)

    $payload = Read-NotifyPaseoActivationPayload -ActivationId $ActivationId
    if ($null -eq $payload) {
        return [pscustomobject]@{
            Available        = $false
            Result           = 'invalid'
            Reason           = 'activation-missing'
            State            = 'missing'
            ActivationId     = $ActivationId
            NotificationId   = ''
            NotificationKind = ''
            ServerId         = ''
            WorkspaceId      = ''
            AgentId          = ''
        }
    }
    return ConvertFrom-NotifyPaseoActivationPayload -Payload $payload -ActivationId $ActivationId
}

function Acquire-NotifyPaseoActivationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [int]$LeaseSeconds = 45
    )

    $mutex = Enter-NotifyPaseoActivationCacheLock
    if ($null -eq $mutex) {
        return [pscustomobject]@{
            Acquired = $false; Available = $true; Result = 'busy'; Reason = 'cache-lock-timeout'; State = 'busy'
            ActivationId = $ActivationId; LeaseId = ''; NotificationId = ''; NotificationKind = ''; ServerId = ''; WorkspaceId = ''; AgentId = ''
        }
    }
    try {
        $payload = Read-NotifyPaseoActivationPayload -ActivationId $ActivationId
        if ($null -eq $payload) {
            return [pscustomobject]@{
                Acquired = $false; Available = $false; Result = 'invalid'; Reason = 'activation-missing'; State = 'missing'
                ActivationId = $ActivationId; LeaseId = ''; NotificationId = ''; NotificationKind = ''; ServerId = ''; WorkspaceId = ''; AgentId = ''
            }
        }

        $state = ConvertFrom-NotifyPaseoActivationPayload -Payload $payload -ActivationId $ActivationId
        if (-not $state.Available) {
            return [pscustomobject]@{
                Acquired = $false; Available = $false; Result = $state.Result; Reason = $state.Reason; State = $state.State
                ActivationId = $ActivationId; LeaseId = ''; NotificationId = ''; NotificationKind = ''; ServerId = ''; WorkspaceId = ''; AgentId = ''
            }
        }
        if ($state.State -eq 'in-flight') {
            return [pscustomobject]@{
                Acquired = $false; Available = $true; Result = 'busy'; Reason = 'in-flight'; State = 'in-flight'
                ActivationId = $ActivationId; LeaseId = ''; NotificationId = $state.NotificationId; NotificationKind = $state.NotificationKind
                ServerId = $state.ServerId; WorkspaceId = $state.WorkspaceId; AgentId = $state.AgentId
            }
        }

        $leaseId = [Guid]::NewGuid().ToString('N')
        $leaseSeconds = [Math]::Max(5, [Math]::Min(120, $LeaseSeconds))
        $payload.state = 'in-flight'
        $payload.leaseId = $leaseId
        $payload.leaseExpiresAtTicks = [DateTime]::UtcNow.AddSeconds($leaseSeconds).Ticks
        [void](Write-NotifyPaseoActivationPayload -ActivationId $ActivationId -Payload $payload)

        return [pscustomobject]@{
            Acquired = $true; Available = $true; Result = 'ready'; Reason = ''; State = 'in-flight'
            ActivationId = $ActivationId; LeaseId = $leaseId; NotificationId = $state.NotificationId; NotificationKind = $state.NotificationKind
            ServerId = $state.ServerId; WorkspaceId = $state.WorkspaceId; AgentId = $state.AgentId
        }
    }
    finally {
        Exit-NotifyPaseoActivationCacheLock -Mutex $mutex
    }
}

function Release-NotifyPaseoActivationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [Parameter(Mandatory = $true)][string]$LeaseId
    )

    $mutex = Enter-NotifyPaseoActivationCacheLock
    if ($null -eq $mutex) { return $false }
    try {
        $payload = Read-NotifyPaseoActivationPayload -ActivationId $ActivationId
        if ($null -eq $payload -or -not $payload.PSObject.Properties['leaseId']) { return $false }
        if ([string]$payload.state -ne 'in-flight' -or [string]$payload.leaseId -ne $LeaseId) { return $false }
        $payload.state = 'ready'
        $payload.leaseId = ''
        $payload.leaseExpiresAtTicks = 0
        return [bool](Write-NotifyPaseoActivationPayload -ActivationId $ActivationId -Payload $payload)
    }
    finally {
        Exit-NotifyPaseoActivationCacheLock -Mutex $mutex
    }
}

function Consume-NotifyPaseoActivationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [Parameter(Mandatory = $true)][string]$LeaseId
    )

    $mutex = Enter-NotifyPaseoActivationCacheLock
    if ($null -eq $mutex) { return $false }
    try {
        $payload = Read-NotifyPaseoActivationPayload -ActivationId $ActivationId
        if ($null -eq $payload -or -not $payload.PSObject.Properties['leaseId']) { return $false }
        if ([string]$payload.state -ne 'in-flight' -or [string]$payload.leaseId -ne $LeaseId) { return $false }
        $expiresAtTicks = [int64]0
        if (-not $payload.PSObject.Properties['expiresAtTicks'] -or -not [int64]::TryParse([string]$payload.expiresAtTicks, [ref]$expiresAtTicks) -or $expiresAtTicks -le [DateTime]::UtcNow.Ticks) {
            return $false
        }
        $path = Get-NotifyPaseoActivationCachePath -ActivationId $ActivationId
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            return $true
        }
        catch {
            # Preserve a terminal marker if physical deletion is temporarily blocked.
            $payload.state = 'consumed'
            $payload.leaseId = ''
            $payload.leaseExpiresAtTicks = 0
            return [bool](Write-NotifyPaseoActivationPayload -ActivationId $ActivationId -Payload $payload)
        }
    }
    catch {
        return $false
    }
    finally {
        Exit-NotifyPaseoActivationCacheLock -Mutex $mutex
    }
}

function Get-NotifyPaseoDesktopRouteScriptPath {
    [CmdletBinding()]
    param()

    $binCandidate = Join-Path (Get-NotifyBridgeBinDir) 'paseo-desktop-route.ps1'
    if (Test-Path -LiteralPath $binCandidate) { return $binCandidate }
    $sourceCandidate = Join-Path $PSScriptRoot 'paseo-desktop-route.ps1'
    if (Test-Path -LiteralPath $sourceCandidate) { return $sourceCandidate }
    return $sourceCandidate
}

function Test-NotifyPaseoDesktopRoutingEnabled {
    [CmdletBinding()]
    param($Config = $null)

    if ($null -eq $Config) { return $false }
    if ($Config -is [hashtable]) {
        if ($Config.ContainsKey('paseoDesktopRoutingEnabled')) {
            return ConvertTo-NotifyBridgeBoolean -Value $Config['paseoDesktopRoutingEnabled'] -Default $false
        }
        if ($Config.ContainsKey('PaseoDesktopRoutingEnabled')) {
            try { return [bool]$Config['PaseoDesktopRoutingEnabled'] } catch { return $false }
        }
        return $false
    }
    if ($Config.PSObject.Properties['PaseoDesktopRoutingEnabled']) {
        try { return [bool]$Config.PaseoDesktopRoutingEnabled } catch { return $false }
    }
    if ($Config.PSObject.Properties['paseoDesktopRoutingEnabled']) {
        return ConvertTo-NotifyBridgeBoolean -Value $Config.paseoDesktopRoutingEnabled -Default $false
    }
    return $false
}

function Get-NotifyPaseoCdpPort {
    [CmdletBinding()]
    param($Config = $null)

    $port = 29318
    if ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('paseoCdpPort')) {
                try { $port = [int]$Config['paseoCdpPort'] } catch { $port = 29318 }
            }
            elseif ($Config.ContainsKey('PaseoCdpPort')) {
                try { $port = [int]$Config['PaseoCdpPort'] } catch { $port = 29318 }
            }
        }
        elseif ($Config.PSObject.Properties['PaseoCdpPort']) {
            try { $port = [int]$Config.PaseoCdpPort } catch { $port = 29318 }
        }
        elseif ($Config.PSObject.Properties['paseoCdpPort']) {
            try { $port = [int]$Config.paseoCdpPort } catch { $port = 29318 }
        }
    }
    if ($port -lt 1024 -or $port -gt 65535) { $port = 29318 }
    return $port
}

function Invoke-NotifyPaseoRouteActivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        $Config = $null,
        [int]$TimeoutMs = 20000
    )

    $startedAt = [DateTime]::UtcNow
    $activationFp = Get-NotifyRouteFingerprint -Value $ActivationId

    if ([string]::IsNullOrWhiteSpace($ActivationId)) {
        return [pscustomobject]@{
            Decision     = 'fail-closed'
            OriginKind   = 'paseo'
            Result       = 'invalid'
            Reason       = 'missing-activation-id'
            ActivationFp = $activationFp
            ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            Retryable    = $false
        }
    }

    $activationState = Resolve-NotifyPaseoActivationState -ActivationId $ActivationId
    if (-not $activationState.Available) {
        return [pscustomobject]@{
            Decision     = 'fail-closed'
            OriginKind   = 'paseo'
            Result       = [string]$activationState.Result
            Reason       = [string]$activationState.Reason
            ActivationFp = $activationFp
            ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            Retryable    = $false
        }
    }

    if (-not (Test-NotifyPaseoDesktopRoutingEnabled -Config $Config)) {
        return [pscustomobject]@{
            Decision     = 'fail-closed'
            OriginKind   = 'paseo'
            Result       = 'disabled'
            Reason       = 'routing-disabled'
            ActivationFp = $activationFp
            ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            Retryable    = $true
        }
    }

    $remainingMs = [int][Math]::Floor(([DateTime]::new([int64]$activationState.ExpiresAtTicks, [DateTimeKind]::Utc) - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remainingMs -lt 1000) {
        return [pscustomobject]@{
            Decision = 'fail-closed'; OriginKind = 'paseo'; Result = 'expired'; Reason = 'insufficient-activation-lifetime'
            ActivationFp = $activationFp; ElapsedMs = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds; Retryable = $false
        }
    }
    $effectiveTimeoutMs = [Math]::Min([Math]::Max(500, $TimeoutMs), [Math]::Max(500, $remainingMs - 250))
    $leaseSeconds = [int][Math]::Ceiling($effectiveTimeoutMs / 1000.0) + 5
    $lease = Acquire-NotifyPaseoActivationLease -ActivationId $ActivationId -LeaseSeconds $leaseSeconds
    if (-not $lease.Acquired) {
        $resultName = if ($lease.Result) { [string]$lease.Result } else { 'invalid' }
        $reason = if ($lease.Reason) { [string]$lease.Reason } else { 'activation-unavailable' }
        $retryable = $resultName -in @('busy', 'cdp-unavailable', 'dispatch-failed', 'ack-timeout', 'target-missing')
        return [pscustomobject]@{
            Decision     = 'fail-closed'
            OriginKind   = 'paseo'
            Result       = $resultName
            Reason       = $reason
            ActivationFp = $activationFp
            ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            Retryable    = $retryable
        }
    }

    try {
        $scriptPath = Get-NotifyPaseoDesktopRouteScriptPath
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
            [void](Release-NotifyPaseoActivationLease -ActivationId $ActivationId -LeaseId $lease.LeaseId)
            return [pscustomobject]@{
                Decision     = 'fail-closed'
                OriginKind   = 'paseo'
                Result       = 'controller-missing'
                Reason       = 'route-script-missing'
                ActivationFp = $activationFp
                ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
                Retryable    = $true
            }
        }

        . $scriptPath

        $route = [pscustomobject]@{
            NotificationId   = $lease.NotificationId
            NotificationKind = $lease.NotificationKind
            ServerId         = $lease.ServerId
            WorkspaceId      = $lease.WorkspaceId
            AgentId          = $lease.AgentId
        }

        $controllerResult = Invoke-NotifyPaseoDesktopRouteActivate -Route $route -Config $Config -TimeoutMs $effectiveTimeoutMs
        $resultName = if ($controllerResult.PSObject.Properties['Result'] -and -not [string]::IsNullOrWhiteSpace([string]$controllerResult.Result)) {
            ([string]$controllerResult.Result).Trim()
        } else {
            'dispatch-failed'
        }
        $reason = if ($controllerResult.PSObject.Properties['Reason'] -and -not [string]::IsNullOrWhiteSpace([string]$controllerResult.Reason)) {
            ([string]$controllerResult.Reason).Trim()
        } else {
            ''
        }

        if ($resultName -eq 'activated') {
            if (Consume-NotifyPaseoActivationState -ActivationId $ActivationId -LeaseId $lease.LeaseId) {
                return [pscustomobject]@{
                    Decision     = 'handled'
                    OriginKind   = 'paseo'
                    Result       = 'activated'
                    Reason       = ''
                    ActivationFp = $activationFp
                    ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
                    Retryable    = $false
                }
            }
            return [pscustomobject]@{
                Decision = 'fail-closed'; OriginKind = 'paseo'; Result = 'consume-failed'; Reason = 'activation-consume-failed'
                ActivationFp = $activationFp; ElapsedMs = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds; Retryable = $false
            }
        }

        [void](Release-NotifyPaseoActivationLease -ActivationId $ActivationId -LeaseId $lease.LeaseId)
        $retryable = $resultName -notin @('expired', 'invalid', 'foreign-owner', 'non-loopback', 'ambiguous')
        return [pscustomobject]@{
            Decision     = 'fail-closed'
            OriginKind   = 'paseo'
            Result       = $resultName
            Reason       = $reason
            ActivationFp = $activationFp
            ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            Retryable    = $retryable
        }
    }
    catch {
        $errorType = $_.Exception.GetType().Name
        $errorLine = if ($_.InvocationInfo) { [int]$_.InvocationInfo.ScriptLineNumber } else { 0 }
        try { [void](Release-NotifyPaseoActivationLease -ActivationId $ActivationId -LeaseId $lease.LeaseId) } catch {}
        return [pscustomobject]@{
            Decision     = 'fail-closed'
            OriginKind   = 'paseo'
            Result       = 'controller-error'
            Reason       = ('client-error-{0}-line{1}' -f $errorType, $errorLine)
            ActivationFp = $activationFp
            ElapsedMs    = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
            Retryable    = $true
        }
    }
}

function Test-NotifyPaseoForegroundActiveAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$AgentId,
        $Config = $null,
        [int]$TimeoutMs = 2500
    )

    if (-not (Test-NotifyPaseoDesktopRoutingEnabled -Config $Config)) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'disabled'
            Reason = 'routing-disabled'
        }
    }

    $scriptPath = Get-NotifyPaseoDesktopRouteScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'controller-missing'
            Reason = 'route-script-missing'
        }
    }

    try {
        . $scriptPath
        return Get-NotifyPaseoForegroundAgentState -ServerId $ServerId -AgentId $AgentId -Config $Config -TimeoutMs $TimeoutMs
    }
    catch {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'probe-error'
            Reason = 'controller-error'
        }
    }
}


# --- Paseo parent contracts: close tombstones + authenticated health ---------------

function Get-NotifyPaseoNotificationFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NotificationId)

    if ([string]::IsNullOrWhiteSpace($NotificationId)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($NotificationId.Trim()))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NotifyPaseoCloseTombstoneDir {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-NotifyBridgeBaseDir) 'paseo-close-tombstone')
}

function Get-NotifyPaseoCloseTombstonePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NotificationFingerprint)

    $fp = $NotificationFingerprint.Trim().ToLowerInvariant()
    if ($fp -notmatch '^[0-9a-f]{64}$') { return '' }
    return (Join-Path (Get-NotifyPaseoCloseTombstoneDir) ('close-{0}.json' -f $fp))
}

function Get-NotifyPaseoCloseEventName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NotificationFingerprint)

    $fp = $NotificationFingerprint.Trim().ToLowerInvariant()
    if ($fp -notmatch '^[0-9a-f]{64}$') { return '' }
    return ('Local\PiRemotePaseoClose_{0}' -f $fp)
}

function Enter-NotifyPaseoCloseTombstoneLock {
    [CmdletBinding()]
    param([int]$TimeoutMs = 5000)

    $mutex = [System.Threading.Mutex]::new($false, 'Local\PiRemotePaseoCloseTombstone')
    try {
        if (-not $mutex.WaitOne([Math]::Max(100, $TimeoutMs), $false)) {
            $mutex.Dispose()
            return $null
        }
        return $mutex
    }
    catch [System.Threading.AbandonedMutexException] {
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-NotifyPaseoCloseTombstoneLock {
    [CmdletBinding()]
    param($Mutex)

    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Test-NotifyPaseoCloseTombstonePayload {
    [CmdletBinding()]
    param(
        $Payload,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint
    )

    if ($null -eq $Payload -or $ExpectedFingerprint -notmatch '^[0-9a-f]{64}$') { return $false }
    if (-not $Payload.PSObject.Properties['version'] -or ([string]$Payload.version).Trim() -ne '1') { return $false }
    if (-not $Payload.PSObject.Properties['fingerprint']) { return $false }
    $fingerprint = ([string]$Payload.fingerprint).Trim().ToLowerInvariant()
    if ($fingerprint -notmatch '^[0-9a-f]{64}$') { return $false }
    if (-not $fingerprint.Equals($ExpectedFingerprint, [System.StringComparison]::Ordinal)) { return $false }
    if (-not $Payload.PSObject.Properties['expiresAtTicks']) { return $false }

    $expiresAtTicks = [int64]0
    if (-not [int64]::TryParse([string]$Payload.expiresAtTicks, [ref]$expiresAtTicks)) { return $false }
    $nowTicks = [DateTime]::UtcNow.Ticks
    if ($expiresAtTicks -le $nowTicks) { return $false }
    if ($expiresAtTicks -gt [DateTime]::UtcNow.AddSeconds(1800).Ticks) { return $false }
    return $true
}

function Clear-NotifyPaseoCloseTombstones {
    [CmdletBinding()]
    param(
        [int]$MaxAgeSeconds = 1800,
        [int]$MaxCount = 96
    )

    $dir = Get-NotifyPaseoCloseTombstoneDir
    if (-not (Test-Path -LiteralPath $dir)) { return }

    foreach ($tempItem in @(Get-ChildItem -LiteralPath $dir -Filter 'close-*.json.tmp-*' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $tempItem.FullName -Force -ErrorAction SilentlyContinue
    }

    $cutoff = (Get-Date).AddSeconds(-[Math]::Max(3, $MaxAgeSeconds))
    $items = @(Get-ChildItem -LiteralPath $dir -Filter 'close-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($item in $items) {
        $remove = $item.LastWriteTime -lt $cutoff
        if (-not $remove) {
            try {
                $nameMatch = [regex]::Match($item.Name, '^close-([0-9a-f]{64})\.json$')
                if (-not $nameMatch.Success) {
                    $remove = $true
                }
                else {
                    $payload = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                    $remove = -not (Test-NotifyPaseoCloseTombstonePayload -Payload $payload -ExpectedFingerprint $nameMatch.Groups[1].Value)
                }
            }
            catch {
                $remove = $true
            }
        }
        if ($remove) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $remaining = @(Get-ChildItem -LiteralPath $dir -Filter 'close-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    while ($remaining.Count -gt $MaxCount) {
        try { Remove-Item -LiteralPath $remaining[0].FullName -Force -ErrorAction SilentlyContinue } catch {}
        if ($remaining.Count -gt 0) { $remaining = @($remaining | Select-Object -Skip 1) } else { break }
    }
}

function Test-NotifyPaseoCloseTombstone {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NotificationId)

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) { return $false }
    $fp = Get-NotifyPaseoNotificationFingerprint -NotificationId $NotificationId
    $path = Get-NotifyPaseoCloseTombstonePath -NotificationFingerprint $fp
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $payload = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        if (Test-NotifyPaseoCloseTombstonePayload -Payload $payload -ExpectedFingerprint $fp) {
            return $true
        }
    }
    catch {}

    # Corrupt, partial, expired, or fingerprint-mismatched markers never suppress.
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {}
    return $false
}

function Test-NotifyPaseoCloseSignal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        $CloseEvent = $null
    )

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) { return $false }
    if ($null -ne $CloseEvent) {
        try {
            if ($CloseEvent.WaitOne(0)) { return $true }
        }
        catch {}
    }
    return (Test-NotifyPaseoCloseTombstone -NotificationId $NotificationId)
}

function Save-NotifyPaseoCloseTombstone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [int]$TtlSeconds = 1800
    )

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        return [pscustomobject]@{ Ok = $false; Result = 'invalid'; Fingerprint = '' }
    }

    $fp = Get-NotifyPaseoNotificationFingerprint -NotificationId $NotificationId
    $mutex = Enter-NotifyPaseoCloseTombstoneLock
    if ($null -eq $mutex) {
        return [pscustomobject]@{ Ok = $false; Result = 'retry'; Fingerprint = $fp }
    }
    try {
        $ttl = [Math]::Max(3, [Math]::Min(1800, $TtlSeconds))
        $dir = Get-NotifyPaseoCloseTombstoneDir
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Clear-NotifyPaseoCloseTombstones -MaxAgeSeconds 1800 -MaxCount 95

        $path = Get-NotifyPaseoCloseTombstonePath -NotificationFingerprint $fp
        $payload = @{
            version        = 1
            fingerprint    = $fp
            expiresAtTicks = [DateTime]::UtcNow.AddSeconds($ttl).Ticks
            createdAtUtc   = [DateTime]::UtcNow.ToString('o')
        }
        $tempPath = $path + ('.tmp-{0}' -f [Guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllText($tempPath, ($payload | ConvertTo-Json -Depth 3 -Compress), [System.Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $path) {
                [System.IO.File]::Replace($tempPath, $path, [NullString]::Value)
            }
            else {
                [System.IO.File]::Move($tempPath, $path)
            }
            $tempPath = ''
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($tempPath)) {
                try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch {}
            }
        }

        # Best-effort signal for live fallback popup processes.
        try {
            $eventName = Get-NotifyPaseoCloseEventName -NotificationFingerprint $fp
            if (-not [string]::IsNullOrWhiteSpace($eventName)) {
                $ev = [System.Threading.EventWaitHandle]::new($true, [System.Threading.EventResetMode]::ManualReset, $eventName)
                try { [void]$ev.Set() } finally { $ev.Dispose() }
            }
        }
        catch {}

        return [pscustomobject]@{ Ok = $true; Result = 'ok'; Fingerprint = $fp }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Result = 'retry'; Fingerprint = $fp }
    }
    finally {
        Exit-NotifyPaseoCloseTombstoneLock -Mutex $mutex
    }
}

function Save-NotifyPaseoActivationUnlessClosed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActivationId,
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [Parameter(Mandatory = $true)][string]$NotificationKind,
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$AgentId,
        [int]$TtlSeconds = 1800
    )

    # Serialize the final tombstone check with activation creation. Whichever
    # operation wins first leaves the other side able to converge without resurrection.
    $mutex = Enter-NotifyPaseoCloseTombstoneLock
    if ($null -eq $mutex) {
        return [pscustomobject]@{ Ok = $false; Result = 'retry' }
    }
    try {
        if (Test-NotifyPaseoCloseTombstone -NotificationId $NotificationId) {
            return [pscustomobject]@{ Ok = $true; Result = 'closed' }
        }
        try {
            [void](Save-NotifyPaseoActivationState -ActivationId $ActivationId -NotificationId $NotificationId -NotificationKind $NotificationKind -ServerId $ServerId -WorkspaceId $WorkspaceId -AgentId $AgentId -TtlSeconds $TtlSeconds)
            return [pscustomobject]@{ Ok = $true; Result = 'saved' }
        }
        catch {
            return [pscustomobject]@{ Ok = $false; Result = 'retry' }
        }
    }
    finally {
        Exit-NotifyPaseoCloseTombstoneLock -Mutex $mutex
    }
}

function Revoke-NotifyPaseoActivationByNotificationId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NotificationId)

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        return [pscustomobject]@{ Ok = $false; Result = 'invalid'; Removed = 0; Scanned = 0; TargetFingerprint = '' }
    }

    $targetId = $NotificationId.Trim()
    $mutex = Enter-NotifyPaseoActivationCacheLock
    if ($null -eq $mutex) {
        return [pscustomobject]@{ Ok = $false; Result = 'retry'; Removed = 0; Scanned = 0; TargetFingerprint = '' }
    }
    try {
        Clear-NotifyPaseoActivationCache -MaxAgeSeconds 1800 -MaxCount 96
        $dir = Get-NotifyPaseoActivationCacheDir
        if (-not (Test-Path -LiteralPath $dir)) {
            return [pscustomobject]@{ Ok = $true; Result = 'ok'; Removed = 0; Scanned = 0; TargetFingerprint = '' }
        }

        $items = @(Get-ChildItem -LiteralPath $dir -Filter 'activation-*.json' -File -ErrorAction SilentlyContinue)
        $scanned = 0
        $removed = 0
        $targetFingerprint = ''
        foreach ($item in $items) {
            $scanned += 1
            if ($scanned -gt 96) { break }
            try {
                $payload = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                $state = ConvertFrom-NotifyPaseoActivationPayload -Payload $payload -ActivationId ''
                $notificationId = ''
                $serverId = ''
                $agentId = ''
                if ($state.Available -or $state.Result -eq 'busy') {
                    $notificationId = [string]$state.NotificationId
                    $serverId = [string]$state.ServerId
                    $agentId = [string]$state.AgentId
                }
                else {
                    if ($payload.PSObject.Properties['protectedNotificationId']) {
                        try { $notificationId = Unprotect-NotifyBridgeValue -Value ([string]$payload.protectedNotificationId) } catch { $notificationId = '' }
                    }
                    if ($payload.PSObject.Properties['protectedPaseoServerId']) {
                        try { $serverId = Unprotect-NotifyBridgeValue -Value ([string]$payload.protectedPaseoServerId) } catch { $serverId = '' }
                    }
                    if ($payload.PSObject.Properties['protectedPaseoAgentId']) {
                        try { $agentId = Unprotect-NotifyBridgeValue -Value ([string]$payload.protectedPaseoAgentId) } catch { $agentId = '' }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($notificationId) -and $notificationId.Trim().Equals($targetId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ([string]::IsNullOrWhiteSpace($targetFingerprint) -and -not [string]::IsNullOrWhiteSpace($serverId) -and -not [string]::IsNullOrWhiteSpace($agentId)) {
                        $targetFingerprint = Get-NotifyPaseoTargetFingerprint -ServerId $serverId -AgentId $agentId
                    }
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                    $removed += 1
                }
            }
            catch {
                # Keep scanning; one corrupt entry must not fail close orchestration.
            }
        }
        return [pscustomobject]@{ Ok = $true; Result = 'ok'; Removed = $removed; Scanned = $scanned; TargetFingerprint = $targetFingerprint }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Result = 'retry'; Removed = 0; Scanned = 0; TargetFingerprint = '' }
    }
    finally {
        Exit-NotifyPaseoActivationCacheLock -Mutex $mutex
    }
}

function Revoke-NotifyPaseoToastActivationPointers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NotificationId)

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        return [pscustomobject]@{ Ok = $false; Result = 'invalid'; Removed = 0; Scanned = 0 }
    }

    $targetId = $NotificationId.Trim()
    $removed = 0
    $scanned = 0
    try {
        $logDirs = @((Get-NotifyBridgeLogDir), (Join-Path (Get-NotifyBridgeDefaultBaseDir) 'logs')) | Select-Object -Unique
        foreach ($logDir in $logDirs) {
            if (-not (Test-Path -LiteralPath $logDir)) { continue }
            foreach ($item in @(Get-ChildItem -LiteralPath $logDir -Filter 'activation-*.json' -File -ErrorAction Stop)) {
                $scanned += 1
                if ($scanned -gt 192) { break }
                try {
                    $payload = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                    $originKind = if ($payload.PSObject.Properties['originKind']) { ([string]$payload.originKind).Trim() } else { '' }
                    if ($originKind -ne 'paseo' -or -not $payload.PSObject.Properties['protectedNotificationId']) { continue }
                    $storedId = Unprotect-NotifyBridgeValue -Value ([string]$payload.protectedNotificationId)
                }
                catch {
                    # A malformed/unreadable unrelated pointer is not an exact match.
                    continue
                }
                if (-not $storedId.Trim().Equals($targetId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                try {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                    $removed += 1
                }
                catch {
                    return [pscustomobject]@{ Ok = $false; Result = 'retry'; Removed = $removed; Scanned = $scanned }
                }
            }
            if ($scanned -gt 192) { break }
        }
        return [pscustomobject]@{ Ok = $true; Result = 'ok'; Removed = $removed; Scanned = $scanned }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Result = 'retry'; Removed = $removed; Scanned = $scanned }
    }
}

function Invoke-NotifyBrokerPaseoCloseByNotificationId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        $Config = $null
    )

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        return [pscustomobject]@{ Ok = $false; Result = 'invalid' }
    }

    $port = 23119
    $timeoutMs = 800
    if ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('BrokerPort')) { try { $port = [int]$Config['BrokerPort'] } catch {} }
            elseif ($Config.ContainsKey('brokerPort')) { try { $port = [int]$Config['brokerPort'] } catch {} }
            if ($Config.ContainsKey('BrokerRequestTimeoutMs')) { try { $timeoutMs = [int]$Config['BrokerRequestTimeoutMs'] } catch {} }
            elseif ($Config.ContainsKey('brokerRequestTimeoutMs')) { try { $timeoutMs = [int]$Config['brokerRequestTimeoutMs'] } catch {} }
        }
        else {
            if ($Config.PSObject.Properties['BrokerPort']) { try { $port = [int]$Config.BrokerPort } catch {} }
            if ($Config.PSObject.Properties['BrokerRequestTimeoutMs']) { try { $timeoutMs = [int]$Config.BrokerRequestTimeoutMs } catch {} }
        }
    }
    $timeoutMs = [Math]::Max(200, [Math]::Min(3000, $timeoutMs))

    $payload = @{
        originKind     = 'paseo'
        version        = 1
        notificationId = $NotificationId.Trim()
    } | ConvertTo-Json -Depth 3 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    $client = $null
    $connectHandle = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectResult = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        $connectHandle = $connectResult.AsyncWaitHandle
        if (-not $connectHandle.WaitOne($timeoutMs)) {
            return [pscustomobject]@{ Ok = $true; Result = 'broker-absent' }
        }
        $client.EndConnect($connectResult)
        $client.ReceiveTimeout = $timeoutMs
        $client.SendTimeout = $timeoutMs
        $requestHead = "POST /close HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestHead)
        $stream = $client.GetStream()
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()

        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Min(150, $timeoutMs))
        while (-not $stream.DataAvailable -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 10
        }
        # Broker absence/down is not a close failure: fallback/tombstone still apply.
        return [pscustomobject]@{ Ok = $true; Result = 'ok' }
    }
    catch {
        return [pscustomobject]@{ Ok = $true; Result = 'broker-unreachable' }
    }
    finally {
        if ($null -ne $connectHandle) { try { $connectHandle.Close() } catch {} }
        if ($null -ne $client) { try { $client.Close() } catch {} }
    }
}

function Remove-NotifyPaseoSystemToast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        [string]$TargetFingerprint = '',
        [string]$ToastAppId = 'Pi Remote'
    )

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        return [pscustomobject]@{ Ok = $false; Result = 'invalid' }
    }

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $tag = $NotificationId.Trim()
        $group = if (-not [string]::IsNullOrWhiteSpace($TargetFingerprint)) { $TargetFingerprint.Trim() } else { '' }
        # Exact tag + agent-group only. Never clear an entire group (would remove newer same-agent toasts).
        if (-not [string]::IsNullOrWhiteSpace($group)) {
            [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tag, $group, $ToastAppId)
        }
        else {
            [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tag)
        }
        return [pscustomobject]@{ Ok = $true; Result = 'ok' }
    }
    catch {
        # Best-effort toast-history errors must never fail the overall close path.
        return [pscustomobject]@{ Ok = $true; Result = 'toast-history-unavailable' }
    }
}

function Invoke-NotifyPaseoCloseByNotificationId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NotificationId,
        $Config = $null,
        [string]$ToastAppId = 'Pi Remote'
    )

    if (-not (Test-NotifyRouteUuid -Value $NotificationId)) {
        return [pscustomobject]@{
            Ok = $false
            Result = 'invalid'
            NotificationFp = ''
            RemovedActivations = 0
        }
    }

    $notificationFp = Get-NotifyRouteFingerprint -Value $NotificationId
    $ttlSeconds = Get-NotifyPaseoActivationTtlSeconds -Config $Config
    $tombstone = Save-NotifyPaseoCloseTombstone -NotificationId $NotificationId -TtlSeconds $ttlSeconds
    if (-not $tombstone.Ok) {
        return [pscustomobject]@{
            Ok = $false
            Result = $(if ($tombstone.Result) { [string]$tombstone.Result } else { 'retry' })
            NotificationFp = $notificationFp
            RemovedActivations = 0
        }
    }

    $revoke = Revoke-NotifyPaseoActivationByNotificationId -NotificationId $NotificationId
    if (-not $revoke.Ok -and [string]$revoke.Result -eq 'retry') {
        return [pscustomobject]@{
            Ok = $false
            Result = 'retry'
            NotificationFp = $notificationFp
            RemovedActivations = [int]$revoke.Removed
        }
    }

    $pointerRevoke = Revoke-NotifyPaseoToastActivationPointers -NotificationId $NotificationId
    if (-not $pointerRevoke.Ok) {
        return [pscustomobject]@{
            Ok = $false
            Result = 'retry'
            NotificationFp = $notificationFp
            RemovedActivations = [int]$revoke.Removed
            RemovedPointers = [int]$pointerRevoke.Removed
        }
    }

    $agentFingerprint = if ($revoke.PSObject.Properties['TargetFingerprint']) { [string]$revoke.TargetFingerprint } else { '' }
    [void](Invoke-NotifyBrokerPaseoCloseByNotificationId -NotificationId $NotificationId -Config $Config)
    [void](Remove-NotifyPaseoSystemToast -NotificationId $NotificationId -TargetFingerprint $agentFingerprint -ToastAppId $ToastAppId)

    return [pscustomobject]@{
        Ok = $true
        Result = 'ok'
        NotificationFp = $notificationFp
        RemovedActivations = [int]$revoke.Removed
        RemovedPointers = [int]$pointerRevoke.Removed
    }
}

function Get-NotifyPaseoPersistedElectronFlags {
    [CmdletBinding()]
    param()

    try {
        return [string][Environment]::GetEnvironmentVariable('PASEO_ELECTRON_FLAGS', 'User')
    }
    catch {
        return ''
    }
}

function Test-NotifyPaseoPersistedElectronFlags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$Flags = ''
    )

    if ([string]::IsNullOrWhiteSpace($Flags)) {
        return [pscustomobject]@{ Ok = $false; Result = 'flags-missing' }
    }
    $tokens = @($Flags -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hasPort = $false
    $hasAddress = $false
    $badAddress = $false
    $badPort = $false
    foreach ($token in $tokens) {
        if ($token -match '^--remote-debugging-port=(.+)$') {
            $portText = $Matches[1].Trim()
            $parsed = 0
            if ([int]::TryParse($portText, [ref]$parsed) -and $parsed -eq $Port) {
                $hasPort = $true
            }
            else {
                $badPort = $true
            }
        }
        elseif ($token -eq '--remote-debugging-port') {
            $badPort = $true
        }
        elseif ($token -match '^--remote-debugging-address=(.+)$') {
            $addr = $Matches[1].Trim()
            if ($addr -eq '127.0.0.1') {
                $hasAddress = $true
            }
            else {
                $badAddress = $true
            }
        }
        elseif ($token -eq '--remote-debugging-address') {
            $badAddress = $true
        }
    }
    if ($badPort -or $badAddress) {
        return [pscustomobject]@{ Ok = $false; Result = 'flags-mismatch' }
    }
    if (-not $hasPort -or -not $hasAddress) {
        return [pscustomobject]@{ Ok = $false; Result = 'flags-incomplete' }
    }
    return [pscustomobject]@{ Ok = $true; Result = 'ok' }
}

function Get-NotifyPaseoDisplayReadyState {
    [CmdletBinding()]
    param(
        $Config = $null,
        [string]$DisplayMode = ''
    )

    $mode = ''
    if (-not [string]::IsNullOrWhiteSpace($DisplayMode)) {
        $mode = $DisplayMode.Trim().ToLowerInvariant()
    }
    elseif ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('DisplayMode')) { $mode = ([string]$Config['DisplayMode']).Trim().ToLowerInvariant() }
            elseif ($Config.ContainsKey('displayMode')) { $mode = ([string]$Config['displayMode']).Trim().ToLowerInvariant() }
        }
        else {
            if ($Config.PSObject.Properties['DisplayMode']) { $mode = ([string]$Config.DisplayMode).Trim().ToLowerInvariant() }
            elseif ($Config.PSObject.Properties['displayMode']) { $mode = ([string]$Config.displayMode).Trim().ToLowerInvariant() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'popup-focus' }

    if ($mode -eq 'system-toast') {
        return [pscustomobject]@{ Ready = $true; Result = 'system-toast' }
    }

    $popupScript = Join-Path (Get-NotifyBridgeBinDir) 'pi-notify-popup.ps1'
    if (-not (Test-Path -LiteralPath $popupScript)) {
        $popupScript = Join-Path $PSScriptRoot 'pi-notify-popup.ps1'
    }
    if (Test-Path -LiteralPath $popupScript) {
        return [pscustomobject]@{ Ready = $true; Result = 'popup-script-present' }
    }
    return [pscustomobject]@{ Ready = $false; Result = 'popup-script-missing' }
}

function Get-NotifyPaseoCdpOwnerReadyState {
    [CmdletBinding()]
    param($Owner)

    if ($null -eq $Owner -or -not $Owner.PSObject.Properties['Available']) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'probe-error'; Result = 'owner-response-malformed'; ProbeTargets = $false }
    }
    if ([bool]$Owner.Available) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'owner-ready'; Result = 'owner-ready'; ProbeTargets = $true }
    }
    if ([string]$Owner.Reason -eq 'no-listener') {
        return [pscustomobject]@{ Ready = $true; RouteState = 'app-absent'; Result = 'app-absent'; ProbeTargets = $false }
    }
    if ([string]$Owner.Result -eq 'non-loopback') {
        return [pscustomobject]@{ Ready = $false; RouteState = 'non-loopback'; Result = 'non-loopback'; ProbeTargets = $false }
    }
    if ([string]$Owner.Result -eq 'foreign-owner') {
        return [pscustomobject]@{ Ready = $false; RouteState = 'foreign-owner'; Result = 'foreign-owner'; ProbeTargets = $false }
    }
    if ([string]$Owner.Result -eq 'ambiguous') {
        return [pscustomobject]@{ Ready = $false; RouteState = 'ambiguous'; Result = 'ambiguous'; ProbeTargets = $false }
    }
    return [pscustomobject]@{ Ready = $false; RouteState = 'probe-error'; Result = [string]$Owner.Reason; ProbeTargets = $false }
}

function Get-NotifyPaseoCdpTargetReadyState {
    [CmdletBinding()]
    param(
        $Response,
        [Parameter(Mandatory = $true)][int]$Port
    )

    if ($null -eq $Response -or -not $Response.PSObject.Properties['Ok'] -or $Response.Ok -isnot [bool]) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'malformed'; Result = 'target-response-malformed' }
    }
    if (-not $Response.Ok) {
        $reason = if ($Response.PSObject.Properties['Reason']) { [string]$Response.Reason } else { '' }
        $routeState = if ($reason -eq 'malformed-target-list') { 'malformed' } else { 'cdp-unavailable' }
        return [pscustomobject]@{ Ready = $false; RouteState = $routeState; Result = $(if ($reason) { $reason } else { 'target-probe-failed' }) }
    }
    if (-not $Response.PSObject.Properties['Targets']) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'malformed'; Result = 'targets-missing' }
    }

    $trusted = @(@($Response.Targets) | Where-Object { Test-NotifyPaseoTrustedPageTarget -Target $_ -Port $Port })
    if ($trusted.Count -lt 1) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'target-missing'; Result = 'target-missing' }
    }
    return [pscustomobject]@{ Ready = $true; RouteState = 'ready'; Result = 'ready' }
}

function Get-NotifyPaseoRouteReadyState {
    [CmdletBinding()]
    param($Config = $null)

    # Side-effect free readiness probe. Never launches, kills, restarts, navigates, or mutates env.
    if (-not (Test-NotifyPaseoDesktopRoutingEnabled -Config $Config)) {
        return [pscustomobject]@{
            Ready = $false
            RouteState = 'disabled'
            Result = 'disabled'
        }
    }

    $port = Get-NotifyPaseoCdpPort -Config $Config
    if ($port -lt 1024 -or $port -gt 65535) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'config-invalid'; Result = 'port-out-of-range' }
    }

    $listenerPort = 23118
    $brokerPort = 23119
    if ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('Port')) { try { $listenerPort = [int]$Config['Port'] } catch {} }
            elseif ($Config.ContainsKey('port')) { try { $listenerPort = [int]$Config['port'] } catch {} }
            if ($Config.ContainsKey('BrokerPort')) { try { $brokerPort = [int]$Config['BrokerPort'] } catch {} }
            elseif ($Config.ContainsKey('brokerPort')) { try { $brokerPort = [int]$Config['brokerPort'] } catch {} }
        }
        else {
            if ($Config.PSObject.Properties['Port']) { try { $listenerPort = [int]$Config.Port } catch {} }
            if ($Config.PSObject.Properties['BrokerPort']) { try { $brokerPort = [int]$Config.BrokerPort } catch {} }
        }
    }
    if ($port -eq $listenerPort -or $port -eq $brokerPort) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'config-invalid'; Result = 'port-conflict' }
    }

    $controllerPath = Get-NotifyPaseoDesktopRouteScriptPath
    if ([string]::IsNullOrWhiteSpace($controllerPath) -or -not (Test-Path -LiteralPath $controllerPath)) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'controller-missing'; Result = 'controller-missing' }
    }

    # Load controller helpers for owner/target/exe checks without side effects.
    try {
        if (-not (Get-Command -Name Get-NotifyPaseoCdpOwnerSnapshot -ErrorAction SilentlyContinue)) {
            . $controllerPath
        }
    }
    catch {
        return [pscustomobject]@{ Ready = $false; RouteState = 'controller-error'; Result = 'controller-load-failed' }
    }

    $expectedExe = Get-NotifyPaseoExpectedExecutablePath -Config $Config
    if ([string]::IsNullOrWhiteSpace($expectedExe) -or -not (Test-Path -LiteralPath $expectedExe)) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'executable-missing'; Result = 'executable-missing' }
    }

    $flags = Get-NotifyPaseoPersistedElectronFlags
    $flagState = Test-NotifyPaseoPersistedElectronFlags -Port $port -Flags $flags
    if (-not $flagState.Ok) {
        return [pscustomobject]@{ Ready = $false; RouteState = 'flags-mismatch'; Result = [string]$flagState.Result }
    }

    $owner = Get-NotifyPaseoCdpOwnerSnapshot -Port $port -Config $Config
    $ownerState = Get-NotifyPaseoCdpOwnerReadyState -Owner $owner
    if (-not $ownerState.ProbeTargets) {
        return [pscustomobject]@{ Ready = [bool]$ownerState.Ready; RouteState = [string]$ownerState.RouteState; Result = [string]$ownerState.Result }
    }

    try {
        $response = Get-NotifyPaseoCdpTargetList -Port $port -TimeoutMs 1200
        return Get-NotifyPaseoCdpTargetReadyState -Response $response -Port $port
    }
    catch {
        return [pscustomobject]@{ Ready = $false; RouteState = 'probe-error'; Result = 'target-probe-error' }
    }
}

function Get-NotifyPaseoHealthSnapshot {
    [CmdletBinding()]
    param(
        $Config = $null,
        [string]$DisplayMode = ''
    )

    $listenerReady = $true
    $display = Get-NotifyPaseoDisplayReadyState -Config $Config -DisplayMode $DisplayMode
    $route = Get-NotifyPaseoRouteReadyState -Config $Config
    $ready = [bool]($listenerReady -and $display.Ready -and $route.Ready)

    return [pscustomobject]@{
        version       = 1
        ready         = $ready
        listenerReady = $listenerReady
        displayReady  = [bool]$display.Ready
        routeReady    = [bool]$route.Ready
        routeState    = [string]$route.RouteState
        capabilities  = [pscustomobject]@{
            notifyV1            = $true
            closeV1             = $true
            existingClickEventV1 = $true
        }
    }
}

function ConvertTo-NotifyPaseoHealthJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot
    )

    # Fixed schema only: never emit token/paths/ports/PIDs/URLs/route IDs/title/body.
    $payload = [ordered]@{
        version       = 1
        ready         = [bool]$Snapshot.ready
        listenerReady = [bool]$Snapshot.listenerReady
        displayReady  = [bool]$Snapshot.displayReady
        routeReady    = [bool]$Snapshot.routeReady
        routeState    = [string]$Snapshot.routeState
        capabilities  = [ordered]@{
            notifyV1             = $true
            closeV1              = $true
            existingClickEventV1 = $true
        }
    }
    return ($payload | ConvertTo-Json -Depth 4 -Compress)
}

function Resolve-NotifyPaseoCloseRequest {
    [CmdletBinding()]
    param($Payload)

    $originKind = Get-NotifyPayloadStringField -Payload $Payload -Name 'originKind'
    $notificationId = Get-NotifyPayloadStringField -Payload $Payload -Name 'notificationId'
    $versionRaw = ''
    if ($null -ne $Payload -and $Payload.PSObject.Properties['version']) {
        try { $versionRaw = [string]$Payload.version } catch { $versionRaw = '' }
        if ([string]::IsNullOrWhiteSpace($versionRaw)) {
            $versionRaw = Get-NotifyPayloadStringField -Payload $Payload -Name 'version'
        }
    }

    $result = [pscustomobject]@{
        IsValid        = $false
        OriginKind     = $originKind
        NotificationId = $notificationId
        Version        = $versionRaw
        InvalidReason  = ''
    }

    # The external contract is exact: no benign-looking extension fields are accepted.
    $properties = if ($null -eq $Payload) { @() } else { @($Payload.PSObject.Properties) }
    $allowed = @('originKind', 'version', 'notificationId')
    if ($properties.Count -ne $allowed.Count) {
        $result.InvalidReason = 'unexpected-field'
        return $result
    }
    foreach ($property in $properties) {
        if ($allowed -cnotcontains [string]$property.Name) {
            $result.InvalidReason = 'unexpected-field'
            return $result
        }
    }
    foreach ($required in $allowed) {
        if ($properties.Name -cnotcontains $required) {
            $result.InvalidReason = 'unexpected-field'
            return $result
        }
    }

    if ($originKind -ne 'paseo') {
        $result.InvalidReason = 'origin-kind'
        return $result
    }
    if (($versionRaw + '').Trim() -ne '1') {
        $result.InvalidReason = 'version'
        return $result
    }
    if (-not (Test-NotifyRouteUuid -Value $notificationId)) {
        $result.InvalidReason = 'notification-id'
        return $result
    }

    $result.IsValid = $true
    $result.Version = '1'
    $result.NotificationId = $notificationId.Trim()
    return $result
}
