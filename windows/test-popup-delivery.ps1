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
. ([scriptblock]::Create((Get-DeliveryFunctions @('Send-NotifyBrokerPopup', 'Invoke-NotifyBrokerPopup', 'Get-NotifyPopupStackPlan'))))
function Write-NotifyListenerLog { param($Message) }
function Get-NotifyRouteFingerprint { param($Value) return 'fixture-fingerprint' }

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

Write-Output ("PASS popup delivery: {0} assertions" -f $script:PassCount)
