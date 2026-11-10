Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot/NotifyBridge.Common.ps1"

$blue = [System.Drawing.Color]::FromArgb(96, 165, 250)
$card = [System.Drawing.Color]::FromArgb(28, 30, 36)
foreach ($item in @(@{ Origin = 'pi-web'; Text = 'Pi Notify'; Dot = $true }, @{ Origin = 'paseo'; Text = 'Paseo'; Dot = $false }, @{ Origin = 'terminal'; Text = 'Pi Remote'; Dot = $false })) {
    $label = [System.Windows.Forms.Label]::new()
    $bitmap = [System.Drawing.Bitmap]::new(240, 18)
    try {
        $label.Size = [System.Drawing.Size]::new(240, 18)
        $label.BackColor = $card
        Set-NotifyAppHeader -Label $label -OriginKind $item.Origin
        $label.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, 240, 18))
        $bluePixel = $bitmap.GetPixel(6, 9).ToArgb() -eq $blue.ToArgb()
        $expectedPadding = if ($item.Dot) { 16 } else { 0 }
        if ($label.Text -cne $item.Text -or $bluePixel -ne $item.Dot -or $label.Padding.Left -ne $expectedPadding) {
            throw "Popup icon or label mismatch for $($item.Origin)."
        }
    } finally {
        $bitmap.Dispose()
        $label.Dispose()
    }
}
'PASS: WinForms paints a real blue dot for Pi Web; other popup headers are unchanged.'
