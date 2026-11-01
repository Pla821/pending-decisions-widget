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
	public bool Layered = false; // 圖示用：逐像素透明的視窗（沒有白底、邊緣平滑，動畫換格也不會閃）
	[DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
	[StructLayout(LayoutKind.Sequential)] struct BLEND { public byte Op, Flags, Alpha, Format; }
	[DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref Point dst, ref Size size, IntPtr hdcSrc, ref Point src, int key, ref BLEND blend, int flags);
	[DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
	[DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
	[DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
	[DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
	[DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
	[DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
	// 把一張帶透明度的圖直接貼成這個視窗的外觀（alpha 0–255 控制整體淡出）
	public void SetSprite(Bitmap bmp, byte alpha) {
		IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), hb = bmp.GetHbitmap(Color.FromArgb(0)), old = SelectObject(mem, hb);
		try {
			Size sz = new Size(bmp.Width, bmp.Height); Point src = new Point(0, 0), dst = new Point(Left, Top);
			BLEND bl = new BLEND(); bl.Op = 0; bl.Flags = 0; bl.Alpha = alpha; bl.Format = 1;
			UpdateLayeredWindow(Handle, screen, ref dst, ref sz, mem, ref src, 0, ref bl, 2);
		} finally { SelectObject(mem, old); DeleteObject(hb); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen); }
	}
	protected override bool ShowWithoutActivation { get { return NoActivate; } }
	protected override CreateParams CreateParams {
		get {
			CreateParams p = base.CreateParams;
			p.ExStyle |= 0x00000080;                 // 不出現在 Alt+Tab
			if (Layered) p.ExStyle |= 0x00080000;    // WS_EX_LAYERED
			if (NoActivate) p.ExStyle |= 0x08000000; // 點它不搶走目前視窗的焦點
			if (Shadow) p.ClassStyle |= 0x00020000;  // 陰影
			return p;
		}
	}
	// Windows 11：請系統畫圓角（有抗鋸齒）；失敗（Windows 10）回傳 false，由呼叫端改用 Region
	public bool RoundCorners() { int v = 2; try { return DwmSetWindowAttribute(this.Handle, 33, ref v, 4) == 0; } catch { return false; } }
}

public class RowItem { public string Title; public string Label; public string Sub; public string Meta; public string Tag; public string Key; public string Extra; public Color LabelColor; }

public class RowList : Control {
	public List<RowItem> Items = new List<RowItem>();
	public int RowHeight = 62, Hover = -1, Scroll = 0;
	public Color Back, Fore, Muted, Line, HoverBack;
	public string EmptyTitle = "", EmptyText = "";
	public Font TitleFont, SubFont, BigFont;
	public int ActivatedIndex = -1;
	public bool SingleClick = false; // 「最近」分頁：點一下就開
	public event EventHandler RowActivated;
	ToolTip tip = new ToolTip();
	public RowList() {
		SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
	}
	int MaxScroll() { return Math.Max(0, Items.Count * RowHeight - Height); }
	public int HitTest(int y) { return IndexAt(y); }
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
	protected override void OnMouseClick(MouseEventArgs e) {
		if (SingleClick && e.Button == MouseButtons.Left) { int i = IndexAt(e.Y); if (i >= 0) { ActivatedIndex = i; if (RowActivated != null) RowActivated(this, EventArgs.Empty); } }
		base.OnMouseClick(e);
	}
	protected override void OnDoubleClick(EventArgs e) {
		if (SingleClick) { base.OnDoubleClick(e); return; }
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
$RecentFile = Join-Path $DataDir 'recent.json'
$UsageFile = Join-Path $DataDir 'usage.json'
$DismissFile = Join-Path $DataDir 'dismissed.json'
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
$script:set = @{ icon = 'bell.png'; message = '有待決定囉！'; hideWhenZero = $false; sound = $true; walk = $false; pet = $false; x = $null; y = $null }
try { if (Test-Path $SetFile) { $j = Get-Content $SetFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @('icon', 'message', 'hideWhenZero', 'sound', 'walk', 'pet', 'x', 'y')) { if ($null -ne $j.$k) { $script:set[$k] = $j.$k } } } } catch { }
function Save-Settings { try { ($script:set | ConvertTo-Json) | Set-Content -Path $SetFile -Encoding UTF8 } catch { } }

function Load-Img([string]$path) { # 讀進記憶體再解碼，不鎖檔
	$bytes = [System.IO.File]::ReadAllBytes($path)
	return [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes)))
}
function Icon-Files { # 內建＋使用者自己的
	$all = @()
	# 動畫圖示＝多張 名稱@1.png、名稱@2.png…（可加 名稱@idle1.png… 當沒待決定時的待機動作），清單只列第一張
	foreach ($d in @($BuiltinIconDir, $UserIconDir)) { if (Test-Path $d) { $all += Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|gif|bmp|ico)$' -and $_.Name -notmatch '@(idle\d+|[02-9]|[1-9]\d+)\.png$' } | Sort-Object Name } }
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
	if ($ext -eq '.gif') { $dest = Join-Path $UserIconDir ($base + $stamp + $ext); Copy-Item $src $dest; return [System.IO.Path]::GetFileName($dest) } # GIF 原樣複製（保留動畫）
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
$iconForm.NoActivate = $true; $iconForm.Shadow = $false; $iconForm.Layered = $true # 逐像素透明視窗：圖直接貼上去，沒有白底
$iconForm.FormBorderStyle = 'None'; $iconForm.TopMost = $true; $iconForm.ShowInTaskbar = $false; $iconForm.StartPosition = 'Manual'; $iconForm.Cursor = 'Hand'
$iconForm.Size = New-Object System.Drawing.Size($IconBox, $IconBox)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$px = if ($null -ne $script:set.x) { [int]$script:set.x } else { $wa.Right - $IconBox - 24 }
$py = if ($null -ne $script:set.y) { [int]$script:set.y } else { $wa.Bottom - $IconBox - 60 }
$iconForm.Location = New-Object System.Drawing.Point($px, $py)
$script:frames = @(); $script:idleFrames = @(); $script:badgeShown = -1; $script:fIdx = 0; $script:fCache = @{}
$script:curBmp = $null; $script:iconAlpha = 255; $script:moving = $false; $script:fxUntil = 0
function Pet-Asleep { [bool]($script:set.pet -and $script:pet.sleeping) }
function Pet-Fx-On { [Environment]::TickCount -lt $script:fxUntil }

function Load-Frames([string]$path) { # 動畫＝一串圖：名稱@1.png…（＋待機用 名稱@idle1.png…）或多格 GIF；一般圖就只有一格
	$name = [System.IO.Path]::GetFileName($path); $dir = Split-Path $path
	$r = @{ active = @(); idle = @() }
	if ($name -match '^(.+)@1\.png$') {
		$base = $Matches[1]
		for ($i = 1; $i -le 60; $i++) { $p = Join-Path $dir ('{0}@{1}.png' -f $base, $i); if (Test-Path $p) { $r.active += , (Load-Img $p) } else { break } }
		for ($i = 1; $i -le 60; $i++) { $p = Join-Path $dir ('{0}@idle{1}.png' -f $base, $i); if (Test-Path $p) { $r.idle += , (Load-Img $p) } else { break } }
	} elseif ($name -match '\.gif$') {
		$img = Load-Img $path; $fd = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0]); $n = $img.GetFrameCount($fd)
		for ($i = 0; $i -lt [Math]::Min($n, 60); $i++) { [void]$img.SelectActiveFrame($fd, $i); $r.active += , (New-Object System.Drawing.Bitmap($img)) }
	}
	if ($r.active.Count -eq 0) { $r.active = @(, (Load-Img $path)) }
	return $r
}
function Build-Frame($img, [int]$count) { # 一格圖＋右上角紅色數字
	$bmp = New-Object System.Drawing.Bitmap($IconBox, $IconBox, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
	$g.Clear([System.Drawing.Color]::Transparent)
	$size = 74
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
	return $bmp
}
function Show-Frame { # 顯示目前這一格（算過的存起來；數字或圖換了才重算）
	$useIdle = ($script:badgeShown -le 0 -and -not $script:moving -and -not (Pet-Fx-On) -and $script:idleFrames.Count -gt 0) # 沒事又沒在走＝待機動作；有事或在走＝跳跳動作
	$seq = if ($useIdle) { $script:idleFrames } else { $script:frames }
	if ($seq.Count -eq 0) { return }
	$i = $script:fIdx % $seq.Count; $key = '{0}|{1}|{2}' -f $(if ($useIdle) { 'i' } else { 'a' }), $i, $script:badgeShown
	if (-not $script:fCache.ContainsKey($key)) { $script:fCache[$key] = Build-Frame $seq[$i] ([Math]::Max(0, $script:badgeShown)) }
	$script:curBmp = $script:fCache[$key]
	if (-not $Snap) { $iconForm.SetSprite($script:curBmp, [byte]$script:iconAlpha) }
}
function Compose-Icon([int]$count) { # 數字變了：快取作廢、換動畫節奏
	if ($script:frames.Count -eq 0) { return }
	$script:badgeShown = $count; $script:fCache = @{}
	Set-AnimRate
	Show-Frame
}
function Set-AnimRate { $anim.Interval = if ($script:badgeShown -le 0 -and (Pet-Asleep)) { 900 } elseif ($script:badgeShown -gt 0 -or $script:moving -or (Pet-Fx-On)) { 140 } else { 420 } } # 有待決定或在走：動得快；沒事：慢慢待機
function Apply-Icon {
	$p = Find-Icon ([string]$script:set.icon)
	if (-not $p) { return }
	try { $r = Load-Frames $p } catch { return }
	$script:frames = @($r.active); $script:idleFrames = @($r.idle); $script:fIdx = 0; $script:fCache = @{}
	if (-not $Snap -and ($script:frames.Count -gt 1 -or $script:idleFrames.Count -gt 1)) { $anim.Start() } else { $anim.Stop() }
	Compose-Icon ([Math]::Max(0, $script:badgeShown))
}
$anim = New-Object System.Windows.Forms.Timer
$anim.Interval = 420
$anim.Add_Tick({ $script:fIdx++; Show-Frame; Set-AnimRate })

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
$script:tab = 'pending'; $script:recent = $null; $script:recentStamp = 0
$TabsH = 38
$tabDefs = @(@('pending', '待決定'), @('broken', '中斷'), @('sessions', '最近對話'), @('projects', '專案'), @('files', '最近檔案'), @('dirs', '資料夾'))
$tabs = New-Object System.Windows.Forms.Panel
$tabs.Dock = 'Top'; $tabs.Height = $TabsH; $tabs.BackColor = $T.surface; $tabs.Cursor = 'Hand'
$tabs.Add_Paint({
	param($s, $e)
	$g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
	$w = $s.Width / $tabDefs.Count
	for ($i = 0; $i -lt $tabDefs.Count; $i++) {
		$on = ($tabDefs[$i][0] -eq $script:tab)
		$label = $tabDefs[$i][1]; if ($i -eq 0 -and $script:headCount -gt 0) { $label = "$label ($($script:headCount))" } elseif ($tabDefs[$i][0] -eq 'broken' -and $script:recent -and @($script:recent.broken).Count -gt 0) { $label = "$label ($(@($script:recent.broken).Count))" }
		$col = if ($on) { $T.fg } else { $T.muted }
		[System.Windows.Forms.TextRenderer]::DrawText($g, $label, $(if ($on) { $FontTitle } else { $FontSub }), (New-Object System.Drawing.Rectangle([int]($i * $w), 0, [int]$w, ($TabsH - 3))), $col, [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
		if ($on) { $g.FillRectangle((New-Object System.Drawing.SolidBrush($T.accent)), [int]($i * $w + 14), ($TabsH - 3), [int]($w - 28), 3) }
	}
})
$tabs.Add_MouseUp({ param($s, $e) $i = [Math]::Min($tabDefs.Count - 1, [Math]::Max(0, [int][Math]::Floor($e.X / ($s.Width / $tabDefs.Count)))); $script:tab = $tabDefs[$i][0]; Rebuild-List; Show-Panel })
$panel.Controls.Remove($head); $panel.Controls.Add($tabs); $panel.Controls.Add($head) # 左到右：標題、分頁、清單、底部按鈕

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
	$rows = [Math]::Max(0, [Math]::Min(7, $list.Items.Count))
	$body = if ($rows -eq 0) { 120 } else { $list.RowHeight * $rows }
	$panel.Size = New-Object System.Drawing.Size($PW, ($HeaderH + $TabsH + $body + $FooterH))
	if (-not $panel.IsHandleCreated) { [void]$panel.Handle; Round-Form $panel 14 } else { Round-Form $panel 14 }
	Place-Around
	$bubble.Hide(); $petBubble.Hide()
	if (-not $Snap -and -not $panel.Visible) { $panel.Show() }
	$head.Invalidate()
}
function Update-Look {
	$n = $script:items.Count
	if ($n -gt 0) {
		$msg = [string]$script:set.message
		Set-Bubble ("{0}  ·  {1} 件" -f $msg, $n)
		$script:iconAlpha = 255
		if (-not $panel.Visible) { Place-Around; if (-not $Snap -and -not $bubble.Visible) { $bubble.Show() } }
	} else {
		$bubble.Hide(); $script:iconAlpha = $(if (Pet-Asleep) { 90 } else { 153 })
		if ($panel.Visible) { $panel.Hide() }
	}
	if ($n -ne $script:badgeShown) { Compose-Icon $n } else { Show-Frame }
	if ($Snap) { return }
	if ($n -eq 0 -and $script:set.hideWhenZero) { if ($iconForm.Visible) { $iconForm.Hide() } } else { if (-not $iconForm.Visible) { $iconForm.Show() } }
}
function Empty-Messages { # 空狀態與錯誤的文案
	if ($script:tab -eq 'broken' -and $script:recent) { return @('沒有中斷的對話', '最近的對話不是正常回完，就是還在跑；有斷線的會出現在這裡。') }
	if ($script:tab -ne 'pending') { if (-not $script:recent) { return @('還沒有資料', '掃描完成後這裡會列出最近的內容（每幾秒更新）。') }; return @('最近三天沒有', '它最近三天沒有做過這類事。') }
	if (-not $script:nodeOk) { return @('找不到 Node.js', '浮窗需要 Node.js 來掃描對話紀錄。請安裝（https://nodejs.org）後重新開啟浮窗。') }
	if ($script:status -and $script:status.ok -eq $false -and $script:status.error -eq 'no-projects') { return @('找不到對話紀錄資料夾', "預期在：$($script:status.projects)`n如果你的 Claude 資料放在別處，請在 config.json 設定 claudeDir。") }
	if (-not $script:status) { return @('正在掃描…', '第一次掃描需要幾秒鐘。') }
	return @('✓ 都回完了', '現在沒有任何對話在等你回答。')
}
function Age-Text([double]$atMs) {
	$mins = [Math]::Max(1, [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $atMs) / 60000))
	if ($mins -ge 1440) { return ('{0} 天' -f [Math]::Round($mins / 1440, 1)) } elseif ($mins -ge 60) { return ('{0} 小時' -f [Math]::Round($mins / 60, 1)) } else { return "$mins 分" }
}
function Short-Dir([string]$p) { # 路徑太長時留尾巴（最後幾層才是重點）：…專案資料夾
	if (-not $p -or $p.Length -le 44) { return $p }
	$parts = $p.Split(''); $s = ''
	for ($i = $parts.Count - 1; $i -ge 0; $i--) { $n = if ($s) { $parts[$i] + '' + $s } else { $parts[$i] }; if ($n.Length -gt 42) { break }; $s = $n }
	return '…' + $s
}
function New-Row([string]$title, [string]$label, $col, [string]$sub, [string]$meta, [string]$key, [string]$tip) {
	$r = New-Object RowItem
	$r.Title = $title; $r.Label = $label; $r.LabelColor = $col; $r.Sub = $sub; $r.Meta = $meta; $r.Key = $key; $r.Tag = $(if ($tip) { $tip } else { "$title`n$sub" })
	return $r
}
function Read-Recent { # data\recent.json（掃描程式寫的：最近執行的指令／寫過的檔案／動過的資料夾），檔案沒變就不重讀
	try {
		if (-not (Test-Path $RecentFile)) { return }
		$st = (Get-Item $RecentFile).LastWriteTimeUtc.Ticks
		if ($st -ne $script:recentStamp) { $script:recent = (Get-Content $RecentFile -Raw -Encoding UTF8) | ConvertFrom-Json; $script:recentStamp = $st }
	} catch { }
}
function Tab-Rows { # 目前這個分頁要列的資料
	$rows = New-Object 'System.Collections.Generic.List[RowItem]'
	switch ($script:tab) {
		'pending' {
			foreach ($it in $script:items) {
				$sid8 = if ($it.sid) { ([string]$it.sid).Substring(0, [Math]::Min(8, ([string]$it.sid).Length)) } else { '' }
				$title = if ($it.title) { [string]$it.title } elseif ($it.cwd) { (Split-Path ([string]$it.cwd).TrimEnd('\', '/') -Leaf) + "（$sid8）" } else { "對話 $sid8" }
				$q = if ($it.kind -eq 'permission') { (([string]$it.tool) + ' ' + ([string]$it.detail)).Trim() } elseif ($it.questions -and $it.questions.Count -gt 0) { [string]$it.questions[0].question } else { '' }
				$label = '選項框'; $col = $T.accent
				if ($it.kind -eq 'permission') { $label = '要你允許'; $col = $T.amber } elseif ($it.kind -eq 'wrapup') { $label = '要你決定'; $col = $T.blue } elseif ($it.kind -eq 'fable') { $label = 'Fable 提醒'; $col = $T.accent } elseif ($it.kind -eq 'usage') { $label = $it.label; $col = $(if ($it.level -ge 2) { $T.accent } else { $T.amber }) }
				$row = New-Row $title $label $col $q (Age-Text ([double]$it.at)) ([string]$it.local) ''
				if ($it.kind -eq 'fable') { $row.Extra = [string]$it.sid }
				[void]$rows.Add($row)
			}
		}
		'broken' { if ($script:recent) { foreach ($x in @($script:recent.broken)) { $proj = if ($x.cwd) { Split-Path ([string]$x.cwd) -Leaf } else { '' }; $sub = '停在：' + $(if ($x.stopped) { [string]$x.stopped } else { '（不明）' }); [void]$rows.Add((New-Row ([string]$x.title) '停住了' $T.accent $sub (Age-Text ([double]$x.at)) ([string]$x.local) ("{0}`n{1}`n{2}`n它最後說：{3}" -f $x.title, $x.cwd, $sub, $x.said))) } } }
		'sessions' { if ($script:recent) { foreach ($x in @($script:recent.sessions)) { $proj = if ($x.cwd) { Split-Path ([string]$x.cwd) -Leaf } else { '' }; $sub = (@($proj, [string]$x.last) | Where-Object { $_ }) -join '  ·  '; [void]$rows.Add((New-Row ([string]$x.title) '對話' $T.blue $sub (Age-Text ([double]$x.at)) ([string]$x.local) ("{0}`n{1}`n{2}" -f $x.title, $x.cwd, $x.last))) } } }
		'projects' { if ($script:recent) { foreach ($x in @($script:recent.projects)) { $leaf = Split-Path ([string]$x.path) -Leaf; if (-not $leaf) { $leaf = [string]$x.path }; [void]$rows.Add((New-Row $leaf ("{0} 個對話" -f $x.count) $T.accent ((@($x.titles) | Where-Object { $_ }) -join '、') (Age-Text ([double]$x.at)) ([string]$x.path) ([string]$x.path))) } } }
		'files' { if ($script:recent) { foreach ($x in @($script:recent.files)) { [void]$rows.Add((New-Row ([System.IO.Path]::GetFileName([string]$x.path)) '檔案' $T.accent (Short-Dir ([System.IO.Path]::GetDirectoryName([string]$x.path))) (Age-Text ([double]$x.at)) ([string]$x.path) ([string]$x.path))) } } }
		'dirs' { if ($script:recent) { foreach ($x in @($script:recent.dirs)) { $leaf = Split-Path ([string]$x.path) -Leaf; if (-not $leaf) { $leaf = [string]$x.path }; [void]$rows.Add((New-Row $leaf '資料夾' $T.amber (Short-Dir ([string]$x.path)) (Age-Text ([double]$x.at)) ([string]$x.path) ([string]$x.path))) } } }
	}
	return $rows
}
function Rebuild-List {
	$list.SingleClick = ($script:tab -ne 'pending')
	$list.Items = (Tab-Rows)
	$list.Scroll = 0
	$em = Empty-Messages; $list.EmptyTitle = $em[0]; $list.EmptyText = $em[1]
	$hint.Text = switch ($script:tab) { 'pending' { '雙擊＝打開對話' } 'broken' { '點＝開對話並複製接續指令' } 'sessions' { '點一下＝打開對話' } 'projects' { '點一下＝開專案資料夾' } 'files' { '點一下＝找到檔案' } 'dirs' { '點一下＝開資料夾' } }
	$list.Invalidate(); $tabs.Invalidate()
}
# ---------- 額度守門：用量 ≥90% 只做你明確要的事、不派子代理；≥98% 全面停止（用量由狀態列小程式 usage-feed.mjs 寫進 data/usage.json，或右鍵「回報額度 %」手動填）----------
$script:usageSince = @{ 90 = 0; 98 = 0 }
function Usage-Pct { # → @{ pct; label } 取兩個窗口較高的；資料太舊（>12 小時）或視窗已重置就不算
	if (-not (Test-Path $UsageFile)) { return $null }
	try {
		$u = (Get-Content $UsageFile -Raw -Encoding UTF8) | ConvertFrom-Json
		$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		if (($nowMs - [double]$u.at) -gt 12 * 3600000) { return $null }
		$best = $null
		foreach ($pair in @(@('five_hour', '5 小時'), @('seven_day', '每週'), @('manual', '手動'))) {
			$w = $u.($pair[0]); if (-not $w -or $null -eq $w.pct) { continue }
			if ($w.resets_at -and ([double]$w.resets_at * 1000) -lt $nowMs -and $pair[0] -ne 'manual') { continue } # 這個窗口已經重置了
			if (-not $best -or [double]$w.pct -gt $best.pct) { $best = @{ pct = [double]$w.pct; name = $pair[1] } }
		}
		return $best
	} catch { return $null }
}
function Usage-Items {
	$b = Usage-Pct
	if (-not $b -or $b.pct -lt 90) { $script:usageSince[90] = 0; $script:usageSince[98] = 0; return @() }
	$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$lvl = if ($b.pct -ge 98) { 2 } else { 1 }
	if ($script:usageSince[90] -eq 0) { $script:usageSince[90] = $nowMs }
	if ($lvl -ge 2 -and $script:usageSince[98] -eq 0) { $script:usageSince[98] = $nowMs }
	$since = if ($lvl -ge 2) { $script:usageSince[98] } else { $script:usageSince[90] }
	$pctText = ('{0}%' -f [Math]::Round($b.pct))
	if ($lvl -ge 2) { $title = "額度 $pctText（$($b.name)）— 全面停止"; $q = '不開新工作、不派子代理、不啟動排程／部署；收到安全斷點、更新接續點、回報一次後等重置或等你說「開始」。' }
	else { $title = "額度 $pctText（$($b.name)）— 只做你明確要的事"; $q = '不派子代理、不開大工作；開頭先告知額度。' }
	return @([pscustomobject]@{ kind = 'usage'; level = $lvl; label = "額度 $pctText"; title = $title; questions = @(@{ question = $q }); at = $since; local = ''; sid = ''; cwd = '' })
}
function Report-Usage { # 右鍵「回報額度 %」：手動輸入目前最高的那個 %
	Add-Type -AssemblyName Microsoft.VisualBasic
	$s = [Microsoft.VisualBasic.Interaction]::InputBox('現在 Claude 用量最高的那個窗口是幾 %？（只填數字；填 0 或留空＝清除）', '回報額度', '')
	if ($s -eq $null) { return }
	$v = 0.0; if (-not [double]::TryParse($s.Trim().TrimEnd('%'), [ref]$v)) { return }
	try {
		if ($v -le 0) { if (Test-Path $UsageFile) { Remove-Item $UsageFile -Force } }
		else { (@{ at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); source = 'manual'; manual = @{ pct = $v } } | ConvertTo-Json -Depth 4) | Set-Content -Path $UsageFile -Encoding UTF8 }
	} catch { }
	Refresh-Data
}
function Dismiss-Fable([string]$sid) { # 「知道了」：這個對話 12 小時內不再提醒 Fable
	if (-not $sid) { return }
	try {
		$d = @{}; if (Test-Path $DismissFile) { $j = (Get-Content $DismissFile -Raw -Encoding UTF8) | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $d[$p.Name] = $p.Value } }
		$d[$sid] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 12 * 3600000
		($d | ConvertTo-Json) | Set-Content -Path $DismissFile -Encoding UTF8
	} catch { }
	Run-Scan
}
function Refresh-Data {
	$items = @()
	try { if (Test-Path $StateFile) { $j = (Get-Content $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json; $items = @($j.items | Where-Object { $_.status -eq 'pending' } | Sort-Object { [double]$_.at } -Descending) } } catch { }
	try { if (Test-Path $StatusFile) { $script:status = (Get-Content $StatusFile -Raw -Encoding UTF8) | ConvertFrom-Json } } catch { }
	$items = @(Usage-Items) + @($items) # 額度警示排在最前面
	$script:items = $items
	$n = $items.Count
	$script:headCount = $n; $head.Invalidate()
	Read-Recent
	Rebuild-List
	if ($n -gt $script:lastCount) { Pet-Wake ''; # 有新的：叮一聲＋圖抖一下
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
$iconForm.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:down = [System.Windows.Forms.Cursor]::Position; $script:moved = $false; $script:startLoc = $iconForm.Location } })
$iconForm.Add_MouseMove({ param($s, $e)
	if ($script:down -and ($e.Button -eq 'Left')) {
		$p = [System.Windows.Forms.Cursor]::Position
		$dx = $p.X - $script:down.X; $dy = $p.Y - $script:down.Y
		if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 5) { $script:moved = $true }
		if ($script:moved) { $iconForm.Location = New-Object System.Drawing.Point(($script:startLoc.X + $dx), ($script:startLoc.Y + $dy)); Place-Around }
	}
})
$iconForm.Add_MouseUp({ param($s, $e)
	if ($e.Button -ne 'Left') { return }
	if ($script:moved) { $script:set.x = $iconForm.Left; if (-not $script:set.walk) { $script:set.y = $iconForm.Top }; Save-Settings } # 走路模式：只記站的位置（x），高度永遠是跑道
	else { if ($panel.Visible) { $panel.Hide(); Update-Look } else { Show-Panel } }
	$script:down = $null
})
$bl.Add_Click({ Show-Panel })
$btnHide.Add_Click({ $panel.Hide(); Update-Look })
$btnWeb.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
function Open-Session([string]$local) { if ($local) { Start-Process ("claude://claude.ai/epitaxy/" + $local) } elseif (Test-Path $HtmlFile) { Start-Process $HtmlFile } } # CLI 使用者沒有桌面版連結：改開網頁清單
function Reveal-Path([string]$p, [bool]$isDir) { # 在檔案總管裡找到它；檔案／資料夾已經不在了就開到還在的最近一層
	if (-not $p) { return }
	try {
		if (Test-Path -LiteralPath $p) { if ($isDir) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') } else { Start-Process explorer.exe -ArgumentList ('/select,"' + $p + '"') }; return }
		$d = Split-Path $p -Parent
		while ($d -and -not (Test-Path -LiteralPath $d)) { $d = Split-Path $d -Parent }
		if ($d) { Start-Process explorer.exe -ArgumentList ('"' + $d + '"') }
	} catch { }
}
$rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
$rowMenu.Font = $FontBtn
$mi = $rowMenu.Items.Add('知道了（這個對話 12 小時內不再提醒 Fable）')
$script:menuSid = ''
$mi.Add_Click({ Dismiss-Fable $script:menuSid })
$list.Add_MouseUp({ param($s, $e)
	if ($e.Button -ne 'Right' -or $script:tab -ne 'pending') { return }
	$i = $list.HitTest($e.Y); if ($i -lt 0) { return }
	$row = $list.Items[$i]
	if ($row.Extra) { $script:menuSid = $row.Extra; $rowMenu.Show($list, $e.Location) }
})
$list.Add_RowActivated({
	$row = $list.Items[$list.ActivatedIndex]
	if (-not $row) { return }
	switch ($script:tab) {
		'pending' { Open-Session $row.Key }
		'broken' { # 把「請從中斷的地方接著做」放進剪貼簿，再打開那個對話；你只要貼上、按送出
			$b = @($script:recent.broken)[$list.ActivatedIndex]
			$txt = '剛剛好像斷線或中斷了。請先看紀錄，確認你上一步做到哪（我這邊看到最後停在：' + $(if ($b -and $b.stopped) { [string]$b.stopped } else { '不明' }) + '），已經做完的不要重做，沒做完的從那裡接著做，做完用一句話跟我說。'
			try { [System.Windows.Forms.Clipboard]::SetText($txt) } catch { }
			Open-Session $row.Key
		}
		'sessions' { Open-Session $row.Key }
		'projects' { Reveal-Path $row.Key $true }
		'files' { Reveal-Path $row.Key $false }
		'dirs' { Reveal-Path $row.Key $true }
	}
})

# ---------- 走來走去（設定裡勾選才啟用）：沒事時在螢幕底邊一左一右地走（走路時用跳跳動作、停下來時用待機動作）；
# 有待決定時就走回「固定位置」（你把它拖去哪就是哪，預設右下角）站好，不再亂跑 ----------
function Runway-Y { [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea.Bottom - $IconBox + 16 } # 腳踩在工作列上緣
function Home-X {
	$w = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$x = if ($null -ne $script:set.x) { [int]$script:set.x } else { $w.Right - $IconBox - 24 }
	return [Math]::Min([Math]::Max($w.Left, $x), $w.Right - $IconBox)
}
function Go-Home { # 設定改變後：走路模式＝站回跑道；不走了＝回到記住的位置
	$script:walkTarget = $null; $script:moving = $false
	if ($script:set.walk) { $iconForm.Location = New-Object System.Drawing.Point((Home-X), (Runway-Y)) }
	elseif ($null -ne $script:set.x -and $null -ne $script:set.y) { $iconForm.Location = New-Object System.Drawing.Point([int]$script:set.x, [int]$script:set.y) }
	else { $w = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea; $iconForm.Location = New-Object System.Drawing.Point(($w.Right - $IconBox - 24), ($w.Bottom - $IconBox - 60)) }
	Place-Around; Set-AnimRate
}
$script:walkTarget = $null; $script:pauseUntil = 0
$rng = New-Object System.Random
$walk = New-Object System.Windows.Forms.Timer
$walk.Interval = 40
$walk.Add_Tick({
	if (-not $script:set.walk -or -not $iconForm.Visible) { return }
	if ($script:down -or $shake.Enabled -or $panel.Visible -or (Pet-Asleep)) { if ($script:moving) { $script:moving = $false; Set-AnimRate }; return } # 被抓著、抖動中、清單開著：先不走
	$w = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$now = [Environment]::TickCount
	$goHome = ($script:items.Count -gt 0)
	if ($goHome) { $script:walkTarget = Home-X }
	elseif ($null -eq $script:walkTarget) {
		if ($now -lt $script:pauseUntil) { if ($script:moving) { $script:moving = $false; Set-AnimRate }; return } # 站著發呆
		do { $tx = $rng.Next($w.Left, $w.Right - $IconBox + 1) } while ([Math]::Abs($tx - $iconForm.Left) -lt 120)
		$script:walkTarget = $tx
	}
	$cur = $iconForm.Left; $diff = $script:walkTarget - $cur
	$step = if ($goHome) { 9 } else { 4 }
	if ([Math]::Abs($diff) -le $step) {
		$nx = $script:walkTarget; $script:walkTarget = $null; $script:pauseUntil = $now + $rng.Next(2500, 8000)
		if ($script:moving) { $script:moving = $false; Set-AnimRate }
	} else {
		$nx = $cur + [Math]::Sign($diff) * $step
		if (-not $script:moving) { $script:moving = $true; Set-AnimRate }
	}
	$ny = Runway-Y
	if ($nx -ne $iconForm.Left -or $ny -ne $iconForm.Top) { $iconForm.Location = New-Object System.Drawing.Point($nx, $ny); if ($bubble.Visible) { Place-Around }; if ($petBubble.Visible) { Place-PetBubble } }
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
	$dlg.ClientSize = New-Object System.Drawing.Size(560, 620); $dlg.Font = $FontBtn; $dlg.BackColor = $T.bg; $dlg.ForeColor = $T.fg
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
	$cb4 = New-Object System.Windows.Forms.CheckBox; $cb4.Text = '讓圖示在螢幕底邊走來走去（有待決定時會回到固定位置站好）'; $cb4.AutoSize = $true; $cb4.Checked = [bool]$script:set.walk; $cb4.Location = New-Object System.Drawing.Point(20, 502)
	$cb5 = New-Object System.Windows.Forms.CheckBox; $cb5.Text = '養電子雞（右鍵選「電子雞」：餵食、陪玩、摸摸、哄睡覺）'; $cb5.AutoSize = $true; $cb5.Checked = [bool]$script:set.pet; $cb5.Location = New-Object System.Drawing.Point(20, 528)
		$ok = Flat-Button '儲存' 96 34 $true; $ok.Location = New-Object System.Drawing.Point(334, 566); $ok.DialogResult = 'OK'
	$cancel = Flat-Button '取消' 96 34 $false; $cancel.Location = New-Object System.Drawing.Point(444, 566); $cancel.DialogResult = 'Cancel'
	$dlg.Controls.AddRange(@($hd, $l1, $l1b, $fp, $btnImg, $l2, $tb, $cb1, $cb2, $cb3, $cb4, $cb5, $ok, $cancel)); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
	if ($Snapshot) { $dlg.FormBorderStyle = 'None'; $dlg.TopMost = $false; $b = Snap-Ctl $dlg; $dlg.Close(); return $b }
	if ($dlg.ShowDialog() -eq 'OK') {
		$script:set.icon = $script:pick
		$script:set.message = if ($tb.Text.Trim()) { $tb.Text.Trim() } else { '有待決定囉！' }
		$script:set.hideWhenZero = $cb1.Checked; $script:set.sound = $cb2.Checked; $script:set.walk = $cb4.Checked; $wasPet = [bool]$script:set.pet; $script:set.pet = $cb5.Checked; Go-Home
		if ($cb3.Checked -ne (Autostart-On)) { Set-Autostart $cb3.Checked }
		Save-Settings; Apply-Icon; Update-Look
			if ($script:set.pet -and -not $wasPet) { $script:pet.last = (Now-Sec); Save-Pet; Pet-Say ('我是{0}！右鍵點我選「電子雞」，可以餵我、陪我玩～' -f $script:pet.name) 7000 } elseif (-not $script:set.pet) { $petBubble.Hide() }
	}
}
$btnSet.Add_Click({ Show-Settings })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = $FontBtn
$m1 = $menu.Items.Add('設定…（換圖／改說的話）'); $m1.Add_Click({ Show-Settings })
$m5 = $menu.Items.Add('回報額度 %…（沒有自動數字時手動填）'); $m5.Add_Click({ Report-Usage })
$m2 = $menu.Items.Add('開網頁清單'); $m2.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
$m3 = $menu.Items.Add('開啟資料夾'); $m3.Add_Click({ Start-Process $DataDir })
[void]$menu.Items.Add('-')
$mp = New-Object System.Windows.Forms.ToolStripMenuItem '電子雞（陪牠玩）'
$mpi = @{}
foreach ($pair in @(@('feed', '餵食'), @('play', '陪玩'), @('pat', '摸摸'), @('sleep', '哄睡覺'), @('status', '看狀態'), @('name', '取名字…'))) { $mpi[$pair[0]] = $mp.DropDownItems.Add($pair[1]) }
$mpi.feed.Add_Click({ $panel.Hide(); Pet-Feed }); $mpi.play.Add_Click({ $panel.Hide(); Pet-Play }); $mpi.pat.Add_Click({ $panel.Hide(); Pet-Pat }); $mpi.sleep.Add_Click({ $panel.Hide(); Pet-ToggleSleep }); $mpi.status.Add_Click({ $panel.Hide(); Pet-Status }); $mpi.name.Add_Click({ $panel.Hide(); Pet-Rename }) # 清單開著時先收起來，不然說的話會被擋住
[void]$menu.Items.Insert(0, $mp)
$menu.Add_Opening({ $mp.Visible = [bool]$script:set.pet; $mpi.sleep.Text = $(if ($script:pet.sleeping) { '叫醒牠' } else { '哄睡覺' }) })
$m4 = $menu.Items.Add('結束浮窗'); $m4.Add_Click({ $iconForm.Close() })
$iconForm.ContextMenuStrip = $menu

# 把圖檔直接拖到浮窗上＝換成那張圖（複製一份進 data\icons，不動原檔）
$iconForm.AllowDrop = $true
$onEnter = { param($s, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } else { $e.Effect = 'None' } }
$onDrop = { param($s, $e)
	foreach ($f in $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)) {
		if ([System.IO.Path]::GetExtension($f) -match '^\.(png|jpg|jpeg|gif|bmp|ico)$') {
			$script:set.icon = Import-Icon $f; Save-Settings; Apply-Icon
			break
		}
	}
}
$iconForm.Add_DragEnter($onEnter); $iconForm.Add_DragDrop($onDrop)

# ---------- 電子雞（設定裡勾「養電子雞」才啟用）：飽足／心情／精神三個數字會隨時間往下掉，右鍵「電子雞」選單餵食、陪玩、摸摸、哄睡覺 ----------
$PetFile = Join-Path $DataDir 'pet.json'
function Now-Sec { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
$script:pet = @{ name = '小橘'; hunger = 80.0; mood = 80.0; energy = 90.0; sleeping = $false; born = (Now-Sec); last = (Now-Sec); fed = 0; played = 0 }
try { if (Test-Path $PetFile) { $pj = Get-Content $PetFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @('name', 'hunger', 'mood', 'energy', 'sleeping', 'born', 'last', 'fed', 'played')) { if ($null -ne $pj.$k) { $script:pet[$k] = $pj.$k } } } } catch { }
function Save-Pet { try { ($script:pet | ConvertTo-Json) | Set-Content -Path $PetFile -Encoding UTF8 } catch { } }
function Pet-Clamp([double]$v) { [Math]::Max(0.0, [Math]::Min(100.0, $v)) }
$script:petSaid = @{}
$petBubble = New-Object PopForm
$petBubble.NoActivate = $true
$petBubble.FormBorderStyle = 'None'; $petBubble.TopMost = $true; $petBubble.ShowInTaskbar = $false; $petBubble.StartPosition = 'Manual'; $petBubble.BackColor = $Navy
$pl = New-Object System.Windows.Forms.Label
$pl.ForeColor = [System.Drawing.Color]::White; $pl.Font = $FontBtn; $pl.TextAlign = 'MiddleCenter'; $pl.Dock = 'Fill'
$petBubble.Controls.Add($pl)
$petHide = New-Object System.Windows.Forms.Timer
$petHide.Add_Tick({ $petHide.Stop(); $petBubble.Hide() })
function Place-PetBubble {
	$wa2 = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$x = [Math]::Min([Math]::Max($wa2.Left, $iconForm.Right - $petBubble.Width), $wa2.Right - $petBubble.Width)
	$y = $iconForm.Top - $petBubble.Height - 8
	if ($bubble.Visible) { $y = $bubble.Top - $petBubble.Height - 6 } # 紅色的待決定對話框在，就疊在它上面
	if ($y -lt $wa2.Top) { $y = $iconForm.Bottom + 8 }
	$petBubble.Location = New-Object System.Drawing.Point($x, $y)
}
function Pet-Say([string]$text, [int]$ms = 5000) {
	if ($Snap -or $panel.Visible -or -not $iconForm.Visible) { return }
	$sz = [System.Windows.Forms.TextRenderer]::MeasureText($text, $FontBtn, (New-Object System.Drawing.Size(280, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
	$pl.Text = $text; $petBubble.Size = New-Object System.Drawing.Size(($sz.Width + 34), ($sz.Height + 22)); Round-Form $petBubble 14
	Place-PetBubble
	if (-not $petBubble.Visible) { $petBubble.Show() }
	$petHide.Stop(); $petHide.Interval = $ms; $petHide.Start()
}
function Pet-Fx([int]$ms) { $script:fxUntil = [Environment]::TickCount + $ms; Set-AnimRate; Show-Frame } # 開心：跳跳動作一陣子
function Pet-Refresh { Save-Pet; Update-Look; Set-AnimRate; Show-Frame }
function Pet-Bar([double]$v) { $n = [int][Math]::Round($v / 10); (('■' * $n) + ('□' * (10 - $n))) + (' {0}%' -f [int]$v) }
function Pet-Decay([double]$mins) {
	$p = $script:pet; $h = [double]$p.hunger; $m = [double]$p.mood; $e = [double]$p.energy
	if ($p.sleeping) { $e += 0.8 * $mins; $h -= 0.12 * $mins; $m -= 0.05 * $mins } else { $h -= 0.35 * $mins; $m -= 0.25 * $mins; $e -= 0.12 * $mins }
	if ($h -le 0) { $m -= 0.2 * $mins } # 餓過頭，心情掉更快
	$p.hunger = Pet-Clamp $h; $p.mood = Pet-Clamp $m; $p.energy = Pet-Clamp $e
}
function Pet-Wake([string]$msg) { if ($script:pet.sleeping) { $script:pet.sleeping = $false; Pet-Refresh; if ($msg) { Pet-Say $msg } } }
function Pet-Feed {
	if ($script:pet.sleeping) { Pet-Say 'Zzz…（睡著了，先別吵牠）'; return }
	if ([double]$script:pet.hunger -ge 95) { Pet-Say '吃不下了，肚子圓滾滾～'; return }
	$script:pet.hunger = Pet-Clamp ([double]$script:pet.hunger + 35); $script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 3); $script:pet.fed = [int]$script:pet.fed + 1
	Pet-Refresh; Pet-Fx 2500; Pet-Say '好好吃！謝謝～'
}
function Pet-Play {
	if ($script:pet.sleeping) { Pet-Say 'Zzz…（睡著了，先別吵牠）'; return }
	if ([double]$script:pet.energy -lt 15) { Pet-Say '太累了…想睡覺…'; return }
	$script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 25); $script:pet.energy = Pet-Clamp ([double]$script:pet.energy - 12); $script:pet.hunger = Pet-Clamp ([double]$script:pet.hunger - 6); $script:pet.played = [int]$script:pet.played + 1
	Pet-Refresh; Pet-Fx 5000; Pet-Say '耶！好好玩！再來再來～'
}
function Pet-Pat {
	if ($script:pet.sleeping) { Pet-Wake '嗯…被你摸醒了'; return }
	$script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 8)
	Pet-Refresh; Pet-Fx 1500; Pet-Say '呼嚕嚕～♥'
}
function Pet-ToggleSleep {
	if ($script:pet.sleeping) { Pet-Wake '早安！' }
	else { $script:pet.sleeping = $true; Pet-Refresh; Pet-Say 'Zzz…晚安～' }
}
function Pet-Status {
	$days = [int](((Now-Sec) - [double]$script:pet.born) / 86400) + 1
	$st = if ($script:pet.sleeping) { '（睡覺中）' } else { '' }
	Pet-Say ("{0} · 第 {1} 天 {2}`n飽足  {3}`n心情  {4}`n精神  {5}`n吃過 {6} 次、玩過 {7} 次" -f $script:pet.name, $days, $st, (Pet-Bar ([double]$script:pet.hunger)), (Pet-Bar ([double]$script:pet.mood)), (Pet-Bar ([double]$script:pet.energy)), [int]$script:pet.fed, [int]$script:pet.played) 9000
}
function Pet-Rename {
	Add-Type -AssemblyName Microsoft.VisualBasic
	$n = [Microsoft.VisualBasic.Interaction]::InputBox('幫牠取個名字：', '電子雞', [string]$script:pet.name)
	if ($n.Trim()) { $script:pet.name = $n.Trim().Substring(0, [Math]::Min(10, $n.Trim().Length)); Save-Pet; Pet-Say ('我叫{0}！' -f $script:pet.name) }
}
function Pet-Chatter { # 肚子餓／無聊／想睡時自己說一聲（同一句 20 分鐘內不重複；有待決定或清單開著時不吵你）
	if ($script:pet.sleeping -or $script:items.Count -gt 0 -or $panel.Visible) { return }
	foreach ($c in @(@('hunger', 30, '肚子餓了…（右鍵「電子雞」→ 餵食）'), @('mood', 30, '好無聊，陪我玩嘛～（右鍵「電子雞」→ 陪玩）'), @('energy', 15, '好想睡…（右鍵「電子雞」→ 哄睡覺）'))) {
		$last = if ($script:petSaid.ContainsKey($c[0])) { $script:petSaid[$c[0]] } else { [DateTime]::MinValue }
		if ([double]$script:pet[$c[0]] -lt $c[1] -and ([DateTime]::Now - $last).TotalMinutes -gt 20) { $script:petSaid[$c[0]] = [DateTime]::Now; Pet-Say $c[2] 6000; return }
	}
}
function Pet-Tick { # 每 30 秒一次：照過了多久把數字往下掉（關機期間最多算 3 小時，不懲罰你）
	if (-not $script:set.pet) { return }
	$now = Now-Sec; $mins = [Math]::Min(180.0, [Math]::Max(0.0, ($now - [double]$script:pet.last) / 60.0)); $script:pet.last = $now
	Pet-Decay $mins
	if ($script:pet.sleeping) { if ([double]$script:pet.energy -ge 98) { Pet-Wake '睡飽了～精神百倍！'; return } }
	elseif ([double]$script:pet.energy -lt 5) { $script:pet.sleeping = $true; Pet-Refresh; Pet-Say '撐不住了…Zzz'; return }
	Save-Pet; Pet-Chatter
}
$petTimer = New-Object System.Windows.Forms.Timer
$petTimer.Interval = 30000
$petTimer.Add_Tick({ Pet-Tick })

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
$ErrLog = Join-Path $DataDir 'error.log'
function Flush-Errors { # 事件裡出的錯不會跳視窗：每輪把累積的錯誤寫進 error.log（最多留最近 3 筆，避免洗版）
	if ($Error.Count -eq 0) { return }
	try { $Error | Select-Object -First 3 | ForEach-Object { Add-Content -Path $ErrLog -Value ("{0} widget: {1} @ {2}" -f (Get-Date -Format s), $_.Exception.Message, $_.InvocationInfo.PositionMessage) -Encoding UTF8 } } catch { }
	$Error.Clear()
}
$timer.Add_Tick({ $script:tick++; if ($script:tick % 2 -eq 0) { Run-Scan }; Refresh-Data; Flush-Errors })

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
		if ($script:curBmp) { $g.DrawImage($script:curBmp, $ix, $iy) }
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
$petTimer.Start()
if ($script:set.walk) { Go-Home }
$walk.Start()
$iconForm.Add_FormClosed({ if ($script:set.pet) { Save-Pet }; $panel.Close(); $bubble.Close(); $petBubble.Close() })
[System.Windows.Forms.Application]::Run($iconForm)
$mutex.ReleaseMutex()
