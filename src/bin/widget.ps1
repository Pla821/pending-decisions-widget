# widget.ps1 — 「待決定」浮窗：螢幕上一個小圖示（右上角有紅色數字），Claude 在等你時圖會抖一下、冒出對話框；
# 點圖展開清單，雙擊一列＝打開那個對話。右鍵：設定（換圖／改說的話）、網頁清單、結束。
# 資料來源：data\pending.json（decision-scan.mjs 每 6 秒掃所有對話寫的）。Windows PowerShell 5.1＋Node.js。
# 啟動：powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File widget.ps1
# ⚠ 這個檔必須存成 UTF-8 with BOM，PowerShell 5.1 才不會把中文讀成亂碼。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class PopForm : Form {
	public bool NoActivate = false;
	public bool Shadow = true;
	[DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
	protected override bool ShowWithoutActivation { get { return NoActivate; } }
	protected override CreateParams CreateParams {
		get {
			CreateParams p = base.CreateParams;
			p.ExStyle |= 0x00000080;                 // 不出現在 Alt+Tab
			if (NoActivate) p.ExStyle |= 0x08000000; // 點它不搶走目前視窗的焦點
			if (Shadow) p.ClassStyle |= 0x00020000;  // 陰影
			return p;
		}
	}
	// Windows 11：請系統畫圓角（有抗鋸齒）；失敗（Windows 10）回傳 false，由呼叫端改用 Region
	public bool RoundCorners() { int v = 2; try { return DwmSetWindowAttribute(this.Handle, 33, ref v, 4) == 0; } catch { return false; } }
}

public class RowItem { public string Title; public string Label; public string Sub; public string Meta; public string Tag; public Color LabelColor; }

public class RowList : Control {
	public List<RowItem> Items = new List<RowItem>();
	public int RowHeight = 62, Hover = -1, Scroll = 0;
	public Color Back, Fore, Muted, Line, HoverBack;
	public string EmptyTitle = "", EmptyText = "";
	public Font TitleFont, SubFont, BigFont;
	public int ActivatedIndex = -1;
	public event EventHandler RowActivated;
	ToolTip tip = new ToolTip();
	public RowList() {
		SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
	}
	int MaxScroll() { return Math.Max(0, Items.Count * RowHeight - Height); }
	int IndexAt(int y) { int i = (y + Scroll) / RowHeight; return (i >= 0 && i < Items.Count) ? i : -1; }
	protected override void OnPaint(PaintEventArgs e) {
		Graphics g = e.Graphics;
		g.Clear(Back);
		TextFormatFlags f = TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding;
		if (Items.Count == 0) {
			Rectangle r1 = new Rectangle(16, Height / 2 - 34, Width - 32, 36);
			Rectangle r2 = new Rectangle(16, Height / 2 + 2, Width - 32, 40);
			TextRenderer.DrawText(g, EmptyTitle, BigFont, r1, Fore, TextFormatFlags.HorizontalCenter | TextFormatFlags.Bottom | TextFormatFlags.NoPrefix);
			TextRenderer.DrawText(g, EmptyText, SubFont, r2, Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
			return;
		}
		for (int i = 0; i < Items.Count; i++) {
			int y = i * RowHeight - Scroll;
			if (y + RowHeight < 0 || y > Height) continue;
			RowItem it = Items[i];
			Rectangle row = new Rectangle(0, y, Width, RowHeight);
			if (i == Hover) { using (SolidBrush b = new SolidBrush(HoverBack)) g.FillRectangle(b, row); }
			using (SolidBrush b = new SolidBrush(it.LabelColor)) { g.FillRectangle(b, 0, y + 10, 4, RowHeight - 20); }
			int metaW = 64;
			TextRenderer.DrawText(g, it.Title, TitleFont, new Rectangle(18, y + 8, Width - 18 - metaW - 14, 24), Fore, f);
			TextRenderer.DrawText(g, it.Meta, SubFont, new Rectangle(Width - metaW - 12, y + 8, metaW, 24), Muted, TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
			Size ls = TextRenderer.MeasureText(it.Label, SubFont, new Size(200, 20), TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
			TextRenderer.DrawText(g, it.Label, SubFont, new Rectangle(18, y + 32, ls.Width + 2, 22), it.LabelColor, f);
			TextRenderer.DrawText(g, it.Sub, SubFont, new Rectangle(18 + ls.Width + 8, y + 32, Width - 18 - ls.Width - 8 - 14, 22), Muted, f);
			using (Pen p = new Pen(Line)) { g.DrawLine(p, 18, y + RowHeight - 1, Width - 1, y + RowHeight - 1); }
		}
	}
	protected override void OnMouseMove(MouseEventArgs e) {
		int i = IndexAt(e.Y);
		if (i != Hover) {
			Hover = i; Invalidate();
			Cursor = i >= 0 ? Cursors.Hand : Cursors.Default;
			tip.SetToolTip(this, i >= 0 ? Items[i].Tag : "");
		}
		base.OnMouseMove(e);
	}
	protected override void OnMouseLeave(EventArgs e) { Hover = -1; Invalidate(); base.OnMouseLeave(e); }
	protected override void OnMouseWheel(MouseEventArgs e) {
		Scroll = Math.Max(0, Math.Min(MaxScroll(), Scroll - Math.Sign(e.Delta) * RowHeight / 2)); Invalidate(); base.OnMouseWheel(e);
	}
	protected override void OnDoubleClick(EventArgs e) {
		Point p = PointToClient(Cursor.Position);
		int i = IndexAt(p.Y);
		if (i >= 0) { ActivatedIndex = i; if (RowActivated != null) RowActivated(this, EventArgs.Empty); }
		base.OnDoubleClick(e);
	}
}
"@
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- 路徑與設定（沒有寫死任何使用者資料夾）----------
$Root = if ($env:PDW_HOME) { $env:PDW_HOME } else { Split-Path -Parent $PSScriptRoot }
$Config = $null
try { $cf = Join-Path $Root 'config.json'; if (Test-Path $cf) { $Config = Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
$DataDir = if ($env:PDW_DATA) { $env:PDW_DATA } elseif ($Config -and $Config.dataDir) { [string]$Config.dataDir } else { Join-Path $Root 'data' }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$UserIconDir = Join-Path $DataDir 'icons'
New-Item -ItemType Directory -Force -Path $UserIconDir | Out-Null
$BuiltinIconDir = Join-Path $Root 'icons'
$StateFile = Join-Path $DataDir 'pending.json'
$StatusFile = Join-Path $DataDir 'status.json'
$HtmlFile = Join-Path $DataDir 'pending.html'
$SetFile = Join-Path $DataDir 'settings.json'
$ScanJs = Join-Path $PSScriptRoot 'decision-scan.mjs'
$StartupDir = if ($env:PDW_STARTUP_DIR) { $env:PDW_STARTUP_DIR } else { [Environment]::GetFolderPath('Startup') }
$LnkPath = Join-Path $StartupDir 'PendingDecisionsWidget.lnk'

# 同一份安裝只留一個浮窗（不同資料夾的安裝互不影響）
$md5 = [System.Security.Cryptography.MD5]::Create()
$hash = ([System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Root.ToLower()))) -replace '-', '').Substring(0, 12)
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\PendingDecisionsWidget_$hash", [ref]$created)
if (-not $created) { exit }

$script:nodeOk = [bool](Get-Command node -ErrorAction SilentlyContinue)
$Snap = [bool]$env:PDW_SNAPSHOT # 截圖模式（給 README 用）：不顯示任何視窗，直接把畫面輸出成 PNG 後結束

# ---------- 色彩（深藍 #1F3A5F／紅 #D94A3A；跟著 Windows 的淺色／深色模式）----------
function RGB([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$dark = $false
$themePref = if ($env:PDW_THEME) { $env:PDW_THEME } elseif ($Config -and $Config.theme) { [string]$Config.theme } else { 'auto' }
try { $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop; $dark = ($v -eq 0) } catch { }
if ($themePref -eq 'dark') { $dark = $true } elseif ($themePref -eq 'light') { $dark = $false } # config.json 的 theme：auto（預設，跟著 Windows）／light／dark
$Navy = RGB '#1F3A5F'; $Red = RGB '#D94A3A'
if ($dark) {
	$T = @{ bg = RGB '#1E242B'; surface = RGB '#262E37'; fg = RGB '#E8ECF1'; muted = RGB '#98A2B0'; line = RGB '#2F3944'; hover = RGB '#2B343E'; header = RGB '#17304F'; footer = RGB '#181D23'; accent = RGB '#F08A7E'; amber = RGB '#E8B04B'; blue = RGB '#7FB0EE'; sel = RGB '#3A5A86' }
} else {
	$T = @{ bg = RGB '#FFFFFF'; surface = RGB '#F1F4F7'; fg = RGB '#16191F'; muted = RGB '#6B7280'; line = RGB '#E6E9EE'; hover = RGB '#F1F5FA'; header = $Navy; footer = RGB '#F6F8FA'; accent = $Red; amber = RGB '#C98512'; blue = RGB '#2F6DB5'; sel = RGB '#BFD6F2' }
}
$fam = 'Segoe UI'
try { if ((New-Object System.Drawing.Text.InstalledFontCollection).Families.Name -contains 'Microsoft JhengHei UI') { $fam = 'Microsoft JhengHei UI' } } catch { }
function Font([double]$size, [bool]$bold = $false) { New-Object System.Drawing.Font($fam, [single]$size, $(if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular })) }
$FontTitle = Font 10.5 $true; $FontSub = Font 9; $FontBig = Font 12 $true; $FontBtn = Font 9.5; $FontBubble = Font 11.5 $true

# ---------- 設定 ----------
$script:set = @{ icon = 'bell.png'; message = '有待決定囉！'; hideWhenZero = $false; sound = $true; x = $null; y = $null }
try { if (Test-Path $SetFile) { $j = Get-Content $SetFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @('icon', 'message', 'hideWhenZero', 'sound', 'x', 'y')) { if ($null -ne $j.$k) { $script:set[$k] = $j.$k } } } } catch { }
function Save-Settings { try { ($script:set | ConvertTo-Json) | Set-Content -Path $SetFile -Encoding UTF8 } catch { } }

function Load-Img([string]$path) { # 讀進記憶體再解碼，不鎖檔
	$bytes = [System.IO.File]::ReadAllBytes($path)
	return [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes)))
}
function Icon-Files { # 內建＋使用者自己的
	$all = @()
	foreach ($d in @($BuiltinIconDir, $UserIconDir)) { if (Test-Path $d) { $all += Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|gif|bmp|ico)$' } | Sort-Object Name } }
	return $all
}
function Find-Icon([string]$name) {
	foreach ($d in @($UserIconDir, $BuiltinIconDir)) { $p = Join-Path $d $name; if (Test-Path $p) { return $p } }
	$f = Icon-Files | Select-Object -First 1; if ($f) { return $f.FullName }
	return $null
}
function Import-Icon([string]$src) { # 匯入圖檔進 data/icons；不透明的照片會自動裁成置中的圓形頭像（直式照片偏上，因為臉通常在上半）；有透明背景的圖示原樣複製
	$base = [System.IO.Path]::GetFileNameWithoutExtension($src); $ext = [System.IO.Path]::GetExtension($src).ToLower()
	$stamp = ''; if (Test-Path (Join-Path $UserIconDir ($base + $ext))) { $stamp = '_' + (Get-Date -Format yyyyMMddHHmmss) }
	$img = Load-Img $src
	$bm = New-Object System.Drawing.Bitmap($img)
	if ($bm.GetPixel(0, 0).A -lt 250) { $dest = Join-Path $UserIconDir ($base + $stamp + $ext); Copy-Item $src $dest; return [System.IO.Path]::GetFileName($dest) }
	$dest = Join-Path $UserIconDir ($base + $stamp + '.png')
	$side = [Math]::Min($img.Width, $img.Height)
	$sx = [int](($img.Width - $side) / 2); $sy = if ($img.Height -gt $img.Width) { [int](($img.Height - $side) * 0.25) } else { 0 }
	$o = 256
	$out = New-Object System.Drawing.Bitmap($o, $o, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($out); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.Clear([System.Drawing.Color]::Transparent)
	$gp = New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddEllipse(6, 6, ($o - 12), ($o - 12)); $g.SetClip($gp)
	$g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $o, $o)), $sx, $sy, $side, $side, [System.Drawing.GraphicsUnit]::Pixel)
	$g.ResetClip(); $g.DrawEllipse((New-Object System.Drawing.Pen($Navy, 8)), 6, 6, ($o - 12), ($o - 12))
	$g.Dispose(); $out.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose(); $bm.Dispose(); $img.Dispose()
	return [System.IO.Path]::GetFileName($dest)
}
function Rounded-Path([int]$w, [int]$h, [int]$r) {
	$gp = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = $r * 2
	$gp.AddArc(0, 0, $d, $d, 180, 90); $gp.AddArc($w - $d, 0, $d, $d, 270, 90); $gp.AddArc($w - $d, $h - $d, $d, $d, 0, 90); $gp.AddArc(0, $h - $d, $d, $d, 90, 90); $gp.CloseFigure()
	return $gp
}
function Round-Form($f, [int]$r) { if (-not $f.RoundCorners()) { $f.Region = New-Object System.Drawing.Region (Rounded-Path $f.Width $f.Height $r) } }
function Alpha-Region([System.Drawing.Bitmap]$bmp) { # 只留圖不透明的地方（圖外面是透明的）
	$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
	for ($y = 0; $y -lt $bmp.Height; $y++) {
		$x = 0
		while ($x -lt $bmp.Width) {
			if ($bmp.GetPixel($x, $y).A -gt 110) { $s = $x; while ($x -lt $bmp.Width -and $bmp.GetPixel($x, $y).A -gt 110) { $x++ }; $gp.AddRectangle((New-Object System.Drawing.Rectangle($s, $y, ($x - $s), 1))) } else { $x++ }
		}
	}
	return New-Object System.Drawing.Region($gp)
}
function Flat-Button([string]$text, [int]$w, [int]$h, [bool]$primary) {
	$b = New-Object System.Windows.Forms.Button
	$b.Text = $text; $b.Size = New-Object System.Drawing.Size($w, $h); $b.FlatStyle = 'Flat'; $b.Font = $FontBtn; $b.Cursor = 'Hand'; $b.UseVisualStyleBackColor = $false
	if ($primary) { $b.BackColor = $Navy; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderSize = 0; if ($dark) { $b.BackColor = RGB '#2E5A93' } }
	else { $b.BackColor = $T.surface; $b.ForeColor = $T.fg; $b.FlatAppearance.BorderColor = $T.line; $b.FlatAppearance.BorderSize = 1 }
	return $b
}

# ---------- 圖示視窗（右上角紅色數字）----------
$IconBox = 92
$iconForm = New-Object PopForm
$iconForm.NoActivate = $true; $iconForm.Shadow = $false
$iconForm.FormBorderStyle = 'None'; $iconForm.TopMost = $true; $iconForm.ShowInTaskbar = $false; $iconForm.StartPosition = 'Manual'; $iconForm.BackColor = [System.Drawing.Color]::White
$iconForm.Size = New-Object System.Drawing.Size($IconBox, $IconBox)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$px = if ($null -ne $script:set.x) { [int]$script:set.x } else { $wa.Right - $IconBox - 24 }
$py = if ($null -ne $script:set.y) { [int]$script:set.y } else { $wa.Bottom - $IconBox - 60 }
$iconForm.Location = New-Object System.Drawing.Point($px, $py)
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = 'Fill'; $pic.SizeMode = 'Normal'; $pic.BackColor = [System.Drawing.Color]::White; $pic.Cursor = 'Hand'
$iconForm.Controls.Add($pic)
$script:baseImg = $null; $script:badgeShown = -1

function Compose-Icon([int]$count) { # 圖＋右上角紅色數字
	if (-not $script:baseImg) { return }
	$bmp = New-Object System.Drawing.Bitmap($IconBox, $IconBox, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
	$g.Clear([System.Drawing.Color]::Transparent)
	$size = 74; $img = $script:baseImg
	$ratio = [Math]::Min($size / $img.Width, $size / $img.Height); $w = [int]($img.Width * $ratio); $h = [int]($img.Height * $ratio)
	$g.DrawImage($img, 2 + [int](($size - $w) / 2), $IconBox - $size - 2 + [int](($size - $h) / 2), $w, $h)
	if ($count -gt 0) {
		$d = 34; $bx = $IconBox - $d - 1; $by = 1
		$g.FillEllipse([System.Drawing.Brushes]::White, ($bx - 2), ($by - 2), ($d + 4), ($d + 4))
		$g.FillEllipse((New-Object System.Drawing.SolidBrush($Red)), $bx, $by, $d, $d)
		$txt = if ($count -gt 9) { '9+' } else { [string]$count }
		$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
		$g.DrawString($txt, (Font 13 $true), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($bx, ($by + 1), $d, $d)), $sf)
	}
	$g.Dispose()
	$old = $pic.Image; $pic.Image = $bmp; if ($old) { $old.Dispose() }
	$rg = Alpha-Region $bmp
	$iconForm.Region = $rg
	$script:badgeShown = $count
}
function Apply-Icon {
	$p = Find-Icon ([string]$script:set.icon)
	if (-not $p) { return }
	try { if ($script:baseImg) { $script:baseImg.Dispose() }; $script:baseImg = Load-Img $p } catch { return }
	Compose-Icon ([Math]::Max(0, $script:badgeShown))
}

# ---------- 對話框（冒泡）----------
$bubble = New-Object PopForm
$bubble.NoActivate = $true
$bubble.FormBorderStyle = 'None'; $bubble.TopMost = $true; $bubble.ShowInTaskbar = $false; $bubble.StartPosition = 'Manual'; $bubble.BackColor = $Red
$bl = New-Object System.Windows.Forms.Label
$bl.ForeColor = [System.Drawing.Color]::White; $bl.Font = $FontBubble; $bl.TextAlign = 'MiddleCenter'; $bl.Dock = 'Fill'; $bl.Cursor = 'Hand'
$bubble.Controls.Add($bl)
function Set-Bubble([string]$text) {
	$sz = [System.Windows.Forms.TextRenderer]::MeasureText($text, $FontBubble, (New-Object System.Drawing.Size(300, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
	$bl.Text = $text
	$bubble.Size = New-Object System.Drawing.Size(($sz.Width + 40), ($sz.Height + 26))
	Round-Form $bubble 16
}

# ---------- 清單視窗 ----------
$PW = 440; $HeaderH = 50; $FooterH = 48
$panel = New-Object PopForm
$panel.FormBorderStyle = 'None'; $panel.TopMost = $true; $panel.ShowInTaskbar = $false; $panel.StartPosition = 'Manual'; $panel.BackColor = $T.bg
$head = New-Object System.Windows.Forms.Panel
$head.Dock = 'Top'; $head.Height = $HeaderH; $head.BackColor = $T.header
$script:headCount = 0
$head.Add_Paint({
	param($s, $e)
	$g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
	[System.Windows.Forms.TextRenderer]::DrawText($g, '待決定', $FontBig, (New-Object System.Drawing.Rectangle(18, 0, 200, $HeaderH)), [System.Drawing.Color]::White, [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
	$label = if ($script:headCount -gt 0) { "$($script:headCount) 件在等你" } else { '全部回完了' }
	$sz = [System.Windows.Forms.TextRenderer]::MeasureText($label, $FontSub)
	$w = $sz.Width + 22; $x = $s.Width - $w - 16; $y = ($HeaderH - 26) / 2
	$col = if ($script:headCount -gt 0) { $Red } else { RGB '#2F7D4F' }
	$gp = Rounded-Path $w 26 13; $m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate($x, $y); $gp.Transform($m)
	$g.FillPath((New-Object System.Drawing.SolidBrush($col)), $gp)
	[System.Windows.Forms.TextRenderer]::DrawText($g, $label, $FontSub, (New-Object System.Drawing.Rectangle([int]$x, [int]$y, $w, 26)), [System.Drawing.Color]::White, [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
})
$list = New-Object RowList
$list.Dock = 'Fill'; $list.Back = $T.bg; $list.Fore = $T.fg; $list.Muted = $T.muted; $list.Line = $T.line; $list.HoverBack = $T.hover
$list.TitleFont = $FontTitle; $list.SubFont = $FontSub; $list.BigFont = $FontBig
$foot = New-Object System.Windows.Forms.Panel
$foot.Dock = 'Bottom'; $foot.Height = $FooterH; $foot.BackColor = $T.footer
$btnWeb = Flat-Button '網頁清單' 92 30 $false; $btnWeb.Location = New-Object System.Drawing.Point(12, 9)
$btnSet = Flat-Button '設定' 70 30 $false; $btnSet.Location = New-Object System.Drawing.Point(112, 9)
$btnHide = Flat-Button '收起來' 84 30 $true; $btnHide.Location = New-Object System.Drawing.Point(($PW - 84 - 12), 9)
$hint = New-Object System.Windows.Forms.Label
$hint.Text = '雙擊一列＝打開那個對話'; $hint.AutoSize = $true; $hint.ForeColor = $T.muted; $hint.Font = $FontSub; $hint.Location = New-Object System.Drawing.Point(196, 16)
$foot.Controls.AddRange(@($btnWeb, $btnSet, $hint, $btnHide))
$panel.Controls.Add($list); $panel.Controls.Add($foot); $panel.Controls.Add($head)

$script:items = @(); $script:lastCount = 0; $script:status = $null

function Place-Around {
	$wa2 = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	foreach ($f in @($bubble, $panel)) {
		$x = [Math]::Min([Math]::Max($wa2.Left, $iconForm.Right - $f.Width), $wa2.Right - $f.Width)
		$y = $iconForm.Top - $f.Height - 8
		if ($y -lt $wa2.Top) { $y = $iconForm.Bottom + 8 }
		$f.Location = New-Object System.Drawing.Point($x, $y)
	}
}
function Show-Panel {
	$rows = [Math]::Max(0, [Math]::Min(7, $script:items.Count))
	$body = if ($rows -eq 0) { 120 } else { $list.RowHeight * $rows }
	$panel.Size = New-Object System.Drawing.Size($PW, ($HeaderH + $body + $FooterH))
	if (-not $panel.IsHandleCreated) { [void]$panel.Handle; Round-Form $panel 14 } else { Round-Form $panel 14 }
	Place-Around
	$bubble.Hide()
	if (-not $Snap -and -not $panel.Visible) { $panel.Show() }
	$head.Invalidate()
}
function Update-Look {
	$n = $script:items.Count
	if ($n -gt 0) {
		$msg = [string]$script:set.message
		Set-Bubble ("{0}  ·  {1} 件" -f $msg, $n)
		$iconForm.Opacity = 1
		if (-not $panel.Visible) { Place-Around; if (-not $Snap -and -not $bubble.Visible) { $bubble.Show() } }
	} else {
		$bubble.Hide(); $iconForm.Opacity = 0.6
		if ($panel.Visible) { $panel.Hide() }
	}
	if ($n -ne $script:badgeShown) { Compose-Icon $n }
	if ($Snap) { return }
	if ($n -eq 0 -and $script:set.hideWhenZero) { if ($iconForm.Visible) { $iconForm.Hide() } } else { if (-not $iconForm.Visible) { $iconForm.Show() } }
}
function Empty-Messages { # 空狀態與錯誤的文案
	if (-not $script:nodeOk) { return @('找不到 Node.js', '浮窗需要 Node.js 來掃描對話紀錄。請安裝（https://nodejs.org）後重新開啟浮窗。') }
	if ($script:status -and $script:status.ok -eq $false -and $script:status.error -eq 'no-projects') { return @('找不到對話紀錄資料夾', "預期在：$($script:status.projects)`n如果你的 Claude 資料放在別處，請在 config.json 設定 claudeDir。") }
	if (-not $script:status) { return @('正在掃描…', '第一次掃描需要幾秒鐘。') }
	return @('✓ 都回完了', '現在沒有任何對話在等你回答。')
}
function Refresh-Data {
	$items = @()
	try { if (Test-Path $StateFile) { $j = (Get-Content $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json; $items = @($j.items | Where-Object { $_.status -eq 'pending' } | Sort-Object { [double]$_.at } -Descending) } } catch { }
	try { if (Test-Path $StatusFile) { $script:status = (Get-Content $StatusFile -Raw -Encoding UTF8) | ConvertFrom-Json } } catch { }
	$script:items = $items
	$n = $items.Count
	$script:headCount = $n; $head.Invalidate()
	$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$rows = New-Object 'System.Collections.Generic.List[RowItem]'
	foreach ($it in $items) {
		$sid8 = if ($it.sid) { ([string]$it.sid).Substring(0, [Math]::Min(8, ([string]$it.sid).Length)) } else { '' }
		$title = if ($it.title) { [string]$it.title } elseif ($it.cwd) { (Split-Path ([string]$it.cwd).TrimEnd('\', '/') -Leaf) + "（$sid8）" } else { "對話 $sid8" }
		$q = if ($it.kind -eq 'permission') { (([string]$it.tool) + ' ' + ([string]$it.detail)).Trim() } elseif ($it.questions -and $it.questions.Count -gt 0) { [string]$it.questions[0].question } else { '' }
		$label = '選項框'; $col = $T.accent
		if ($it.kind -eq 'permission') { $label = '要你允許'; $col = $T.amber } elseif ($it.kind -eq 'wrapup') { $label = '要你決定'; $col = $T.blue }
		$mins = [Math]::Max(1, [int](($now - [double]$it.at) / 60000))
		$wait = if ($mins -ge 1440) { '{0} 天' -f [Math]::Round($mins / 1440, 1) } elseif ($mins -ge 60) { '{0} 小時' -f [Math]::Round($mins / 60, 1) } else { "$mins 分" }
		$r = New-Object RowItem
		$r.Title = $title; $r.Label = $label; $r.LabelColor = $col; $r.Sub = $q; $r.Meta = $wait; $r.Tag = [string]$it.local
		$r.Tag = ("{0}`n{1}" -f $title, $q)
		[void]$rows.Add($r)
	}
	$list.Items = $rows
	$em = Empty-Messages; $list.EmptyTitle = $em[0]; $list.EmptyText = $em[1]
	$list.Invalidate()
	if ($n -gt $script:lastCount) { # 有新的：叮一聲＋圖抖一下
		if ($script:set.sound) { try { [System.Media.SystemSounds]::Exclamation.Play() } catch { } }
		$script:shakeStep = 0; $script:shakeX = $iconForm.Left; $shake.Start()
	}
	$script:lastCount = $n
	Update-Look
	if ($panel.Visible) { Show-Panel }
}

# 抖動
$shake = New-Object System.Windows.Forms.Timer
$shake.Interval = 35
$offs = @(-10, 10, -9, 9, -7, 7, -5, 5, -3, 3, 0)
$shake.Add_Tick({
	if ($script:shakeStep -ge $offs.Count) { $shake.Stop(); $iconForm.Left = $script:shakeX; Place-Around; return }
	$iconForm.Left = $script:shakeX + $offs[$script:shakeStep]; $script:shakeStep++
})

# 點圖＝展開／收起清單；按住拖＝搬位置
$script:down = $null; $script:moved = $false
$pic.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:down = [System.Windows.Forms.Cursor]::Position; $script:moved = $false; $script:startLoc = $iconForm.Location } })
$pic.Add_MouseMove({ param($s, $e)
	if ($script:down -and ($e.Button -eq 'Left')) {
		$p = [System.Windows.Forms.Cursor]::Position
		$dx = $p.X - $script:down.X; $dy = $p.Y - $script:down.Y
		if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 5) { $script:moved = $true }
		if ($script:moved) { $iconForm.Location = New-Object System.Drawing.Point(($script:startLoc.X + $dx), ($script:startLoc.Y + $dy)); Place-Around }
	}
})
$pic.Add_MouseUp({ param($s, $e)
	if ($e.Button -ne 'Left') { return }
	if ($script:moved) { $script:set.x = $iconForm.Left; $script:set.y = $iconForm.Top; Save-Settings }
	else { if ($panel.Visible) { $panel.Hide(); Update-Look } else { Show-Panel } }
	$script:down = $null
})
$bl.Add_Click({ Show-Panel })
$btnHide.Add_Click({ $panel.Hide(); Update-Look })
$btnWeb.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
$list.Add_RowActivated({
	$it = $script:items[$list.ActivatedIndex]
	if ($it -and $it.local) { Start-Process ("claude://claude.ai/epitaxy/" + [string]$it.local) } elseif (Test-Path $HtmlFile) { Start-Process $HtmlFile } # CLI 使用者沒有桌面版連結：改開網頁清單
})

# ---------- 開機自動啟動 ----------
function Autostart-On { Test-Path $LnkPath }
function Set-Autostart([bool]$on) {
	try {
		if ($on) {
			$ws = New-Object -ComObject WScript.Shell
			$lnk = $ws.CreateShortcut($LnkPath)
			$lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
			$lnk.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
			$lnk.WindowStyle = 7; $lnk.Description = 'Pending Decisions Widget'; $lnk.Save()
		} elseif (Test-Path $LnkPath) { Remove-Item $LnkPath -Force }
	} catch { }
}

# ---------- 設定視窗 ----------
function Show-Settings([switch]$Snapshot) {
	$dlg = if ($Snapshot) { New-Object PopForm } else { New-Object System.Windows.Forms.Form }
	$dlg.Text = '待決定浮窗 — 設定'; $dlg.StartPosition = 'CenterScreen'; $dlg.TopMost = $true
	$dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
	$dlg.ClientSize = New-Object System.Drawing.Size(560, 548); $dlg.Font = $FontBtn; $dlg.BackColor = $T.bg; $dlg.ForeColor = $T.fg
	$hd = New-Object System.Windows.Forms.Label
	$hd.Text = '  待決定浮窗 · 設定'; $hd.Dock = 'Top'; $hd.Height = 48; $hd.BackColor = $T.header; $hd.ForeColor = [System.Drawing.Color]::White; $hd.Font = $FontBig; $hd.TextAlign = 'MiddleLeft'
	$l1 = New-Object System.Windows.Forms.Label; $l1.Text = '浮窗圖示（點一下選）'; $l1.Font = $FontTitle; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(20, 64)
	$l1b = New-Object System.Windows.Forms.Label; $l1b.Text = '也可以直接把圖檔拖到桌面上的浮窗'; $l1b.ForeColor = $T.muted; $l1b.Font = $FontSub; $l1b.AutoSize = $true; $l1b.Location = New-Object System.Drawing.Point(180, 68)
	$fp = New-Object System.Windows.Forms.FlowLayoutPanel
	$fp.Location = New-Object System.Drawing.Point(20, 92); $fp.Size = New-Object System.Drawing.Size(520, 204); $fp.AutoScroll = $true; $fp.BackColor = $T.surface; $fp.Padding = New-Object System.Windows.Forms.Padding(6)
	$script:pick = [string]$script:set.icon
	function Fill-Thumbs {
		$fp.Controls.Clear()
		foreach ($f in (Icon-Files)) {
			$pb = New-Object System.Windows.Forms.PictureBox
			$pb.Size = New-Object System.Drawing.Size(84, 84); $pb.SizeMode = 'Zoom'; $pb.Margin = New-Object System.Windows.Forms.Padding(6); $pb.Padding = New-Object System.Windows.Forms.Padding(8); $pb.Cursor = 'Hand'; $pb.Tag = $f.Name; $pb.BackColor = $T.bg
			try { $pb.Image = Load-Img $f.FullName } catch { }
			$pb.Add_Paint({ param($s, $e) if ($s.Tag -eq $script:pick) { $pen = New-Object System.Drawing.Pen($T.sel, 4); $e.Graphics.DrawRectangle($pen, 2, 2, ($s.Width - 5), ($s.Height - 5)); $pen2 = New-Object System.Drawing.Pen($Navy, 2); if ($dark) { $pen2.Color = RGB '#8DB4E8' }; $e.Graphics.DrawRectangle($pen2, 1, 1, ($s.Width - 3), ($s.Height - 3)) } })
			$pb.Add_Click({ param($s, $e) $script:pick = [string]$s.Tag; foreach ($c in $fp.Controls) { $c.Invalidate() } })
			$fp.Controls.Add($pb)
		}
	}
	Fill-Thumbs
	$btnImg = Flat-Button '從電腦選圖片…（複製一份進來，不動原檔）' 330 32 $false; $btnImg.Location = New-Object System.Drawing.Point(20, 306)
	$btnImg.Add_Click({
		$ofd = New-Object System.Windows.Forms.OpenFileDialog
		$ofd.Filter = '圖片 (*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.ico)|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.ico'; $ofd.Title = '選一張圖'
		if ($ofd.ShowDialog() -eq 'OK') {
			$script:pick = Import-Icon $ofd.FileName; Fill-Thumbs
		}
	})
	$l2 = New-Object System.Windows.Forms.Label; $l2.Text = '有待決定時，圖旁邊要說的話'; $l2.Font = $FontTitle; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(20, 356)
	$tb = New-Object System.Windows.Forms.TextBox; $tb.Text = [string]$script:set.message; $tb.MaxLength = 40; $tb.Size = New-Object System.Drawing.Size(520, 28); $tb.Location = New-Object System.Drawing.Point(20, 382); $tb.Font = $FontBtn; $tb.BackColor = $T.surface; $tb.ForeColor = $T.fg; $tb.BorderStyle = 'FixedSingle'
	$cb1 = New-Object System.Windows.Forms.CheckBox; $cb1.Text = '沒有待決定時，把圖藏起來（有了才跳出來）'; $cb1.AutoSize = $true; $cb1.Checked = [bool]$script:set.hideWhenZero; $cb1.Location = New-Object System.Drawing.Point(20, 424)
	$cb2 = New-Object System.Windows.Forms.CheckBox; $cb2.Text = '有新的待決定時發出提示音'; $cb2.AutoSize = $true; $cb2.Checked = [bool]$script:set.sound; $cb2.Location = New-Object System.Drawing.Point(20, 450)
	$cb3 = New-Object System.Windows.Forms.CheckBox; $cb3.Text = '開機時自動啟動浮窗'; $cb3.AutoSize = $true; $cb3.Checked = (Autostart-On); $cb3.Location = New-Object System.Drawing.Point(20, 476)
	$ok = Flat-Button '儲存' 96 34 $true; $ok.Location = New-Object System.Drawing.Point(334, 496); $ok.DialogResult = 'OK'
	$cancel = Flat-Button '取消' 96 34 $false; $cancel.Location = New-Object System.Drawing.Point(444, 496); $cancel.DialogResult = 'Cancel'
	$dlg.Controls.AddRange(@($hd, $l1, $l1b, $fp, $btnImg, $l2, $tb, $cb1, $cb2, $cb3, $ok, $cancel)); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
	if ($Snapshot) { $dlg.FormBorderStyle = 'None'; $dlg.TopMost = $false; $b = Snap-Ctl $dlg; $dlg.Close(); return $b }
	if ($dlg.ShowDialog() -eq 'OK') {
		$script:set.icon = $script:pick
		$script:set.message = if ($tb.Text.Trim()) { $tb.Text.Trim() } else { '有待決定囉！' }
		$script:set.hideWhenZero = $cb1.Checked; $script:set.sound = $cb2.Checked
		if ($cb3.Checked -ne (Autostart-On)) { Set-Autostart $cb3.Checked }
		Save-Settings; Apply-Icon; Update-Look
	}
}
$btnSet.Add_Click({ Show-Settings })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = $FontBtn
$m1 = $menu.Items.Add('設定…（換圖／改說的話）'); $m1.Add_Click({ Show-Settings })
$m2 = $menu.Items.Add('開網頁清單'); $m2.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
$m3 = $menu.Items.Add('開啟資料夾'); $m3.Add_Click({ Start-Process $DataDir })
[void]$menu.Items.Add('-')
$m4 = $menu.Items.Add('結束浮窗'); $m4.Add_Click({ $iconForm.Close() })
$pic.ContextMenuStrip = $menu

# 把圖檔直接拖到浮窗上＝換成那張圖（複製一份進 data\icons，不動原檔）
$iconForm.AllowDrop = $true; $pic.AllowDrop = $true
$onEnter = { param($s, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } else { $e.Effect = 'None' } }
$onDrop = { param($s, $e)
	foreach ($f in $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)) {
		if ([System.IO.Path]::GetExtension($f) -match '^\.(png|jpg|jpeg|gif|bmp|ico)$') {
			$script:set.icon = Import-Icon $f; Save-Settings; Apply-Icon
			break
		}
	}
}
$iconForm.Add_DragEnter($onEnter); $pic.Add_DragEnter($onEnter); $iconForm.Add_DragDrop($onDrop); $pic.Add_DragDrop($onDrop)

# ---------- 啟動：每 3 秒讀狀態、每 6 秒叫 node 掃一次所有對話 ----------
$script:scanProc = $null
function Run-Scan {
	if (-not $script:nodeOk) { return }
	if ($script:scanProc -and -not $script:scanProc.HasExited) { return } # 上一次還沒掃完
	try {
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		$psi.FileName = 'node'; $psi.Arguments = '"' + $ScanJs + '"'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
		$script:scanProc = [System.Diagnostics.Process]::Start($psi)
	} catch { }
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$script:tick = 0
$timer.Add_Tick({ $script:tick++; if ($script:tick % 2 -eq 0) { Run-Scan }; Refresh-Data })

# ---------- 截圖模式：把真正的視窗畫到圖上（不會在螢幕上跳出任何東西）----------
function Snap-Ctl($c) { # 沒顯示的視窗畫不出子控制項：先放到螢幕外（-20000）、不搶焦點地 Show，畫完再藏起來
	$c.NoActivate = $true; $c.StartPosition = 'Manual'; $c.Location = New-Object System.Drawing.Point(-20000, -20000)
	$c.Show(); [System.Windows.Forms.Application]::DoEvents()
	$b = New-Object System.Drawing.Bitmap($c.Width, $c.Height); $c.DrawToBitmap($b, (New-Object System.Drawing.Rectangle(0, 0, $c.Width, $c.Height))); $c.Hide(); return $b
}
function Draw-Popup($g, $bmp, [int]$x, [int]$y, [int]$r) { # 陰影＋圓角
	for ($i = 12; $i -ge 1; $i--) {
		$p = Rounded-Path ($bmp.Width + 2 * $i) ($bmp.Height + 2 * $i) ($r + $i); $m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate(($x - $i), ($y - $i + 5)); $p.Transform($m)
		$g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(7, 10, 20, 40))), $p)
	}
	$gp = Rounded-Path $bmp.Width $bmp.Height $r; $m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate($x, $y); $gp.Transform($m)
	$g.SetClip($gp); $g.DrawImage($bmp, $x, $y); $g.ResetClip()
}
function Take-Snapshots {
	$bgA = if ($dark) { RGB '#2B3544' } else { RGB '#EAEFF7' }; $bgB = if ($dark) { RGB '#1A2029' } else { RGB '#CCD8EA' }
	foreach ($scene in @('bubble', 'panel')) {
		if ($scene -eq 'bubble' -and $script:items.Count -eq 0) { continue }
		$W = 720; $H = if ($scene -eq 'panel') { 80 + 50 + 48 + [Math]::Max(120, 62 * [Math]::Min(7, $script:items.Count)) + $IconBox } else { 250 }
		$canvas = New-Object System.Drawing.Bitmap($W, $H); $g = [System.Drawing.Graphics]::FromImage($canvas); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
		$g.FillRectangle((New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(0, 0, $W, $H)), $bgA, $bgB, 55)), 0, 0, $W, $H)
		$ix = $W - $IconBox - 30; $iy = $H - $IconBox - 28
		if ($pic.Image) { $g.DrawImage($pic.Image, $ix, $iy) }
		if ($scene -eq 'panel') { Show-Panel; $pb = Snap-Ctl $panel; Draw-Popup $g $pb ($ix + $IconBox - $PW) ($iy - $panel.Height - 10) 9 }
		else { $bb = Snap-Ctl $bubble; Draw-Popup $g $bb ($ix + $IconBox - $bb.Width) ($iy - $bb.Height - 12) 9 }
		$g.Dispose(); $canvas.Save((Join-Path $env:PDW_SNAPSHOT ($env:PDW_SNAPSHOT_PREFIX + $scene + '.png')))
	}
	$sb = @(Show-Settings -Snapshot)[-1] # 設定視窗
	if ($script:items.Count -gt 0) {
		$W = $sb.Width + 80; $H = $sb.Height + 80
		$canvas = New-Object System.Drawing.Bitmap($W, $H); $g = [System.Drawing.Graphics]::FromImage($canvas); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
		$g.FillRectangle((New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(0, 0, $W, $H)), $bgA, $bgB, 55)), 0, 0, $W, $H)
		Draw-Popup $g $sb 40 38 10; $g.Dispose(); $canvas.Save((Join-Path $env:PDW_SNAPSHOT ($env:PDW_SNAPSHOT_PREFIX + 'settings.png')))
	}
}
Apply-Icon
if ($Snap) { New-Item -ItemType Directory -Force $env:PDW_SNAPSHOT | Out-Null; Run-Scan; if ($script:scanProc) { [void]$script:scanProc.WaitForExit(20000) }; Refresh-Data; Take-Snapshots; exit }
Run-Scan
Refresh-Data
$timer.Start()
$iconForm.Add_FormClosed({ $panel.Close(); $bubble.Close() })
[System.Windows.Forms.Application]::Run($iconForm)
$mutex.ReleaseMutex()
