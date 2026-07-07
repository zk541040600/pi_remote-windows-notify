param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/NotifyBridge.Common.ps1"
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Set-NotifyBridgeActiveConfigPath -ConfigPath $ConfigPath
}
$baseDir = Get-NotifyBridgeBaseDir
$pidPath = Join-Path $baseDir 'listener.pid'
$listenerPath = Join-Path $PSScriptRoot 'notify-listener.ps1'

Set-Content -LiteralPath $pidPath -Value ([string]$PID) -Encoding ASCII
try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        & $listenerPath
    }
    else {
        & $listenerPath -ConfigPath $ConfigPath
    }
}
finally {
    try {
        $current = if (Test-Path -LiteralPath $pidPath) { [string](Get-Content -LiteralPath $pidPath -Raw) } else { '' }
        if ($current.Trim() -eq [string]$PID) {
            Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}
