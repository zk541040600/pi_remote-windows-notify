# Exercise real hotkey state selection with isolated files and a mocked process query.
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows/test-popup-hotkey.ps1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0

function Assert-Hotkey {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PassCount += 1
    Write-Output "PASS $Name"
}

function Read-HotkeyTestFunctions {
    param([string]$Name, [string[]]$Functions)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $parts = foreach ($functionName in $Functions) {
        $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
        if ($null -eq $found) { throw "Function missing: $functionName" }
        $found.Extent.Text
    }
    return ($parts -join "`n")
}

. ([scriptblock]::Create((Read-HotkeyTestFunctions 'pi-notify-hotkey.ps1' @('Get-NotifyHotkeyLivePopupStates', 'Get-NotifyHotkeyFingerprint', 'Send-NotifyHotkeyBrokerPost', 'Start-NotifyHotkeyActivation', 'Invoke-NotifyHotkeyBrokerActivateOldest', 'Invoke-NotifyHotkeyOldestPopup'))))
. ([scriptblock]::Create((Read-HotkeyTestFunctions 'NotifyBridge.Common.ps1' @('Get-NotifyPopupActivationEventName', 'Read-NotifyPopupLiveJson'))))

$script:HotkeyTestDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-hotkey-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:HotkeyTestDirectory | Out-Null
$config = [pscustomobject]@{ ConfigPath = (Join-Path $script:HotkeyTestDirectory 'a.json') }
$ownFingerprint = Get-NotifyHotkeyFingerprint -Value $config.ConfigPath
$foreignFingerprint = Get-NotifyHotkeyFingerprint -Value (Join-Path $script:HotkeyTestDirectory 'b.json')
$script:OwnershipQueries = [System.Collections.Generic.List[int]]::new()
$script:OwnedProcessIds = @{ 41001 = $true; 41002 = $true; 41003 = $false }
function Get-NotifyBridgeLogDir { return $script:HotkeyTestDirectory }
function Write-NotifyHotkeyLog { param($Message) }
function Test-NotifyHotkeyPopupProcessOwned {
    param([int]$ProcessId)
    $script:OwnershipQueries.Add($ProcessId)
    return ($script:OwnedProcessIds.ContainsKey($ProcessId) -and $script:OwnedProcessIds[$ProcessId])
}
function Save-HotkeyTestState {
    param([string]$Name, $ProcessId, [string]$Fingerprint, [int64]$StartedAtTicks, [switch]$Expired)
    $path = Join-Path $script:HotkeyTestDirectory ('popup-live.' + $Name + '.json')
    $state = @{
        processId = $ProcessId; configFingerprint = $Fingerprint; brokerManaged = $true
        popupId = $Name; startedAtTicks = $StartedAtTicks; stackIndex = 0; targetFingerprint = $Name
        expiresAtTicks = [DateTime]::UtcNow.AddMinutes($(if ($Expired) { -1 } else { 5 })).Ticks
    }
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    $foreignPaths = @(
        Save-HotkeyTestState 'foreign' 41099 $foreignFingerprint 1
        Save-HotkeyTestState 'foreign-expired' 41098 $foreignFingerprint 2 -Expired
        Save-HotkeyTestState 'foreign-invalid-pid' 'invalid' $foreignFingerprint 3
    )
    [void](Save-HotkeyTestState 'same-3' 41001 $ownFingerprint 30)
    [void](Save-HotkeyTestState 'same-1' 41001 $ownFingerprint 10)
    [void](Save-HotkeyTestState 'same-2' 41001 $ownFingerprint 20)
    $states = @(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey ($states.Count -eq 3) 'only this configuration supplies hotkey candidates'
    Assert-Hotkey (($states.PopupId -join ',') -eq 'same-1,same-2,same-3') 'candidate age ordering is preserved'
    Assert-Hotkey ($script:OwnershipQueries.Count -eq 1 -and $script:OwnershipQueries[0] -eq 41001) 'same-process cards query ownership once and foreign states never query it'
    foreach ($path in $foreignPaths) {
        Assert-Hotkey (Test-Path -LiteralPath $path) ('another configuration retains ' + [System.IO.Path]::GetFileName($path))
    }

    $script:OwnershipQueries.Clear()
    [void](Save-HotkeyTestState 'different-process' 41002 $ownFingerprint 40)
    $states = @(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey ($states.Count -eq 4) 'different owned processes remain selectable'
    Assert-Hotkey ((($script:OwnershipQueries | Sort-Object) -join ',') -eq '41001,41002') 'each distinct process is queried once per enumeration'

    $script:OwnershipQueries.Clear()
    $script:OwnedProcessIds[41001] = $false
    $states = @(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey ($states.Count -eq 1 -and $states[0].ProcessId -eq 41002) 'ownership is refreshed on the next enumeration'
    Assert-Hotkey (@($script:OwnershipQueries | Where-Object { $_ -eq 41001 }).Count -eq 1) 'failed ownership is also cached only within one enumeration'
    Assert-Hotkey (@(Get-ChildItem -LiteralPath $script:HotkeyTestDirectory -Filter 'popup-live.same-*.json').Count -eq 0) 'stale records from this configuration are removed'
    foreach ($path in $foreignPaths) {
        Assert-Hotkey (Test-Path -LiteralPath $path) ('ownership cleanup preserves ' + [System.IO.Path]::GetFileName($path))
    }

    $script:OwnershipQueries.Clear()
    $firstDeadPath = Save-HotkeyTestState 'dead-1' 41003 $ownFingerprint 50
    $secondDeadPath = Save-HotkeyTestState 'dead-2' 41003 $ownFingerprint 60
    [void]@(Get-NotifyHotkeyLivePopupStates)
    Assert-Hotkey (@($script:OwnershipQueries | Where-Object { $_ -eq 41003 }).Count -eq 1) 'several dead-process cards perform one ownership query'
    Assert-Hotkey (-not (Test-Path -LiteralPath $firstDeadPath) -and -not (Test-Path -LiteralPath $secondDeadPath)) 'all dead-process cards from this configuration are cleaned'
}
finally {
    Remove-Item -LiteralPath $script:HotkeyTestDirectory -Recurse -Force
}

# Real loopback exchanges exercise fragmented, missing and delayed acknowledgements.
function Invoke-HotkeyResponseTest {
    param([string[]]$Chunks, [int]$ChunkDelayMs = 0, [int]$TimeoutMs = 500, [switch]$ResetAfterRequest, [switch]$Oldest)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $ready = [System.Threading.ManualResetEvent]::new($false)
    $server = [System.Management.Automation.PowerShell]::Create()
    $async = $null
    try {
        [void]$server.AddScript(@'
param($Listener, $Chunks, $ChunkDelayMs, $Ready, $ResetAfterRequest)
$ErrorActionPreference = 'Stop'
$client = $null; $reader = $null
try {
    [void]$Ready.Set()
    $client = $Listener.AcceptTcpClient()
    $client.ReceiveTimeout = 3000; $client.SendTimeout = 3000
    $stream = $client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
    $requestLine = $reader.ReadLine()
    $contentLength = 0
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw 'Incomplete hotkey request header.' }
        if ($line.Length -eq 0) { break }
        if ($line -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }
    $body = [char[]]::new($contentLength)
    $received = 0
    while ($received -lt $contentLength) {
        $count = $reader.Read($body, $received, ($contentLength - $received))
        if ($count -le 0) { throw 'Incomplete hotkey request body.' }
        $received += $count
    }
    [pscustomobject]@{ RequestLine = $requestLine; Body = (-join $body) }
    try {
        foreach ($chunk in $Chunks) {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$chunk)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            if ($ChunkDelayMs -gt 0) { Start-Sleep -Milliseconds $ChunkDelayMs }
        }
    }
    catch [System.IO.IOException] { } # The bounded client may leave before a slow responder.
    if ($ResetAfterRequest) { $client.Client.LingerState = [System.Net.Sockets.LingerOption]::new($true, 0) }
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
        if (-not $ready.WaitOne(5000)) { throw 'Hotkey test responder did not become ready.' }
        $config = [pscustomobject]@{ BrokerPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $script:HotkeyActivationAttempts = [System.Collections.Generic.List[string]]::new()
        if ($Oldest) {
            function Get-NotifyHotkeyLivePopupStates {
                return @([pscustomobject]@{ BrokerManaged = $true; PopupId = 'first"card' }, [pscustomobject]@{ BrokerManaged = $true; PopupId = 'second-card' })
            }
            $realActivation = ${function:Start-NotifyHotkeyActivation}
            function Start-NotifyHotkeyActivation {
                param($PopupState)
                $script:HotkeyActivationAttempts.Add([string]$PopupState.PopupId)
                return (& $realActivation -PopupState $PopupState)
            }
            $accepted = Invoke-NotifyHotkeyOldestPopup
        }
        else { $accepted = Send-NotifyHotkeyBrokerPost -Path '/activate-oldest' -TimeoutMs $TimeoutMs }
        $elapsedMs = $clock.ElapsedMilliseconds
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw 'Hotkey test responder did not finish.' }
        $serverOutput = @($server.EndInvoke($async))
        if ($server.HadErrors -or $serverOutput.Count -ne 1) { throw ('Hotkey responder failed: ' + ($server.Streams.Error | Out-String)) }
        return [pscustomobject]@{ Accepted = $accepted; ElapsedMs = $elapsedMs; Request = $serverOutput[0]; Attempts = @($script:HotkeyActivationAttempts.ToArray()) }
    }
    finally {
        $listener.Stop()
        if ($null -ne $async -and -not $async.IsCompleted) { try { $server.Stop() } catch {} }
        $server.Dispose()
        $ready.Dispose()
    }
}

$response = Invoke-HotkeyResponseTest -Chunks @('HT', 'TP/1.1 ', '200', " OK`r`nContent-Length: 0`r`n`r`n") -ChunkDelayMs 15
Assert-Hotkey $response.Accepted 'fragmented HTTP 200 is accepted'
Assert-Hotkey ($response.Request.RequestLine -eq 'POST /activate-oldest HTTP/1.1' -and $response.Request.Body -eq '{}') 'oldest path sends a complete bounded POST'
$response = Invoke-HotkeyResponseTest -Chunks @('HTTP/1.1 5', "03 Service Unavailable`r`nContent-Length: 0`r`n`r`n") -ChunkDelayMs 15
Assert-Hotkey (-not $response.Accepted) 'complete fragmented rejection permits the next candidate'
foreach ($scenario in @('empty', 'partial', 'reset', 'overlong')) {
    $chunks = switch ($scenario) {
        'partial' { 'HTTP/1.1 5' }
        'reset' { 'HTTP/1.' }
        'overlong' { 'HTTP/1.1 200 ' + ('x' * 300) }
    }
    $response = Invoke-HotkeyResponseTest -Chunks @($chunks) -ResetAfterRequest:($scenario -eq 'reset') -Oldest
    Assert-Hotkey $response.Accepted "$scenario acknowledgement consumes the key after a full request"
    Assert-Hotkey ($response.Attempts.Count -eq 1 -and $response.Attempts[0] -eq 'first"card') "$scenario acknowledgement cannot activate a second card"
    $payload = $response.Request.Body | ConvertFrom-Json
    Assert-Hotkey ($response.Request.RequestLine -eq 'POST /close HTTP/1.1' -and $payload.popupId -eq 'first"card' -and $payload.activate -eq $true) "$scenario card request preserves JSON values"
}
$response = Invoke-HotkeyResponseTest -Chunks @('H', 'T', 'T', 'P', '/', '1') -ChunkDelayMs 80 -TimeoutMs 150
Assert-Hotkey ($response.Accepted -and $response.ElapsedMs -lt 1200) 'fragmented acknowledgement shares one elapsed time budget'
& {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $config = [pscustomobject]@{ BrokerPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    $listener.Stop()
    Assert-Hotkey (-not (Send-NotifyHotkeyBrokerPost -Path '/close' -TimeoutMs 100)) 'connection failure before sending permits fallback'
    Assert-Hotkey (-not (Invoke-NotifyHotkeyBrokerActivateOldest)) 'oldest wrapper does not report a rejected POST as success'
}

Write-Output ("Popup hotkey tests passed: {0}" -f $script:PassCount)
