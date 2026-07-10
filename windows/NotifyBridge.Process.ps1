# Start a hidden command through the existing scheduled-task path with VBS fallback.
function Start-NotifyBridgeDetachedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,
        [string]$Name = 'process'
    )

    $vbsPath = Join-Path $env:TEMP ('pi-notify-{0}-start-{1}-{2}.vbs' -f $Name, $PID, ([Guid]::NewGuid().ToString('N')))
    $escapedCommand = $CommandLine.Replace('"', '""')
    $content = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$escapedCommand", 0, False
"@
    [System.IO.File]::WriteAllText($vbsPath, $content.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $taskName = 'PiNotifyStart_{0}_{1}' -f $Name, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument (Join-NotifyBridgeProcessArguments @($vbsPath))
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 6
        return
    }
    catch {
        Start-Process -FilePath 'wscript.exe' -ArgumentList (Join-NotifyBridgeProcessArguments @($vbsPath)) -WindowStyle Hidden | Out-Null
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# Match a full path in a command line without accepting a longer sibling prefix.
function Test-NotifyBridgeCommandLineContainsPath {
    [CmdletBinding()]
    param(
        [string]$CommandLine,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $needle = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $start = 0
    while ($start -lt $CommandLine.Length) {
        $index = $CommandLine.IndexOf($needle, $start, [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { return $false }
        $end = $index + $needle.Length
        if ($end -ge $CommandLine.Length) { return $true }
        $next = [string]$CommandLine[$end]
        if ([char]::IsWhiteSpace($CommandLine[$end]) -or $next -eq '"' -or $next -eq "'" -or $next -eq '\' -or $next -eq '/') { return $true }
        $start = $index + 1
    }
    return $false
}

# Check whether a process command line belongs to one of the current instance paths.
function Test-NotifyBridgeProcessOwnedByPaths {
    [CmdletBinding()]
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)]
        [string[]]$OwnedPaths
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    foreach ($path in $OwnedPaths) {
        if (Test-NotifyBridgeCommandLineContainsPath -CommandLine $CommandLine -Path $path) { return $true }
    }
    return $false
}

# Enumerate one script's processes only when their command line belongs to this instance.
function Get-NotifyBridgeScriptProcessIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [string[]]$OwnedPaths,
        [int]$ExcludeProcessId = $PID
    )

    $processIds = @()
    $escaped = [regex]::Escape($ScriptName)
    try {
        $items = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $commandLine = [string]$_.CommandLine
            ($_.ProcessId -ne $ExcludeProcessId) -and
                (Test-NotifyBridgeProcessOwnedByPaths -CommandLine $commandLine -OwnedPaths $OwnedPaths) -and
                ($commandLine -match ('(?i)-File\s+("[^"]*{0}"|[^\s"]*{0})' -f $escaped))
        } | Select-Object -ExpandProperty ProcessId
        foreach ($processId in $items) {
            if ($processId) { $processIds += [int]$processId }
        }
    }
    catch {
    }

    return @($processIds | Select-Object -Unique)
}
