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
        [int]$RetryAttempt = 0
    )

    $typeName = if ($Request.ContainsKey('type')) { [string]$Request['type'] } else { '' }
    $typeFp = Get-NotifyRouteFingerprint -Value $typeName

    if ($script:NotifyRouteHostClientMock -is [scriptblock]) {
        return & $script:NotifyRouteHostClientMock $Request $WaitMs
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

    if (-not $available -or $resultName -eq 'adapter-unavailable' -or $reason -in @('route-host-missing', 'client-error', 'empty-response')) {
        return [pscustomobject]@{
            Decision = 'fail-closed'
            Result   = if ($resultName) { $resultName } else { 'adapter-unavailable' }
            Reason   = if ($reason) { $reason } else { 'adapter-unavailable' }
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
        [int]$ActivateWaitMs = 15000,
        [int]$ActivateTimeoutMs = 18000
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
        [int]$WaitMs = 5000,
        [int]$TimeoutMs = 8000
    )

    $now = Get-NotifyUnixTimeMilliseconds
    $fields = @{
        notificationId = $NotificationId
        snapshotId     = $SnapshotId
        deadlineMs     = ($now + [Math]::Max(500, $WaitMs))
    }
    $envelope = New-NotifyRouteRequestEnvelope -Type 'activate' -Fields $fields -TtlMs ([Math]::Max(5000, $WaitMs + 1000))
    $request = @{}
    foreach ($k in $envelope.Keys) { $request[$k] = $envelope[$k] }

    $clientResult = Invoke-NotifyRouteHostClient -Request $request -WaitMs $WaitMs -TimeoutMs $TimeoutMs -Config $Config
    return [pscustomobject]@{
        ClientResult = $clientResult
        Decision     = (Get-NotifyRouteActivateDecision -OriginKind 'pi-web' -NotificationId $NotificationId -SnapshotId $SnapshotId -ClientResult $clientResult)
    }
}
