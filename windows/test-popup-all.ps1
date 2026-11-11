# Run popup regressions in separate processes so native test stubs cannot leak between suites.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$powerShell = Join-Path $PSHOME 'powershell.exe'
foreach ($name in @('test-popup-ui', 'test-popup-state', 'test-popup-hotkey', 'test-popup-delivery', 'test-popup-identity', 'test-popup-paint', 'test-pi-notify-header', 'test-popup-coordination', 'test-popup-listener')) {
    & $powerShell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot ($name + '.ps1'))
    if ($LASTEXITCODE -ne 0) { throw ("Popup regression failed: {0} (exit {1})" -f $name, $LASTEXITCODE) }
}
Write-Output 'All popup regression suites passed.'
