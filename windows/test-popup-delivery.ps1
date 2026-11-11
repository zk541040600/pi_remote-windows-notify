# Exercise popup delivery without displaying UI, starting a broker or stopping real processes.
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/test-popup-delivery.ps1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0

function Assert-Delivery {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}

$tokens = $null; $errors = $null
$listenerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'notify-listener.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
function Get-DeliveryFunctions {
    param([string[]]$Names)
    $definitions = foreach ($name in $Names) {
        $found = $listenerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $found) { throw "Missing function: $name" }
        $found.Extent.Text
    }
    return ($definitions -join "`n")
}
. ([scriptblock]::Create((Get-DeliveryFunctions @('Read-HttpRequest', 'Send-NotifyBrokerPopup', 'Invoke-NotifyBrokerPopup', 'Get-NotifyPopupStackPlan', 'Show-Toast'))))
function Write-NotifyListenerLog { param($Message) }
function Get-NotifyRouteFingerprint { param($Value) return 'fixture-fingerprint' }

$brokerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'pi-notify-broker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$backgroundText = $brokerAst.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('param($Listener, $Queue,') }, $true)
if ($null -eq $backgroundText) { throw 'Missing broker background script.' }
$backgroundAst = [System.Management.Automation.Language.Parser]::ParseInput($backgroundText.Value, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$backgroundParser = $backgroundAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-BgRequest' }, $true)
if ($null -eq $backgroundParser) { throw 'Missing broker request parser.' }
. ([scriptblock]::Create($backgroundParser.Extent.Text))

# Exercise both actual parsers with a stream that splits headers and UTF-8 bodies.
Add-Type @'
using System;
using System.IO;
public sealed class NotifyDeliveryFragmentStream : MemoryStream {
    private readonly int maxRead;
    public NotifyDeliveryFragmentStream(byte[] bytes, int maxRead) : base(bytes) { this.maxRead = maxRead; }
    public override int Read(byte[] buffer, int offset, int count) { return base.Read(buffer, offset, Math.Min(count, maxRead)); }
}
'@
function Read-DeliveryFixture {
    param([string]$Request, [int]$MaxRead = 4096)
    $stream = [NotifyDeliveryFragmentStream]::new([System.Text.Encoding]::UTF8.GetBytes($Request), $MaxRead)
    try { return & $script:DeliveryParser -Stream $stream }
    finally { $stream.Dispose() }
}
function Assert-DeliveryRequestRejected {
    param([string]$Request, [string]$Name)
    $rejected = $false
    try { [void](Read-DeliveryFixture -Request $Request -MaxRead 3) }
    catch { $rejected = $true }
    Assert-Delivery $rejected $Name
}

foreach ($surface in @('listener', 'broker')) {
    $script:DeliveryParser = if ($surface -eq 'listener') { 'Read-HttpRequest' } else { 'Read-BgRequest' }
    $body = '{"body":"' + [char]0x4e2d + '"}'
    $length = [System.Text.Encoding]::UTF8.GetByteCount($body)
    foreach ($fragmentSize in @(1, 7, 4096)) {
        $request = Read-DeliveryFixture -Request "POST /notify HTTP/1.1`r`nContent-Length: $length`r`n`r`n$body" -MaxRead $fragmentSize
        Assert-Delivery ([System.Text.Encoding]::UTF8.GetString($request.BodyBytes) -ceq $body) "$surface preserves exact UTF-8 bytes with fragment size $fragmentSize"
    }
    $request = Read-DeliveryFixture -Request "GET /health HTTP/1.1`r`nHost: localhost`r`n`r`n"
    Assert-Delivery ($request.RequestLine -eq 'GET /health HTTP/1.1' -and $request.BodyBytes.Length -eq 0) "$surface accepts a bodyless health request"
    $request = Read-DeliveryFixture -Request "POST /notify HTTP/1.1`r`nContent-Length: 2`r`n`r`n{}ignored"
    Assert-Delivery ([System.Text.Encoding]::UTF8.GetString($request.BodyBytes) -eq '{}') "$surface consumes only the declared body"
    Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nContent-Length: 20`r`n`r`n{}" "$surface rejects EOF even when the short body is valid JSON"
    Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nContent-Length: 2`r`n`r`n{" "$surface rejects a truncated JSON body"
    Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nContent-Length: 2" "$surface rejects an incomplete header"
    foreach ($lengthValue in @('-1', '+2', 'abc', '', '2147483648', '65537')) {
        Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nContent-Length: $lengthValue`r`n`r`n{}" "$surface rejects invalid or oversized content length '$lengthValue'"
    }
    Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nContent-Length: 2`r`ncontent-length: 3`r`n`r`n{}" "$surface rejects conflicting content lengths"
    Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nContent-Length: 2`r`ncontent-length: 2`r`n`r`n{}" "$surface rejects duplicate framing headers"
    Assert-DeliveryRequestRejected "POST /notify HTTP/1.1`r`nTransfer-Encoding: chunked`r`n`r`n0`r`n`r`n" "$surface rejects unsupported transfer encoding"
    $request = Read-DeliveryFixture -Request ("POST /notify HTTP/1.1`r`nContent-Length: 65536`r`n`r`n" + ('x' * 65536))
    Assert-Delivery ($request.BodyBytes.Length -eq 65536) "$surface accepts the maximum permitted complete body"
}

# A loopback-only responder controls TCP fragmentation independently of the sender under test.
function Invoke-DeliveryResponseTest {
    param([string[]]$Chunks, [int]$ChunkDelayMs = 0, [switch]$ResetAfterRequest)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $ready = [System.Threading.ManualResetEvent]::new($false)
    $server = [System.Management.Automation.PowerShell]::Create()
    $async = $null
    try {
        [void]$server.AddScript(@'
param($Listener, $Chunks, $ChunkDelayMs, $Ready, $ResetAfterRequest)
$ErrorActionPreference = 'Stop'
$client = $null
$reader = $null
try {
    [void]$Ready.Set()
    $client = $Listener.AcceptTcpClient()
    $client.ReceiveTimeout = 2000
    $client.SendTimeout = 2000
    $stream = $client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
    $contentLength = 0
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw 'Sender closed before its request header.' }
        if ($line.Length -eq 0) { break }
        if ($line -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }
    $body = [char[]]::new($contentLength)
    $received = 0
    while ($received -lt $contentLength) {
        $count = $reader.Read($body, $received, ($contentLength - $received))
        if ($count -le 0) { throw 'Sender closed before its request body.' }
        $received += $count
    }
    foreach ($chunk in $Chunks) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$chunk)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        if ($ChunkDelayMs -gt 0) { Start-Sleep -Milliseconds $ChunkDelayMs }
    }
    if ($ResetAfterRequest) { $client.Client.LingerState = [System.Net.Sockets.LingerOption]::new($true, 0) }
    'served'
}
finally {
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $client) { $client.Close() }
}
'@)
        [void]$server.AddParameter('Listener', $listener)
        [void]$server.AddParameter('Chunks', $Chunks)
        [void]$server.AddParameter('ChunkDelayMs', $ChunkDelayMs)
        [void]$server.AddParameter('Ready', $ready)
        [void]$server.AddParameter('ResetAfterRequest', [bool]$ResetAfterRequest)
        $async = $server.BeginInvoke()
        if (-not $ready.WaitOne(5000)) { throw 'Test responder did not become ready.' }
        $config = [pscustomobject]@{ BrokerPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; BrokerRequestTimeoutMs = 500 }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $sent = Send-NotifyBrokerPopup -Title 'fixture-title' -Body 'fixture-body' -TargetFingerprint 'fixture-target'
        $elapsedMs = $clock.ElapsedMilliseconds
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw 'Test responder did not finish.' }
        $serverOutput = @($server.EndInvoke($async))
        if ($server.HadErrors -or $serverOutput -notcontains 'served') { throw ('Test responder failed: ' + ($server.Streams.Error | Out-String)) }
        return [pscustomobject]@{ Sent = $sent; ElapsedMs = $elapsedMs }
    }
    finally {
        $listener.Stop()
        if ($null -ne $async -and -not $async.IsCompleted) { try { $server.Stop() } catch {} }
        $server.Dispose()
        $ready.Dispose()
    }
}

$response = Invoke-DeliveryResponseTest -Chunks @('HT', 'TP/1.1 ', '200', " OK`r`nContent-Length: 0`r`n`r`n") -ChunkDelayMs 15
Assert-Delivery $response.Sent 'fragmented HTTP 200 does not launch a duplicate fallback'
$response = Invoke-DeliveryResponseTest -Chunks @('HTTP/1.1 5', "03 Service Unavailable`r`nContent-Length: 0`r`n`r`n") -ChunkDelayMs 15
Assert-Delivery (-not $response.Sent) 'complete fragmented rejection permits fallback'
$response = Invoke-DeliveryResponseTest -Chunks @('HTTP/1.1 5')
Assert-Delivery $response.Sent 'partial status without a line ending cannot reject an already-written request'
Assert-Delivery ($response.ElapsedMs -lt 1500) 'incomplete acknowledgement has a bounded wait'
$response = Invoke-DeliveryResponseTest -Chunks @()
Assert-Delivery $response.Sent 'closed connection without status preserves ambiguous-delivery policy'
$response = Invoke-DeliveryResponseTest -Chunks @(('HTTP/1.1 200 ' + ('x' * 300)))
Assert-Delivery ($response.Sent -and $response.ElapsedMs -lt 1500) 'overlong status without a line ending remains bounded'
$response = Invoke-DeliveryResponseTest -Chunks @('HTTP/1.') -ResetAfterRequest
Assert-Delivery $response.Sent 'connection reset after the complete request cannot launch a duplicate fallback'
Assert-Delivery ($response.ElapsedMs -lt 1500) 'reset acknowledgement remains bounded'

& {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $config = [pscustomobject]@{ BrokerPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; BrokerRequestTimeoutMs = 300 }
    $listener.Stop()
    Assert-Delivery (-not (Send-NotifyBrokerPopup -Title 'fixture' -Body 'body' -TargetFingerprint 'target')) 'failure before writing the request still permits fallback'
}

& {
    $config = [pscustomobject]@{ BrokerEnabled = $true; BrokerStartupTimeoutMs = 100 }
    $script:HealthResults = [System.Collections.Generic.Queue[bool]]::new()
    $script:HealthCalls = 0; $script:BrokerStarts = 0; $script:PopupPosts = 0
    $script:StartResult = $true; $script:PostResult = $true
    function Test-NotifyBrokerHealth {
        $script:HealthCalls += 1
        if ($script:HealthResults.Count) { return $script:HealthResults.Dequeue() }
        return $false
    }
    function Start-NotifyBroker { $script:BrokerStarts += 1; return $script:StartResult }
    function Send-NotifyBrokerPopup { $script:PopupPosts += 1; return $script:PostResult }
    $popupArgs = @{ Title = 'fixture'; Body = 'body'; TargetFingerprint = 'target' }

    $script:HealthResults.Enqueue($true)
    Assert-Delivery (Invoke-NotifyBrokerPopup @popupArgs) 'healthy broker receives popup'
    Assert-Delivery ($script:HealthCalls -eq 1 -and $script:BrokerStarts -eq 0 -and $script:PopupPosts -eq 1) 'healthy delivery probes once and posts once'

    $script:HealthCalls = 0; $script:BrokerStarts = 0; $script:PopupPosts = 0
    $script:HealthResults.Enqueue($false); $script:HealthResults.Enqueue($true)
    Assert-Delivery (Invoke-NotifyBrokerPopup @popupArgs) 'newly started broker receives popup'
    Assert-Delivery ($script:HealthCalls -eq 2 -and $script:BrokerStarts -eq 1 -and $script:PopupPosts -eq 1) 'startup reuses successful poll without another health request'

    $script:HealthCalls = 0; $script:BrokerStarts = 0; $script:PopupPosts = 0
    $script:StartResult = $false
    Assert-Delivery (-not (Invoke-NotifyBrokerPopup @popupArgs)) 'failed broker startup requests fallback'
    Assert-Delivery ($script:HealthCalls -eq 1 -and $script:PopupPosts -eq 0) 'failed startup does not probe or post again'

    $script:HealthCalls = 0; $script:BrokerStarts = 0; $script:PopupPosts = 0
    $config.BrokerEnabled = $false
    Assert-Delivery (-not (Invoke-NotifyBrokerPopup @popupArgs)) 'disabled broker requests fallback'
    Assert-Delivery ($script:HealthCalls -eq 0 -and $script:BrokerStarts -eq 0 -and $script:PopupPosts -eq 0) 'disabled broker performs no network work'
}

& {
    $config = [pscustomobject]@{ PopupPlacement = 'cursor'; PopupMaxVisible = 3 }
    function Get-NotifyPopupWorkingArea { param($Placement) return [pscustomobject]@{ Height = 900 } }
    function Get-NotifyPopupStackCapacity { param($WorkingAreaHeight, $MaxVisible) return $MaxVisible }
    function Get-NotifyPopupProcesses { return $script:PopupProcesses }
    function Stop-Process {
        param($Id, [switch]$Force, $ErrorAction)
        [void]$script:StopAttempts.Add([int]$Id)
        if ($script:FailedStopIds -contains [int]$Id) { throw 'simulated process exit failure' }
    }
    function New-DeliveryPopup {
        param([int]$ProcessId, [string]$Target, [int]$Slot)
        return [pscustomobject]@{
            ProcessId = $ProcessId; TargetFingerprint = $Target; StackIndex = $Slot
            CreatedAtUtc = [DateTime]::UtcNow.AddMinutes($Slot - 10)
        }
    }
    $script:StopAttempts = [System.Collections.Generic.List[int]]::new()
    $script:FailedStopIds = @(101)
    $script:PopupProcesses = @(New-DeliveryPopup 101 'same' 0)
    $slot = Get-NotifyPopupStackPlan -TargetKey 'same' -TargetFingerprint 'same'
    Assert-Delivery ($slot -eq -1) 'failed same-target close blocks a new popup even with spare slots'
    Assert-Delivery (($script:StopAttempts -join ',') -eq '101') 'failed replacement stops after the failed process'

    $script:StopAttempts.Clear()
    $script:PopupProcesses = @(New-DeliveryPopup 101 'offscreen' 5)
    $slot = Get-NotifyPopupStackPlan -TargetKey 'incoming' -TargetFingerprint 'incoming'
    Assert-Delivery ($slot -eq -1) 'failed out-of-range close blocks a new popup even with spare slots'

    $script:StopAttempts.Clear()
    $script:PopupProcesses = @(
        (New-DeliveryPopup 101 'a' 0), (New-DeliveryPopup 102 'b' 1), (New-DeliveryPopup 103 'c' 2)
    )
    $slot = Get-NotifyPopupStackPlan -TargetKey 'incoming' -TargetFingerprint 'incoming'
    Assert-Delivery ($slot -eq -1) 'failed overflow close cannot allocate a new slot'
    Assert-Delivery (($script:StopAttempts -join ',') -eq '101') 'failed overflow does not close additional unrelated cards'

    $script:StopAttempts.Clear()
    $script:FailedStopIds = @()
    $slot = Get-NotifyPopupStackPlan -TargetKey 'incoming' -TargetFingerprint 'incoming'
    Assert-Delivery ($slot -eq 0 -and ($script:StopAttempts -join ',') -eq '101') 'successful overflow still replaces only the oldest card'

    $script:StopAttempts.Clear()
    $slot = Get-NotifyPopupStackPlan -TargetKey 'b' -TargetFingerprint 'b'
    Assert-Delivery ($slot -eq 1 -and ($script:StopAttempts -join ',') -eq '102') 'successful same-target replacement reuses its slot'
}

# A failed fallback allocation must reach the existing delivery-error handler.
& {
    $TestDesktopSinkPath = ''
    $DisplayMode = 'popup-focus'
    $PopupTimeoutSeconds = 10
    $script:NotifyPopupScript = Join-Path $PSScriptRoot 'pi-notify-popup.ps1'
    $config = [pscustomobject]@{ RemoteHostAlias = 'fixture'; PopupPlacement = 'cursor' }
    $script:FallbackLaunches = 0; $script:FallbackAllocations = 0; $script:ArtifactCleanups = 0
    $script:BrokerAccepted = $false; $script:AllocatedSlot = -1
    function Get-NotifyPopupTargetKey { param($TargetHost, $CwdBase, $TabTitle) return 'target' }
    function Invoke-NotifyBrokerPopup { return $script:BrokerAccepted }
    function Get-NotifyPopupStackPlan { $script:FallbackAllocations += 1; return $script:AllocatedSlot }
    function Clear-NotifyBridgePopupArtifacts { param([switch]$Aggressive) $script:ArtifactCleanups += 1 }
    function Start-NotifyPopupProcess { $script:FallbackLaunches += 1 }
    $showArgs = @{ Title = 'fixture'; Body = 'body'; ToastAppId = 'fixture'; OriginKind = 'paseo'; TargetFingerprint = 'target'; SnapshotId = 'activation' }
    $failed = $false
    try { Show-Toast @showArgs }
    catch [System.InvalidOperationException] { $failed = $true }
    Assert-Delivery $failed 'no free fallback slot reports a delivery failure for retry'
    Assert-Delivery ($script:FallbackLaunches -eq 0 -and $script:ArtifactCleanups -eq 0) 'failed allocation does not launch or clean up unrelated popup state'

    $script:AllocatedSlot = 0
    Show-Toast @showArgs
    Assert-Delivery ($script:FallbackLaunches -eq 1) 'a later successful allocation can deliver the retried notification'

    $script:BrokerAccepted = $true
    $script:AllocatedSlot = -1
    $allocationsBefore = $script:FallbackAllocations
    Show-Toast @showArgs
    Assert-Delivery ($script:FallbackAllocations -eq $allocationsBefore -and $script:FallbackLaunches -eq 1) 'broker acceptance still skips the fallback allocation and process'
}

Write-Output ("PASS popup delivery: {0} assertions" -f $script:PassCount)
