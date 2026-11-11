# Real loopback HTTP/runspace checks; no live notification instance is touched.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0
function Assert-Listener {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'pi-notify-broker.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Start-NotifyBrokerHttpListener', 'Stop-NotifyBrokerHttpListener')) {
    $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $found) { throw "Function missing: $name" }
    . ([scriptblock]::Create($found.Extent.Text))
}
function Write-NotifyBrokerLog { param($Message) }
function Send-ListenerRequest {
    param([int]$Port, [string]$Request)
    $client = [System.Net.Sockets.TcpClient]::new()
    $reader = $null
    try {
        $client.Connect('127.0.0.1', $Port)
        $client.ReceiveTimeout = 2000
        $stream = $client.GetStream()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Request)
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [System.IO.StreamReader]::new($stream)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $client.Close()
    }
}
$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ('popup-listener-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($scratchDir)
$config = [pscustomobject]@{ BrokerRequestTimeoutMs = 30000 }
$brokerPort = 0
$script:NotifyBrokerLogPath = Join-Path $scratchDir 'listener.log'
$script:NotifyBrokerLogLock = [object]::new()
foreach ($name in @('Listener', 'ListenerRunspace', 'ListenerPowerShell', 'ListenerHandle', 'ListenerState')) {
    Set-Variable -Scope Script -Name ('NotifyBroker' + $name) -Value $null
}
try {
    foreach ($scenario in @('idle', 'partial-header', 'partial-body')) {
        $client = $null
        $script:NotifyBrokerPopupQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        try {
            Start-NotifyBrokerHttpListener
            $port = $script:NotifyBrokerListener.LocalEndpoint.Port
            $response = Send-ListenerRequest -Port $port -Request "GET /health HTTP/1.1`r`nHost: localhost`r`n`r`n"
            Assert-Listener ($response.StartsWith('HTTP/1.1 200 ')) "$scenario listener becomes ready"
            if ($scenario -eq 'idle') {
                $response = Send-ListenerRequest -Port $port -Request "POST /popup HTTP/1.1`r`nContent-Length: invalid`r`n`r`n{}"
                Assert-Listener ($response.StartsWith('HTTP/1.1 400 ') -and $script:NotifyBrokerPopupQueue.IsEmpty) 'invalid body framing is rejected before enqueue'
                $response = Send-ListenerRequest -Port $port -Request "POST /popup HTTP/1.1`r`nContent-Length: 2`r`n`r`n{}"
                Assert-Listener ($response.StartsWith('HTTP/1.1 200 ') -and $script:NotifyBrokerPopupQueue.Count -eq 1) 'listener accepts the next valid request after a malformed request'
            }
            else {
                $client = [System.Net.Sockets.TcpClient]::new()
                $client.Connect('127.0.0.1', $port)
                $request = if ($scenario -eq 'partial-header') { 'POST /popup HTTP/1.1' }
                    else { "POST /popup HTTP/1.1`r`nContent-Length: 100`r`n`r`n{" }
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
                $client.GetStream().Write($bytes, 0, $bytes.Length)
                $wait = [System.Diagnostics.Stopwatch]::StartNew()
                while ($null -eq $script:NotifyBrokerListenerState.Client -and $wait.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 5 }
                Assert-Listener ($null -ne $script:NotifyBrokerListenerState.Client) "$scenario has an accepted in-flight client"
            }
            $savedState = $script:NotifyBrokerListenerState
            $savedHandle = $script:NotifyBrokerListenerHandle
            $savedPowerShell = $script:NotifyBrokerListenerPowerShell
            $savedRunspace = $script:NotifyBrokerListenerRunspace
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Stop-NotifyBrokerHttpListener
            $elapsed = $clock.ElapsedMilliseconds
            Assert-Listener ($elapsed -lt 2000) "$scenario shutdown interrupts the 30-second I/O timeout (${elapsed}ms)"
            Assert-Listener ($savedHandle.IsCompleted -and $savedState.Stopping -and $null -eq $savedState.Client) "$scenario pipeline finishes without an accept-error loop"
            Assert-Listener ($savedRunspace.RunspaceStateInfo.State -eq 'Closed') "$scenario runspace is closed"
            $disposed = $false
            try { [void]$savedPowerShell.Invoke() } catch [System.ObjectDisposedException] { $disposed = $true }
            Assert-Listener $disposed "$scenario PowerShell pipeline is disposed"
            Assert-Listener ($null -eq $script:NotifyBrokerListener -and $null -eq $script:NotifyBrokerListenerPowerShell -and $null -eq $script:NotifyBrokerListenerRunspace -and $null -eq $script:NotifyBrokerListenerHandle -and $null -eq $script:NotifyBrokerListenerState) "$scenario releases shared references"
            Stop-NotifyBrokerHttpListener
            Assert-Listener $true "$scenario shutdown is idempotent"
        }
        finally {
            Stop-NotifyBrokerHttpListener
            if ($null -ne $client) { $client.Close() }
        }
    }
}
finally { Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "Popup listener tests passed: $script:PassCount"
