# Paseo desktop route controller (loopback CDP only).
# Dot-source this module; do not execute as a standalone CLI with plaintext route files.
# It dispatches the existing renderer click event only: no direct navigation, cold launch,
# process restart, click-time environment mutation, remote CDP, or plaintext route files.

Set-StrictMode -Version Latest

if (-not (Get-Command -Name Get-NotifyRouteFingerprint -ErrorAction SilentlyContinue)) {
    throw 'paseo-desktop-route.ps1 must be dot-sourced after NotifyBridge.Common.ps1'
}
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {}

function Get-NotifyPaseoCdpHostCandidates {
    [CmdletBinding()]
    param()
    return @('127.0.0.1', '::1')
}

function Test-NotifyPaseoLoopbackAddress {
    [CmdletBinding()]
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $text = $Address.Trim().ToLowerInvariant()
    if ($text.StartsWith('[') -and $text.EndsWith(']') -and $text.Length -gt 2) {
        $text = $text.Substring(1, $text.Length - 2)
    }
    return ($text -eq '127.0.0.1' -or $text -eq '::1')
}

function Get-NotifyPaseoCdpPortFromConfig {
    [CmdletBinding()]
    param($Config = $null)

    if (Get-Command -Name Get-NotifyPaseoCdpPort -ErrorAction SilentlyContinue) {
        return Get-NotifyPaseoCdpPort -Config $Config
    }
    return 29318
}

function Test-NotifyPaseoListenerPortConflict {
    [CmdletBinding()]
    param(
        [int]$Port,
        $Config = $null
    )

    $listenerPort = 23118
    $brokerPort = 23119
    if ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('port')) { try { $listenerPort = [int]$Config['port'] } catch {} }
            if ($Config.ContainsKey('Port')) { try { $listenerPort = [int]$Config['Port'] } catch {} }
            if ($Config.ContainsKey('brokerPort')) { try { $brokerPort = [int]$Config['brokerPort'] } catch {} }
            if ($Config.ContainsKey('BrokerPort')) { try { $brokerPort = [int]$Config['BrokerPort'] } catch {} }
        }
        else {
            if ($Config.PSObject.Properties['Port']) { try { $listenerPort = [int]$Config.Port } catch {} }
            if ($Config.PSObject.Properties['BrokerPort']) { try { $brokerPort = [int]$Config.BrokerPort } catch {} }
        }
    }
    return ($Port -eq $listenerPort -or $Port -eq $brokerPort)
}

function Get-NotifyPaseoExpectedExecutablePath {
    [CmdletBinding()]
    param($Config = $null)

    $configured = ''
    if ($null -ne $Config) {
        if ($Config -is [hashtable]) {
            if ($Config.ContainsKey('PaseoExecutablePath')) { $configured = [string]$Config['PaseoExecutablePath'] }
            elseif ($Config.ContainsKey('paseoExecutablePath')) { $configured = [string]$Config['paseoExecutablePath'] }
        }
        elseif ($Config.PSObject.Properties['PaseoExecutablePath']) { $configured = [string]$Config.PaseoExecutablePath }
        elseif ($Config.PSObject.Properties['paseoExecutablePath']) { $configured = [string]$Config.paseoExecutablePath }
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return '' }
    $standardPath = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\Paseo\Paseo.exe'))
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        try {
            $full = [System.IO.Path]::GetFullPath($configured.Trim())
            if (-not $full.Equals($standardPath, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
            return $full
        }
        catch { return '' }
    }

    return $standardPath
}

function Get-NotifyPaseoCdpOwnerSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        $Config = $null,
        [scriptblock]$ConnectionProbe = $null,
        [scriptblock]$ProcessProbe = $null
    )

    $result = [pscustomobject]@{
        Available        = $false
        Result           = 'probe-error'
        Reason           = 'listener-probe-unavailable'
        OwnerProcessId   = 0
        OwnerProcessName = ''
        LocalAddresses   = @()
        NonLoopback      = $false
        ForeignOwner     = $false
    }

    # Enumerate all listeners before filtering so an empty result is proven and
    # cannot be confused with Get-NetTCPConnection lookup/access failures.
    if ($null -eq $ConnectionProbe) {
        if (-not (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
            return $result
        }
        $ConnectionProbe = {
            param($TargetPort)
            @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { [int]$_.LocalPort -eq [int]$TargetPort })
        }
    }
    try {
        $connections = @(& $ConnectionProbe $Port)
    }
    catch {
        $result.Reason = 'listener-probe-failed'
        return $result
    }

    if ($connections.Count -eq 0) {
        $result.Result = 'cdp-unavailable'
        $result.Reason = 'no-listener'
        return $result
    }

    $addresses = @()
    $ownerIds = @()
    foreach ($conn in $connections) {
        $addr = [string]$conn.LocalAddress
        $addresses += $addr
        if (-not (Test-NotifyPaseoLoopbackAddress -Address $addr)) {
            $result.NonLoopback = $true
        }
        try {
            $ownerIds += [int]$conn.OwningProcess
        }
        catch {
            $result.Reason = 'owner-id-unreadable'
            return $result
        }
    }
    $result.LocalAddresses = @($addresses | Select-Object -Unique)

    if ($result.NonLoopback) {
        $result.Result = 'non-loopback'
        $result.Reason = 'listener-not-loopback'
        return $result
    }

    $ownerIds = @($ownerIds | Select-Object -Unique)
    if ($ownerIds.Count -ne 1) {
        $result.Result = 'ambiguous'
        $result.Reason = 'multiple-owners'
        return $result
    }

    $ownerId = [int]$ownerIds[0]
    if ($null -eq $ProcessProbe) {
        $ProcessProbe = { param($TargetProcessId) Get-Process -Id $TargetProcessId -ErrorAction Stop }
    }
    try {
        $proc = & $ProcessProbe $ownerId
        $ownerName = [string]$proc.ProcessName
        $ownerPath = [string]$proc.Path
    }
    catch {
        $result.Reason = 'owner-probe-failed'
        return $result
    }

    $result.OwnerProcessId = $ownerId
    $result.OwnerProcessName = $ownerName
    if ($ownerName -notmatch '(?i)^paseo$') {
        $result.Result = 'foreign-owner'
        $result.Reason = 'owner-not-paseo'
        $result.ForeignOwner = $true
        return $result
    }

    $expectedPath = Get-NotifyPaseoExpectedExecutablePath -Config $Config
    if ([string]::IsNullOrWhiteSpace($expectedPath) -or [string]::IsNullOrWhiteSpace($ownerPath)) {
        $result.Reason = 'owner-path-unverified'
        return $result
    }
    try { $ownerPath = [System.IO.Path]::GetFullPath($ownerPath) } catch {
        $result.Reason = 'owner-path-unreadable'
        return $result
    }
    if (-not $ownerPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Result = 'foreign-owner'
        $result.Reason = 'owner-path-mismatch'
        $result.ForeignOwner = $true
        return $result
    }

    $result.Available = $true
    $result.Result = 'ready'
    $result.Reason = ''
    return $result
}

function Invoke-NotifyPaseoHttpGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 1500
    )

    $client = $null
    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromMilliseconds([Math]::Max(250, $TimeoutMs))
        $task = $client.GetStringAsync($Url)
        if (-not $task.Wait([Math]::Max(250, $TimeoutMs))) {
            return [pscustomobject]@{ Ok = $false; Body = ''; Reason = 'timeout' }
        }
        return [pscustomobject]@{ Ok = $true; Body = [string]$task.Result; Reason = '' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Body = ''; Reason = 'http-error' }
    }
    finally {
        if ($null -ne $client) { try { $client.Dispose() } catch {} }
    }
}

function Get-NotifyPaseoCdpTargetList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 1500
    )

    $hosts = @(Get-NotifyPaseoCdpHostCandidates)
    foreach ($hostName in $hosts) {
        $url = if ($hostName -eq '::1') {
            ('http://[{0}]:{1}/json/list' -f $hostName, $Port)
        }
        else {
            ('http://{0}:{1}/json/list' -f $hostName, $Port)
        }
        $response = Invoke-NotifyPaseoHttpGet -Url $url -TimeoutMs $TimeoutMs
        if (-not $response.Ok -or [string]::IsNullOrWhiteSpace($response.Body)) {
            continue
        }
        try {
            $parsed = $response.Body | ConvertFrom-Json
            $items = @($parsed)
            return [pscustomobject]@{
                Ok      = $true
                Host    = $hostName
                Targets = $items
                Reason  = ''
            }
        }
        catch {
            return [pscustomobject]@{
                Ok      = $false
                Host    = $hostName
                Targets = @()
                Reason  = 'malformed-target-list'
            }
        }
    }

    return [pscustomobject]@{
        Ok      = $false
        Host    = ''
        Targets = @()
        Reason  = 'cdp-unavailable'
    }
}

function Test-NotifyPaseoTrustedPageTarget {
    [CmdletBinding()]
    param(
        $Target,
        [int]$Port = 0
    )

    if ($null -eq $Target) { return $false }
    $typeName = if ($Target.PSObject.Properties['type']) { ([string]$Target.type).Trim().ToLowerInvariant() } else { '' }
    if ($typeName -ne 'page') { return $false }

    $targetId = if ($Target.PSObject.Properties['id']) { ([string]$Target.id).Trim() } else { '' }
    $url = if ($Target.PSObject.Properties['url']) { [string]$Target.url } else { '' }
    $webSocketDebuggerUrl = if ($Target.PSObject.Properties['webSocketDebuggerUrl']) { [string]$Target.webSocketDebuggerUrl } else { '' }
    if ([string]::IsNullOrWhiteSpace($targetId) -or $targetId.Length -gt 256 -or $targetId -match '[\x00-\x1F\x7F-\x9F]') { return $false }
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($webSocketDebuggerUrl)) { return $false }

    try {
        $pageUri = [Uri]$url
        $wsUri = [Uri]$webSocketDebuggerUrl
    }
    catch { return $false }

    # A title or substring is not an authority boundary. Trust only the desktop app scheme
    # and the exact websocket endpoint belonging to this page id.
    if ($pageUri.Scheme -ne 'paseo' -or $pageUri.Host -ne 'app') { return $false }
    if ($wsUri.Scheme -ne 'ws' -or -not (Test-NotifyPaseoLoopbackAddress -Address $wsUri.Host)) { return $false }
    if ($Port -gt 0 -and $wsUri.Port -ne $Port) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($wsUri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($wsUri.Query) -or -not [string]::IsNullOrWhiteSpace($wsUri.Fragment)) { return $false }
    $expectedWsPath = '/devtools/page/{0}' -f $targetId
    $actualWsPath = ''
    try { $actualWsPath = [Uri]::UnescapeDataString($wsUri.AbsolutePath) } catch { return $false }
    if (-not $actualWsPath.Equals($expectedWsPath, [System.StringComparison]::Ordinal)) { return $false }
    return $true
}

function ConvertFrom-NotifyPaseoRendererRouteState {
    [CmdletBinding()]
    param(
        [string]$Pathname = '',
        [string]$Search = ''
    )

    $serverId = ''
    $agentId = ''
    $workspaceId = ''

    if ($Pathname -match '/h/([^/]+)') {
        try { $serverId = [Uri]::UnescapeDataString($Matches[1]) } catch { $serverId = $Matches[1] }
    }
    if ($Pathname -match '/workspace/([^/?#]+)') {
        try { $workspaceId = [Uri]::UnescapeDataString($Matches[1]) } catch { $workspaceId = $Matches[1] }
    }
    if ($Search -match '(?:^|[?&])open=([^&]+)') {
        $openRaw = $Matches[1]
        try { $openRaw = [Uri]::UnescapeDataString($openRaw) } catch {}
        if ($openRaw -match '^agent:(.+)$') {
            $agentId = $Matches[1]
        }
    }
    elseif ($Pathname -match '/agent/([^/?#]+)') {
        try { $agentId = [Uri]::UnescapeDataString($Matches[1]) } catch { $agentId = $Matches[1] }
    }

    return [pscustomobject]@{
        ServerId    = $serverId
        WorkspaceId = $workspaceId
        AgentId     = $agentId
        Pathname    = $Pathname
        Search      = $Search
    }
}

function New-NotifyPaseoCdpEvaluateExpression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('probe', 'dispatch')][string]$Mode,
        [string]$ServerId = '',
        [string]$WorkspaceId = '',
        [string]$AgentId = ''
    )

    if ($Mode -eq 'probe') {
        # Minimal read-only state probe. No route IDs embedded.
        return @'
(() => {
  try {
    return JSON.stringify({
      ok: true,
      pathname: String(location.pathname || ''),
      search: String(location.search || ''),
      visibilityState: String(document.visibilityState || ''),
      hasFocus: !!document.hasFocus()
    });
  } catch (err) {
    return JSON.stringify({ ok: false, reason: 'probe-error' });
  }
})()
'@
    }

    $detailObject = [ordered]@{
        data = [ordered]@{
            serverId    = $ServerId
            workspaceId = $WorkspaceId
            agentId     = $AgentId
        }
    }
    $json = ($detailObject | ConvertTo-Json -Depth 4 -Compress)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    # Decode controlled JSON and dispatch the existing Paseo event only.
    return @"
(() => {
  try {
    const raw = atob('$b64');
    const detail = JSON.parse(raw);
    const event = new CustomEvent('paseo:web-notification-click', {
      detail: detail,
      cancelable: true
    });
    const notCanceled = dispatchEvent(event);
    return JSON.stringify({
      ok: true,
      defaultPrevented: !!event.defaultPrevented,
      dispatchReturned: !!notCanceled,
      handlerAck: !!event.defaultPrevented
    });
  } catch (err) {
    return JSON.stringify({ ok: false, reason: 'dispatch-error' });
  }
})()
"@
}

function Invoke-NotifyPaseoCdpWebSocketCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WebSocketUrl,
        [Parameter(Mandatory = $true)][hashtable]$Command,
        [int]$TimeoutMs = 4000
    )

    # Hard gate: websocket must target loopback only.
    try {
        $uri = [Uri]$WebSocketUrl
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Result = 'invalid'; Reason = 'bad-ws-url'; Payload = $null }
    }
    if (-not (Test-NotifyPaseoLoopbackAddress -Address $uri.Host)) {
        return [pscustomobject]@{ Ok = $false; Result = 'non-loopback'; Reason = 'ws-not-loopback'; Payload = $null }
    }

    $ws = $null
    try {
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
        if (-not $connectTask.Wait([Math]::Max(250, $TimeoutMs))) {
            return [pscustomobject]@{ Ok = $false; Result = 'cdp-unavailable'; Reason = 'ws-connect-timeout'; Payload = $null }
        }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            return [pscustomobject]@{ Ok = $false; Result = 'cdp-unavailable'; Reason = 'ws-not-open'; Payload = $null }
        }

        $id = Get-Random -Minimum 1 -Maximum 1000000
        $envelope = [ordered]@{
            id     = $id
            method = [string]$Command['method']
            params = $Command['params']
        }
        $json = ($envelope | ConvertTo-Json -Depth 8 -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = [ArraySegment[byte]]::new($bytes)
        $sendTask = $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
        if (-not $sendTask.Wait([Math]::Max(250, $TimeoutMs))) {
            return [pscustomobject]@{ Ok = $false; Result = 'cdp-unavailable'; Reason = 'ws-send-timeout'; Payload = $null }
        }

        $buffer = New-Object byte[] 65536
        $ms = [System.IO.MemoryStream]::new()
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(250, $TimeoutMs))
        while ([DateTime]::UtcNow -lt $deadline) {
            $receiveSegment = [ArraySegment[byte]]::new($buffer)
            $receiveTask = $ws.ReceiveAsync($receiveSegment, [System.Threading.CancellationToken]::None)
            $remaining = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            if (-not $receiveTask.Wait($remaining)) {
                return [pscustomobject]@{ Ok = $false; Result = 'cdp-unavailable'; Reason = 'ws-receive-timeout'; Payload = $null }
            }
            $receiveResult = $receiveTask.Result
            if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                break
            }
            $ms.Write($buffer, 0, $receiveResult.Count)
            if ($ms.Length -gt 262144) {
                return [pscustomobject]@{ Ok = $false; Result = 'dispatch-failed'; Reason = 'ws-response-too-large'; Payload = $null }
            }
            if ($receiveResult.EndOfMessage) {
                $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                $ms.SetLength(0)
                try {
                    $parsed = $text | ConvertFrom-Json
                }
                catch {
                    continue
                }
                if ($parsed.PSObject.Properties['id'] -and ([string]$parsed.id -eq [string]$id)) {
                    if ($parsed.PSObject.Properties['error']) {
                        return [pscustomobject]@{ Ok = $false; Result = 'dispatch-failed'; Reason = 'cdp-command-error'; Payload = $null }
                    }
                    return [pscustomobject]@{
                        Ok      = $true
                        Result  = 'ok'
                        Reason  = ''
                        Payload = $parsed
                    }
                }
            }
        }
        return [pscustomobject]@{ Ok = $false; Result = 'cdp-unavailable'; Reason = 'ws-response-missing'; Payload = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Result = 'cdp-unavailable'; Reason = 'ws-error'; Payload = $null }
    }
    finally {
        if ($null -ne $ws) {
            try {
                if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    $closeTask = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [System.Threading.CancellationToken]::None)
                    [void]$closeTask.Wait(1000)
                }
            }
            catch {}
            try { $ws.Dispose() } catch {}
        }
    }
}

function Invoke-NotifyPaseoCdpRuntimeEvaluate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WebSocketUrl,
        [Parameter(Mandatory = $true)][string]$Expression,
        [int]$TimeoutMs = 4000
    )

    $command = @{
        method = 'Runtime.evaluate'
        params = @{
            expression    = $Expression
            returnByValue = $true
            awaitPromise  = $true
        }
    }
    $response = Invoke-NotifyPaseoCdpWebSocketCommand -WebSocketUrl $WebSocketUrl -Command $command -TimeoutMs $TimeoutMs
    if (-not $response.Ok) {
        return [pscustomobject]@{
            Ok     = $false
            Result = $response.Result
            Reason = $response.Reason
            Value  = $null
        }
    }

    try {
        $payload = $response.Payload
        $valueText = ''
        if ($payload.result -and $payload.result.result -and $payload.result.result.PSObject.Properties['value']) {
            $valueText = [string]$payload.result.result.value
        }
        elseif ($payload.result -and $payload.result.PSObject.Properties['result'] -and $payload.result.result.PSObject.Properties['value']) {
            $valueText = [string]$payload.result.result.value
        }
        if ([string]::IsNullOrWhiteSpace($valueText)) {
            return [pscustomobject]@{
                Ok     = $false
                Result = 'dispatch-failed'
                Reason = 'empty-evaluate'
                Value  = $null
            }
        }
        $parsedValue = $valueText | ConvertFrom-Json
        return [pscustomobject]@{
            Ok     = $true
            Result = 'ok'
            Reason = ''
            Value  = $parsedValue
        }
    }
    catch {
        return [pscustomobject]@{
            Ok     = $false
            Result = 'dispatch-failed'
            Reason = 'evaluate-parse-error'
            Value  = $null
        }
    }
}

function Invoke-NotifyPaseoCdpBringToFront {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WebSocketUrl,
        [int]$TimeoutMs = 2000
    )

    $command = @{
        method = 'Page.bringToFront'
        params = @{}
    }
    return Invoke-NotifyPaseoCdpWebSocketCommand -WebSocketUrl $WebSocketUrl -Command $command -TimeoutMs $TimeoutMs
}

function Get-NotifyPaseoTrustedTargetsWithState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 2500
    )

    $list = Get-NotifyPaseoCdpTargetList -Port $Port -TimeoutMs $TimeoutMs
    if (-not $list.Ok) {
        return [pscustomobject]@{
            Ok      = $false
            Result  = $(if ($list.Reason) { $list.Reason } else { 'cdp-unavailable' })
            Reason  = $list.Reason
            Targets = @()
        }
    }

    $trusted = @()
    foreach ($target in @($list.Targets)) {
        if (-not (Test-NotifyPaseoTrustedPageTarget -Target $target -Port $Port)) { continue }
        $wsUrl = [string]$target.webSocketDebuggerUrl
        if (-not (Test-NotifyPaseoLoopbackAddress -Address ([Uri]$wsUrl).Host)) {
            return [pscustomobject]@{
                Ok      = $false
                Result  = 'non-loopback'
                Reason  = 'target-ws-not-loopback'
                Targets = @()
            }
        }
        $probeExpr = New-NotifyPaseoCdpEvaluateExpression -Mode probe
        $probe = Invoke-NotifyPaseoCdpRuntimeEvaluate -WebSocketUrl $wsUrl -Expression $probeExpr -TimeoutMs $TimeoutMs
        if (-not $probe.Ok -or $null -eq $probe.Value -or -not $probe.Value.ok) {
            continue
        }
        $routeState = ConvertFrom-NotifyPaseoRendererRouteState -Pathname ([string]$probe.Value.pathname) -Search ([string]$probe.Value.search)
        $trusted += [pscustomobject]@{
            Id              = if ($target.PSObject.Properties['id']) { [string]$target.id } else { '' }
            Title           = if ($target.PSObject.Properties['title']) { [string]$target.title } else { '' }
            Url             = if ($target.PSObject.Properties['url']) { [string]$target.url } else { '' }
            WebSocketUrl    = $wsUrl
            Pathname        = [string]$probe.Value.pathname
            Search          = [string]$probe.Value.search
            VisibilityState = [string]$probe.Value.visibilityState
            HasFocus        = [bool]$probe.Value.hasFocus
            ServerId        = [string]$routeState.ServerId
            WorkspaceId     = [string]$routeState.WorkspaceId
            AgentId         = [string]$routeState.AgentId
        }
    }

    return [pscustomobject]@{
        Ok      = $true
        Result  = 'ready'
        Reason  = ''
        Targets = $trusted
    }
}

function Select-NotifyPaseoActivationTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$AgentId
    )

    $server = $ServerId.Trim()
    $agent = $AgentId.Trim()
    $exactAgent = @($Targets | Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$_.ServerId)) -and
            (-not [string]::IsNullOrWhiteSpace([string]$_.AgentId)) -and
            ([string]$_.ServerId -eq $server) -and
            ([string]$_.AgentId -eq $agent)
        })
    if ($exactAgent.Count -eq 1) {
        return [pscustomobject]@{
            Ok     = $true
            Result = 'exact-agent'
            Reason = ''
            Target = $exactAgent[0]
            Count  = 1
        }
    }
    if ($exactAgent.Count -gt 1) {
        return [pscustomobject]@{
            Ok     = $false
            Result = 'ambiguous'
            Reason = 'multiple-exact-agent'
            Target = $null
            Count  = $exactAgent.Count
        }
    }

    $exactServer = @($Targets | Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$_.ServerId)) -and
            ([string]$_.ServerId -eq $server)
        })
    if ($exactServer.Count -eq 1) {
        return [pscustomobject]@{
            Ok     = $true
            Result = 'exact-server'
            Reason = ''
            Target = $exactServer[0]
            Count  = 1
        }
    }
    if ($exactServer.Count -gt 1) {
        return [pscustomobject]@{
            Ok     = $false
            Result = 'ambiguous'
            Reason = 'multiple-exact-server'
            Target = $null
            Count  = $exactServer.Count
        }
    }

    return [pscustomobject]@{
        Ok     = $false
        Result = 'target-missing'
        Reason = 'no-matching-target'
        Target = $null
        Count  = 0
    }
}

function Get-NotifyPaseoForegroundAgentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerId,
        [Parameter(Mandatory = $true)][string]$AgentId,
        $Config = $null,
        [int]$TimeoutMs = 2500
    )

    $port = Get-NotifyPaseoCdpPortFromConfig -Config $Config
    if (Test-NotifyPaseoListenerPortConflict -Port $port -Config $Config) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'port-conflict'
            Reason = 'cdp-port-conflict'
        }
    }

    $owner = Get-NotifyPaseoCdpOwnerSnapshot -Port $port -Config $Config
    if ($owner.NonLoopback) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'non-loopback'
            Reason = $owner.Reason
        }
    }
    if ($owner.ForeignOwner) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'foreign-owner'
            Reason = $owner.Reason
        }
    }
    if (-not $owner.Available) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = $(if ($owner.Result) { $owner.Result } else { 'cdp-unavailable' })
            Reason = $owner.Reason
        }
    }

    $targets = Get-NotifyPaseoTrustedTargetsWithState -Port $port -TimeoutMs $TimeoutMs
    if (-not $targets.Ok) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = $targets.Result
            Reason = $targets.Reason
        }
    }

    $active = @($targets.Targets | Where-Object {
            ([string]$_.ServerId -eq $ServerId.Trim()) -and
            ([string]$_.AgentId -eq $AgentId.Trim()) -and
            ([string]$_.VisibilityState -eq 'visible') -and
            ([bool]$_.HasFocus)
        })

    if ($active.Count -eq 1) {
        return [pscustomobject]@{
            State  = 'active'
            Result = 'exact-agent-focused'
            Reason = ''
            Count  = 1
        }
    }
    if ($active.Count -gt 1) {
        return [pscustomobject]@{
            State  = 'unknown'
            Result = 'ambiguous'
            Reason = 'multiple-active'
            Count  = $active.Count
        }
    }

    return [pscustomobject]@{
        State  = 'inactive'
        Result = 'not-active'
        Reason = ''
        Count  = 0
    }
}

function Invoke-NotifyPaseoDesktopRouteActivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Route,
        $Config = $null,
        [int]$TimeoutMs = 20000
    )

    $startedAt = [DateTime]::UtcNow
    $serverId = if ($Route.PSObject.Properties['ServerId']) { [string]$Route.ServerId } else { '' }
    $workspaceId = if ($Route.PSObject.Properties['WorkspaceId']) { [string]$Route.WorkspaceId } else { '' }
    $agentId = if ($Route.PSObject.Properties['AgentId']) { [string]$Route.AgentId } else { '' }
    $routeFp = Get-NotifyRouteFingerprint -Value ('{0}|{1}' -f $serverId, $agentId)

    if ([string]::IsNullOrWhiteSpace($serverId) -or [string]::IsNullOrWhiteSpace($workspaceId) -or [string]::IsNullOrWhiteSpace($agentId)) {
        return [pscustomobject]@{
            Result     = 'invalid'
            Reason     = 'incomplete-route'
            RouteFp    = $routeFp
            CandidateCount = 0
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    $port = Get-NotifyPaseoCdpPortFromConfig -Config $Config
    if (Test-NotifyPaseoListenerPortConflict -Port $port -Config $Config) {
        return [pscustomobject]@{
            Result     = 'cdp-unavailable'
            Reason     = 'cdp-port-conflict'
            RouteFp    = $routeFp
            CandidateCount = 0
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    $owner = Get-NotifyPaseoCdpOwnerSnapshot -Port $port -Config $Config
    if ($owner.NonLoopback) {
        return [pscustomobject]@{
            Result     = 'non-loopback'
            Reason     = $owner.Reason
            RouteFp    = $routeFp
            CandidateCount = 0
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }
    if ($owner.ForeignOwner) {
        return [pscustomobject]@{
            Result     = 'foreign-owner'
            Reason     = $owner.Reason
            RouteFp    = $routeFp
            CandidateCount = 0
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }
    if (-not $owner.Available) {
        return [pscustomobject]@{
            Result     = $(if ($owner.Result) { $owner.Result } else { 'cdp-unavailable' })
            Reason     = $owner.Reason
            RouteFp    = $routeFp
            CandidateCount = 0
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    $targets = Get-NotifyPaseoTrustedTargetsWithState -Port $port -TimeoutMs ([Math]::Min(4000, $TimeoutMs))
    if (-not $targets.Ok) {
        return [pscustomobject]@{
            Result     = $targets.Result
            Reason     = $targets.Reason
            RouteFp    = $routeFp
            CandidateCount = 0
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    $selection = Select-NotifyPaseoActivationTarget -Targets @($targets.Targets) -ServerId $serverId -AgentId $agentId
    if (-not $selection.Ok) {
        return [pscustomobject]@{
            Result     = $selection.Result
            Reason     = $selection.Reason
            RouteFp    = $routeFp
            CandidateCount = [int]$selection.Count
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    $target = $selection.Target
    $bring = Invoke-NotifyPaseoCdpBringToFront -WebSocketUrl $target.WebSocketUrl -TimeoutMs 2000
    if (-not $bring.Ok) {
        return [pscustomobject]@{
            Result = 'foreground-denied'; Reason = $bring.Reason; RouteFp = $routeFp; CandidateCount = 1
            ElapsedMs = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    $dispatchExpr = New-NotifyPaseoCdpEvaluateExpression -Mode dispatch -ServerId $serverId -WorkspaceId $workspaceId -AgentId $agentId
    $dispatch = Invoke-NotifyPaseoCdpRuntimeEvaluate -WebSocketUrl $target.WebSocketUrl -Expression $dispatchExpr -TimeoutMs ([Math]::Min(5000, $TimeoutMs))
    if (-not $dispatch.Ok -or $null -eq $dispatch.Value -or -not $dispatch.Value.ok) {
        return [pscustomobject]@{
            Result     = 'dispatch-failed'
            Reason     = $(if ($dispatch.Reason) { $dispatch.Reason } else { 'dispatch-error' })
            RouteFp    = $routeFp
            CandidateCount = 1
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }
    if (-not [bool]$dispatch.Value.handlerAck -and -not [bool]$dispatch.Value.defaultPrevented) {
        return [pscustomobject]@{
            Result     = 'ack-timeout'
            Reason     = 'handler-not-acked'
            RouteFp    = $routeFp
            CandidateCount = 1
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    # Bounded exact-agent acceptance poll after handler ACK.
    $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Min(8000, [Math]::Max(1000, $TimeoutMs / 2)))
    $accepted = $false
    $routeAccepted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $probeExpr = New-NotifyPaseoCdpEvaluateExpression -Mode probe
        $probe = Invoke-NotifyPaseoCdpRuntimeEvaluate -WebSocketUrl $target.WebSocketUrl -Expression $probeExpr -TimeoutMs 1500
        if (-not $probe.Ok -or $null -eq $probe.Value -or -not $probe.Value.ok) {
            continue
        }
        $routeState = ConvertFrom-NotifyPaseoRendererRouteState -Pathname ([string]$probe.Value.pathname) -Search ([string]$probe.Value.search)
        if ([string]$routeState.ServerId -eq $serverId -and [string]$routeState.AgentId -eq $agentId) {
            $routeAccepted = $true
            if ([string]$probe.Value.visibilityState -eq 'visible' -and [bool]$probe.Value.hasFocus) {
                $accepted = $true
                break
            }
        }
    }

    if (-not $accepted) {
        return [pscustomobject]@{
            Result     = $(if ($routeAccepted) { 'foreground-denied' } else { 'ack-timeout' })
            Reason     = $(if ($routeAccepted) { 'exact-agent-not-foreground' } else { 'exact-agent-not-accepted' })
            RouteFp    = $routeFp
            CandidateCount = 1
            ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        }
    }

    return [pscustomobject]@{
        Result     = 'activated'
        Reason     = ''
        RouteFp    = $routeFp
        CandidateCount = 1
        Selection  = $selection.Result
        ElapsedMs  = [int]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
    }
}
