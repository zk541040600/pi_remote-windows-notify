# Execute real paint callbacks on in-memory controls, including an injected draw failure.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:PaintPassCount = 0
$script:PaintMessages = [System.Collections.Generic.List[string]]::new()
$script:PaintResources = [System.Collections.Generic.List[object]]::new()
$script:FailWallpaperLog = $false
$script:FailedWallpaper = $null

function Assert-Paint {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:PaintPassCount += 1
    Write-Output "PASS $Name"
}
function Read-PaintAst {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
function Read-PaintFunctions {
    param($Ast, [string[]]$Names)
    $parts = foreach ($name in $Names) {
        $functionAst = $Ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $functionAst) { throw "Function missing: $name" }
        $functionAst.Extent.Text
    }
    return ($parts -join "`n")
}
function Test-PaintResourceDisposed {
    param($Resource)
    if ($null -eq $Resource) { return $false }
    $clone = $null
    try {
        # Property getters may return cached values or suppress native errors in PowerShell.
        # Clone crosses the GDI+ boundary and fails when the native resource is disposed.
        $clone = $Resource.Clone()
        return $false
    } catch { return $true }
    finally { if ($null -ne $clone) { $clone.Dispose() } }
}
function Write-NotifyBrokerLog {
    param([string]$Message)
    $script:PaintMessages.Add($Message)
    if ($script:FailWallpaperLog -and $Message -like '*wallpaper-loaded*') {
        $script:FailedWallpaper = Get-Variable -Name bitmap -Scope 1 -ValueOnly
        $script:FailWallpaperLog = $false
        throw 'Injected failure after bitmap allocation.'
    }
}
function Write-NotifyPopupLog {
    param([string]$Message)
    $script:PaintMessages.Add($Message)
    if ($script:FailWallpaperLog -and $Message -like '*wallpaper-loaded*') {
        $script:FailedWallpaper = Get-Variable -Name bitmap -Scope 1 -ValueOnly
        $script:FailWallpaperLog = $false
        throw 'Injected failure after bitmap allocation.'
    }
}
# Keep real GDI objects so disposed state is observable after a callback returns.
function New-Object {
    param([Parameter(Position=0)][string]$TypeName, [Parameter(Position=1)][object[]]$ArgumentList)
    $value = if ($PSBoundParameters.ContainsKey('ArgumentList')) {
        Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
    } else { Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName }
    if ($value -is [System.Drawing.Drawing2D.GraphicsPath] -or $value -is [System.Drawing.Pen] -or $value -is [System.Drawing.SolidBrush]) {
        $script:PaintResources.Add($value)
    }
    return $value
}

$disposalProbes = @(
    [System.Drawing.Pen]::new([System.Drawing.Color]::Red, 1)
    [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Blue)
    [System.Drawing.Drawing2D.GraphicsPath]::new()
    [System.Drawing.Bitmap]::new(2, 2)
)
foreach ($probe in $disposalProbes) {
    try { Assert-Paint (-not (Test-PaintResourceDisposed $probe)) ('native check accepts live ' + $probe.GetType().Name) }
    finally { $probe.Dispose() }
    Assert-Paint (Test-PaintResourceDisposed $probe) ('native check rejects disposed ' + $probe.GetType().Name)
}

$commonAst = Read-PaintAst 'NotifyBridge.Common.ps1'
. ([scriptblock]::Create((Read-PaintFunctions $commonAst @('Get-NotifyAppLabel', 'Set-NotifyAppHeader'))))
$script:NotifyBrokerWallpaperImage = $null
$script:NotifyPopupWallpaperImage = $null
$borderColor = [System.Drawing.Color]::FromArgb(74, 80, 96)
$accentColor = [System.Drawing.Color]::FromArgb(94, 234, 212)
$imagePath = Join-Path ([System.IO.Path]::GetTempPath()) ('pi-notify-paint-' + [Guid]::NewGuid().ToString('N') + '.png')
$imageFixture = [System.Drawing.Bitmap]::new(2, 2)
try { $imageFixture.Save($imagePath, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $imageFixture.Dispose() }

try {
    foreach ($surface in @('Broker', 'Popup')) {
        $ast = Read-PaintAst ('pi-notify-' + $surface.ToLowerInvariant() + '.ps1')
        . ([scriptblock]::Create((Read-PaintFunctions $ast @(('New-Notify'+$surface+'RoundedPath'), ('Get-Notify'+$surface+'WallpaperImage')))))
        $paintAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression.Extent.Text -eq '$panel' -and $node.Member.Value -eq 'Add_Paint' }, $true)
        $paint = $paintAst.Arguments[0].ScriptBlock.GetScriptBlock()
        $panel = [System.Windows.Forms.Panel]::new()
        $panel.Size = [System.Drawing.Size]::new(420, 154)
        $this = $panel
        $bitmap = [System.Drawing.Bitmap]::new(420, 154)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $script:PaintResources.Clear(); $script:PaintMessages.Clear()
            $fakeGraphics = [pscustomobject]@{ SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::Default }
            $fakeGraphics | Add-Member ScriptMethod DrawPath { param($Pen, $Path) throw 'Injected draw failure.' }
            $_ = [pscustomobject]@{ Graphics = $fakeGraphics }
            & $paint
            Assert-Paint ($script:PaintMessages.Count -eq 1 -and $script:PaintMessages[0] -like '*paint-error*Injected draw failure*') "$surface draw failure is contained"
            Assert-Paint ($script:PaintResources.Count -eq 3) "$surface failure reached path, pen and brush allocation"
            foreach ($resource in $script:PaintResources) {
                Assert-Paint (Test-PaintResourceDisposed $resource) ("$surface failure disposes " + $resource.GetType().Name)
            }

            $script:PaintResources.Clear(); $script:PaintMessages.Clear()
            $_ = [pscustomobject]@{ Graphics = $graphics }
            & $paint
            Assert-Paint ($script:PaintMessages.Count -eq 0 -and $bitmap.GetPixel(2, 80).ToArgb() -eq $accentColor.ToArgb()) "$surface normal card paint succeeds"
            foreach ($resource in $script:PaintResources) {
                Assert-Paint (Test-PaintResourceDisposed $resource) ("$surface normal paint disposes " + $resource.GetType().Name)
            }
        } finally { $graphics.Dispose(); $bitmap.Dispose(); $panel.Dispose() }

        $loader = 'Get-Notify' + $surface + 'WallpaperImage'
        $loaded = & $loader -Path $imagePath
        try { Assert-Paint ($null -ne $loaded -and $loaded.Width -eq 2) "$surface successful wallpaper remains caller-owned" } finally { if ($null -ne $loaded) { $loaded.Dispose() } }
        $script:FailWallpaperLog = $true; $script:FailedWallpaper = $null
        $loaded = & $loader -Path $imagePath
        Assert-Paint ($null -eq $loaded -and $null -ne $script:FailedWallpaper) "$surface post-allocation wallpaper error is contained"
        Assert-Paint (Test-PaintResourceDisposed $script:FailedWallpaper) "$surface failed wallpaper bitmap is disposed"
    }

    $label = [System.Windows.Forms.Label]::new()
    $bitmap = [System.Drawing.Bitmap]::new(240, 18)
    try {
        $label.Size = [System.Drawing.Size]::new(240, 18)
        Set-NotifyAppHeader -Label $label -OriginKind 'pi-web'
        $label.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, 240, 18))
        Assert-Paint ($label.Text -eq 'Pi Notify' -and $bitmap.GetPixel(6, 9).ToArgb() -eq [System.Drawing.Color]::FromArgb(96, 165, 250).ToArgb()) 'Pi header still paints its blue source badge'
    } finally { $bitmap.Dispose(); $label.Dispose() }
}
finally { Remove-Item -LiteralPath $imagePath -Force -ErrorAction SilentlyContinue }
Write-Output ("Popup paint tests passed: {0}" -f $script:PaintPassCount)
