param([string]$OutDir = (Join-Path $PSScriptRoot '..\src\icons'), [string]$Name = 'orange-mascot')
# Draws the animated orange pixel mascot as PNG frames (name@1..8.png = active hop-and-wave, name@idle1..8.png = calm idle).
# Built-in skin "orange mascot" (Claude-style pixel critter, drawn here with plain rectangles; regenerates src\icons\orange-mascot@*.png). Keep ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$body = [System.Drawing.Color]::FromArgb(217, 119, 87)
$eyeC = [System.Drawing.Color]::FromArgb(36, 28, 26)
$bb = New-Object System.Drawing.SolidBrush($body); $eb = New-Object System.Drawing.SolidBrush($eyeC)
function Frame([string]$file, [int]$dy, [int]$armL, [int]$armR, [bool]$blink) {
	$bmp = New-Object System.Drawing.Bitmap(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'None'; $g.PixelOffsetMode = 'Half'; $g.Clear([System.Drawing.Color]::Transparent)
	$top = 62 + $dy; $bot = 158 + $dy
	$g.FillRectangle($bb, 44, $top, 168, 96)                         # body
	$g.FillRectangle($bb, 16, $armL + $dy, 28, 28)                   # left arm
	$g.FillRectangle($bb, 212, $armR + $dy, 28, 28)                  # right arm
	$legLen = 202 - $bot                                              # legs reach the ground; shorter when airborne is handled by dy
	if ($dy -lt 0) { $legLen = 44 + [int]($dy * 0.45) }               # tucked legs while jumping
	foreach ($lx in @(58, 86, 156, 184)) { $g.FillRectangle($bb, $lx, $bot, 14, $legLen) }
	if ($blink) { foreach ($ex in @(72, 170)) { $g.FillRectangle($eb, $ex, (102 + $dy), 14, 6) } }
	else { foreach ($ex in @(72, 170)) { $g.FillRectangle($eb, $ex, (90 + $dy), 14, 28) } }
	$g.Dispose(); $bmp.Save((Join-Path $OutDir $file), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
# active: crouch, jump, wave in the air, land, blink
$act = @(@(0, 104, 104, $false), @(8, 120, 120, $false), @(-14, 76, 76, $false), @(-30, 62, 62, $false), @(-22, 70, 70, $false), @(-6, 90, 90, $false), @(8, 120, 120, $false), @(0, 104, 104, $true))
for ($i = 0; $i -lt $act.Count; $i++) { $a = $act[$i]; Frame ('{0}@{1}.png' -f $Name, ($i + 1)) $a[0] $a[1] $a[2] $a[3] }
# idle: stand, breathe, blink, wave the right arm
$idl = @(@(0, 104, 104, $false), @(2, 104, 104, $false), @(0, 104, 104, $false), @(0, 104, 104, $true), @(0, 104, 104, $false), @(0, 104, 74, $false), @(0, 104, 92, $false), @(0, 104, 74, $false))
for ($i = 0; $i -lt $idl.Count; $i++) { $a = $idl[$i]; Frame ('{0}@idle{1}.png' -f $Name, ($i + 1)) $a[0] $a[1] $a[2] $a[3] }
'frames written to ' + (Resolve-Path $OutDir)
