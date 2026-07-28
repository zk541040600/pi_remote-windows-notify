[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/NotifyBridge.Common.ps1"

# Reserve a loopback port for one short-lived listener fixture.
function Get-NotifyQqTestPort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try {
        return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    }
    finally {
        $probe.Stop()
    }
}

# Count complete fake-sender records without reading any real sender configuration.
function Get-NotifyQqTestOutputCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }
    return @([System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

# Wait for an asynchronous fake sender or structured log result.
function Wait-NotifyQqTestCondition {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutMs = 8000,
        [string]$Failure = 'Timed out waiting for QQ test condition.'
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 50
    }
    throw $Failure
}

# Send one real HTTP request through the listener producer boundary and return its response body.
function Invoke-NotifyQqTestRequest {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $requestHead = "POST /notify HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nContent-Type: application/json; charset=utf-8`r`nX-Pi-Notify-Token: $Token`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestHead)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect([System.Net.IPAddress]::Loopback, $Port)
        $stream = $client.GetStream()
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $response = $reader.ReadToEnd()
        $separator = $response.IndexOf("`r`n`r`n")
        if ($separator -lt 0) {
            throw 'Listener returned a malformed HTTP response.'
        }
        if ($response -notmatch '^HTTP/1\.1 200\b') {
            throw ('Listener returned a non-success response: {0}' -f (($response -split "`r?`n")[0]))
        }
        return $response.Substring($separator + 4)
    }
    finally {
        $client.Close()
    }
}

# Start the actual listener with a marker-only desktop sink and fake QQ sender config.
function Start-NotifyQqTestListener {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$SenderScript,
        [Parameter(Mandatory = $true)][string]$DesktopSinkPath,
        [string]$DisplayMode = 'popup-focus',
        [int]$MaxConcurrent = 2,
        [int]$TimeoutSeconds = 1
    )

    $port = Get-NotifyQqTestPort
    $configPath = Join-Path $BaseDir 'config.json'
    $token = 'qq-test-token'
    $config = Ensure-NotifyBridgeConfig `
        -ConfigPath $configPath `
        -ListenHost '127.0.0.1' `
        -Port $port `
        -Token $token `
        -RemoteHostAlias 'qq-test' `
        -SshExecutable 'cmd.exe' `
        -DisplayMode $DisplayMode `
        -BrokerEnabled $false `
        -QqNotifyEnabled $true `
        -QqNodeExecutable $NodeExecutable `
        -QqSenderScript $SenderScript `
        -QqSendTimeoutSeconds $TimeoutSeconds `
        -QqMaxConcurrent $MaxConcurrent

    $rawConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $missingRouteHost = Join-Path $BaseDir 'missing-route-host.exe'
    if ($rawConfig.PSObject.Properties['routeHostExe']) {
        $rawConfig.routeHostExe = $missingRouteHost
    }
    else {
        $rawConfig | Add-Member -NotePropertyName 'routeHostExe' -NotePropertyValue $missingRouteHost
    }
    [System.IO.File]::WriteAllText($configPath, ($rawConfig | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

    $listenerScript = Join-Path $PSScriptRoot 'notify-listener.ps1'
    $listenerArgs = Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $listenerScript,
        '-ConfigPath', $configPath,
        '-TestDesktopSinkPath', $DesktopSinkPath
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-NotifyBridgePowerShellExe
    $startInfo.Arguments = $listenerArgs
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    try {
        Wait-NotifyQqTestCondition -TimeoutMs 8000 -Failure 'Test listener did not open its loopback port.' -Condition {
            $probe = [System.Net.Sockets.TcpClient]::new()
            try {
                $probe.Connect([System.Net.IPAddress]::Loopback, $port)
                return $true
            }
            catch {
                if ($process.HasExited) {
                    throw 'Test listener exited before accepting requests.'
                }
                return $false
            }
            finally {
                $probe.Close()
            }
        }
    }
    catch {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(2000) | Out-Null
        }
        try { $null = $stdoutTask.GetAwaiter().GetResult() } catch {}
        try { $null = $stderrTask.GetAwaiter().GetResult() } catch {}
        $process.Dispose()
        throw
    }

    return [pscustomobject]@{
        Process     = $process
        StdoutTask  = $stdoutTask
        StderrTask  = $stderrTask
        Port        = $port
        Token       = $token
        ConfigPath  = $config.ConfigPath
        BaseDir     = $BaseDir
        ListenerLog = Join-Path $BaseDir 'logs\listener.log'
        SenderLog   = Join-Path $BaseDir 'logs\qq-sender.log'
        PendingDir  = Join-Path $BaseDir 'qq-pending'
    }
}

# Stop only the listener process owned by this test fixture.
function Stop-NotifyQqTestListener {
    param([Parameter(Mandatory = $true)]$Fixture)

    if (-not $Fixture.Process.HasExited) {
        $Fixture.Process.Kill()
        $Fixture.Process.WaitForExit(3000) | Out-Null
    }
    try { $null = $Fixture.StdoutTask.GetAwaiter().GetResult() } catch {}
    try { $null = $Fixture.StderrTask.GetAwaiter().GetResult() } catch {}
    $Fixture.Process.Dispose()
}

# Run the worker directly to verify its bounded result and unconditional temp cleanup.
function Invoke-NotifyQqTestWorker {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $env:PI_NOTIFY_QQ_TEST_MODE = $Mode
    $textFile = Join-Path (Split-Path -Parent $ConfigPath) ('worker-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($textFile, $Text, [System.Text.UTF8Encoding]::new($false))
    $workerScript = Join-Path $PSScriptRoot 'pi-notify-qq-sender.ps1'
    $workerArgs = Join-NotifyBridgeProcessArguments @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $workerScript,
        '-ConfigPath', $ConfigPath,
        '-TextFile', $textFile
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-NotifyBridgePowerShellExe
    $startInfo.Arguments = $workerArgs
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $process.WaitForExit(8000)) {
        $process.Kill()
        throw ('Worker fixture did not exit for mode {0}.' -f $Mode)
    }
    $process.Dispose()
    if (Test-Path -LiteralPath $textFile) {
        throw ('Worker left its text file for mode {0}.' -f $Mode)
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-qq-test-' + [Guid]::NewGuid().ToString('N'))
$directDir = Join-Path $testRoot 'direct'
$listenerDir = Join-Path $testRoot 'listener'
$capacityDir = Join-Path $testRoot 'capacity'
$missingDir = Join-Path $testRoot 'missing'
$fakeSender = Join-Path $testRoot 'fake-qq-sender.mjs'
$outputPath = Join-Path $testRoot 'fake-output.jsonl'
$desktopSink = Join-Path $listenerDir 'desktop.log'
$capacityDesktopSink = Join-Path $capacityDir 'desktop.log'
$missingDesktopSink = Join-Path $missingDir 'desktop.log'
$listenerFixture = $null
$capacityFixture = $null
$missingFixture = $null
$savedOutput = $env:PI_NOTIFY_QQ_TEST_OUTPUT
$savedMode = $env:PI_NOTIFY_QQ_TEST_MODE

try {
    New-Item -ItemType Directory -Force -Path $testRoot, $directDir, $listenerDir, $capacityDir, $missingDir | Out-Null
    $fakeSenderSource = @'
import { appendFileSync, readFileSync } from "node:fs";
const index = process.argv.indexOf("--text-file");
const text = readFileSync(process.argv[index + 1], "utf8");
const mode = process.env.PI_NOTIFY_QQ_TEST_MODE || "success";
if (mode === "nonzero") {
  console.error("RAW-PRIVATE-DIAGNOSTIC");
  process.exit(7);
}
if (mode === "timeout") {
  setTimeout(() => {}, 10000);
} else {
  appendFileSync(process.env.PI_NOTIFY_QQ_TEST_OUTPUT, JSON.stringify(text) + "\n", "utf8");
}
'@
    [System.IO.File]::WriteAllText($fakeSender, $fakeSenderSource, [System.Text.UTF8Encoding]::new($false))

    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) {
        $nodeCommand = Get-Command node -ErrorAction Stop
    }
    $nodeExecutable = [string]$nodeCommand.Source
    $env:PI_NOTIFY_QQ_TEST_OUTPUT = $outputPath

    $directConfig = Ensure-NotifyBridgeConfig `
        -ConfigPath (Join-Path $directDir 'config.json') `
        -SshExecutable 'cmd.exe' `
        -QqNotifyEnabled $true `
        -QqNodeExecutable $nodeExecutable `
        -QqSenderScript $fakeSender `
        -QqSendTimeoutSeconds 1 `
        -QqMaxConcurrent 2
    Invoke-NotifyQqTestWorker -ConfigPath $directConfig.ConfigPath -Mode 'success' -Text 'DIRECT-SUCCESS-CANARY'
    Invoke-NotifyQqTestWorker -ConfigPath $directConfig.ConfigPath -Mode 'nonzero' -Text 'DIRECT-NONZERO-CANARY'
    Invoke-NotifyQqTestWorker -ConfigPath $directConfig.ConfigPath -Mode 'timeout' -Text 'DIRECT-TIMEOUT-CANARY'

    $missingSender = Join-Path $directDir 'missing-sender.mjs'
    $directConfig = Ensure-NotifyBridgeConfig -ConfigPath $directConfig.ConfigPath -QqSenderScript $missingSender
    Invoke-NotifyQqTestWorker -ConfigPath $directConfig.ConfigPath -Mode 'success' -Text 'DIRECT-MISSING-CANARY'
    $directLog = [System.IO.File]::ReadAllText((Join-Path $directDir 'logs\qq-sender.log'), [System.Text.UTF8Encoding]::new($false))
    foreach ($requiredStatus in @('qq-send-ok', 'qq-send-failed exitCode=7', 'qq-send-timeout', 'qq-send-unavailable reason=sender')) {
        if ($directLog -notmatch [regex]::Escape($requiredStatus)) {
            throw ('Missing direct worker status: {0}' -f $requiredStatus)
        }
    }
    if ($directLog -match 'DIRECT-|RAW-PRIVATE-DIAGNOSTIC') {
        throw 'Worker log exposed message text or raw sender stderr.'
    }

    $env:PI_NOTIFY_QQ_TEST_MODE = 'success'
    $listenerFixture = Start-NotifyQqTestListener -BaseDir $listenerDir -NodeExecutable $nodeExecutable -SenderScript $fakeSender -DesktopSinkPath $desktopSink -DisplayMode 'system-toast'
    $askPayload = @{
        title = 'Ask title'
        body = 'Waiting for answer'
        focusTarget = 'qq-test'
        cwdBase = 'ask-project'
        routeVersion = 1
        notificationId = [Guid]::NewGuid().ToString()
        notificationKind = 'ask-user'
        originKind = 'terminal'
    }
    if ((Invoke-NotifyQqTestRequest -Port $listenerFixture.Port -Token $listenerFixture.Token -Payload $askPayload) -ne 'ok') {
        throw 'ask-user listener request did not return ok.'
    }
    Wait-NotifyQqTestCondition -Condition { (Get-NotifyQqTestOutputCount -Path $outputPath) -ge 2 }

    $turnPayload = @{
        title = 'Turn title'
        body = 'Turn complete'
        focusTarget = 'qq-test'
        tabTitle = 'test-tab'
        routeVersion = 1
        notificationId = [Guid]::NewGuid().ToString()
        notificationKind = 'turn-complete'
        originKind = 'terminal'
    }
    if ((Invoke-NotifyQqTestRequest -Port $listenerFixture.Port -Token $listenerFixture.Token -Payload $turnPayload) -ne 'ok') {
        throw 'turn-complete listener request did not return ok.'
    }
    Wait-NotifyQqTestCondition -Condition { (Get-NotifyQqTestOutputCount -Path $outputPath) -ge 3 }

    $webPayload = @{
        title = 'Web title'
        body = 'Web complete'
        routeVersion = 1
        notificationId = [Guid]::NewGuid().ToString()
        notificationKind = 'turn-complete'
        originKind = 'pi-web'
        instanceKey = 'qq-test-web-instance'
        routingKey = ('a' * 64)
    }
    if ((Invoke-NotifyQqTestRequest -Port $listenerFixture.Port -Token $listenerFixture.Token -Payload $webPayload) -ne 'ok') {
        throw 'Pi Web listener request did not return ok.'
    }
    Wait-NotifyQqTestCondition -Condition { (Get-NotifyQqTestOutputCount -Path $outputPath) -ge 4 }

    $dedupPrecisePayload = @{
        title = 'Dedup title'
        body = 'Dedup body'
        focusTarget = 'qq-test'
        cwdBase = 'dedup-project'
    }
    $dedupImprecisePayload = @{
        title = 'Dedup title'
        body = 'Dedup body'
        focusTarget = 'qq-test'
    }
    $beforeDedup = Get-NotifyQqTestOutputCount -Path $outputPath
    if ((Invoke-NotifyQqTestRequest -Port $listenerFixture.Port -Token $listenerFixture.Token -Payload $dedupPrecisePayload) -ne 'ok') {
        throw 'First dedup fixture request did not return ok.'
    }
    Wait-NotifyQqTestCondition -Condition { (Get-NotifyQqTestOutputCount -Path $outputPath) -eq ($beforeDedup + 1) }
    if ((Invoke-NotifyQqTestRequest -Port $listenerFixture.Port -Token $listenerFixture.Token -Payload $dedupImprecisePayload) -ne 'dedup') {
        throw 'Imprecise duplicate listener request was not dropped.'
    }
    Start-Sleep -Milliseconds 300
    if ((Get-NotifyQqTestOutputCount -Path $outputPath) -ne ($beforeDedup + 1)) {
        throw 'Imprecise duplicate listener request launched a second QQ worker.'
    }

    $listenerMessages = @([System.IO.File]::ReadAllLines($outputPath, [System.Text.UTF8Encoding]::new($false)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($expectedMessage in @("Ask title`r`nWaiting for answer", "Turn title`r`nTurn complete", "Web title`r`nWeb complete")) {
        if ($listenerMessages -notcontains $expectedMessage) {
            throw ('Listener-to-worker text mismatch: {0}' -f $expectedMessage.Replace("`r`n", ' / '))
        }
    }
    $listenerLog = [System.IO.File]::ReadAllText($listenerFixture.ListenerLog, [System.Text.UTF8Encoding]::new($false))
    if ($listenerLog -match 'Ask title|Waiting for answer|Turn title|Turn complete|Web title|Web complete|No target title|No target body') {
        throw 'Listener log exposed QQ message text.'
    }

    Stop-NotifyQqTestListener -Fixture $listenerFixture
    $listenerFixture = $null

    $env:PI_NOTIFY_QQ_TEST_MODE = 'timeout'
    $capacityFixture = Start-NotifyQqTestListener -BaseDir $capacityDir -NodeExecutable $nodeExecutable -SenderScript $fakeSender -DesktopSinkPath $capacityDesktopSink -MaxConcurrent 1 -TimeoutSeconds 1
    $capacityOne = @{ title = 'Capacity one'; body = 'Capacity body one'; focusTarget = 'qq-test'; cwdBase = 'capacity-one' }
    $capacityTwo = @{ title = 'Capacity two'; body = 'Capacity body two'; focusTarget = 'qq-test'; cwdBase = 'capacity-two' }
    if ((Invoke-NotifyQqTestRequest -Port $capacityFixture.Port -Token $capacityFixture.Token -Payload $capacityOne) -ne 'ok' -or
        (Invoke-NotifyQqTestRequest -Port $capacityFixture.Port -Token $capacityFixture.Token -Payload $capacityTwo) -ne 'ok') {
        throw 'Capacity fixture changed the listener success response.'
    }
    Wait-NotifyQqTestCondition -Condition {
        (Test-Path -LiteralPath $capacityFixture.ListenerLog) -and
        ([System.IO.File]::ReadAllText($capacityFixture.ListenerLog) -match 'qq-send-drop reason=capacity')
    }
    Wait-NotifyQqTestCondition -Condition {
        (Test-Path -LiteralPath $capacityFixture.SenderLog) -and
        ([System.IO.File]::ReadAllText($capacityFixture.SenderLog) -match 'qq-send-timeout')
    }
    Wait-NotifyQqTestCondition -Condition {
        -not (Test-Path -LiteralPath $capacityFixture.PendingDir) -or
        @(Get-ChildItem -LiteralPath $capacityFixture.PendingDir -Filter '*.txt' -File -ErrorAction SilentlyContinue).Count -eq 0
    }
    if (@([System.IO.File]::ReadAllLines($capacityDesktopSink)).Count -ne 2) {
        throw 'Capacity limit interfered with desktop notification delivery.'
    }
    Stop-NotifyQqTestListener -Fixture $capacityFixture
    $capacityFixture = $null

    $env:PI_NOTIFY_QQ_TEST_MODE = 'success'
    $missingFixture = Start-NotifyQqTestListener -BaseDir $missingDir -NodeExecutable $nodeExecutable -SenderScript (Join-Path $missingDir 'missing-sender.mjs') -DesktopSinkPath $missingDesktopSink
    $noTargetBefore = Get-NotifyQqTestOutputCount -Path $outputPath
    $noTargetPayload = @{ title = 'No target title'; body = 'No target body'; focusTarget = 'qq-test' }
    if ((Invoke-NotifyQqTestRequest -Port $missingFixture.Port -Token $missingFixture.Token -Payload $noTargetPayload) -ne 'no-target') {
        throw 'Popup-focus no-target request did not preserve no-target response.'
    }
    Start-Sleep -Milliseconds 300
    if ((Get-NotifyQqTestOutputCount -Path $outputPath) -ne $noTargetBefore) {
        throw 'Popup-focus no-target request launched a QQ worker.'
    }
    $missingPayload = @{ title = 'Missing sender title'; body = 'Missing sender body'; focusTarget = 'qq-test'; cwdBase = 'missing-sender' }
    if ((Invoke-NotifyQqTestRequest -Port $missingFixture.Port -Token $missingFixture.Token -Payload $missingPayload) -ne 'ok') {
        throw 'Unavailable sender changed the listener success response.'
    }
    Wait-NotifyQqTestCondition -Condition {
        (Test-Path -LiteralPath $missingFixture.ListenerLog) -and
        ([System.IO.File]::ReadAllText($missingFixture.ListenerLog) -match 'qq-send-unavailable reason=sender')
    }
    if (@([System.IO.File]::ReadAllLines($missingDesktopSink)).Count -ne 1) {
        throw 'Unavailable sender interfered with desktop notification delivery.'
    }
    Stop-NotifyQqTestListener -Fixture $missingFixture
    $missingFixture = $null

    Write-Host 'QQ notify fake integration passed'
}
finally {
    if ($null -ne $listenerFixture) { Stop-NotifyQqTestListener -Fixture $listenerFixture }
    if ($null -ne $capacityFixture) { Stop-NotifyQqTestListener -Fixture $capacityFixture }
    if ($null -ne $missingFixture) { Stop-NotifyQqTestListener -Fixture $missingFixture }
    if ($null -eq $savedOutput) { Remove-Item Env:PI_NOTIFY_QQ_TEST_OUTPUT -ErrorAction SilentlyContinue } else { $env:PI_NOTIFY_QQ_TEST_OUTPUT = $savedOutput }
    if ($null -eq $savedMode) { Remove-Item Env:PI_NOTIFY_QQ_TEST_MODE -ErrorAction SilentlyContinue } else { $env:PI_NOTIFY_QQ_TEST_MODE = $savedMode }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
