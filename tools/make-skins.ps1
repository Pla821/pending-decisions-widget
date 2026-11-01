param([string]$OutDir = (Join-Path $PSScriptRoot '..\src\icons'))
# Regenerates the built-in pet skins (8 walking frames + 8 idle frames each) with GDI+:
#   gemini-star     - a four-point sparkle in blue/purple/pink gradient (just the symbol, no face)
#   chatgpt-knot    - a white six-loop knot on a green disc (just the symbol, no face)
# Simple shapes drawn by hand; only meant as a personal desktop icon skin.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$S = 256
function Col([string]$h) { [System.Drawing.ColorTranslator]::FromHtml($h) }
function PF([double]$x, [double]$y) { New-Object System.Drawing.PointF([single]$x, [single]$y) }
function New-Canvas {
	$bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
	return @($bmp, $g)
}
function Star-Path([double]$R, [double]$k) { # four-point sparkle centred on (0,0), tips at distance R, waist controlled by k
	$p = New-Object System.Drawing.Drawing2D.GraphicsPath
	$p.AddBezier((PF 0 (-$R)), (PF $k (-$k)), (PF $k (-$k)), (PF $R 0))
	$p.AddBezier((PF $R 0), (PF $k $k), (PF $k $k), (PF 0 $R))
	$p.AddBezier((PF 0 $R), (PF (-$k) $k), (PF (-$k) $k), (PF (-$R) 0))
	$p.AddBezier((PF (-$R) 0), (PF (-$k) (-$k)), (PF (-$k) (-$k)), (PF 0 (-$R)))
	$p.CloseFigure(); return $p
}
function Draw-Sparkle($g, [double]$x, [double]$y, [double]$r, [int]$alpha) {
	$g.TranslateTransform([single]$x, [single]$y)
	$path = Star-Path $r ($r * 0.14)
	$g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 255, 255, 255))), $path)
	$g.ResetTransform()
}
# ---- Gemini: four-point sparkle ----
function Draw-Gemini($mode, [int]$i) {
	$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
	$ph = $i / 8.0 * 2 * [Math]::PI
	if ($mode -eq 'walk') { $rot = 14 * [Math]::Sin($ph); $bounce = -12 * [Math]::Abs([Math]::Sin($ph)); $sc = 1 + 0.05 * [Math]::Cos($ph * 2) }
	else { $rot = 4 * [Math]::Sin($ph); $bounce = 3 * [Math]::Sin($ph); $sc = 1 + 0.04 * [Math]::Sin($ph) }
	$g.TranslateTransform(128, [single](128 + $bounce)); $g.RotateTransform([single]$rot); $g.ScaleTransform([single]$sc, [single]$sc)
	$path = Star-Path 112 12
	$rect = New-Object System.Drawing.RectangleF(-112, -112, 224, 224)
	$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Col '#4285F4'), (Col '#D96570'), 45.0)
	$cb = New-Object System.Drawing.Drawing2D.ColorBlend(3); $cb.Colors = [System.Drawing.Color[]]@((Col '#4285F4'), (Col '#9B72CB'), (Col '#D96570')); $cb.Positions = [single[]]@(0, 0.5, 1); $br.InterpolationColors = $cb
	$g.FillPath($br, $path)
	$g.ResetTransform()
	if ($mode -eq 'idle') { # twinkles
		$a1 = [int](140 + 110 * [Math]::Sin($ph)); $a2 = [int](140 + 110 * [Math]::Sin($ph + 2.4))
		Draw-Sparkle $g 30 36 14 ([Math]::Max(0, [Math]::Min(255, $a1))); Draw-Sparkle $g 226 218 11 ([Math]::Max(0, [Math]::Min(255, $a2)))
	}
	$g.Dispose(); return $bmp
}
# ---- ChatGPT: six interlocking loops on a green disc ----
function Draw-Knot($mode, [int]$i) {
	$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
	$ph = $i / 8.0 * 2 * [Math]::PI
	if ($mode -eq 'walk') { $bounce = -12 * [Math]::Abs([Math]::Sin($ph)); $spin = 360.0 * $i / 8 * 0.25 }
	else { $bounce = 2.5 * [Math]::Sin($ph); $spin = 6 * [Math]::Sin($ph) }
	$g.TranslateTransform(128, [single](128 + $bounce))
	$rect = New-Object System.Drawing.RectangleF(-112, -112, 224, 224)
	$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Col '#19C390'), (Col '#0E8F6B'), 60.0)
	$g.FillEllipse($br, $rect)
	$g.RotateTransform([single]$spin)
	$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 7); $pen.LineJoin = 'Round'
	for ($k = 0; $k -lt 6; $k++) { # each loop is a rounded bar, pushed out from the centre and turned 60 degrees from its neighbour
		$g.RotateTransform(60); $g.TranslateTransform(36, 0)
		$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
		$gp.AddArc(-14, -64, 28, 28, 180, 180); $gp.AddLine(14, -50, 14, 50); $gp.AddArc(-14, 36, 28, 28, 0, 180); $gp.CloseFigure()
		$g.DrawPath($pen, $gp); $g.TranslateTransform(-36, 0)
	}
	$g.ResetTransform(); $g.Dispose(); return $bmp
}
foreach ($spec in @(@('gemini-star', 'Draw-Gemini'), @('chatgpt-knot', 'Draw-Knot'))) {
	for ($i = 0; $i -lt 8; $i++) {
		foreach ($mode in 'walk', 'idle') {
			$bmp = & $spec[1] $mode $i
			$name = if ($mode -eq 'walk') { '{0}@{1}.png' -f $spec[0], ($i + 1) } else { '{0}@idle{1}.png' -f $spec[0], ($i + 1) }
			$bmp.Save((Join-Path $OutDir $name), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
		}
	}
}
'done'
