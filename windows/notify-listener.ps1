[CmdletBinding()]
param(
    [string]$ListenHost,
    [int]$Port,
    [string]$Token,
    [string]$ConfigPath,
    [string]$AppId = "Pi Remote",
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

$configArgs = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArgs.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('ListenHost')) { $configArgs.ListenHost = $ListenHost }
if ($PSBoundParameters.ContainsKey('Port')) { $configArgs.Port = $Port }
if ($PSBoundParameters.ContainsKey('Token')) { $configArgs.Token = $Token }
$config = Ensure-NotifyBridgeConfig @configArgs
$ListenHost = $config.ListenHost
$Port = $config.Port
$Token = $config.Token
$ConfigPath = $config.ConfigPath
$DisplayMode = $config.DisplayMode
$PopupTimeoutSeconds = $config.PopupTimeoutSeconds
$script:NotifyMaxBodyBytes = 1048576
$script:NotifyToastEventHandlers = New-Object System.Collections.ArrayList
$script:NotifyActivationScript = Join-Path $PSScriptRoot 'pi-notify-activate.ps1'
$script:NotifyPopupScript = Join-Path $PSScriptRoot 'pi-notify-popup.ps1'
$script:NotifyPowerShellExe = Get-NotifyBridgePowerShellExe
$script:NotifyListenerLogPath = Join-Path (Get-NotifyBridgeLogDir) 'listener.log'
$script:NotifyPopupStdoutLogPath = Join-Path (Get-NotifyBridgeLogDir) 'popup-stdout.log'
$script:NotifyPopupStderrLogPath = Join-Path (Get-NotifyBridgeLogDir) 'popup-stderr.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NotifyListenerLogPath) | Out-Null

function Write-NotifyListenerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:NotifyListenerLogPath -Value $line -Encoding UTF8
}

function Write-HttpResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [string]$Body = "",
        [string]$ContentType = "text/plain; charset=utf-8"
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
    $header = "HTTP/1.1 $StatusCode $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Read-HttpRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream
    )

    $buffer = [byte[]]::new(4096)
    $memory = [System.IO.MemoryStream]::new()
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }

        $memory.Write($buffer, 0, $read)
        $bytes = $memory.ToArray()
        $startIndex = [Math]::Max(0, $bytes.Length - $read - 3)
        for ($i = $startIndex; $i -le $bytes.Length - 4; $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) {
                $headerEnd = $i + 4
                break
            }
        }

        if ($memory.Length -gt 65536) {
            throw "HTTP header too large."
        }
    }

    if ($headerEnd -lt 0) {
        throw "Incomplete HTTP request header."
    }

    $allBytes = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = if ($lines.Length -gt 0) { [string]$lines[0] } else { '' }
    $requestLine = $requestLine.Trim()
    if ([string]::IsNullOrWhiteSpace($requestLine)) {
        throw "Missing HTTP request line."
    }

    $headers = @{}
    if ($lines.Length -gt 1) {
        foreach ($line in $lines[1..($lines.Length - 1)]) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $index = $line.IndexOf(':')
            if ($index -le 0) {
                continue
            }
            $headers[$line.Substring(0, $index).Trim()] = $line.Substring($index + 1).Trim()
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) {
        $contentLengthValid = [int]::TryParse([string]$headers['Content-Length'], [ref]$contentLength)
        if (-not $contentLengthValid -or $contentLength -lt 0) {
            throw "Invalid Content-Length header."
        }
        if ($contentLength -gt $script:NotifyMaxBodyBytes) {
            throw "HTTP body too large."
        }
    }

    $bodyMemory = [System.IO.MemoryStream]::new()
    $existingBytes = $allBytes.Length - $headerEnd
    if ($existingBytes -gt 0) {
        $bodyMemory.Write($allBytes, $headerEnd, $existingBytes)
    }

    while ($bodyMemory.Length -lt $contentLength) {
        $remaining = [Math]::Min($buffer.Length, $contentLength - [int]$bodyMemory.Length)
        $read = $Stream.Read($buffer, 0, $remaining)
        if ($read -le 0) {
            break
        }
        $bodyMemory.Write($buffer, 0, $read)
    }

    $bodyBytes = $bodyMemory.ToArray()
    if ($bodyBytes.Length -gt $contentLength) {
        $trimmed = [byte[]]::new($contentLength)
        [Array]::Copy($bodyBytes, 0, $trimmed, 0, $contentLength)
        $bodyBytes = $trimmed
    }

    return [pscustomobject]@{
        RequestLine = $requestLine
        Headers     = $headers
        BodyBytes   = $bodyBytes
    }
}

function Get-NotifyBridgeActivationUri {
    param(
        [string]$TargetHost,
        [string]$CwdBase,
        [string]$TabTitle
    )

    $protocol = Get-NotifyBridgeProtocolName
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($TargetHost)) {
        $parts += ('host=' + [Uri]::EscapeDataString($TargetHost.Trim()))
    }
    if (-not [string]::IsNullOrWhiteSpace($CwdBase)) {
        $parts += ('cwdBase=' + [Uri]::EscapeDataString($CwdBase.Trim()))
    }
    if (-not [string]::IsNullOrWhiteSpace($TabTitle)) {
        $parts += ('tabTitle=' + [Uri]::EscapeDataString($TabTitle.Trim()))
    }

    if ($parts.Count -gt 0) {
        return ('{0}://focus?{1}' -f $protocol, ($parts -join '&'))
    }

    return ('{0}://focus' -f $protocol)
}

function Get-NotifyPopupTargetKey {
    param(
        [string]$FocusTarget,
        [string]$CwdBase,
        [string]$TabTitle
    )

    $normalizedHost = ''
    $normalizedCwd = ''
    $normalizedTab = ''
    if (-not [string]::IsNullOrWhiteSpace($FocusTarget)) { $normalizedHost = $FocusTarget.Trim().ToLowerInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($CwdBase)) { $normalizedCwd = $CwdBase.Trim().ToLowerInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($TabTitle)) { $normalizedTab = $TabTitle.Trim().ToLowerInvariant() }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((@($normalizedHost, $normalizedCwd, $normalizedTab) -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-NotifyToastActivation {
    param(
        [string]$LaunchUri
    )

    if ([string]::IsNullOrWhiteSpace($LaunchUri)) {
        return
    }

    if (-not (Test-Path -LiteralPath $script:NotifyActivationScript)) {
        return
    }

    Start-Process -FilePath $script:NotifyPowerShellExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:NotifyActivationScript,
        '-ConfigPath', $ConfigPath,
        $LaunchUri
    ) | Out-Null
}

function Show-Toast {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Body,
        [Parameter(Mandatory = $true)]
        [string]$ToastAppId,
        [string]$LaunchUri
    )

    $focusTarget = $config.RemoteHostAlias
    $cwdBase = ''
    $tabTitle = ''
    if (-not [string]::IsNullOrWhiteSpace($LaunchUri)) {
        try {
            $parsed = [Uri]$LaunchUri
            $query = $parsed.Query.TrimStart('?')
            foreach ($pair in $query -split '&') {
                if ([string]::IsNullOrWhiteSpace($pair)) { continue }
                $parts = $pair -split '=', 2
                $name = [Uri]::UnescapeDataString(([string]$parts[0]).Replace('+', ' '))
                $value = if ($parts.Length -gt 1) { [Uri]::UnescapeDataString(([string]$parts[1]).Replace('+', ' ')) } else { '' }
                if ($name -eq 'host' -and -not [string]::IsNullOrWhiteSpace($value)) { $focusTarget = $value }
                if ($name -eq 'cwdBase' -and -not [string]::IsNullOrWhiteSpace($value)) { $cwdBase = $value }
                if ($name -eq 'tabTitle' -and -not [string]::IsNullOrWhiteSpace($value)) { $tabTitle = $value }
            }
        }
        catch {
        }
    }

    if ($DisplayMode -eq 'popup-focus' -and (Test-Path -LiteralPath $script:NotifyPopupScript)) {
        $payloadPath = Join-Path (Get-NotifyBridgeLogDir) 'popup-payload.json'
        $payload = @{
            title          = $Title
            body           = $Body
            focusTarget    = $focusTarget
            cwdBase        = $cwdBase
            tabTitle       = $tabTitle
            timeoutSeconds = $PopupTimeoutSeconds
        }
        [System.IO.File]::WriteAllText($payloadPath, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        $targetKey = Get-NotifyPopupTargetKey -FocusTarget $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle

        # ponytail: one popup process per notification. The daemon watcher can
        # miss later payload writes; short-lived popups are boring and reliable.
        try {
            Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object { $_.CommandLine -like '*pi-notify-popup.ps1*' -and $_.CommandLine -like '*-Daemon*' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        catch {
            Write-NotifyListenerLog -Message ('popup-daemon-cleanup-error "{0}"' -f $_.Exception.Message)
        }

        try {
            $oldPopups = @(Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object {
                    $_.CommandLine -like '*pi-notify-popup.ps1*' -and
                    ($_.CommandLine -like ('*-TargetKey*{0}*' -f $targetKey) -or $_.CommandLine -notlike '*-TargetKey*')
                })
            foreach ($oldPopup in $oldPopups) {
                Stop-Process -Id $oldPopup.ProcessId -Force -ErrorAction SilentlyContinue
            }
            if ($oldPopups.Count -gt 0) {
                Write-NotifyListenerLog -Message ('popup-replaced-old targetKey={0} count={1}' -f $targetKey, $oldPopups.Count)
            }
        }
        catch {
            Write-NotifyListenerLog -Message ('popup-replace-old-error targetKey={0} "{1}"' -f $targetKey, $_.Exception.Message)
        }

        foreach ($pathToClear in @($script:NotifyPopupStdoutLogPath, $script:NotifyPopupStderrLogPath)) {
            try {
                if (Test-Path -LiteralPath $pathToClear) {
                    Remove-Item -LiteralPath $pathToClear -Force -ErrorAction Stop
                }
            }
            catch {
            }
        }

        Write-NotifyListenerLog -Message ('popup-launch title="{0}" focusTarget="{1}" cwdBase="{2}" targetKey={3} timeout={4} payload="{5}" stdout="{6}" stderr="{7}"' -f $Title, $focusTarget, $cwdBase, $targetKey, $PopupTimeoutSeconds, $payloadPath, $script:NotifyPopupStdoutLogPath, $script:NotifyPopupStderrLogPath)
        $popupProcess = Start-Process -FilePath $script:NotifyPowerShellExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script:NotifyPopupScript,
            '-ConfigPath', $ConfigPath,
            '-PayloadPath', $payloadPath,
            '-TargetKey', $targetKey
        ) -RedirectStandardOutput $script:NotifyPopupStdoutLogPath -RedirectStandardError $script:NotifyPopupStderrLogPath -PassThru
        Write-NotifyListenerLog -Message ('popup-pid {0}' -f $popupProcess.Id)
        return
    }

    $type = 'Windows.UI.Notifications'
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null

    $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
    # scenario="reminder" keeps the toast on screen until user dismisses it
    $toastNode = $xml.SelectSingleNode('/toast')
    if ($null -ne $toastNode) {
        $scenarioAttr = $xml.CreateAttribute('scenario')
        $scenarioAttr.Value = 'reminder'
        $toastNode.Attributes.Append($scenarioAttr) | Out-Null
        # reminder scenario requires at least one action
        $actionsNode = $xml.CreateElement('actions')
        $actionNode = $xml.CreateElement('action')
        $actionNode.SetAttribute('content', 'dismiss')
        $actionNode.SetAttribute('arguments', 'dismiss')
        $actionsNode.AppendChild($actionNode) | Out-Null
        $toastNode.AppendChild($actionsNode) | Out-Null
    }
    $texts = $xml.GetElementsByTagName('text')
    $texts.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
    $texts.Item(1).AppendChild($xml.CreateTextNode($Body)) | Out-Null

    Write-NotifyListenerLog -Message ('system-toast title="{0}" body="{1}"' -f $Title, $Body)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
}

$ipAddress = [System.Net.IPAddress]::Parse($ListenHost)
$listener = [System.Net.Sockets.TcpListener]::new($ipAddress, $Port)
$listener.Server.ReceiveTimeout = 15000
$listener.Server.SendTimeout = 15000
$listener.Start()

Write-Host (("Pi notify listener running at http://{0}:{1}/notify" -f $ListenHost, $Port))
Write-Host "Config: $ConfigPath"
Write-Host "Remote endpoint through ssh -R: $($config.RemoteUrl)"
Write-NotifyListenerLog -Message ('listener-start url={0} config="{1}" mode={2}' -f $config.LocalUrl, $ConfigPath, $DisplayMode)

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $notified = $false
        $stream = $null
        try {
            $client.ReceiveTimeout = 15000
            $client.SendTimeout = 15000
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream

            $parts = $request.RequestLine.Split(' ', 3)
            $method = if ($parts.Length -ge 1) { $parts[0].ToUpperInvariant() } else { '' }
            $path = if ($parts.Length -ge 2) { $parts[1] } else { '/' }

            if ($method -eq 'GET' -and $path -eq '/health') {
                Write-NotifyListenerLog -Message 'health-check ok'
                Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body '{"ok":true}' -ContentType 'application/json; charset=utf-8'
                continue
            }

            if ($method -ne 'POST') {
                Write-HttpResponse -Stream $stream -StatusCode 405 -Reason 'Method Not Allowed' -Body 'method not allowed'
                continue
            }

            if ($path -notin @('/', '/notify')) {
                Write-HttpResponse -Stream $stream -StatusCode 404 -Reason 'Not Found' -Body 'not found'
                continue
            }

            $headerToken = [string]$request.Headers['X-Pi-Notify-Token']
            if ($headerToken -ne $Token) {
                Write-HttpResponse -Stream $stream -StatusCode 403 -Reason 'Forbidden' -Body 'forbidden'
                continue
            }

            $bodyText = if ($request.BodyBytes.Length -gt 0) {
                [System.Text.Encoding]::UTF8.GetString($request.BodyBytes)
            }
            else {
                ''
            }

            $payload = $null
            if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                $payload = $bodyText | ConvertFrom-Json
            }

            $title = 'Pi'
            $body = 'Ready for input'
            $focusTarget = [string]$config.RemoteHostAlias
            $cwdBase = ''
            $tabTitle = ''
            if ($null -ne $payload) {
                if ($payload.PSObject.Properties['title'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.title)) {
                    $title = [string]$payload.title
                }
                if ($payload.PSObject.Properties['body'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.body)) {
                    $body = [string]$payload.body
                }
                if ($payload.PSObject.Properties['focusTarget'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.focusTarget)) {
                    $focusTarget = [string]$payload.focusTarget
                }
                if ($payload.PSObject.Properties['cwdBase'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.cwdBase)) {
                    $cwdBase = [string]$payload.cwdBase
                }
                if ($payload.PSObject.Properties['tabTitle'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.tabTitle)) {
                    $tabTitle = [string]$payload.tabTitle
                }
            }
            $title = if ([string]::IsNullOrWhiteSpace($title)) { 'Pi' } else { $title.Trim() }
            $body = if ([string]::IsNullOrWhiteSpace($body)) { 'Ready for input' } else { $body.Trim() }
            $tabTitle = if ([string]::IsNullOrWhiteSpace($tabTitle)) { '' } else { $tabTitle.Trim() }
            $launchUri = Get-NotifyBridgeActivationUri -TargetHost $focusTarget -CwdBase $cwdBase -TabTitle $tabTitle

            Write-NotifyListenerLog -Message ('notify title="{0}" body="{1}" tabTitle="{2}" launchUri="{3}"' -f $title, $body, $tabTitle, $launchUri)
            Show-Toast -Title $title -Body $body -ToastAppId $AppId -LaunchUri $launchUri
            $notified = $true
            Write-Host ("[{0}] notify: {1} :: {2}" -f (Get-Date -Format 'HH:mm:ss'), $title, $body)
            Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Body 'ok'
        }
        catch {
            try {
                if ($stream) {
                    Write-HttpResponse -Stream $stream -StatusCode 500 -Reason 'Internal Server Error' -Body 'error'
                }
            }
            catch {
            }
            Write-NotifyListenerLog -Message ('error "{0}"' -f $_.Exception.Message)
            Write-Warning $_.Exception.Message
        }
        finally {
            try {
                $client.Close()
            }
            catch {
            }
        }

        if ($Once -and $notified) {
            break
        }
    }
}
finally {
    try {
        $listener.Stop()
    }
    catch {
    }
}
