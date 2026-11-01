param([string]$OutDir = (Join-Path ([Environment]::GetFolderPath('MyPictures')) '截圖'))
# 截圖：整個畫面凍住、拖曳框選一塊，放開就存成圖片（預設在「圖片\截圖」）並複製到剪貼簿，直接貼上就能用。
# 只點一下不拖＝整個畫面；Esc 或右鍵＝取消。（獨立的小程式，浮窗按截圖時才叫它；這支是「高 DPI 感知」的，所以截出來是實際解析度、不會糊。）
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class DpiX { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[void][DpiX]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
Start-Sleep -Milliseconds 400 # 等浮窗和選單先收起來，才不會被拍進去
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$shot = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
$g0 = [System.Drawing.Graphics]::FromImage($shot); $g0.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size); $g0.Dispose()
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.Bounds = $vs; $form.TopMost = $true; $form.ShowInTaskbar = $false; $form.Cursor = [System.Windows.Forms.Cursors]::Cross
$form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
$script:a = $null; $script:b = $null; $script:save = $false
function Sel-Rect {
	if (-not $script:a -or -not $script:b) { return [System.Drawing.Rectangle]::Empty }
	$x = [Math]::Min($script:a.X, $script:b.X); $y = [Math]::Min($script:a.Y, $script:b.Y)
	return New-Object System.Drawing.Rectangle($x, $y, [Math]::Abs($script:a.X - $script:b.X), [Math]::Abs($script:a.Y - $script:b.Y))
}
$form.Add_Paint({
	param($s, $e)
	$g = $e.Graphics
	$g.DrawImage($shot, 0, 0)
	$dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
	$r = Sel-Rect
	if ($r.Width -gt 2 -and $r.Height -gt 2) {
		$g.SetClip($r, [System.Drawing.Drawing2D.CombineMode]::Exclude); $g.FillRectangle($dim, 0, 0, $form.Width, $form.Height); $g.ResetClip()
		$g.DrawRectangle((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)), $r)
		$lab = '{0} × {1}' -f $r.Width, $r.Height
		$g.DrawString($lab, $form.Font, [System.Drawing.Brushes]::White, $r.X + 4, [Math]::Max(2, $r.Y - 20))
	} else { $g.FillRectangle($dim, 0, 0, $form.Width, $form.Height); $g.DrawString('拖曳框選要截的範圍（只點一下＝整個畫面，Esc 取消）', $form.Font, [System.Drawing.Brushes]::White, 24, 24) }
})
$form.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:a = $e.Location; $script:b = $e.Location } else { $form.Close() } })
$form.Add_MouseMove({ param($s, $e) if ($script:a -and $e.Button -eq 'Left') { $script:b = $e.Location; $form.Invalidate() } })
$form.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left' -and $script:a) { $script:b = $e.Location; $script:save = $true; $form.Close() } })
$form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $script:save = $false; $form.Close() } })
[void]$form.ShowDialog()
if ($script:save) {
	$r = Sel-Rect
	if ($r.Width -lt 6 -or $r.Height -lt 6) { $r = New-Object System.Drawing.Rectangle(0, 0, $shot.Width, $shot.Height) } # 只點一下＝整個畫面
	$crop = $shot.Clone($r, $shot.PixelFormat)
	New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
	$file = Join-Path $OutDir ('截圖_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png')
	$crop.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
	try { [System.Windows.Forms.Clipboard]::SetImage($crop) } catch { }
	$t = New-Object System.Windows.Forms.Form
	$t.FormBorderStyle = 'None'; $t.StartPosition = 'CenterScreen'; $t.TopMost = $true; $t.ShowInTaskbar = $false; $t.BackColor = [System.Drawing.Color]::FromArgb(31, 58, 95); $t.Size = New-Object System.Drawing.Size(520, 64); $t.Opacity = 0.95
	$l = New-Object System.Windows.Forms.Label; $l.Dock = 'Fill'; $l.ForeColor = [System.Drawing.Color]::White; $l.TextAlign = 'MiddleCenter'; $l.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 11, [System.Drawing.FontStyle]::Bold)
	$l.Text = "已截圖並複製到剪貼簿（直接貼上就行）`n" + $file
	$t.Controls.Add($l)
	$tm = New-Object System.Windows.Forms.Timer; $tm.Interval = 2200; $tm.Add_Tick({ $tm.Stop(); $t.Close() }); $tm.Start()
	[void]$t.ShowDialog()
}
