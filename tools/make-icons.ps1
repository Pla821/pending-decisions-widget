param([string]$OutDir = (Join-Path $PSScriptRoot '..\src\icons'))
# Regenerates the built-in icons (flat vector style, navy #1F3A5F / red #D94A3A) with GDI+.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$S = 256
$navy = [System.Drawing.Color]::FromArgb(31, 58, 95); $navy2 = [System.Drawing.Color]::FromArgb(52, 92, 146)
$red = [System.Drawing.Color]::FromArgb(217, 74, 58); $red2 = [System.Drawing.Color]::FromArgb(236, 112, 94)
$white = [System.Drawing.Brushes]::White
function New-Canvas {
	$bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([System.Drawing.Color]::Transparent)
	return @($bmp, $g)
}
function Fill-Disc($g, $c1, $c2) {
	$rect = New-Object System.Drawing.Rectangle(8, 8, ($S - 16), ($S - 16))
	$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 60)
	$g.FillEllipse($br, $rect)
}
function Round-Rect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
	$gp = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = $r * 2
	$gp.AddArc($x, $y, $d, $d, 180, 90); $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90); $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $gp.CloseFigure()
	return $gp
}
function Badge-Dot($g) { # small red notification dot with white ring, top-right
	$g.FillEllipse($white, 150, 38, 62, 62)
	$g.FillEllipse((New-Object System.Drawing.SolidBrush($red)), 157, 45, 48, 48)
}
function Save($bmp, $g, $name) { $g.Dispose(); $bmp.Save((Join-Path $OutDir $name), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() }

# bell
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Fill-Disc $g $navy2 $navy
$bell = New-Object System.Drawing.Drawing2D.GraphicsPath
$bell.AddBezier(80, 172, 98, 152, 92, 124, 98, 106)
$bell.AddBezier(98, 106, 106, 80, 150, 80, 158, 106)
$bell.AddBezier(158, 106, 164, 124, 158, 152, 176, 172)
$bell.CloseFigure()
$g.FillPath($white, $bell)
$g.FillPath($white, (Round-Rect 74 168 108 14 7))
$g.FillEllipse($white, 118, 62, 20, 20)
$g.FillEllipse($white, 114, 188, 28, 20)
Save $bmp $g 'bell.png'

# chat bubble with a question mark
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Fill-Disc $g $navy2 $navy
$g.FillPath($white, (Round-Rect 58 66 140 98 26))
$g.FillPolygon($white, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(84, 152)), (New-Object System.Drawing.PointF(84, 196)), (New-Object System.Drawing.PointF(126, 156))))
$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
$f = New-Object System.Drawing.Font('Segoe UI', 84, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$g.DrawString('?', $f, (New-Object System.Drawing.SolidBrush($red)), (New-Object System.Drawing.RectangleF(58, 64, 140, 102)), $sf)
Save $bmp $g 'chat.png'

# exclamation mark on red
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Fill-Disc $g $red2 $red
$g.FillPath($white, (Round-Rect 112 56 32 98 16))
$g.FillEllipse($white, 110, 168, 36, 36)
Save $bmp $g 'alert.png'

# envelope with a dot
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Fill-Disc $g $navy2 $navy
$g.FillPath($white, (Round-Rect 56 90 144 98 16))
$pen = New-Object System.Drawing.Pen($navy, 9); $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
$g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(66, 104)), (New-Object System.Drawing.PointF(128, 150)), (New-Object System.Drawing.PointF(190, 104))))
Save $bmp $g 'envelope.png'
'icons written to ' + (Resolve-Path $OutDir)
