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
	List<RowItem> _items = new List<RowItem>(); public List<RowItem> Items { get { return _items; } set { _items = value ?? new List<RowItem>(); } } // 設成 null 也不會當掉
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
	int MaxScroll() { return Math.Max(0, (Items == null ? 0 : Items.Count) * RowHeight - Height); }
	public int HitTest(int y) { return IndexAt(y); }
	int IndexAt(int y) { if (Items == null) return -1; int i = (y + Scroll) / RowHeight; return (i >= 0 && i < Items.Count) ? i : -1; }
	public string LastError = "";
	protected override void OnPaint(PaintEventArgs e) { try { PaintBody(e); } catch (Exception ex) { LastError = ex.ToString(); } } // 畫圖出一次錯就會永久變成紅色大叉叉：吞掉、記下原因，下次重畫
	void PaintBody(PaintEventArgs e) {
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
		int total = Items.Count * RowHeight;
			if (Scroll > Math.Max(0, total - Height)) Scroll = Math.Max(0, total - Height); // 清單變短時別卡在空白處
			for (int i = 0; i < Items.Count; i++) {
			int y = i * RowHeight - Scroll;
			if (y + RowHeight < 0 || y > Height) continue;
			RowItem it = Items[i]; if (it == null) continue;
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
		if (total > Height && Height > 0) { // 一次只顯示幾列：右邊一條細細的捲軸提示還有更多（滾輪捲動）
			int th = Math.Max(28, (int)((long)Height * Height / total));
			int ty = (int)((long)(Height - th) * Scroll / (total - Height));
			using (SolidBrush b = new SolidBrush(Color.FromArgb(160, Muted))) { g.FillRectangle(b, Width - 7, ty + 3, 4, th - 6); }
		}
	}
	protected override void OnMouseEnter(EventArgs e) { if (!Focused) Focus(); base.OnMouseEnter(e); } // 滑鼠移進來就能用滾輪
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
$script:set = @{ icon = 'bell.png'; message = '有待決定囉！'; hideWhenZero = $false; sound = $true; walk = $false; pet = $false; x = $null; y = $null; perch = $false; autoShrink = $true; openOnHover = $false; panelHide = 0; shrinkAfter = 20; idleAfter = 8; idle = @('juggle', 'heart', 'sway', 'zzz') }
try { if (Test-Path $SetFile) { $j = Get-Content $SetFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @('icon', 'message', 'hideWhenZero', 'sound', 'walk', 'pet', 'x', 'y', 'perch', 'autoShrink', 'panelHide', 'shrinkAfter', 'idleAfter', 'openOnHover', 'idle')) { if ($null -ne $j.$k) { $script:set[$k] = $j.$k } } } } catch { }
function Save-Settings { try { ($script:set | ConvertTo-Json) | Set-Content -Path $SetFile -Encoding UTF8 } catch { } }

function Load-Img([string]$path) { # 讀進記憶體再解碼，不鎖檔
	$bytes = [System.IO.File]::ReadAllBytes($path)
	return [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes)))
}
function Icon-Files { # 內建＋使用者自己的
	$all = @()
	# 動畫圖示＝多張 名稱@1.png、名稱@2.png…（可加 名稱@idle1.png… 當沒待決定時的待機動作），清單只列第一張
	foreach ($d in @($BuiltinIconDir, $UserIconDir)) { if (Test-Path $d) { $all += Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|gif|bmp|ico)$' -and $_.Name -notmatch '@(idle\d+|[02-9]|[1-9]\d+)\.png$' } | Sort-Object Name } }
	return @($all | Group-Object Name | ForEach-Object { $_.Group[0] }) # 內建與使用者資料夾同名時只列一次（Find-Icon 仍優先用使用者那份）
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
# 存起來的位置不保證還在畫面上：換解析度、拔掉外接螢幕、或被拖到工作列下面之後，
# 直接照用就會整隻看不到（2026-11-04 實際遇到：小橘常常掉到畫面以下）。
# 先找涵蓋這個點的螢幕，都不涵蓋就回主螢幕，再把座標夾回該螢幕的可用範圍。
# 下緣容許 $RunwayPad，跟 Runway-Y 同值，免得把走路模式的正常站位往上推。
$RunwayPad = 16
$pt0 = New-Object System.Drawing.Point($px, $py)
$scr0 = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($pt0) } | Select-Object -First 1
if (-not $scr0) { $scr0 = [System.Windows.Forms.Screen]::PrimaryScreen }
$w0 = $scr0.WorkingArea
$px = [Math]::Min([Math]::Max($px, $w0.Left), [Math]::Max($w0.Left, $w0.Right - $IconBox))
$py = [Math]::Min([Math]::Max($py, $w0.Top), [Math]::Max($w0.Top, $w0.Bottom - $IconBox + $RunwayPad))
$iconForm.Location = New-Object System.Drawing.Point($px, $py)
function Snap-OnScreen { # 把浮窗夾回畫面內。拖到畫面外放開會彈回來，也保證不會把看不到的座標存起來
	$pt1 = New-Object System.Drawing.Point($iconForm.Left, $iconForm.Top)
	$s1 = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($pt1) } | Select-Object -First 1
	if (-not $s1) { $s1 = [System.Windows.Forms.Screen]::FromControl($iconForm) }
	$w1 = $s1.WorkingArea
	$nx1 = [Math]::Min([Math]::Max($iconForm.Left, $w1.Left), [Math]::Max($w1.Left, $w1.Right - $IconBox))
	$ny1 = [Math]::Min([Math]::Max($iconForm.Top, $w1.Top), [Math]::Max($w1.Top, $w1.Bottom - $IconBox + 16))
	if ($nx1 -ne $iconForm.Left -or $ny1 -ne $iconForm.Top) { $iconForm.Location = New-Object System.Drawing.Point($nx1, $ny1) }
}
$script:frames = @(); $script:idleFrames = @(); $script:badgeShown = -1; $script:fIdx = 0; $script:fCache = @{}
$script:curBmp = $null; $script:iconAlpha = 255; $script:moving = $false; $script:fxUntil = 0; $script:fxKind = ''
$script:shrink = 0.0; $script:collapsed = $false; $script:lastActive = [Environment]::TickCount; $script:nextIdleAct = [Environment]::TickCount + 12000; $script:panelAt = [Environment]::TickCount # 沒人理就慢慢縮小、把小工具收起來；滑鼠移上去或有新通知就展開
function Pet-Asleep { [bool]($script:set.pet -and $script:pet.sleeping) }
$IdleActs = @(@('juggle', '托球（在紅圈上彈球）'), @('bat', '打棒球（揮棒把球打飛）'), @('jump', '原地跳跳'), @('music', '唱歌（冒音符）'), @('sparkle', '閃閃發亮'), @('bubble', '吹泡泡'), @('heart', '冒愛心'), @('sway', '左右搖擺跳舞'), @('zzz', '打盹'))
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
function Build-Frame($img, [int]$count, [string]$ov = '', [int]$lvl = 4, [int]$fi = 0, [double]$sc = 1.0) { # 一格圖＋右上角紅色數字＋（電子雞）成長大小、皇冠、動作小圖
	$bmp = New-Object System.Drawing.Bitmap($IconBox, $IconBox, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
	$g.Clear([System.Drawing.Color]::Transparent)
	$full = 74
	$size = [int]($full * $sc * @(0.74, 0.84, 0.92, 1.0, 1.0)[[Math]::Min(4, [Math]::Max(0, $lvl - 1))]) # 越養越大；沒人理時再縮小（$sc）
	$ratio = [Math]::Min($size / $img.Width, $size / $img.Height); $w = [int]($img.Width * $ratio); $h = [int]($img.Height * $ratio)
	$cx = 2 + $full / 2; $topY = $IconBox - 2 - $h
	$sw = $(if ($ov -eq 'sway') { [int](7 * [Math]::Sin($fi * 1.3)) } else { 0 }); $jy = $(if ($ov -eq 'jump') { [int](-14 * [Math]::Abs([Math]::Sin($fi * 0.8))) } else { 0 }); $g.DrawImage($img, 2 + [int](($full - $w) / 2) + $sw, $topY + $jy, $w, $h)
	if ($lvl -ge 5) { # 最高級：頭上戴皇冠
		$cr = [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($cx - 12), $topY)), (New-Object System.Drawing.PointF(($cx - 12), ($topY - 12))), (New-Object System.Drawing.PointF(($cx - 6), ($topY - 5))), (New-Object System.Drawing.PointF($cx, ($topY - 15))), (New-Object System.Drawing.PointF(($cx + 6), ($topY - 5))), (New-Object System.Drawing.PointF(($cx + 12), ($topY - 12))), (New-Object System.Drawing.PointF(($cx + 12), $topY)))
		$g.FillPolygon((New-Object System.Drawing.SolidBrush((RGB '#FFC933'))), $cr)
	}
	switch ($ov) {
		'heart' { for ($k = 0; $k -lt 3; $k++) { $hy = $topY - 4 - (($fi * 5 + $k * 11) % 28); $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 232, 64, 122))), (Heart-Path (12 + $k * 22) $hy 6)) } }
		'eat' { $s = 1.0 - ($fi % 6) * 0.14; $ox = $cx - 38; $oy = $topY + 22
			$pts = [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF($ox, ($oy - 10 * $s))), (New-Object System.Drawing.PointF(($ox + 11 * $s), ($oy + 8 * $s))), (New-Object System.Drawing.PointF(($ox - 11 * $s), ($oy + 8 * $s))))
			$g.FillPolygon([System.Drawing.Brushes]::White, $pts); $g.FillRectangle((New-Object System.Drawing.SolidBrush((RGB '#2B2F36'))), ($ox - 5 * $s), ($oy + 1 * $s), (10 * $s), (7 * $s)) }
		'play' { $bx = 8 + ($fi % 6) * 11; $by = $topY + 8 - [Math]::Abs([Math]::Sin($fi * 0.9)) * 22
			$g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#E5533D'))), $bx, $by, 14, 14); $g.DrawArc((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)), ($bx + 3), ($by + 3), 8, 8, 200, 70) }
		'zzz' { $b = ($fi % 2) * 3; $zc = New-Object System.Drawing.SolidBrush((RGB '#9DB8E8')); $g.DrawString('z', (Font 10 $true), $zc, ($cx + 16), ($topY - 6 - $b)); $g.DrawString('Z', (Font 14 $true), $zc, ($cx + 26), ($topY - 22 - $b)) }
		'bat' { $p = $fi % 8; $px = $cx + 6; $py = $topY + $h * 0.55; $ang = @(-75, -75, -70, -55, -25, 10, 45, 60)[$p]; $rad = $ang * [Math]::PI / 180
			$g.DrawLine((New-Object System.Drawing.Pen((RGB '#C68B4A'), 5)), $px, $py, ($px + 30 * [Math]::Cos($rad)), ($py + 30 * [Math]::Sin($rad)))
			if ($p -le 5) { $bx = 92 - $p * 5; $by = $py - 2 } else { $bx = 67 + ($p - 5) * 10; $by = $py - 2 - ($p - 5) * 10 }
			$g.FillEllipse([System.Drawing.Brushes]::White, ($bx - 5), ($by - 5), 10, 10); $g.DrawArc((New-Object System.Drawing.Pen((RGB '#D94A3A'), 1.2)), ($bx - 3), ($by - 3), 6, 6, 200, 130)
			if ($p -eq 5) { $g.DrawString('!', (Font 12 $true), (New-Object System.Drawing.SolidBrush((RGB '#FFC933'))), ($bx - 4), ($by - 24)) } }
		'music' { for ($k = 0; $k -lt 3; $k++) { $ny = $topY - 2 - (($fi * 4 + $k * 13) % 30); $nx = 10 + $k * 22 + [int](4 * [Math]::Sin($fi * 0.7 + $k)); $g.DrawString([string][char]0x266A, (Font 14 $true), (New-Object System.Drawing.SolidBrush((RGB '#7FB0EE'))), $nx, $ny) } }
		'sparkle' { for ($k = 0; $k -lt 4; $k++) { $sz = 8 + (($fi + $k * 2) % 4) * 2; $g.DrawString([string][char]0x2726, (Font $sz $true), (New-Object System.Drawing.SolidBrush((RGB '#FFC933'))), (6 + $k * 20), ($topY - 8 + (($k * 17 + $fi * 3) % 40))) } }
		'bubble' { for ($k = 0; $k -lt 4; $k++) { $by2 = $topY + 6 - (($fi * 4 + $k * 11) % 44); $r2 = 4 + (($k + $fi) % 3) * 2; $bx2 = $cx + 14 + $k * 7 + [int](3 * [Math]::Sin($fi * 0.6 + $k)); $g.DrawEllipse((New-Object System.Drawing.Pen((RGB '#8DB4E8'), 1.5)), $bx2, $by2, $r2 * 2, $r2 * 2) } }
		'sad' { $g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#6DB3F2'))), ($cx + 18), ($topY + 6 + ($fi % 2) * 2), 8, 12) }
	}
	$jug = ($ov -eq 'juggle') # 托球：紅圈往下移一點，球在圈上彈
	if ($count -gt 0 -or $jug) {
		$d = [int](34 * [Math]::Max(0.62, $sc)); $bx = $IconBox - $d - 3; $by = $(if ($jug) { 24 } else { 3 }) # 圈圈（含白邊）完整留在圖裡，不再被切掉
		$g.FillEllipse([System.Drawing.Brushes]::White, ($bx - 2), ($by - 2), ($d + 4), ($d + 4))
		$g.FillEllipse((New-Object System.Drawing.SolidBrush($Red)), $bx, $by, $d, $d)
		$txt = if ($count -gt 9) { '9+' } else { [string]$count }
		$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
		if ($count -gt 0) { $g.DrawString($txt, (Font ([Math]::Max(8, [int](13 * [Math]::Max(0.62, $sc)))) $true), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($bx, ($by + 1), $d, $d)), $sf) }
		if ($jug) { $bo = [Math]::Abs([Math]::Sin($fi * 0.9)) * 9; $g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#FFD34D'))), ($bx + [int]($d / 2) - 6), ($by - 13 - $bo), 12, 12); $g.DrawArc((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)), ($bx + [int]($d / 2) - 3), ($by - 10 - $bo), 6, 6, 200, 70) }
	}
	$g.Dispose()
	return $bmp
}
function Show-Frame { # 顯示目前這一格（算過的存起來；數字或圖換了才重算）
	$useIdle = ($script:badgeShown -le 0 -and -not $script:moving -and -not (Pet-Fx-On) -and $script:idleFrames.Count -gt 0) # 沒事又沒在走＝待機動作；有事或在走＝跳跳動作
	$seq = if ($useIdle) { $script:idleFrames } else { $script:frames }
	if ($seq.Count -eq 0) { return }
	$i = $script:fIdx % $seq.Count; $ov = Pet-Overlay; $lv = Pet-Level
	$sq = [int]($script:shrink * 10); $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $(if ($useIdle) { 'i' } else { 'a' }), $i, $script:badgeShown, $ov, $lv, $sq, $(if ($ov) { $script:fIdx % 6 } else { 0 })
	if (-not $script:fCache.ContainsKey($key)) { $script:fCache[$key] = Build-Frame $seq[$i] ([Math]::Max(0, $script:badgeShown)) $ov $lv $script:fIdx (1.0 - 0.045 * $sq) }
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
	if (-not $Snap -and ($script:frames.Count -gt 1 -or $script:idleFrames.Count -gt 1 -or $script:set.pet)) { $anim.Start() } else { $anim.Stop() }
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
$btnShot = Flat-Button '截圖' 56 30 $false; $btnShot.Location = New-Object System.Drawing.Point(188, 9)
$hint = New-Object System.Windows.Forms.Label
$hint.Text = '雙擊一列＝打開那個對話'; $hint.AutoSize = $true; $hint.ForeColor = $T.muted; $hint.Font = $FontSub; $hint.Location = New-Object System.Drawing.Point(252, 16)
$foot.Controls.AddRange(@($btnWeb, $btnSet, $btnShot, $hint, $btnHide))
$panel.Controls.Add($list); $panel.Controls.Add($foot); $panel.Controls.Add($head)

$script:items = @(); $script:lastCount = 0; $script:status = $null
$script:tab = 'pending'; $script:recent = $null; $script:recentStamp = 0
$TabsH = 38
$tabDefs = @(@('pending', '待決定'), @('running', '進行中'), @('broken', '中斷'), @('sessions', '最近對話'), @('projects', '專案'), @('files', '最近檔案'), @('dirs', '資料夾'))
$tabs = New-Object System.Windows.Forms.Panel
$tabs.Dock = 'Top'; $tabs.Height = $TabsH; $tabs.BackColor = $T.surface; $tabs.Cursor = 'Hand'
$tabs.Add_Paint({
	param($s, $e)
	$g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
	$w = $s.Width / $tabDefs.Count
	for ($i = 0; $i -lt $tabDefs.Count; $i++) {
		$on = ($tabDefs[$i][0] -eq $script:tab)
		$label = $tabDefs[$i][1]; if ($i -eq 0 -and $script:headCount -gt 0) { $label = "$label ($($script:headCount))" } elseif ($tabDefs[$i][0] -eq 'broken' -and $script:recent -and @($script:recent.broken).Count -gt 0) { $label = "$label ($(@($script:recent.broken).Count))" } elseif ($tabDefs[$i][0] -eq 'running' -and (Running-Count) -gt 0) { $label = "$label ($(Running-Count))" }
		$col = if ($on) { $T.fg } else { $T.muted }
		[System.Windows.Forms.TextRenderer]::DrawText($g, $label, $(if ($on) { $FontTitle } else { $FontSub }), (New-Object System.Drawing.Rectangle([int]($i * $w), 0, [int]$w, ($TabsH - 3))), $col, [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
		if ($on) { $g.FillRectangle((New-Object System.Drawing.SolidBrush($T.accent)), [int]($i * $w + 14), ($TabsH - 3), [int]($w - 28), 3) }
	}
})
$tabs.Add_MouseUp({ param($s, $e) if ($script:pdMoved) { return }; $i =[Math]::Min($tabDefs.Count - 1, [Math]::Max(0, [int][Math]::Floor($e.X / ($s.Width / $tabDefs.Count)))); $script:tab = $tabDefs[$i][0]; Rebuild-List; Show-Panel })
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
	$rows = [Math]::Max(0, [Math]::Min(3, $list.Items.Count))
	$body = if ($rows -eq 0) { 120 } else { $list.RowHeight * $rows }
	$panel.Size = New-Object System.Drawing.Size($PW, ($HeaderH + $TabsH + $body + $FooterH))
	if (-not $panel.IsHandleCreated) { [void]$panel.Handle; Round-Form $panel 14 } else { Round-Form $panel 14 }
	Place-Around
	$bubble.Hide(); $petBubble.Hide()
	if (-not $Snap -and -not $panel.Visible) { $panel.Show() }
	$head.Invalidate()
}
function Update-Look {
	if ($script:shooting) { return }
	$n = $script:items.Count
	if ($n -gt 0) {
		$msg = [string]$script:set.message
		Set-Bubble ("{0}  ·  {1} 件" -f $msg, $n)
		$script:iconAlpha = 255
		if ($script:collapsed -and -not $panel.Visible) { $bubble.Hide() } elseif (-not $panel.Visible) { Place-Around; if (-not $Snap -and -not $bubble.Visible) { $bubble.Show() } }
	} else {
		$bubble.Hide(); $script:iconAlpha = $(if (Pet-Asleep) { 90 } else { 153 })
		if ($panel.Visible) { $panel.Hide() }
	}
	if ($n -ne $script:badgeShown) { Compose-Icon $n } else { Show-Frame }
	if ($Snap) { return }
	if ($n -eq 0 -and $script:set.hideWhenZero) { if ($iconForm.Visible) { $iconForm.Hide() } } else { if (-not $iconForm.Visible) { $iconForm.Show() } }
	Tray-Update
}
function Empty-Messages { # 空狀態與錯誤的文案
	if ($script:tab -eq 'running' -and $script:recent) { return @('可以關機了', '沒有對話在做事，也沒有下載、轉檔之類的背景程式，這時關機不會中斷任何事。') }
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
				if ($it.kind -eq 'wrapup' -and $q) { $q = '▶ 雙擊直接點按鈕：' + $q }
				if ($it.qid -and [double]$it.qUntil -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { $q = '▶ 雙擊直接點選項：' + $q } # 手機與小工具都能答（先點先贏）
				if ($it.kind -eq 'permission') { $label = '要你允許'; $col = $T.amber } elseif ($it.kind -eq 'wrapup') { $label = '要你決定'; $col = $T.blue } elseif ($it.kind -eq 'fable') { $label = 'Fable 提醒'; $col = $T.accent } elseif ($it.kind -eq 'proposal') { $label = '等你按開始'; $col = $T.blue } elseif ($it.kind -eq 'usage') { $label = $it.label; $col = $(if ($it.level -ge 2) { $T.accent } else { $T.amber }) }
				$row = New-Row $title $label $col $q (Age-Text ([double]$it.at)) ([string]$it.local) $(if ($it.kind -eq 'proposal') { "$title`n$q`n（右鍵 → 知道了：這張卡不再提醒）" } else { '' })
				if ($it.kind -eq 'fable') { $row.Extra = [string]$it.sid } elseif ($it.kind -eq 'proposal') { $row.Extra = [string]$it.id }
				[void]$rows.Add($row)
			}
		}
		'running' { if ($script:recent) { $pn = @(Get-PausableRuns).Count; [void]$rows.Add((New-Row '■ 全部暫停' '一鍵' $T.accent ('關機前用：電腦逐個替使用者按各對話的「停止」（目前可停 ' + $pn + ' 個；會先問 使用者）') '' 'pause-all' "關機、拔外接硬碟前，請所有正在跑的對話停手`n點這一列：確認後，電腦會逐個切到那個對話、替使用者按輸入框右邊的「停止」鍵（不是強制關閉）`n停成功的會記起來，之後按「全部繼續」才會叫醒它們`n在等使用者回答的對話不會被碰；結果記在 data 資料夾的 pause.log")); $rn = Paused-Count; [void]$rows.Add((New-Row '▶ 全部繼續' '一鍵' $T.accent ('叫醒剛剛暫停成功的對話（目前 ' + $rn + ' 個；會先問 使用者；每個要重讀整段對話，花額度）') '' 'resume-all' "把剛剛「全部暫停」停成功的對話叫醒，請它們從停下的地方接著做`n點這一列：確認後，在背景替每個對話送一句固定的話（和「全部重新啟動」同一招）")) }; if ((Running-Count) -gt 0) { [void]$rows.Add((New-Row '先別關機' '提示' $T.accent ('還有 ' + (Running-Count) + ' 件在跑，現在關機會中斷它們' + $(if (@($script:recent.running | Where-Object { $_.fable }).Count -gt 0) { '（⚠ 有對話正在用 Fable）' } else { '' })) '' '' '')) }; if ($script:recent) { foreach ($x in @($script:recent.running)) { $sub = '正在：' + $(if ($x.doing) { [string]$x.doing } else { '（不明）' }); if ($x.fable) { $sub = '⚠ 正在用 Fable｜' + $sub }; [void]$rows.Add((New-Row ([string]$x.title) '跑著' $(if ($x.fable) { $T.accent } else { $T.amber }) $sub (Age-Text ([double]$x.at)) ([string]$x.local) ("{0}`n{1}`n{2}" -f $x.title, $x.cwd, $sub))) } }
		# 背景程式也列在這頁（對話回完了、程式還在跑）
		foreach ($w in @($script:workers)) { [void]$rows.Add((New-Row ([string]$w.title) '背景' $T.blue $(if ($w.sub -and $w.sub -ne $w.title) { [string]$w.sub } elseif ($w.dir) { Short-Dir ([string]$w.dir) } else { '（程式 ' + $w.pid + '）' }) (Age-Text ([double]$w.at)) ($(if ($ses = Find-WorkerSession $w) { 'ses:' + $ses } elseif ($w.dir) { 'dir:' + $w.dir } else { '' })) ("{0}`n{1}" -f $w.title, $w.cmd))) } }
		'broken' { if ($script:recent) { if (@($script:recent.broken).Count -gt 0) { [void]$rows.Add((New-Row '▶ 全部重新啟動' '一鍵' $T.accent ('一鍵叫醒下面中斷的對話（一次最多 3 個，會先問你；在背景接著做，不會跳視窗）') '' 'restart-all' "把「中斷」的對話全部叫醒
點這一列：確認後，在背景替每個中斷的對話送「請從中斷處接著做」
一次最多 3 個；結果記在 data 資料夾的 restart.log")) }; foreach ($x in @($script:recent.broken)) { $proj = if ($x.cwd) { Split-Path ([string]$x.cwd) -Leaf } else { '' }; $sub = '停在：' + $(if ($x.stopped) { [string]$x.stopped } else { '（不明）' }); [void]$rows.Add((New-Row ([string]$x.title) '停住了' $T.accent $sub (Age-Text ([double]$x.at)) ([string]$x.local) ("{0}`n{1}`n{2}`n它最後說：{3}" -f $x.title, $x.cwd, $sub, $x.said))) } } }
		'sessions' { if ($script:recent) { foreach ($x in @($script:recent.sessions)) { $proj = if ($x.cwd) { Split-Path ([string]$x.cwd) -Leaf } else { '' }; $sub = (@($proj, [string]$x.last) | Where-Object { $_ }) -join '  ·  '; [void]$rows.Add((New-Row ([string]$x.title) '對話' $T.blue $sub (Age-Text ([double]$x.at)) ([string]$x.local) ("{0}`n{1}`n{2}" -f $x.title, $x.cwd, $x.last))) } } }
		'projects' { if ($script:recent) { foreach ($x in @($script:recent.projects)) { $leaf = Split-Path ([string]$x.path) -Leaf; if (-not $leaf) { $leaf = [string]$x.path }; [void]$rows.Add((New-Row $leaf ("{0} 個對話" -f $x.count) $T.accent ((@($x.titles) | Where-Object { $_ }) -join '、') (Age-Text ([double]$x.at)) ([string]$x.path) ([string]$x.path))) } } }
		'files' { if ($script:recent) { foreach ($x in @($script:recent.files)) { [void]$rows.Add((New-Row ([System.IO.Path]::GetFileName([string]$x.path)) '檔案' $T.accent (Short-Dir ([System.IO.Path]::GetDirectoryName([string]$x.path))) (Age-Text ([double]$x.at)) ([string]$x.path) ([string]$x.path))) } } }
		'dirs' { if ($script:recent) { foreach ($x in @($script:recent.dirs)) { $leaf = Split-Path ([string]$x.path) -Leaf; if (-not $leaf) { $leaf = [string]$x.path }; [void]$rows.Add((New-Row $leaf '資料夾' $T.amber (Short-Dir ([string]$x.path)) (Age-Text ([double]$x.at)) ([string]$x.path) ([string]$x.path))) } } }
	}
	return $rows
}
function Rebuild-List {
	$list.SingleClick = ($script:tab -ne 'pending')
	$newItems = New-Object 'System.Collections.Generic.List[RowItem]' # 一列一列加進去：直接把陣列指給 Items 偶爾會報「無法將 Object[] 轉成 RowItem」（error.log 一直出現），而且沒有任何一列時 Tab-Rows 什麼都不回傳，這樣寫兩種情況都安全
	foreach ($nr in @(Tab-Rows)) { if ($nr -is [RowItem]) { [void]$newItems.Add($nr) } elseif ($nr -is [System.Collections.IEnumerable]) { foreach ($nr2 in $nr) { if ($nr2 -is [RowItem]) { [void]$newItems.Add($nr2) } } } }
	$list.Items = $newItems
	if ($script:listTab -ne $script:tab) { $list.Scroll = 0; $script:listTab = $script:tab } # 每 3 秒會重建一次：只有換分頁才回到最上面，不然捲到一半就彈回去
	$em = Empty-Messages; $list.EmptyTitle = $em[0]; $list.EmptyText = $em[1]
	$hint.Text = switch ($script:tab) { 'pending' { '雙擊＝開對話' } 'running' { '點＝跳到那個對話' } 'broken' { '點＝開對話＋複製' } 'sessions' { '點＝開對話' } 'projects' { '點＝開資料夾' } 'files' { '點一下＝找到檔案' } 'dirs' { '點一下＝開資料夾' } }
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
	$b = $(if ($Config -and $Config.notify -and $Config.notify.usage -eq $false) { $null } else { Usage-Pct }) # config.json 的 notify.usage 設 false＝關掉額度警示（改完要重開浮窗）
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
function Dismiss-Fable([string]$sid, [int]$hours = 12) { # 「知道了」：這個對話 12 小時內不再提醒 Fable；建議任務卡片傳 hours 更長
	if (-not $sid) { return }
	try {
		$d = @{}; if (Test-Path $DismissFile) { $j = (Get-Content $DismissFile -Raw -Encoding UTF8) | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $d[$p.Name] = $p.Value } }
		$d[$sid] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $hours * 3600000
		($d | ConvertTo-Json) | Set-Content -Path $DismissFile -Encoding UTF8
	} catch { }
	Run-Scan
}
# 背景程式：電腦上現在還在跑的工作（下載、轉檔、備份、腳本…）；對話回完了它們還在跑，關機會中斷
$script:workers = @(); $script:workersAt = [DateTime]::MinValue; $script:lastAct = [DateTime]::MinValue
$WorkerSkip = 'gemini-mcp-tool|npx-cli\.js|codex-runtimes|claude-code|pending-decisions|-NoExit|dev-mods|Claude_Browser|\\mcp'
function Running-Count { $a = 0; if ($script:recent -and $script:recent.running) { $a = @($script:recent.running).Count }; return ($a + @($script:workers).Count) }
function Find-WorkerSession($w) { # 這個背景程式是哪個對話開的：先比程式檔名出現在誰的指令／檔案，再比資料夾落在誰的工作資料夾底下
	if (-not $script:recent) { return '' }
	$name = [string]$w.title
	if ($name -and $name -match '\.(mjs|js|py|ps1|cmd|bat)$') {
		foreach ($x in @($script:recent.runs)) { if ($x.local -and ([string]$x.cmd).Contains($name)) { return [string]$x.local } }
		foreach ($x in @($script:recent.files)) { if ($x.local -and ([string]$x.path).EndsWith($name, [StringComparison]::OrdinalIgnoreCase)) { return [string]$x.local } }
	}
	if ($w.dir) { $best = ''; $bl = 0; foreach ($x in @($script:recent.sessions)) { $c = [string]$x.cwd; if ($x.local -and $c.Length -gt $bl -and ([string]$w.dir).StartsWith($c, [StringComparison]::OrdinalIgnoreCase)) { $best = [string]$x.local; $bl = $c.Length } }; if ($best) { return $best } }
	return ''
}
function Read-Workers { # 每 15 秒查一次；剛啟動不到 20 秒的先不算（避免短指令一閃而過）
	if (([DateTime]::Now - $script:workersAt).TotalSeconds -lt 15) { return }
	$script:workersAt = [DateTime]::Now
	try {
		$out = New-Object System.Collections.ArrayList
		$flt = "Name='node.exe' OR Name='python.exe' OR Name='pythonw.exe' OR Name='py.exe' OR Name='ffmpeg.exe' OR Name='robocopy.exe' OR Name='rclone.exe' OR Name='curl.exe' OR Name='wget.exe' OR Name='7z.exe' OR Name='powershell.exe' OR Name='pwsh.exe'"
		foreach ($p in @(Get-CimInstance Win32_Process -Filter $flt -ErrorAction Stop)) {
			$cmd = [string]$p.CommandLine
			if (-not $cmd -or $p.ProcessId -eq $PID -or $cmd -match $WorkerSkip) { continue }
			if ($p.Name -match 'powershell|pwsh' -and $cmd -notmatch '-File|-Command') { continue }
			if (-not $p.CreationDate -or ([DateTime]::Now - $p.CreationDate).TotalSeconds -lt 20) { continue }
			$m = [regex]::Match($cmd, '"([^"]+\.(mjs|js|py|ps1|cmd|bat))"|(\S+\.(mjs|js|py|ps1|cmd|bat))')
			$scr = if ($m.Success) { $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[3].Value }) } else { '' }
			$dir = ''; if ($scr -and [System.IO.Path]::IsPathRooted($scr)) { try { $dir = [System.IO.Path]::GetDirectoryName($scr) } catch { } }
			$args1 = ($cmd -replace '^"[^"]+"\s*', '' -replace '^\S+\s*', '').Trim(); if ($args1.Length -gt 110) { $args1 = $args1.Substring(0, 110) + '…' }
			[void]$out.Add([pscustomobject]@{ title = $(if ($scr) { [System.IO.Path]::GetFileName($scr) } else { [string]$p.Name }); pid = [int]$p.ProcessId; at = [double]([DateTimeOffset]$p.CreationDate).ToUnixTimeMilliseconds(); sub = $args1; cmd = $cmd; dir = $dir })
		}
		$script:workers = @($out | Sort-Object at)
	} catch { }
}
function Refresh-Data {
	$items = @()
	try { if (Test-Path $StateFile) { $j = (Get-Content $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json; $items = @($j.items | Where-Object { $_.status -eq 'pending' } | Sort-Object { [double]$_.at } -Descending) } } catch { }
	try { if (Test-Path $StatusFile) { $script:status = (Get-Content $StatusFile -Raw -Encoding UTF8) | ConvertFrom-Json } } catch { }
	if (-not (Q-Flags).widget) { $items = @($items | Where-Object { $_.kind }) } # 小工具選項框開關：關＝不列選項框（沒有 kind 的就是選項框）
	$items = @(Usage-Items) + @($items) # 額度警示排在最前面
	$script:items = $items
	$n = $items.Count
	$script:headCount = $n; $head.Invalidate()
	Read-Recent
	Read-Workers
	Rebuild-List
	if ($n -gt $script:lastCount) { Pet-Wake ''; # 有新的：叮一聲＋圖抖一下
		if ($script:set.sound) { try { [System.Media.SystemSounds]::Exclamation.Play() } catch { } }
		$script:shakeStep = 0; $script:shakeX = $iconForm.Left; $shake.Start()
		$script:lastActive = [Environment]::TickCount # 新通知：展開、重新計時
	}
	if ($n -lt $script:lastCount -and $script:set.pet -and ([DateTime]::Now - $script:lastDecXp).TotalMinutes -ge 3) { $script:lastDecXp = [DateTime]::Now; Pet-Gain 6 '處理好了！' }
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
	if ($script:fight) { if (-not $script:moved) { Fight-Guard }; $script:down = $null; $script:moved = $false; return } # 打架時點小橘＝閃躲
	if ($script:moved) { Snap-OnScreen; $script:set.x = $iconForm.Left; $script:set.y = $iconForm.Top; $script:set.perch = ([Math]::Abs($iconForm.Top - (Runway-Y)) -gt 30); Save-Settings } # 畫面任何位置都能放；走路模式下拖離跑道＝牠就停在那裡不亂走，拖回跑道附近才繼續走
	elseif ($script:set.pet -and $script:pet.sleeping) { Pet-Wake '早安～被你叫醒了！' } # 睡著時點一下牠＝叫醒（再點一下才開清單）
	else { if ($panel.Visible) { $panel.Hide(); Update-Look } else { Show-Panel } }
	$script:down = $null
})
$bl.Add_Click({ if (-not $script:pdMoved) { Show-Panel } })
$btnHide.Add_Click({ $panel.Hide(); Update-Look })
$btnWeb.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
function Restart-AllBroken {
	$exe = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'
	if (-not (Test-Path -LiteralPath $exe)) { Pet-Say '找不到 claude.exe，改用 /restart-broken' 6000; try { [System.Windows.Forms.Clipboard]::SetText('/restart-broken') } catch { }; return }
	if (-not $script:wokeAt) { $script:wokeAt = @{} }
	$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$cand = New-Object System.Collections.ArrayList
	foreach ($x in @($script:recent.broken)) {
		if (-not $x.sid -or $x.run) { continue }
		if ([string]$x.stopped -match '^你說：' -and [string]$x.stopped -match 'system-reminder') { continue }
		if ($script:wokeAt.ContainsKey([string]$x.sid) -and ($now - $script:wokeAt[[string]$x.sid]) -lt 600000) { continue }
		if (Woke-Recently ([string]$x.sid)) { continue } # 手機叫醒過的也算（共用 restart.log）
		[void]$cand.Add($x)
	}
	if ($cand.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($(if ($waiting -gt 0) { '沒有要停的：有 ' + $waiting + ' 個對話正在等使用者回答選項框，它們本來就停著，不用按停止。' } else { '目前沒有正在跑的對話，不需要暫停。' }) + [Environment]::NewLine + [Environment]::NewLine + '（只算「正在執行中」的對話；背景程式不會被停）', '全部暫停', 'OK', 'Information'); return }
	$pick = @($cand | Select-Object -First 3)
	$names = ($pick | ForEach-Object { '・' + [string]$_.title }) -join [Environment]::NewLine
	$more = if ($cand.Count -gt 3) { [Environment]::NewLine + '（另外還有 ' + ($cand.Count - 3) + ' 個，這次先不叫）' } else { '' }
	$msg = '要在背景叫醒這 ' + $pick.Count + ' 個對話嗎？' + [Environment]::NewLine + [Environment]::NewLine + $names + $more + [Environment]::NewLine + [Environment]::NewLine + '每個都要重讀整段對話（花額度）；它們在背景接著做，沒有權限的動作會被擋住。'
	if ([System.Windows.Forms.MessageBox]::Show($msg, '全部重新啟動', 'YesNo', 'Question') -ne 'Yes') { return }
	$text = '剛剛好像斷線或中斷了。請先看紀錄，確認你上一步做到哪，已經做完的不要重做，沒做完的從那裡接著做，做完用一句話跟我說。'
	$log = Join-Path $DataDir 'restart.log'
	$ok = 0
	foreach ($x in $pick) {
		try {
			$cwd = [string]$x.cwd
			$pj = Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.claude\projects') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName ($x.sid + '.jsonl') } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
			if ($pj) { $m = Select-String -LiteralPath $pj -Pattern '"cwd":"((?:[^"\\]|\\.)*)"' -List | Select-Object -First 1; if ($m) { $cwd = ($m.Matches[0].Groups[1].Value -replace '\\\\', '\') } }
			if (-not $cwd -or -not (Test-Path -LiteralPath $cwd)) { $cwd = $env:USERPROFILE }
			$out = Join-Path $DataDir ('restart_' + ([string]$x.sid).Substring(0, 8) + '.out')
			[void](Start-Process -FilePath $exe -ArgumentList ('-p "' + $text + '" --resume ' + $x.sid + ' --output-format json') -WorkingDirectory $cwd -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError ($out + '.err'))
			$script:wokeAt[[string]$x.sid] = $now
			Add-Content -LiteralPath $log -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 叫醒 ' + $x.sid + ' ' + [string]$x.title + ' @ ' + $cwd)
			$ok++
		} catch { Add-Content -LiteralPath $log -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 失敗 ' + $x.sid + ' ' + $_.Exception.Message) }
	}
	Pet-Say ('已在背景叫醒 ' + $ok + ' 個，幾分鐘後看「停住了」有沒有少') 9000
}
function Get-PausableRuns { # 和 pd-agent 的 runningNow／waitingSids 同一套規則：recent.json 裡正在跑、有標題與連結、而且不是在等使用者回答的對話
	$out = @()
	if (-not $script:recent -or -not $script:recent.sessions) { return @() }
	$wait = @{}; foreach ($it in @($script:items)) { if ($it.sid -and ($it.kind -in @($null, 'question', 'permission', 'wrapup'))) { $wait[([string]$it.sid).ToLower()] = $true } }
	foreach ($x in @($script:recent.sessions)) {
		if (-not $x.run -or -not $x.sid -or -not $x.title -or ([string]$x.local) -notmatch '^local_[0-9a-f-]{36}$') { continue }
		if ($wait.ContainsKey(([string]$x.sid).ToLower())) { continue }
		$out += $x
	}
	return $out
}
function Get-WaitingRunCount { $n = 0; if ($script:recent -and $script:recent.sessions) { $wait = @{}; foreach ($it in @($script:items)) { if ($it.sid -and ($it.kind -in @($null, 'question', 'permission', 'wrapup'))) { $wait[([string]$it.sid).ToLower()] = $true } }; foreach ($x in @($script:recent.sessions)) { if ($x.run -and $x.sid -and $wait.ContainsKey(([string]$x.sid).ToLower())) { $n++ } } }; return $n }
function Paused-Count { try { $pf = Join-Path $DataDir 'paused.json'; if (Test-Path -LiteralPath $pf) { $j = (Get-Content -LiteralPath $pf -Raw -Encoding UTF8) | ConvertFrom-Json; return @($j.items | Where-Object { $_.ok -and -not $_.resumed }).Count } } catch { }; return 0 }
function Agent-Alive { try { $c = New-Object System.Net.Sockets.TcpClient; $iar = $c.BeginConnect('127.0.0.1', 47831, $null, $null); $ok = $iar.AsyncWaitHandle.WaitOne(500); if ($ok -and $c.Connected) { $c.Close(); return $true }; $c.Close() } catch { }; return $false }
function Send-CtlRequest([string]$action, [string]$doneTitle) { # 把請求交給 pd-agent（data\ctl-request.json），再用計時器等 data\ctl-result.json 回來，顯示結果
	if (-not (Agent-Alive)) { Pet-Say '常駐小程式（pd-agent）沒開，等一分鐘它會自己起來；或看看有沒有設定飛傳信箱' 8000; return }
	$at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$rf = Join-Path $DataDir 'ctl-result.json'; try { if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force } } catch { }
	[System.IO.File]::WriteAllText((Join-Path $DataDir 'ctl-request.json'), (@{ action = $action; at = $at } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
	$script:ctlWait = @{ at = $at; action = $action; title = $doneTitle; tries = 0 }
	Pet-Say ($(if ($action -eq 'pause') { '電腦開始逐個按停止了，這段時間請先別動滑鼠鍵盤' } else { '開始叫醒了' })) 9000
	if (-not $script:ctlTm) {
		$script:ctlTm = New-Object System.Windows.Forms.Timer; $script:ctlTm.Interval = 2000
		$script:ctlTm.Add_Tick({
			$w = $script:ctlWait; if (-not $w) { $script:ctlTm.Stop(); return }
			$w.tries++
			$rf2 = Join-Path $DataDir 'ctl-result.json'; $r = $null
			try { if (Test-Path -LiteralPath $rf2) { $r = (Get-Content -LiteralPath $rf2 -Raw -Encoding UTF8) | ConvertFrom-Json } } catch { }
			if ($r -and [double]$r.reqAt -eq [double]$w.at) {
				$script:ctlTm.Stop(); $script:ctlWait = $null
				$msg = [string]$r.note
				if ($w.action -eq 'pause' -and $r.failed -and @($r.failed).Count -gt 0) { $msg += [Environment]::NewLine + [Environment]::NewLine + '這些請使用者自己在 Claude 裡按停止：' + [Environment]::NewLine + ((@($r.failed) | ForEach-Object { '・' + [string]$_.title + '（' + [string]$_.note + '）' }) -join [Environment]::NewLine) }
				if ($w.action -eq 'pause' -and $r.waiting -and @($r.waiting).Count -gt 0) { $msg += [Environment]::NewLine + [Environment]::NewLine + '這些在等使用者回答（本來就停著，沒有停止鍵）：' + [Environment]::NewLine + ((@($r.waiting) | ForEach-Object { '・' + [string]$_ }) -join [Environment]::NewLine) }
				[void][System.Windows.Forms.MessageBox]::Show($msg, $w.title, 'OK', $(if ($r.ok) { 'Information' } else { 'Warning' }))
				return
			}
			if ($w.tries -gt 180) { $script:ctlTm.Stop(); $script:ctlWait = $null; Pet-Say '等了 6 分鐘沒收到電腦的回報，請看 data\pause.log' 9000 } # 20 個對話最多約 2～3 分鐘
		})
	}
	$script:ctlTm.Start()
}
function Pause-All {
	if ($script:ctlWait) { Pet-Say '上一個暫停／繼續還在做' 5000; return }
	$cand = @(Get-PausableRuns | Select-Object -First 20); $waiting = Get-WaitingRunCount
	if ($cand.Count -eq 0) { Pet-Say ($(if ($waiting -gt 0) { '沒有要停的：' + $waiting + ' 個在等使用者回答，本來就停著' } else { '目前沒有正在跑的對話' })) 6000; return }
	$names = ($cand | ForEach-Object { '・' + [string]$_.title }) -join [Environment]::NewLine
	$msg = '要請這 ' + $cand.Count + ' 個正在跑的對話停手嗎？' + [Environment]::NewLine + [Environment]::NewLine + $names + [Environment]::NewLine + [Environment]::NewLine + '電腦會逐個切到那個對話、替使用者按「停止」（不是強制關閉），每個約 5 秒，這段時間 Claude 視窗會一直切換，請先別動滑鼠鍵盤。' + $(if ($waiting -gt 0) { [Environment]::NewLine + $waiting + ' 個在等使用者回答的不會被碰。' } else { '' }) + [Environment]::NewLine + '停成功的會記住，之後可按「全部繼續」。'
	if ([System.Windows.Forms.MessageBox]::Show($msg, '全部暫停', 'YesNo', 'Question') -ne 'Yes') { return }
	Send-CtlRequest 'pause' '全部暫停：結果'
}
function Resume-All {
	if ($script:ctlWait) { Pet-Say '上一個暫停／繼續還在做' 5000; return }
	$n = Paused-Count
	if ($n -le 0) { Pet-Say '沒有可以繼續的（還沒按過全部暫停，或已經繼續過了）' 6000; return }
	$msg = '要叫醒剛剛暫停成功的 ' + $n + ' 個對話嗎？' + [Environment]::NewLine + [Environment]::NewLine + '每個都要重讀整段對話（花額度），它們在背景接著做，沒有權限的動作會被擋住。每個間隔 2 秒啟動。'
	if ([System.Windows.Forms.MessageBox]::Show($msg, '全部繼續', 'YesNo', 'Question') -ne 'Yes') { return }
	Send-CtlRequest 'resume' '全部繼續：結果'
}
function Woke-Recently([string]$sid) { # data\restart.log（小工具與手機遙控共用）：這個對話 10 分鐘內有沒有被叫醒過
	$lg = Join-Path $DataDir 'restart.log'
	if (-not $sid -or -not (Test-Path -LiteralPath $lg)) { return $false }
	try {
		foreach ($ln in @(Get-Content -LiteralPath $lg -Tail 60 -Encoding UTF8)) {
			if ($ln -match '(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) 叫醒 ([0-9a-fA-F-]{36})' -and $matches[2] -eq $sid) { if (([DateTime]::Now - [DateTime]::Parse($matches[1])).TotalMinutes -lt 10) { return $true } }
		}
	} catch { }
	return $false
}
function Json-Str([string]$s) { return (ConvertTo-Json -InputObject $s -Compress) }
function Show-AnswerDialog($it) { # 直接在小工具點選項回答 Claude 的選擇題：走飛傳信箱 /pd/api/reply（和手機同一個項目，先點先贏；hook 收到答案就不跳原生對話框）
	$srv = ''; $sec = ''
	try { $srv = ([string]$Config.push.server).TrimEnd('/'); $sec = [string]$Config.push.secret } catch { }
	if (-not $srv -or $sec.Length -lt 32) { Pet-Say '沒設定飛傳信箱，不能從小工具回答' 6000; return }
	$qs = @($it.questions); $meta = @($it.qmeta)
	$W = 580
	$f = New-Object System.Windows.Forms.Form
	$f.Text = '回答選項框 — ' + $(if ($it.title) { [string]$it.title } else { '對話' })
	$f.StartPosition = 'CenterScreen'; $f.Font = $FontBtn; $f.BackColor = $T.bg; $f.ForeColor = $T.fg
	$f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true; $f.ShowInTaskbar = $true
	$outer = New-Object System.Windows.Forms.FlowLayoutPanel
	$outer.FlowDirection = 'TopDown'; $outer.WrapContents = $false; $outer.AutoScroll = $true; $outer.Location = New-Object System.Drawing.Point(8, 8)
	$groups = New-Object System.Collections.ArrayList
	for ($qi = 0; $qi -lt $qs.Count; $qi++) {
		$q = $qs[$qi]; $multi = ($meta.Count -gt $qi -and $meta[$qi].multi -eq $true); $descs = @(); if ($meta.Count -gt $qi) { $descs = @($meta[$qi].descs) }
		$gp = New-Object System.Windows.Forms.FlowLayoutPanel # 每題一個容器：單選鈕才不會跨題連動
		$gp.FlowDirection = 'TopDown'; $gp.WrapContents = $false; $gp.AutoSize = $true; $gp.AutoSizeMode = 'GrowAndShrink'; $gp.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
		$lb = New-Object System.Windows.Forms.Label
		$lb.AutoSize = $true; $lb.MaximumSize = New-Object System.Drawing.Size(($W - 60), 0); $lb.Font = $FontTitle; $lb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
		$lb.Text = [string]$q.question + $(if ($multi) { '（可複選）' } else { '' })
		[void]$gp.Controls.Add($lb)
		$opts = New-Object System.Collections.ArrayList
		$oi = 0
		$tb = New-Object System.Windows.Forms.TextBox
		$tb.Width = $W - 80; $tb.MaxLength = 200; $tb.Margin = New-Object System.Windows.Forms.Padding(22, 2, 0, 0)
		foreach ($o in @($q.options)) {
			$ctl = if ($multi) { New-Object System.Windows.Forms.CheckBox } else { New-Object System.Windows.Forms.RadioButton }
			$ctl.AutoSize = $true; $ctl.MaximumSize = New-Object System.Drawing.Size(($W - 70), 0); $ctl.Margin = New-Object System.Windows.Forms.Padding(8, 2, 0, 4)
			$d = if ($descs.Count -gt $oi) { [string]$descs[$oi] } else { '' }
			$ctl.Text = [string]$o + $(if ($d) { "  —  $d" } else { '' })
			if (-not $multi) { $ctl.Tag = $tb; $ctl.Add_CheckedChanged({ param($s, $e) if ($s.Checked) { $s.Tag.Text = '' } }) }
			[void]$opts.Add($ctl); [void]$gp.Controls.Add($ctl); $oi++
		}
		$ol = New-Object System.Windows.Forms.Label
		$ol.AutoSize = $true; $ol.ForeColor = $T.muted; $ol.Text = '其他（自己打字）：'; $ol.Margin = New-Object System.Windows.Forms.Padding(8, 6, 0, 0)
		[void]$gp.Controls.Add($ol); [void]$gp.Controls.Add($tb)
		if (-not $multi) { $tb.Tag = $opts; $tb.Add_TextChanged({ param($s, $e) if ($s.Text.Trim()) { foreach ($x in $s.Tag) { $x.Checked = $false } } }) }
		[void]$groups.Add(@{ opts = $opts; other = $tb; multi = $multi })
		[void]$outer.Controls.Add($gp)
	}
	$status = New-Object System.Windows.Forms.Label
	$status.AutoSize = $false; $status.ForeColor = $T.muted; $status.Height = 22
	$btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = '送出答案'; $btnOk.Width = 110; $btnOk.Height = 32
	$btnOpen = New-Object System.Windows.Forms.Button; $btnOpen.Text = '開對話'; $btnOpen.Width = 90; $btnOpen.Height = 32
	$btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = '取消'; $btnCancel.Width = 80; $btnCancel.Height = 32
	foreach ($b in @($btnOk, $btnOpen, $btnCancel)) { $b.FlatStyle = 'System'; $b.BackColor = $T.surface; $b.ForeColor = $T.fg }
	$f.Controls.Add($outer); $f.Controls.Add($status); $f.Controls.Add($btnOk); $f.Controls.Add($btnOpen); $f.Controls.Add($btnCancel)
	# 版面：內容高度先量，再決定視窗高度（最高 640）
	$outer.Size = New-Object System.Drawing.Size(($W - 16), 100)
	$total = 0; foreach ($c in $outer.Controls) { $total += $c.PreferredSize.Height + 14 }
	$outer.Height = [Math]::Min([Math]::Max(140, $total + 8), 600)
	$f.ClientSize = New-Object System.Drawing.Size($W, ($outer.Height + 16 + 22 + 50))
	$status.Location = New-Object System.Drawing.Point(12, ($outer.Bottom + 6)); $status.Width = $W - 24
	$by = $outer.Bottom + 34
	$btnCancel.Location = New-Object System.Drawing.Point(($W - 92), $by); $btnOpen.Location = New-Object System.Drawing.Point(($W - 92 - 100), $by); $btnOk.Location = New-Object System.Drawing.Point(($W - 92 - 100 - 120), $by)
	$f.AcceptButton = $btnOk; $f.CancelButton = $btnCancel
	# 事件處理不用閉包（腳本層函式在閉包裡找不到），狀態放 $script:ad*
	$script:adIt = $it; $script:adF = $f; $script:adGroups = $groups; $script:adStatus = $status; $script:adOk = $btnOk; $script:adSrv = $srv; $script:adSec = $sec; $script:adUntil = [double]$it.qUntil
	$tm = New-Object System.Windows.Forms.Timer; $tm.Interval = 1000; $script:adTm = $tm
	$tm.Add_Tick({
		$left = [int](($script:adUntil - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000)
		if ($left -le 0) { $script:adStatus.Text = '已逾時：電腦那邊會改跳原本的對話框，請在那裡回答'; $script:adOk.Enabled = $false; $script:adTm.Stop() } elseif ($script:adIt.sync) { $script:adStatus.Text = "手機、Claude 視窗與這裡先答先贏；答完電腦會自動在 Claude 視窗點好（答案送出後這張卡就消失）" } else { $script:adStatus.Text = "手機與這裡先點先贏，還剩 $left 秒（逾時後會改跳原本的對話框）" }
	})
	$tm.Start()
	$btnOpen.Add_Click({ Open-Session ([string]$script:adIt.local) })
	$btnOk.Add_Click({
		$groups = $script:adGroups; $it = $script:adIt; $f = $script:adF; $tm = $script:adTm; $status = $script:adStatus; $btnOk = $script:adOk; $srv = $script:adSrv; $sec = $script:adSec
		$parts = New-Object System.Collections.ArrayList
		for ($i = 0; $i -lt $groups.Count; $i++) {
			$g = $groups[$i]; $sel = New-Object System.Collections.ArrayList
			for ($k = 0; $k -lt $g.opts.Count; $k++) { if ($g.opts[$k].Checked) { [void]$sel.Add($k) } }
			$other = $g.other.Text.Trim()
			if ($sel.Count + $(if ($other) { 1 } else { 0 }) -lt 1) { [System.Windows.Forms.MessageBox]::Show("第 $($i + 1) 題還沒選（可以選一個選項，或在「其他」打字）", '還沒選完') | Out-Null; return }
			[void]$parts.Add('{"sel":[' + ($sel -join ',') + '],"other":' + (Json-Str $other) + '}')
		}
		$body = '{"id":' + (Json-Str ([string]$it.qid)) + ',"answers":[' + ($parts -join ',') + ']}'
		$btnOk.Enabled = $false; $status.Text = '送出中…'; [System.Windows.Forms.Application]::DoEvents()
		try {
			[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
			[void](Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($srv + '/pd/api/reply') -Headers @{ Authorization = 'Bearer ' + $sec } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15)
			$tm.Stop(); $f.Close(); Pet-Say '答案已送出，Claude 馬上收到' 5000
		} catch {
			$code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
			$msg = if ($code -eq 404) { '這題已經逾時或被取消了。電腦那邊會改跳原本的對話框，請直接在那裡回答。' } elseif ($code -eq 409) { '手機已經先回答了這一題。' } elseif ($code -eq 400) { '答案格式被伺服器拒絕（選項數量不對？）' } elseif ($code -eq 401 -or $code -eq 503) { '飛傳信箱密碼不對或沒啟用。' } else { '送出失敗（網路不通？）：' + $_.Exception.Message }
			[System.Windows.Forms.MessageBox]::Show($msg, '沒送出去') | Out-Null
			if ($code -eq 404 -or $code -eq 409) { $tm.Stop(); $f.Close() } else { $btnOk.Enabled = $true; $status.Text = '' }
		}
	})
	[void]$f.ShowDialog()
	$tm.Stop(); $tm.Dispose(); $f.Dispose()
}
function Show-WrapDialog($it) { # 收尾提問卡：點卡片上的按鈕→經飛傳信箱叫電腦端 pd-agent 在背景把那句話送給該對話（和手機同一條路，同樣的安全閘）
	$srv = ''; $sec = ''
	try { $srv = ([string]$Config.push.server).TrimEnd('/'); $sec = [string]$Config.push.secret } catch { }
	if (-not $srv -or $sec.Length -lt 32) { Pet-Say '沒設定飛傳信箱，不能從小工具送出' 6000; return }
	$opts = @($it.questions[0].options)
	$f = New-Object System.Windows.Forms.Form
	$f.Text = '回答提問卡 — ' + $(if ($it.title) { [string]$it.title } else { '對話' })
	$f.StartPosition = 'CenterScreen'; $f.Font = $FontBtn; $f.BackColor = $T.bg; $f.ForeColor = $T.fg
	$f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
	$W = 560
	$lq = New-Object System.Windows.Forms.Label; $lq.AutoSize = $true; $lq.MaximumSize = New-Object System.Drawing.Size(($W - 40), 0); $lq.Font = $FontTitle; $lq.Text = [string]$it.questions[0].question; $lq.Location = New-Object System.Drawing.Point(20, 16)
	$f.Controls.Add($lq)
	$y = $lq.Bottom + 8
	if ($it.detail) {
		$ld = New-Object System.Windows.Forms.Label; $ld.AutoSize = $true; $ld.MaximumSize = New-Object System.Drawing.Size(($W - 40), 0); $ld.ForeColor = $T.muted; $ld.Text = [string]$it.detail; $ld.Location = New-Object System.Drawing.Point(20, $y)
		$f.Controls.Add($ld); $y = $ld.Bottom + 8
	}
	$script:wrIt = $it; $script:wrF = $f; $script:wrSrv = $srv; $script:wrSec = $sec
	$y += 8
	for ($i = 0; $i -lt $opts.Count; $i++) {
		$b = New-Object System.Windows.Forms.Button; $b.Text = [string]$opts[$i]; $b.Tag = $i; $b.Size = New-Object System.Drawing.Size(($W - 40), 38); $b.Location = New-Object System.Drawing.Point(20, $y); $b.FlatStyle = 'System'
		$b.Add_Click({ param($s, $e)
			$it = $script:wrIt; $label = [string]$it.questions[0].options[[int]$s.Tag]
			if ([System.Windows.Forms.MessageBox]::Show("要把「$label」送給這個對話嗎？`n電腦會在背景用 claude 把這句話送過去，對話會接著做（花額度）。", '送出答案', 'YesNo', 'Question') -ne 'Yes') { return }
			$card = 'pd-' + ([System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$it.id))) -replace '-', '').ToLower().Substring(0, 20)
			$body = '{"action":"reply","card":' + (Json-Str $card) + ',"idx":' + [int]$s.Tag + '}'
			try {
				[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
				[void](Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($script:wrSrv + '/pd/api/cmd') -Headers @{ Authorization = 'Bearer ' + $script:wrSec } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15)
				$script:wrF.Close(); Pet-Say ('已請電腦在背景送出「' + $label + '」，幾秒後卡片會消失') 6000
			} catch {
				$code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
				$msg = if ($code -eq 503) { '電腦接收程式沒連線（小工具剛開還要等一分鐘），稍後再試。' } elseif ($code -eq 409) { '這張卡已經送出過了。' } elseif ($code -eq 400) { '伺服器還沒看到這張卡（等幾秒同步），或它已經不在等你了。' } elseif ($code -eq 429) { '太頻繁了，等幾分鐘再試。' } else { '送出失敗：' + $_.Exception.Message }
				[System.Windows.Forms.MessageBox]::Show($msg, '沒送出去') | Out-Null
			}
		})
		$f.Controls.Add($b); $y += 46
	}
	$bo = New-Object System.Windows.Forms.Button; $bo.Text = '開對話（自己回）'; $bo.Size = New-Object System.Drawing.Size(150, 32); $bo.Location = New-Object System.Drawing.Point(20, ($y + 6)); $bo.FlatStyle = 'System'
	$bo.Add_Click({ Open-Session ([string]$script:wrIt.local); $script:wrF.Close() })
	$bc = New-Object System.Windows.Forms.Button; $bc.Text = '取消'; $bc.Size = New-Object System.Drawing.Size(90, 32); $bc.Location = New-Object System.Drawing.Point(($W - 110), ($y + 6)); $bc.FlatStyle = 'System'; $bc.DialogResult = 'Cancel'
	$f.Controls.Add($bo); $f.Controls.Add($bc); $f.CancelButton = $bc
	$f.ClientSize = New-Object System.Drawing.Size($W, ($y + 52))
	[void]$f.ShowDialog(); $f.Dispose()
}
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
$mi.Add_Click({ if ([string]$script:menuSid -like 'prop:*') { Dismiss-Fable $script:menuSid 168 } else { Dismiss-Fable $script:menuSid } })
$list.Add_MouseUp({ param($s, $e)
	if ($e.Button -ne 'Right' -or $script:tab -ne 'pending') { return }
	$i = $list.HitTest($e.Y); if ($i -lt 0) { return }
	$row = $list.Items[$i]
	if ($row.Extra) { $script:menuSid = $row.Extra; $mi.Text = $(if ([string]$row.Extra -like 'prop:*') { '知道了（這張建議任務卡不再提醒）' } else { '知道了（這個對話 12 小時內不再提醒 Fable）' }); $rowMenu.Show($list, $e.Location) }
})
$list.Add_RowActivated({
	if ($script:pdMoved) { return } # 剛剛是在拖整個浮窗，不是點那一列
	if (([DateTime]::Now - $script:lastAct).TotalMilliseconds -lt 800) { return } # 雙擊會連點兩次，只開一次
	$script:lastAct = [DateTime]::Now
	$row = $list.Items[$list.ActivatedIndex]
	if (-not $row) { return }
	switch ($script:tab) {
		'pending' {
			$pit = @($script:items)[$list.ActivatedIndex]
			if ($pit -and $pit.qid -and [double]$pit.qUntil -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -and $pit.questions -and @($pit.questions).Count -gt 0 -and @($pit.questions[0].options).Count -ge 2) { Show-AnswerDialog $pit } elseif ($pit -and $pit.kind -eq 'wrapup' -and $pit.questions -and @($pit.questions).Count -gt 0 -and @($pit.questions[0].options).Count -ge 1) { Show-WrapDialog $pit } else { Open-Session $row.Key }
		}
		'broken' { # 把「請從中斷的地方接著做」放進剪貼簿，再打開那個對話；你只要貼上、按送出
			if ([string]$row.Key -eq 'restart-all') { Restart-AllBroken; return }
				$b = @($script:recent.broken)[$list.ActivatedIndex - 1]
			$txt = '剛剛好像斷線或中斷了。請先看紀錄，確認你上一步做到哪（我這邊看到最後停在：' + $(if ($b -and $b.stopped) { [string]$b.stopped } else { '不明' }) + '），已經做完的不要重做，沒做完的從那裡接著做，做完用一句話跟我說。'
			try { [System.Windows.Forms.Clipboard]::SetText($txt) } catch { }
			Open-Session $row.Key
		}
		'running' { if ([string]$row.Key -eq 'pause-all') { Pause-All; return } elseif ([string]$row.Key -eq 'resume-all') { Resume-All; return } elseif ([string]$row.Key -like 'ses:*') { Open-Session ([string]$row.Key).Substring(4) } elseif ([string]$row.Key -like 'dir:*') { Reveal-Path ([string]$row.Key).Substring(4) $true } elseif ($row.Key) { Open-Session $row.Key } }
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
	if ($script:set.walk -and -not $script:set.perch) { $iconForm.Location = New-Object System.Drawing.Point((Home-X), (Runway-Y)) }
	elseif ($null -ne $script:set.x -and $null -ne $script:set.y) { $iconForm.Location = New-Object System.Drawing.Point([int]$script:set.x, [int]$script:set.y) }
	else { $w = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea; $iconForm.Location = New-Object System.Drawing.Point(($w.Right - $IconBox - 24), ($w.Bottom - $IconBox - 60)) }
	Place-Around; Set-AnimRate
}
$script:walkTarget = $null; $script:pauseUntil = 0
$rng = New-Object System.Random
$walk = New-Object System.Windows.Forms.Timer
$walk.Interval = 40
$walk.Add_Tick({
	if (-not $script:set.walk -or $script:set.perch -or -not $iconForm.Visible -or $script:petBusy) { return } # 玩遊戲（追東西／打架）時由遊戲接手
	if ($script:down -or $script:pd -or $shake.Enabled -or $panel.Visible -or (Pet-Asleep)) { if ($script:moving) { $script:moving = $false; Set-AnimRate }; return } # 被抓著、抖動中、清單開著：先不走
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
	$dlg.Font = $FontBtn; $dlg.BackColor = $T.bg; $dlg.ForeColor = $T.fg
	$hd = New-Object System.Windows.Forms.Label
	$hd.Text = '  待決定浮窗 · 設定'; $hd.Dock = 'Top'; $hd.Height = 48; $hd.BackColor = $T.header; $hd.ForeColor = [System.Drawing.Color]::White; $hd.Font = $FontBig; $hd.TextAlign = 'MiddleLeft'
	$dlg.ClientSize = New-Object System.Drawing.Size(560, 680)
	$body = New-Object System.Windows.Forms.Panel # 內容放在可捲動的區塊裡（右鍵選單裡的設定也都收進來，項目多了就用滾輪）
	$body.Location = New-Object System.Drawing.Point(0, 48); $body.Size = New-Object System.Drawing.Size(560, 576); $body.AutoScroll = $true; $body.BackColor = $T.bg
	$bar = New-Object System.Windows.Forms.Panel
	$bar.Location = New-Object System.Drawing.Point(0, 624); $bar.Size = New-Object System.Drawing.Size(560, 56); $bar.BackColor = $T.footer
	$l1 = New-Object System.Windows.Forms.Label; $l1.Text = '浮窗圖示（點一下選）'; $l1.Font = $FontTitle; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(20, 16)
	$l1b = New-Object System.Windows.Forms.Label; $l1b.Text = '也可以直接把圖檔拖到桌面上的浮窗'; $l1b.ForeColor = $T.muted; $l1b.Font = $FontSub; $l1b.AutoSize = $true; $l1b.Location = New-Object System.Drawing.Point(180, 20)
	$fp = New-Object System.Windows.Forms.FlowLayoutPanel
	$fp.Location = New-Object System.Drawing.Point(20, 44); $fp.Size = New-Object System.Drawing.Size(510, 204); $fp.AutoScroll = $true; $fp.BackColor = $T.surface; $fp.Padding = New-Object System.Windows.Forms.Padding(6)
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
	$btnImg = Flat-Button '從電腦選圖片…（複製一份進來，不動原檔）' 330 32 $false; $btnImg.Location = New-Object System.Drawing.Point(20, 258)
	$btnImg.Add_Click({
		$ofd = New-Object System.Windows.Forms.OpenFileDialog
		$ofd.Filter = '圖片 (*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.ico)|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.ico'; $ofd.Title = '選一張圖'
		if ($ofd.ShowDialog() -eq 'OK') {
			$script:pick = Import-Icon $ofd.FileName; Fill-Thumbs
		}
	})
	$l2 = New-Object System.Windows.Forms.Label; $l2.Text = '有待決定時，圖旁邊要說的話'; $l2.Font = $FontTitle; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(20, 308)
	$tb = New-Object System.Windows.Forms.TextBox; $tb.Text = [string]$script:set.message; $tb.MaxLength = 40; $tb.Size = New-Object System.Drawing.Size(510, 28); $tb.Location = New-Object System.Drawing.Point(20, 334); $tb.Font = $FontBtn; $tb.BackColor = $T.surface; $tb.ForeColor = $T.fg; $tb.BorderStyle = 'FixedSingle'
	$cb1 = New-Object System.Windows.Forms.CheckBox; $cb1.Text = '沒有待決定時，把圖藏起來（有了才跳出來）'; $cb1.AutoSize = $true; $cb1.Checked = [bool]$script:set.hideWhenZero; $cb1.Location = New-Object System.Drawing.Point(20, 376)
	$cb2 = New-Object System.Windows.Forms.CheckBox; $cb2.Text = '有新的待決定時發出提示音'; $cb2.AutoSize = $true; $cb2.Checked = [bool]$script:set.sound; $cb2.Location = New-Object System.Drawing.Point(20, 402)
	$cb3 = New-Object System.Windows.Forms.CheckBox; $cb3.Text = '開機時自動啟動浮窗'; $cb3.AutoSize = $true; $cb3.Checked = (Autostart-On); $cb3.Location = New-Object System.Drawing.Point(20, 428)
	$cb4 = New-Object System.Windows.Forms.CheckBox; $cb4.Text = '讓圖示在螢幕底邊走來走去（有待決定時會回到固定位置站好）'; $cb4.AutoSize = $true; $cb4.Checked = [bool]$script:set.walk; $cb4.Location = New-Object System.Drawing.Point(20, 454)
	$cb5 = New-Object System.Windows.Forms.CheckBox; $cb5.Text = '養電子雞（右鍵選「電子雞」：餵食、陪玩、摸摸、哄睡覺）'; $cb5.AutoSize = $true; $cb5.Checked = [bool]$script:set.pet; $cb5.Location = New-Object System.Drawing.Point(20, 480)
	$cb6 = New-Object System.Windows.Forms.CheckBox; $cb6.Text = '沒有新通知就自動縮小、收起小工具（滑鼠移上去恢復）'; $cb6.AutoSize = $true; $cb6.Checked = [bool]$script:set.autoShrink; $cb6.Location = New-Object System.Drawing.Point(20, 506)
	function New-SecRow([string]$text, [int]$y, [int]$val, [int]$min, [int]$max) { # 一列「說明＋可輸入的秒數」
		$lb = New-Object System.Windows.Forms.Label; $lb.Text = $text; $lb.Font = $FontBtn; $lb.AutoSize = $true; $lb.Location = New-Object System.Drawing.Point(20, ($y + 4))
		$nu = New-Object System.Windows.Forms.NumericUpDown; $nu.Minimum = $min; $nu.Maximum = $max; $nu.Value = [Math]::Min($max, [Math]::Max($min, $val)); $nu.Font = $FontBtn; $nu.Size = New-Object System.Drawing.Size(80, 28); $nu.Location = New-Object System.Drawing.Point(400, $y); $nu.BackColor = $T.surface; $nu.ForeColor = $T.fg
		$un = New-Object System.Windows.Forms.Label; $un.Text = '秒'; $un.Font = $FontBtn; $un.AutoSize = $true; $un.Location = New-Object System.Drawing.Point(486, ($y + 4))
		return @($lb, $nu, $un)
	}
	$rPh = New-SecRow '清單點開後，沒碰它幾秒自動收起（0＝按「收起來」才收）' 536 ([int]$script:set.panelHide) 0 3600; $nPh = $rPh[1]
	$rSa = New-SecRow '沒新通知也沒人碰，幾秒後開始縮小、收起小工具' 572 ([int]$script:set.shrinkAfter) 3 3600; $nSa = $rSa[1]
	$rIa = New-SecRow '沒人碰，幾秒後電子雞開始做動作' 608 ([int]$script:set.idleAfter) 2 3600; $nIa = $rIa[1]
	$cb7 = New-Object System.Windows.Forms.CheckBox; $cb7.Text = '有待決定時，滑鼠碰到小橘就自動打開清單（不勾＝要點一下才打開）'; $cb7.AutoSize = $true; $cb7.Checked = [bool]$script:set.openOnHover; $cb7.Location = New-Object System.Drawing.Point(20, 648)
	$l4 = New-Object System.Windows.Forms.Label; $l4.Text = '電子雞沒人理牠時會做什麼（可複選，要開電子雞才用得到）'; $l4.Font = $FontTitle; $l4.AutoSize = $true; $l4.Location = New-Object System.Drawing.Point(20, 690)
	$idleCbs = @(); $curIdle = @($script:set.idle); $ix = 0
	foreach ($d in $IdleActs) {
		$c = New-Object System.Windows.Forms.CheckBox; $c.Text = $d[1]; $c.Tag = $d[0]; $c.AutoSize = $true; $c.Checked = ($curIdle -contains $d[0]); $c.Add_CheckedChanged({ if ($this.Checked) { Pet-Fx 4500 ([string]$this.Tag) } }) # 勾起來先演一次給你看
		$c.Location = New-Object System.Drawing.Point((20 + 260 * ($ix % 2)), (720 + 26 * [Math]::Floor($ix / 2))); $idleCbs += $c; $ix++
	}
	$l5 = New-Object System.Windows.Forms.Label; $l5.Text = '其他（原本在右鍵選單裡的）'; $l5.Font = $FontTitle; $l5.AutoSize = $true; $l5.Location = New-Object System.Drawing.Point(20, 870)
	$bUse = Flat-Button '回報額度 %…' 120 32 $false; $bUse.Location = New-Object System.Drawing.Point(20, 898); $bUse.Add_Click({ Report-Usage })
	$bWeb = Flat-Button '開網頁清單' 110 32 $false; $bWeb.Location = New-Object System.Drawing.Point(150, 898); $bWeb.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
	$bDir = Flat-Button '開啟資料夾' 110 32 $false; $bDir.Location = New-Object System.Drawing.Point(270, 898); $bDir.Add_Click({ Start-Process $DataDir })
	$bQuit = Flat-Button '結束浮窗' 110 32 $false; $bQuit.Location = New-Object System.Drawing.Point(390, 898); $bQuit.Add_Click({ $script:quitReq = $true; $this.FindForm().DialogResult = 'Cancel' })
	$pad = New-Object System.Windows.Forms.Label; $pad.Size = New-Object System.Drawing.Size(10, 10); $pad.Location = New-Object System.Drawing.Point(20, 940) # 讓最底下的按鈕下面留一點空白
	$body.Controls.AddRange(@($l1, $l1b, $fp, $btnImg, $l2, $tb, $cb1, $cb2, $cb3, $cb4, $cb5, $cb6, $rPh[0], $nPh, $rPh[2], $rSa[0], $nSa, $rSa[2], $rIa[0], $nIa, $rIa[2], $cb7, $l4, $l5, $bUse, $bWeb, $bDir, $bQuit, $pad)); $body.Controls.AddRange($idleCbs)
	$ok = Flat-Button '儲存' 96 34 $true; $ok.Location = New-Object System.Drawing.Point(334, 11); $ok.DialogResult = 'OK'
	$cancel = Flat-Button '取消' 96 34 $false; $cancel.Location = New-Object System.Drawing.Point(444, 11); $cancel.DialogResult = 'Cancel'
	$bar.Controls.AddRange(@($ok, $cancel))
	$dlg.Controls.AddRange(@($hd, $body, $bar)); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
	if ($Snapshot) { $dlg.FormBorderStyle = 'None'; $dlg.TopMost = $false; $b = Snap-Ctl $dlg; $dlg.Close(); return $b }
	if ($dlg.ShowDialog() -eq 'OK') {
		$script:set.icon = $script:pick
		$script:set.message = if ($tb.Text.Trim()) { $tb.Text.Trim() } else { '有待決定囉！' }
		$script:set.autoShrink = $cb6.Checked; $script:set.openOnHover = $cb7.Checked; $script:lastActive = [Environment]::TickCount; $script:set.panelHide = [int]$nPh.Value; $script:set.shrinkAfter = [int]$nSa.Value; $script:set.idleAfter = [int]$nIa.Value; $script:panelAt = [Environment]::TickCount; $script:set.idle = @($idleCbs | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag })
		$script:set.hideWhenZero = $cb1.Checked; $script:set.sound = $cb2.Checked; $script:set.walk = $cb4.Checked; $wasPet = [bool]$script:set.pet; $script:set.pet = $cb5.Checked; Go-Home
		if ($cb3.Checked -ne (Autostart-On)) { Set-Autostart $cb3.Checked }
		Save-Settings; Apply-Icon; Update-Look
			if ($script:set.pet -and -not $wasPet) { $script:pet.last = (Now-Sec); Save-Pet; Pet-Say ('我是{0}！右鍵點我選「電子雞」，可以餵我、陪我玩～' -f $script:pet.name) 7000 } elseif (-not $script:set.pet) { $petBubble.Hide(); Game-Reset; $item.Hide() }
	}
	if ($script:quitReq) { $script:quitReq = $false; $iconForm.Close() }
}
$btnSet.Add_Click({ Show-Settings })
$btnShot.Add_Click({ Take-Shot })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = $FontBtn
$m1 = $menu.Items.Add('設定…（所有設定都在這裡）'); $m1.Add_Click({ Show-Settings })
$m5 = $menu.Items.Add('回報額度 %…（沒有自動數字時手動填）'); $m5.Add_Click({ Report-Usage })
$m2 = $menu.Items.Add('開網頁清單'); $m2.Add_Click({ if (Test-Path $HtmlFile) { Start-Process $HtmlFile } })
$m3 = $menu.Items.Add('開啟資料夾'); $m3.Add_Click({ Start-Process $DataDir })
# 選項框出現在哪裡（Claude 原生框一定跳；這三個是開關，存在 config.json，改完下一個選項框起生效）
$QModeJs = Join-Path $PSScriptRoot 'question-mode.mjs'
function Get-QFlags { # → @{ phone; answerable; widget }；讀不到就用預設
	$d = @{ phone = $true; answerable = $false; widget = $true }
	if (-not $script:nodeOk) { return $d }
	try { $o = (& node $QModeJs) | Out-String; $j = $o | ConvertFrom-Json; return @{ phone = [bool]$j.phone; answerable = [bool]$j.answerable; widget = [bool]$j.widget } } catch { return $d }
}
$script:qFlagsAt = 0; $script:qFlags = @{ phone = $true; answerable = $false; widget = $true }
function Q-Flags { # 15 秒內不重讀（避免每 3 秒就叫起 node）
	$n = [Environment]::TickCount
	if ($n - $script:qFlagsAt -gt 15000 -or $n -lt $script:qFlagsAt) { $script:qFlags = Get-QFlags; $script:qFlagsAt = $n }
	return $script:qFlags
}
function Set-QFlag([string]$which, [bool]$on) { if ($script:nodeOk) { try { [void](& node $QModeJs $which $(if ($on) { 'on' } else { 'off' })) } catch { } }; $script:qFlagsAt = 0 }
$mq1 = New-Object System.Windows.Forms.ToolStripMenuItem '選項框也出現在手機'; $mq1.Add_Click({ $f = Get-QFlags; Set-QFlag 'phone' (-not $f.phone) })
$mq2 = New-Object System.Windows.Forms.ToolStripMenuItem '選項框列在小工具「待決定」'; $mq2.Add_Click({ $f = Get-QFlags; Set-QFlag 'widget' (-not $f.widget) })
$mq3 = New-Object System.Windows.Forms.ToolStripMenuItem '可答模式：手機／小工具可點選項（原生框會延後最多 60 秒）'; $mq3.Add_Click({ $f = Get-QFlags; Set-QFlag 'answerable' (-not $f.answerable) })
[void]$menu.Items.Add('-'); [void]$menu.Items.AddRange(@($mq1, $mq2, $mq3))
$menu.Add_Opening({ $f = Get-QFlags; $mq1.Checked = $f.phone; $mq2.Checked = $f.widget; $mq3.Checked = $f.answerable })
[void]$menu.Items.Add('-')
$mp = New-Object System.Windows.Forms.ToolStripMenuItem '電子雞（陪牠玩）'
$mpi = @{}
foreach ($pair in @(@('feed', '餵食'), @('play', '陪玩'), @('pat', '摸摸'), @('sleep', '哄睡覺'), @('status', '看狀態'), @('name', '取名字…'))) { $mpi[$pair[0]] = $mp.DropDownItems.Add($pair[1]) }
$mpi.feed.Add_Click({ $panel.Hide(); Pet-Feed }); $mpi.play.Add_Click({ $panel.Hide(); Pet-Play }); $mpi.pat.Add_Click({ $panel.Hide(); Pet-Pat }); $mpi.sleep.Add_Click({ $panel.Hide(); Pet-ToggleSleep }); $mpi.status.Add_Click({ $panel.Hide(); Pet-Status }); $mpi.name.Add_Click({ $panel.Hide(); Pet-Rename }) # 清單開著時先收起來，不然說的話會被擋住
[void]$menu.Items.Insert(0, $mp)
$mShot = New-Object System.Windows.Forms.ToolStripMenuItem '截圖（拖曳框選，存到「圖片\截圖」並複製）'
$mShot.Add_Click({ Take-Shot })
[void]$menu.Items.Insert(1, $mShot)
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
$script:pet = @{ name = '小橘'; hunger = 80.0; mood = 80.0; energy = 90.0; sleeping = $false; born = (Now-Sec); last = (Now-Sec); fed = 0; played = 0; xp = 0; wins = 0 }
try { if (Test-Path $PetFile) { $pj = Get-Content $PetFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @('name', 'hunger', 'mood', 'energy', 'sleeping', 'born', 'last', 'fed', 'played', 'xp', 'wins')) { if ($null -ne $pj.$k) { $script:pet[$k] = $pj.$k } } } } catch { }
function Save-Pet { try { ($script:pet | ConvertTo-Json) | Set-Content -Path $PetFile -Encoding UTF8 } catch { } }
function Pet-Clamp([double]$v) { [Math]::Max(0.0, [Math]::Min(100.0, $v)) }
$script:petSaid = @{}; $script:lastDecXp = [DateTime]::MinValue
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
function Pet-Fx([int]$ms, [string]$kind = 'heart') { $script:fxKind = $kind; $script:fxUntil = [Environment]::TickCount + $ms; Set-AnimRate; Show-Frame }
function Pet-Overlay { # 牠身上現在要畫什麼：做動作時是動作小圖；睡覺 zzz；餓了流汗
	if (-not $script:set.pet) { return '' }
	if (Pet-Fx-On) { return [string]$script:fxKind }
	if ($script:pet.sleeping) { return 'zzz' }
	if ([double]$script:pet.hunger -lt 30) { return 'sad' }
	return ''
}
function Pet-Level { if (-not $script:set.pet) { return 4 }; $l = 1; foreach ($th in @(40, 120, 260, 500)) { if ([int]$script:pet.xp -ge $th) { $l++ } }; return $l }
function Pet-Stage([int]$l) { @('蛋寶寶', '小橘', '少年橘', '大橘', '橘王')[$l - 1] }
function Pet-Gain([int]$n, [string]$why = '') { # 加經驗；升級時會變大（最高級戴皇冠）
	$before = Pet-Level; $script:pet.xp = [int]$script:pet.xp + $n; $after = Pet-Level; Save-Pet
	if ($after -gt $before) { Pet-Fx 6000 'heart'; Pet-Say ('升級了！Lv.{0} {1}' -f $after, (Pet-Stage $after)) 7000 }
	elseif ($why) { Pet-Say ('{0}　經驗 +{1}' -f $why, $n) 4000 }
} # 開心：跳跳動作一陣子
function Pet-Refresh { Save-Pet; Update-Look; Set-AnimRate; Show-Frame }
function Pet-Bar([double]$v) { $n = [int][Math]::Round($v / 10); (('■' * $n) + ('□' * (10 - $n))) + (' {0}%' -f [int]$v) }
function Pet-Decay([double]$mins) {
	$p = $script:pet; $h = [double]$p.hunger; $m = [double]$p.mood; $e = [double]$p.energy
	if ($p.sleeping) { $e += 0.8 * $mins; $h -= 0.12 * $mins; $m -= 0.05 * $mins } else { $h -= 0.35 * $mins; $m -= 0.25 * $mins; $e -= 0.12 * $mins }
	if ($h -le 0) { $m -= 0.2 * $mins } # 餓過頭，心情掉更快
	$p.hunger = Pet-Clamp $h; $p.mood = Pet-Clamp $m; $p.energy = Pet-Clamp $e
}
function Pet-Wake([string]$msg) { if ($script:pet.sleeping) { $script:pet.sleeping = $false; $script:pet.energy = [Math]::Max([double]$script:pet.energy, 30.0); # 叫醒時至少給點精神，不然馬上又睡著
 Pet-Refresh; if ($msg) { Pet-Say $msg } } }
function Pet-Feed {
	if ($script:pet.sleeping) { Pet-Wake '' } # 睡著了：直接叫醒，不用再找選單
	$full = [double]$script:pet.hunger -ge 95 # 飯糰不限量：飽了也照吃（只是經驗少一點）
	$script:pet.hunger = Pet-Clamp ([double]$script:pet.hunger + 35); $script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 3); $script:pet.fed = [int]$script:pet.fed + 1
	Pet-Refresh; Pet-Fx 2500 'eat'; Pet-Say $(if ($full) { '肚子圓滾滾還是要吃～' } else { '好好吃！謝謝～' }) 3000; Pet-Gain $(if ($full) { 1 } else { 5 })
}
function Pet-Play {
	if ($script:pet.sleeping) { Pet-Wake '' } # 睡著了：直接叫醒，不用再找選單
	$script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 25); $script:pet.energy = Pet-Clamp ([double]$script:pet.energy - 12); $script:pet.hunger = Pet-Clamp ([double]$script:pet.hunger - 6); $script:pet.played = [int]$script:pet.played + 1
	Pet-Refresh; Pet-Fx 5000 'play'; Pet-Say '耶！好好玩！再來再來～' 3000; Pet-Gain 8
}
function Pet-Pat {
	if ($script:pet.sleeping) { Pet-Wake '嗯…被你摸醒了'; return }
	$script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 8)
	Pet-Refresh; Pet-Fx 2500 'heart'; Pet-Say '呼嚕嚕～♥' 2500; Pet-Gain 1
}
function Pet-ToggleSleep {
	if ($script:pet.sleeping) { Pet-Wake '早安！' }
	else { $script:pet.sleeping = $true; Pet-Refresh; Pet-Say 'Zzz…晚安～' }
}
function Pet-Status {
	$days = [int](((Now-Sec) - [double]$script:pet.born) / 86400) + 1
	$st = if ($script:pet.sleeping) { '（睡覺中）' } else { '' }
	$lv = Pet-Level; $nx = @(40, 120, 260, 500, 0)[$lv - 1]; $xpLine = if ($nx -gt 0) { '經驗 {0}/{1}' -f [int]$script:pet.xp, $nx } else { '經驗 {0}（已滿級）' -f [int]$script:pet.xp }
	Pet-Say ("{0} Lv.{8} {9} · 第 {1} 天 {2}`n{10}`n飽足  {3}`n心情  {4}`n精神  {5}`n吃過 {6} 次、玩過 {7} 次、打贏怪獸 {11} 次" -f $script:pet.name, $days, $st, (Pet-Bar ([double]$script:pet.hunger)), (Pet-Bar ([double]$script:pet.mood)), (Pet-Bar ([double]$script:pet.energy)), [int]$script:pet.fed, [int]$script:pet.played, $lv, (Pet-Stage $lv), $xpLine, [int]$script:pet.wins) 9000
}
function Pet-Rename {
	Add-Type -AssemblyName Microsoft.VisualBasic
	$n = [Microsoft.VisualBasic.Interaction]::InputBox('幫牠取個名字：', '電子雞', [string]$script:pet.name)
	if ($n.Trim()) { $script:pet.name = $n.Trim().Substring(0, [Math]::Min(10, $n.Trim().Length)); Save-Pet; Pet-Say ('我叫{0}！' -f $script:pet.name) }
}
function Pet-Chatter { # 肚子餓／無聊／想睡時自己說一聲（同一句 20 分鐘內不重複；有待決定或清單開著時不吵你）
	if ($script:pet.sleeping -or $script:items.Count -gt 0 -or $panel.Visible -or $script:petBusy -or $script:toy -or $script:mon) { return }
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
	if ((Pet-Level) -ge 2 -and $script:items.Count -eq 0 -and -not $panel.Visible -and $rng.Next(0, 300) -eq 0) { Mon-Spawn $true } # 偶爾（平均約 2.5 小時）自己冒出一隻怪獸
}
$petTimer = New-Object System.Windows.Forms.Timer
$petTimer.Interval = 30000
$petTimer.Add_Tick({ Pet-Tick })

# ---------- 桌面上的小道具（電子雞開著才有）：飯糰＝餵食、皮球＝陪玩、愛心＝摸摸、月亮＝睡覺／叫醒；點一下就做，不用開選單 ----------
$TrayCell = 38; $TrayGap = 4; $TraySize = $TrayCell * 2 + $TrayGap
function Heart-Path([single]$cx, [single]$cy, [single]$s) {
	$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
	$gp.AddBezier($cx, ($cy + $s * 0.9), ($cx - $s * 1.6), ($cy - $s * 0.1), ($cx - $s * 0.8), ($cy - $s * 1.3), $cx, ($cy - $s * 0.45))
	$gp.AddBezier($cx, ($cy - $s * 0.45), ($cx + $s * 0.8), ($cy - $s * 1.3), ($cx + $s * 1.6), ($cy - $s * 0.1), $cx, ($cy + $s * 0.9))
	return $gp
}
$script:histFile = $null; $script:weekly = $null; $script:weeklyAt = -999999
function Weekly-Info { # → @{ pct; live }：每週用量 %。狀態列餵的（即時）優先；沒有就用 Claude 桌面版自己記的最近一筆（12 小時內，可能慢一點，畫面上會加 ~）
	try {
		$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		if (Test-Path $UsageFile) {
			$u = (Get-Content $UsageFile -Raw -Encoding UTF8) | ConvertFrom-Json
			$w = $u.seven_day
			if ($w -and $w.resets_at) { $script:wkResetMs = [double]$w.resets_at * 1000 }
			if ($w -and $null -ne $w.pct -and (($nowMs - [double]$u.at) -lt 6 * 3600000) -and -not ($w.resets_at -and ([double]$w.resets_at * 1000) -lt $nowMs)) { return @{ pct = [double]$w.pct; live = ($u.source -in 'statusline', 'oauth', 'mod') } } # 手動／別處寫的數字只算「約」(~)，不冒充即時
		}
		if (-not $script:histFile) { $base = Join-Path $env:LOCALAPPDATA 'Claude-Data'; if (Test-Path $base) { $script:histFile = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'plan-usage-history.json' } | Where-Object { Test-Path $_ } | Select-Object -First 1 } }
		if ($script:histFile) {
			$h = (Get-Content $script:histFile -Raw -Encoding UTF8) | ConvertFrom-Json
			$s = @($h.samples | Where-Object { $null -ne $_.u.sd }) | Select-Object -Last 1
			if ($s -and $script:wkResetMs -and $script:wkResetMs -lt $nowMs -and [double]$s.t -lt $script:wkResetMs) { return @{ pct = 0.0; live = $false } } # 週額度已重置、這筆是重置前的紀錄：不能再顯示舊數字
				if ($s -and ($nowMs - [double]$s.t) -lt 12 * 3600000) { return @{ pct = [double]$s.u.sd; live = $false } }
		}
	} catch { }
	return $null
}
$PillH = 26
function Build-Pill([string]$pill, [double]$pct) { # 小小一條「週 84%」（綠／黃／紅）
	$bmp = New-Object System.Drawing.Bitmap($TraySize, $PillH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([System.Drawing.Color]::Transparent)
	$col = if ($pct -ge 90) { '#D94A3A' } elseif ($pct -ge 70) { '#D9962B' } else { '#2F7D4F' }
	$gp = Rounded-Path ($TraySize - 1) ($PillH - 1) 12
	$g.FillPath((New-Object System.Drawing.SolidBrush((RGB $col))), $gp)
	$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
	$g.DrawString($pill, $FontTitle, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, $TraySize, $PillH)), $sf)
	$g.Dispose(); return $bmp
}
function Build-Item([int]$i) { # 想要的東西：0 飯糰（肚子餓時才出現）、1 皮球（無聊時才出現）
	$bmp = New-Object System.Drawing.Bitmap($TrayCell, $TrayCell, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
	$bg = if ($i -eq 0) { '#FFF1D6' } else { '#FFE3DD' }
	$g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB $bg))), 1, 1, ($TrayCell - 2), ($TrayCell - 2))
	$g.DrawEllipse((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)), 2, 2, ($TrayCell - 4), ($TrayCell - 4))
	$cx = $TrayCell / 2; $cy = $TrayCell / 2
	if ($i -eq 0) {
		$pts = [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF($cx, ($cy - 11))), (New-Object System.Drawing.PointF(($cx + 12), ($cy + 8))), (New-Object System.Drawing.PointF(($cx - 12), ($cy + 8))))
		$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 7); $pen.LineJoin = 'Round'
		$g.DrawPolygon($pen, $pts); $g.FillPolygon([System.Drawing.Brushes]::White, $pts)
		$g.FillRectangle((New-Object System.Drawing.SolidBrush((RGB '#2B2F36'))), ($cx - 6), ($cy + 2), 12, 8)
	} else {
		$g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#E5533D'))), ($cx - 12), ($cy - 12), 24, 24)
		$g.DrawArc((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.5)), ($cx - 8), ($cy - 8), 16, 16, 200, 70)
		$g.DrawLine((New-Object System.Drawing.Pen((RGB '#B63A28'), 1.5)), ($cx - 12), $cy, ($cx + 12), $cy)
	}
	$g.Dispose(); return $bmp
}
$tray = New-Object PopForm # 週用量小條（不能點，純顯示）
$tray.NoActivate = $true; $tray.Shadow = $false; $tray.Layered = $true
$tray.FormBorderStyle = 'None'; $tray.TopMost = $true; $tray.ShowInTaskbar = $false; $tray.StartPosition = 'Manual'; $tray.Size = New-Object System.Drawing.Size($TraySize, $PillH)
$item = New-Object PopForm # 牠想要的東西：點一下就給牠
$item.NoActivate = $true; $item.Shadow = $false; $item.Layered = $true
$item.FormBorderStyle = 'None'; $item.TopMost = $true; $item.ShowInTaskbar = $false; $item.StartPosition = 'Manual'; $item.Size = New-Object System.Drawing.Size($TrayCell, $TrayCell); $item.Cursor = 'Hand'
$script:trayKey = ''; $script:trayBmp = $null; $script:itemKind = -1; $script:itemBmps = @{}
function Place-Tray {
	$wa2 = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$left = $iconForm.Left - 2; if ($left - $TraySize - $TrayCell - 8 -lt $wa2.Left) { $left = $iconForm.Right + $TraySize + $TrayCell + 8 } # 左邊放不下就放右邊
	$ix = $left - $TrayCell - 4; $iy = $iconForm.Bottom - $TrayCell - 10
	if (-not ($script:carry -and $script:carryForm -eq $item)) { $item.Location = New-Object System.Drawing.Point($ix, $iy) } # 正被你拖著的時候別搶回去
	$tx = $(if ($item.Visible) { $ix } else { $left }) - $TraySize - 4
	$tray.Location = New-Object System.Drawing.Point($tx, ($iconForm.Bottom - $PillH - 16))
	$cx0 = $(if ($tray.Visible) { $tx } elseif ($item.Visible) { $ix } else { $left }) - 34
	$cam.Location = New-Object System.Drawing.Point($cx0, ($iconForm.Bottom - 30 - 18))
	if ($play) { $play.Location = New-Object System.Drawing.Point(($cx0 - 34), ($iconForm.Bottom - 30 - 18)) }
}
function Tray-Update { # 每次畫面更新時：週用量小條、還有牠現在想要什麼（餓了才出飯糰、無聊才出皮球；沒事桌面上就只有牠）
	if ($Snap -or -not $tray -or $script:shooting) { return }
	if ([Environment]::TickCount - $script:weeklyAt -gt 30000) { $script:weekly = Weekly-Info; $script:weeklyAt = [Environment]::TickCount }
	$shown = ([bool]$iconForm.Visible -and -not $script:collapsed)
	if ($shown) { if (-not $cam.Visible) { $cam.Show() }; $cam.SetSprite($camBmp, [byte]225) } elseif ($cam.Visible) { $cam.Hide() }
	if ($play) { if ($shown) { if (-not $play.Visible) { $play.Show() }; $play.SetSprite($script:playBmp, [byte]225) } elseif ($play.Visible) { $play.Hide() } }
	$pill = ''; $pct = 0.0
	if ($script:weekly) { $pct = [double]$script:weekly.pct; $pill = ('{0}週 {1}%' -f $(if ($script:weekly.live) { '' } else { '~' }), [int][Math]::Round($pct)) }
	if ($shown -and $pill) {
		$key = '{0}|{1}' -f $pill, [int]($pct / 10)
		if ($key -ne $script:trayKey -or -not $script:trayBmp) { $script:trayKey = $key; $script:trayBmp = Build-Pill $pill $pct }
		if (-not $tray.Visible) { $tray.Show() }
		$tray.SetSprite($script:trayBmp, [byte]225)
	} elseif ($tray.Visible) { $tray.Hide() }
	$want = -1
	if ($shown -and $script:set.pet -and -not $script:pet.sleeping) { if ([double]$script:pet.hunger -lt 45) { $want = 0 } elseif ([double]$script:pet.mood -lt 40 -and [double]$script:pet.energy -ge 15) { $want = 1 } }
	if ($script:toy -and -not ($script:carry -and $script:carryForm -eq $item)) { $want = -1 } # 已經有東西丟出來了，飯糰／皮球鈕先收起來
	if ($script:fight -or $script:mon) { $want = -1 }
	if ($want -ge 0) {
		if (-not $script:itemBmps.ContainsKey($want)) { $script:itemBmps[$want] = Build-Item $want }
		$script:itemKind = $want
		if (-not $item.Visible) { $item.Show() }
		$item.SetSprite($script:itemBmps[$want], [byte]255)
	} elseif ($item.Visible) { $item.Hide(); $script:itemKind = -1 }
	Place-Tray
}
$item.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:itemDown = [System.Windows.Forms.Cursor]::Position } })
$item.Add_MouseMove({ # 按住拖一下＝把飯糰／皮球拿起來，丟到桌面任何地方；只點一下＝直接給牠
	param($s, $e)
	if ($e.Button -ne 'Left') { return }
	if ($script:carry) { Carry-Move; return }
	if ($script:itemDown -and $script:itemKind -ge 0 -and -not $script:toy) {
		$p = [System.Windows.Forms.Cursor]::Position
		if ([Math]::Abs($p.X - $script:itemDown.X) + [Math]::Abs($p.Y - $script:itemDown.Y) -gt 6) { Toy-Spawn $script:itemKind $item.Location; Carry-Begin $item; $script:itemDown = $null }
	}
})
$item.Add_MouseUp({
	param($s, $e)
	if ($e.Button -ne 'Left') { return }
	$script:itemDown = $null
	if ($script:carry) { Carry-Up; Tray-Update; return }
	$panel.Hide()
	if ($script:itemKind -eq 0) { Pet-Feed } elseif ($script:itemKind -eq 1) { Pet-Play }
	Tray-Update
})
$cam = New-Object PopForm # 截圖鈕：點一下就開始框選
$cam.NoActivate = $true; $cam.Shadow = $false; $cam.Layered = $true
$cam.FormBorderStyle = 'None'; $cam.TopMost = $true; $cam.ShowInTaskbar = $false; $cam.StartPosition = 'Manual'; $cam.Size = New-Object System.Drawing.Size(30, 30); $cam.Cursor = 'Hand'
$camBmp = New-Object System.Drawing.Bitmap(30, 30, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$cg = [System.Drawing.Graphics]::FromImage($camBmp); $cg.SmoothingMode = 'AntiAlias'; $cg.Clear([System.Drawing.Color]::Transparent)
$cg.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#26344A'))), 1, 1, 28, 28)
$cg.DrawEllipse((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)), 2, 2, 26, 26)
$cg.FillRectangle([System.Drawing.Brushes]::White, 12, 8, 6, 3)
$cg.FillRectangle([System.Drawing.Brushes]::White, 8, 10, 14, 11)
$cg.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#26344A'))), 12, 12, 6, 6)
$cg.Dispose()
$script:shooting = $false; $script:shotProc = $null
$shotTimer = New-Object System.Windows.Forms.Timer
$shotTimer.Interval = 300
$shotTimer.Add_Tick({
	if ($script:shotProc -and -not $script:shotProc.HasExited) {
		if (([DateTime]::Now - $script:shotStart).TotalSeconds -lt 90) { return }
		try { $script:shotProc.Kill() } catch { } # 截圖小程式卡住超過 90 秒：強制結束，把寵物叫回來
	}
	$shotTimer.Stop(); $script:shooting = $false; $script:shotProc = $null
	$iconForm.Show(); Update-Look; Tray-Update
})
function Take-Shot { # 把浮窗的所有小視窗先藏起來（才不會拍進去），叫截圖小程式出來框選；它結束後再把浮窗放回來
	if ($script:shooting) { return }
	if ($script:toy -or $script:fight -or $script:mon) { Game-Reset } # 遊戲中的小視窗先收掉，不然會被拍進去
	$shotScript = Join-Path $PSScriptRoot 'shot.ps1'
	if (-not (Test-Path $shotScript)) { return }
	$script:shooting = $true
	foreach ($f in @($panel, $bubble, $petBubble, $tray, $item, $cam, $play, $dockF, $iconForm)) { try { $f.Hide() } catch { } }
	$out = Join-Path ([Environment]::GetFolderPath('MyPictures')) '截圖'
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
	$psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $shotScript + '" -OutDir "' + $out + '"'
	$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
	$script:shotStart = [DateTime]::Now
	try { $script:shotProc = [System.Diagnostics.Process]::Start($psi) } catch { $script:shotProc = $null }
	$shotTimer.Start()
}
$cam.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left' -and -not $script:pdMoved) { Take-Shot } })
$iconForm.Add_LocationChanged({ if ($tray.Visible -or $item.Visible -or $cam.Visible) { Place-Tray } })

# ---------- 遊戲（電子雞開著才有）：丟食物、追皮球、打怪獸 ----------
# 食物／皮球：右鍵「電子雞」拿出來，或牠餓了／無聊時桌面上出現的飯糰、皮球，用滑鼠拖到桌面任何地方放開（皮球可以甩）；牠會跑過去吃／追著踢。
# 怪獸：右鍵「電子雞」→ 找怪獸打架（升到 Lv.2 後偶爾也會自己冒出來，不理牠 2 分鐘就走）。點怪獸＝出招；怪獸變紅光時點小橘＝閃躲反擊。
$script:carry = $null; $script:carryForm = $null; $script:toy = $null; $script:mon = $null; $script:fight = $null
$script:petBusy = $false; $script:returning = $false; $script:itemDown = $null; $script:monBmps = @{}; $script:hudKey = ''
$ToyS = $TrayCell; $MonS = 84
foreach ($nm in 'toyF', 'monF', 'hudF') {
	$f = New-Object PopForm
	$f.NoActivate = $true; $f.Shadow = $false; $f.Layered = $true
	$f.FormBorderStyle = 'None'; $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'
	Set-Variable -Name $nm -Value $f
}
$toyF.Size = New-Object System.Drawing.Size($ToyS, $ToyS); $toyF.Cursor = 'Hand'
$monF.Size = New-Object System.Drawing.Size($MonS, $MonS); $monF.Cursor = 'Hand'
$hudF.Size = New-Object System.Drawing.Size(264, 62)
$hudFont = Font 9 $true; $hudFont2 = Font 8.5
function Pet-StepTo([double]$tx, [double]$ty, [double]$step) { # 小橘（左上角）朝 (tx, ty) 走 $step 像素；到了回傳 $true
	$cx = $iconForm.Left; $cy = $iconForm.Top; $dx = $tx - $cx; $dy = $ty - $cy; $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
	if ($d -le $step) { $nx = [int]$tx; $ny = [int]$ty; $arr = $true } else { $nx = [int]($cx + $dx / $d * $step); $ny = [int]($cy + $dy / $d * $step); $arr = $false }
	if ($nx -ne $cx -or $ny -ne $cy) { $iconForm.Location = New-Object System.Drawing.Point($nx, $ny); if ($petBubble.Visible) { Place-PetBubble } }
	$want = -not $arr
	if ($want -ne [bool]$script:moving) { $script:moving = $want; Set-AnimRate }
	return $arr
}
function Pet-Return { # 玩完了：不走路模式就慢慢走回記住的位置；走路模式不用，牠自己會接著逛
	$script:moving = $false; Set-AnimRate
	$script:returning = $true; $gameTimer.Start() # 玩完一定走回原本的位置（走路模式＝回跑道、沒拖過＝回右下角）；飯糰現在可以放在畫面任何位置，不走回來牠會一直飄在半空
}
function Return-Target { # 回哪裡：[x, y]
	$w = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	if ($script:set.walk -and -not $script:set.perch) { return @([int]$iconForm.Left, [int](Runway-Y)) }
	if ($null -ne $script:set.x -and $null -ne $script:set.y) { return @([int]$script:set.x, [int]$script:set.y) }
	return @(($w.Right - $IconBox - 24), ($w.Bottom - $IconBox - 60))
}
function Toy-Clear {
	$script:toy = $null; $script:carry = $null; $script:carryForm = $null
	try { $toyF.Hide() } catch { }
	if (-not $script:fight) { $script:petBusy = $false; Pet-Return }
}
function Toy-Spawn([int]$kind, $loc) { # 把飯糰（0）／皮球（1）放出來，等你拖
	if ($script:toy) { Toy-Clear }
	if (-not $script:itemBmps.ContainsKey($kind)) { $script:itemBmps[$kind] = Build-Item $kind }
	$script:toy = @{ kind = $kind; x = [double]$loc.X; y = [double]$loc.Y; vx = 0.0; vy = 0.0; state = 'idle'; born = [Environment]::TickCount; kicks = 0; lastKick = 0 }
	$toyF.Location = $loc; if (-not $toyF.Visible) { $toyF.Show() }
	$toyF.SetSprite($script:itemBmps[$kind], [byte]255)
	$gameTimer.Start()
}
function Toy-Menu([int]$kind) {
	if (($script:petBusy -and -not $script:toy) -or $script:fight -or $script:mon) { Pet-Say '等一下，現在在忙～'; return } # 牠正在跑去吃／追上一個東西時可以直接再丟下一個
	if ($script:pet.sleeping) { Pet-Wake '' } # 睡著了：直接叫醒，不用再找選單
	$wa = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$x = $iconForm.Left - $ToyS - 12; if ($x -lt $wa.Left) { $x = $iconForm.Right + 12 }
	Toy-Spawn $kind (New-Object System.Drawing.Point($x, ($iconForm.Bottom - $ToyS - 40)))
	Pet-Say ('把{0}拖到桌面任何地方放開，我去{1}！' -f $(if ($kind -eq 0) { '飯糰' } else { '皮球（可以用甩的）' }), $(if ($kind -eq 0) { '吃' } else { '追' })) 5000
}
function Carry-Begin($form) { # 開始拖：$form 是正在被滑鼠按住的那個小視窗（飯糰鈕或剛放出來的東西）
	$p = [System.Windows.Forms.Cursor]::Position
	$script:carryForm = $form; $script:carry = @{ ox = $p.X - $form.Left; oy = $p.Y - $form.Top; s = (New-Object System.Collections.ArrayList) }
	if ($script:toy) { $script:toy.state = 'held' }
}
function Carry-Move {
	if (-not $script:carry) { return }
	$p = [System.Windows.Forms.Cursor]::Position
	$wa = $(if ($script:toy -and $script:toy.kind -eq 0) { [System.Windows.Forms.Screen]::FromPoint($p).Bounds } else { [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea }) # 飯糰：游標在哪個螢幕、哪個位置（含工作列）都能放；皮球因為有物理反彈，還是限制在小橘那個螢幕
	$x = [Math]::Min([Math]::Max($wa.Left, $p.X - $script:carry.ox), $wa.Right - $ToyS); $y = [Math]::Min([Math]::Max($wa.Top, $p.Y - $script:carry.oy), $wa.Bottom - $ToyS)
	$script:carryForm.Location = New-Object System.Drawing.Point($x, $y)
	[void]$script:carry.s.Add(@($x, $y, [Environment]::TickCount)); if ($script:carry.s.Count -gt 6) { $script:carry.s.RemoveAt(0) }
}
function Carry-Up { # 放開：食物掉到地上、皮球照你甩的速度飛出去；小橘就跑過去
	if (-not $script:carry -or -not $script:toy) { $script:carry = $null; return }
	$t = $script:toy; $cf = $script:carryForm; $now = [Environment]::TickCount
	$t.x = [double]$cf.Left; $t.y = [double]$cf.Top
	$vx = 0.0; $vy = 0.0; $s = $script:carry.s
	if ($s.Count -ge 2) { $a = $s[0]; $b = $s[$s.Count - 1]; $dt = [Math]::Max(1, $b[2] - $a[2]); if ($now - $b[2] -lt 120 -and $t.kind -eq 1) { $vx = [Math]::Max(-42.0, [Math]::Min(42.0, ($b[0] - $a[0]) / $dt * 30)); $vy = [Math]::Max(-42.0, [Math]::Min(42.0, ($b[1] - $a[1]) / $dt * 30)) } }
	$t.vx = $vx; $t.vy = $vy; $t.state = $(if ($t.kind -eq 0) { 'rest' } else { 'fall' }); # 飯糰放哪就停哪，小橘走過去吃；皮球才會掉下去彈
	 $script:carry = $null; $script:carryForm = $null
	if ($cf -ne $toyF) { try { $cf.Hide() } catch { }; $toyF.Location = New-Object System.Drawing.Point([int]$t.x, [int]$t.y); if (-not $toyF.Visible) { $toyF.Show() }; $toyF.SetSprite($script:itemBmps[$t.kind], [byte]255) }
	if ($script:pet.sleeping) { Pet-Wake '' }
	$script:petBusy = $true; $script:returning = $false; $panel.Hide(); $gameTimer.Start()
}
function Toy-Step($now, $wa) { # 食物／皮球每格的動作；回傳還要不要繼續
	$t = $script:toy; $S = $ToyS; $floor = $wa.Bottom - $S + 2
	if ($t.state -eq 'idle') { if ($now - $t.born -gt 120000) { Toy-Clear; return $false }; return $true }
	if ($t.state -eq 'held') { return $true }
	if ($t.state -eq 'fall') {
		$t.vy += 1.6; $t.x += $t.vx; $t.y += $t.vy
		if ($t.y -ge $floor) { $t.y = $floor; if ($t.kind -eq 1 -and [Math]::Abs($t.vy) -gt 4) { $t.vy = - $t.vy * 0.68 } else { $t.vy = 0.0 }; $t.vx *= $(if ($t.kind -eq 1) { 0.97 } else { 0.7 }) }
		if ($t.y -lt $wa.Top) { $t.y = $wa.Top; $t.vy = [Math]::Abs($t.vy) * 0.5 }
		if ($t.x -lt $wa.Left) { $t.x = $wa.Left; $t.vx = [Math]::Abs($t.vx) * 0.8 }
		if ($t.x -gt $wa.Right - $S) { $t.x = $wa.Right - $S; $t.vx = - [Math]::Abs($t.vx) * 0.8 }
		if ($t.y -ge $floor - 0.5 -and [Math]::Abs($t.vy) -lt 0.5 -and [Math]::Abs($t.vx) -lt 0.4) { $t.vx = 0.0; $t.state = 'rest' }
		$toyF.Location = New-Object System.Drawing.Point([int]$t.x, [int]$t.y)
	}
	# 小橘跑過去（只在地上跑）
	$tcx = $t.x + $S / 2; $pcx = $iconForm.Left + $IconBox / 2; $dx = $tcx - $pcx; $pf = Runway-Y
	if ($t.kind -eq 0) {
		$tcy = $t.y + $S / 2; $pcy = $iconForm.Top + $IconBox / 2; $dy = $tcy - $pcy
		if ([Math]::Abs($dx) -lt 36 -and [Math]::Abs($dy) -lt 36) { Toy-Clear; Pet-Feed; return $false }
		[void](Pet-StepTo ($tcx - $IconBox / 2) ($tcy - $IconBox / 2) 10) # 往飯糰的位置直直走過去（畫面任何位置都行）
	} else {
		if ([Math]::Abs($dx) -lt 52 -and $t.y -gt $floor - 70 -and $now - $t.lastKick -gt 450) { # 踢！
			$dir = $(if ($dx -ge 0) { 1 } else { -1 }); if ($t.x -lt $wa.Left + 90) { $dir = 1 } elseif ($t.x -gt $wa.Right - 90 - $S) { $dir = -1 }
			$t.vx = $dir * (9 + $rng.Next(0, 8)); $t.vy = - (11 + $rng.Next(0, 7)); $t.state = 'fall'; $t.kicks++; $t.lastKick = $now
			$script:pet.mood = Pet-Clamp ([double]$script:pet.mood + 2); Pet-Fx 500 'play'
			if ($t.kicks -ge 10 -or $now - $t.born -gt 90000) { Toy-Clear; Pet-Play; return $false }
		} else { [void](Pet-StepTo ($tcx - $IconBox / 2) $pf 11) }
	}
	return $true
}
function Build-Monster([int]$flash, [int]$dir, [int]$bob) { # flash：0 平常、1 被打到（變白）、2 要攻擊了（紅光＋驚嘆號）；dir：眼睛看向左（-1）右（1）；bob：0–2 上下晃
	$key = '{0}|{1}|{2}' -f $flash, $dir, $bob
	if ($script:monBmps.ContainsKey($key)) { return $script:monBmps[$key] }
	$bmp = New-Object System.Drawing.Bitmap($MonS, $MonS, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
	$yo = $bob * 2
	$bc = @('#7B4FBF', '#FFFFFF', '#E0483A')[$flash]; $bl = @('#A98BE0', '#F2F2F2', '#F59A8F')[$flash]
	$dark = New-Object System.Drawing.SolidBrush((RGB '#2B2F36')); $horn = New-Object System.Drawing.SolidBrush((RGB '#F2E6C9'))
	foreach ($hx in 18, 50) { $g.FillPolygon($horn, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF($hx, (34 + $yo))), (New-Object System.Drawing.PointF(($hx + 8), (10 + $yo))), (New-Object System.Drawing.PointF(($hx + 16), (30 + $yo))))) }
	$bb = New-Object System.Drawing.SolidBrush((RGB $bc))
	$g.FillEllipse($bb, 14, 74, 20, 9); $g.FillEllipse($bb, 50, 74, 20, 9)
	$g.FillEllipse($bb, 6, (28 + $yo), 72, (50 - $yo))
	$g.DrawEllipse((New-Object System.Drawing.Pen((RGB '#2B2F36'), 2)), 6, (28 + $yo), 72, (50 - $yo))
	$g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB $bl))), 24, (52 + $yo), 36, 22)
	foreach ($ex in 18, 46) {
		$g.FillEllipse([System.Drawing.Brushes]::White, $ex, (38 + $yo), 20, 22)
		$g.FillEllipse($dark, ($ex + 6 + $dir * 3), (46 + $yo), 8, 9)
	}
	$bp = New-Object System.Drawing.Pen((RGB '#2B2F36'), 3)
	$g.DrawLine($bp, 16, (36 + $yo), 38, (43 + $yo)); $g.DrawLine($bp, 68, (36 + $yo), 46, (43 + $yo))
	$g.FillRectangle($dark, 31, (62 + $yo), 22, 5)
	$g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(33, (62 + $yo))), (New-Object System.Drawing.PointF(37, (71 + $yo))), (New-Object System.Drawing.PointF(41, (62 + $yo)))))
	$g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(43, (62 + $yo))), (New-Object System.Drawing.PointF(47, (71 + $yo))), (New-Object System.Drawing.PointF(51, (62 + $yo)))))
	if ($flash -eq 2) { $g.DrawString('!', (Font 15 $true), (New-Object System.Drawing.SolidBrush((RGB '#D94A3A'))), 36, -3) }
	$g.Dispose(); $script:monBmps[$key] = $bmp; return $bmp
}
function Build-Hud([int]$php, [int]$pmax, [int]$mhp, [int]$mmax, [string]$msg) {
	$bmp = New-Object System.Drawing.Bitmap(264, 62, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([System.Drawing.Color]::Transparent)
	$g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238, 31, 58, 95))), (Rounded-Path 263 61 12))
	$nm = [string]$script:pet.name; if ($nm.Length -gt 3) { $nm = $nm.Substring(0, 3) }
	$rows = @(@($nm, $php, $pmax, '#4CC38A', 8), @('怪獸', $mhp, $mmax, '#E0483A', 24))
	foreach ($r in $rows) {
		$g.DrawString($r[0], $hudFont, [System.Drawing.Brushes]::White, 8, ($r[4] - 3))
		$g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 255, 255, 255))), 48, $r[4], 206, 10)
		$w = [int](206 * [Math]::Max(0, [Math]::Min(1, [double]$r[1] / [double]$r[2]))); if ($w -gt 0) { $g.FillRectangle((New-Object System.Drawing.SolidBrush((RGB $r[3]))), 48, $r[4], $w, 10) }
	}
	$g.DrawString($msg, $hudFont2, (New-Object System.Drawing.SolidBrush((RGB '#FFD58A'))), 8, 42)
	$g.Dispose(); return $bmp
}
function Mon-Spawn([bool]$auto) {
	if ($script:petBusy -or $script:fight -or $script:mon -or $script:toy) { if (-not $auto) { Pet-Say '等一下，現在在忙～' }; return }
	if ($script:pet.sleeping) { if ($auto) { return }; Pet-Wake '' }
	$wa = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$mx = $iconForm.Left - 330; if ($mx -lt $wa.Left + 10) { $mx = [Math]::Min($iconForm.Right + 240, $wa.Right - $MonS - 10) }
	$script:mon = @{ x = [double]$mx; y = [double]($wa.Bottom - $MonS + 6); born = [Environment]::TickCount; key = ''; flashUntil = 0 }
	$monF.Location = New-Object System.Drawing.Point([int]$mx, [int]($wa.Bottom - $MonS + 6)); if (-not $monF.Visible) { $monF.Show() }
	$monF.SetSprite((Build-Monster 0 $(if ($mx -lt $iconForm.Left) { 1 } else { -1 }) 0), [byte]255)
	$panel.Hide(); Pet-Say '怪獸出現了！點牠就開打（輸了也沒關係）' 6000
	$gameTimer.Start()
}
function Fight-Begin {
	if ($script:fight -or -not $script:mon) { return }
	$lv = Pet-Level; $now = [Environment]::TickCount
	$script:fight = @{ pmax = 50 + 12 * $lv; php = 50 + 12 * $lv; mmax = 36 + 14 * $lv; mhp = 36 + 14 * $lv; pMode = 'home'; mMode = 'idle'; homeX = $iconForm.Left; mHome = $script:mon.x; nextAtk = $now + 2200; guardUntil = 0; lastAtk = 0; mT = 0; msg = '開打！點怪獸出招'; ended = $false; endAt = 0; win = $false; lv = $lv }
	$script:petBusy = $true; $script:returning = $false; $script:hudKey = ''
	$panel.Hide(); $bubble.Hide(); $petBubble.Hide()
	$wa = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$hx = [Math]::Min([Math]::Max($wa.Left, (($iconForm.Left + $script:mon.x) / 2) - 90), $wa.Right - 264)
	$hudF.Location = New-Object System.Drawing.Point([int]$hx, ($wa.Bottom - 240)); if (-not $hudF.Visible) { $hudF.Show() }
}
function Fight-Attack {
	$F = $script:fight; if (-not $F -or $F.ended) { return }
	$now = [Environment]::TickCount
	if ($F.pMode -ne 'home' -or $now - $F.lastAtk -lt 600) { return }
	$F.pMode = 'dash'
}
function Fight-Guard {
	$F = $script:fight; if (-not $F -or $F.ended) { return }
	$now = [Environment]::TickCount
	if ($now -lt $F.guardUntil + 250) { return }
	$F.guardUntil = $now + 600; $F.msg = '閃躲！'
}
function Fight-End([bool]$win) {
	$F = $script:fight; $F.ended = $true; $F.win = $win; $F.endAt = [Environment]::TickCount
	$p = $script:pet
	if ($win) {
		$p.mood = Pet-Clamp ([double]$p.mood + 20); $p.hunger = Pet-Clamp ([double]$p.hunger - 8); $p.energy = Pet-Clamp ([double]$p.energy - 12)
		$p.wins = [int]$p.wins + 1; $F.msg = '打贏了！'; Pet-Refresh; Pet-Fx 4000 'heart'; Pet-Gain (22 + 4 * $F.lv) '打贏怪獸了！'
	} else {
		$p.mood = Pet-Clamp ([double]$p.mood - 15); $p.energy = Pet-Clamp ([double]$p.energy - 15); $p.hunger = Pet-Clamp ([double]$p.hunger - 5)
		$F.msg = '輸了…下次再來'; Pet-Refresh; Pet-Fx 3000 'sad'; Pet-Gain 4 '好痛…雖敗猶榮'
	}
}
function Fight-Step($now, $wa) {
	$F = $script:fight; $M = $script:mon; $pf = Runway-Y; $mfloor = $wa.Bottom - $MonS + 6
	$mcx = $M.x + $MonS / 2; $pcx = $iconForm.Left + $IconBox / 2; $dirToPet = $(if ($pcx -ge $mcx) { 1 } else { -1 })
	if ($F.ended) { # 結束：怪獸淡出、過一會兒收場
		$el = $now - $F.endAt; $a = [int][Math]::Max(0, 255 - 255 * $el / 800); $monF.SetSprite((Build-Monster 0 $dirToPet 0), [byte]$a)
		if ($el -gt 1600) { $monF.Hide(); $hudF.Hide(); $script:fight = $null; $script:mon = $null; $script:petBusy = $false; Pet-Return }
		return
	}
	# --- 小橘 ---
	if ($F.pMode -eq 'home') { [void](Pet-StepTo $F.homeX $pf 12) }
	elseif ($F.pMode -eq 'dash') {
		$d = $(if ($mcx -ge $pcx) { 1 } else { -1 })
		if (Pet-StepTo ($mcx - $d * 62 - $IconBox / 2) $pf 30) {
			$dmg = 7 + 2 * $F.lv + $rng.Next(0, 6); $F.mhp -= $dmg; $M.flashUntil = $now + 180; $F.msg = ('命中！ -{0}' -f $dmg); $F.pMode = 'back'; $F.lastAtk = $now; Pet-Fx 400 'play'
			if ($F.mhp -le 0) { $F.mhp = 0; Fight-End $true; return }
		}
	}
	elseif ($F.pMode -eq 'back') { if (Pet-StepTo $F.homeX $pf 20) { $F.pMode = 'home' } }
	if ($now -lt $F.guardUntil) { $prog = 1 - ($F.guardUntil - $now) / 600.0; $iconForm.Top = [int]($pf - 46 * [Math]::Sin([Math]::PI * $prog)) } # 跳起來閃
	# --- 怪獸 ---
	switch ($F.mMode) {
		'idle' { $M.x += [Math]::Sign($F.mHome - $M.x) * [Math]::Min(14, [Math]::Abs($F.mHome - $M.x)); if ($now -ge $F.nextAtk -and $F.pMode -eq 'home') { $F.mMode = 'tele'; $F.mT = $now; $F.msg = '怪獸要攻擊了！快點小橘閃躲' } }
		'tele' { if ($now - $F.mT -ge 700) { $F.mMode = 'lunge'; $F.mT = $now } }
		'lunge' {
			$arr = $false; $tx = $pcx - $dirToPet * 56 - $MonS / 2; $dx = $tx - $M.x
			if ([Math]::Abs($dx) -le 36) { $M.x = $tx; $arr = $true } else { $M.x += [Math]::Sign($dx) * 36 }
			if ($arr -or $now - $F.mT -ge 320) {
				if ($now -le $F.guardUntil) { $F.mhp -= 6; $M.flashUntil = $now + 180; $F.msg = '閃過了！反擊 -6'; $F.mMode = 'stun'; $F.mT = $now; if ($F.mhp -le 0) { $F.mhp = 0; Fight-End $true; return } }
				else { $dmg = 6 + $F.lv + $rng.Next(0, 6); $F.php -= $dmg; $F.msg = ('被打到了… -{0}' -f $dmg); Pet-Fx 500 'sad'; $F.mMode = 'back'; if ($F.php -le 0) { $F.php = 0; Fight-End $false; return } }
				$F.nextAtk = $now + $rng.Next(1800, 3200)
			}
		}
		'stun' { if ($now - $F.mT -ge 700) { $F.mMode = 'back' } }
		'back' { $dx = $F.mHome - $M.x; if ([Math]::Abs($dx) -le 18) { $M.x = $F.mHome; $F.mMode = 'idle' } else { $M.x += [Math]::Sign($dx) * 18 } }
	}
	$flash = $(if ($now -lt $M.flashUntil) { 1 } elseif ($F.mMode -eq 'tele' -or $F.mMode -eq 'lunge') { 2 } else { 0 })
	$bob = $(if ($F.mMode -eq 'idle') { [int](($now / 280) % 3) } else { 0 })
	$monF.Location = New-Object System.Drawing.Point([int]$M.x, [int]$mfloor)
	$k = '{0}|{1}|{2}' -f $flash, $dirToPet, $bob
	if ($k -ne $M.key) { $M.key = $k; $monF.SetSprite((Build-Monster $flash $dirToPet $bob), [byte]255) }
	$hk = '{0}|{1}|{2}' -f $F.php, $F.mhp, $F.msg
	if ($hk -ne $script:hudKey) { $script:hudKey = $hk; $hudF.SetSprite((Build-Hud $F.php $F.pmax $F.mhp $F.mmax $F.msg), [byte]255) }
}
function Mon-Wait-Step($now, $wa) { # 怪獸站著等你點；2 分鐘沒人理就走
	$M = $script:mon
	if ($now - $M.born -gt 120000) { $monF.Hide(); $script:mon = $null; Pet-Say '怪獸走掉了～' 3000; return }
	$bob = [int](($now / 300) % 3); $dir = $(if ($M.x -lt $iconForm.Left) { 1 } else { -1 }); $k = '0|{0}|{1}' -f $dir, $bob
	if ($k -ne $M.key) { $M.key = $k; $monF.SetSprite((Build-Monster 0 $dir $bob), [byte]255) }
}
function Game-Step {
	$lb = (([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -ne 0) # 丟出去的飯糰／皮球還在時，點畫面其他位置（不是小橘、不是飯糰、不是浮窗）＝收起來、小橘跳回原位
	if ($lb -and -not $script:lastLeft -and $script:toy -and $script:toy.state -ne 'held' -and -not $script:carry) {
		$cp = [System.Windows.Forms.Cursor]::Position; $inside = $false
		foreach ($fm in @($toyF, $iconForm, $dockF, $play, $panel, $petBubble)) { try { if ($fm.Visible -and $fm.Bounds.Contains($cp)) { $inside = $true } } catch { } }
		if (-not $inside) { $script:lastLeft = $lb; Pet-Reset; return }
	}
	$script:lastLeft = $lb
	$now = [Environment]::TickCount; $wa = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea; $busy = $false
	if ($script:toy) { if (Toy-Step $now $wa) { $busy = $true } }
	if ($script:fight) { Fight-Step $now $wa; $busy = $true } elseif ($script:mon) { Mon-Wait-Step $now $wa; $busy = $true }
	if ($script:returning -and -not $script:petBusy) { $rt = Return-Target; if (Pet-StepTo $rt[0] $rt[1] 14) { $script:returning = $false; Place-Around } else { $busy = $true } }
	if (-not $busy) { $gameTimer.Stop() }
}
function Game-Reset { # 出錯時的保險：收掉所有東西、把牠放回原本的樣子
	$gameTimer.Stop(); $script:toy = $null; $script:carry = $null; $script:carryForm = $null; $script:fight = $null; $script:mon = $null; $script:petBusy = $false; $script:returning = $false
	foreach ($f in @($toyF, $monF, $hudF)) { try { $f.Hide() } catch { } }
	$script:moving = $false; Set-AnimRate
}
$gameTimer = New-Object System.Windows.Forms.Timer
$gameTimer.Interval = 30
$gameTimer.Add_Tick({
	try { Game-Step } catch { try { Add-Content -Path $ErrLog -Value ("{0} game: {1}" -f (Get-Date -Format s), $_.Exception.ToString()) -Encoding UTF8 } catch { }; Game-Reset }
})
$toyF.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left' -and $script:toy -and $script:toy.state -eq 'idle') { Carry-Begin $toyF } })
$toyF.Add_MouseMove({ param($s, $e) if ($e.Button -eq 'Left' -and $script:carry) { Carry-Move } })
$toyF.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left' -and $script:carry) { Carry-Up } })
$monF.Add_MouseUp({ param($s, $e) if ($e.Button -ne 'Left') { return }; if ($script:fight) { Fight-Attack } elseif ($script:mon) { Fight-Begin; Fight-Attack } })
$mpi.food = $mp.DropDownItems.Add('丟飯糰（拖到桌面任何地方放開）'); $mpi.ball = $mp.DropDownItems.Add('丟皮球（拖著甩出去，牠會追）'); $mpi.mon = $mp.DropDownItems.Add('找怪獸打架（點怪獸出招）')
function Pet-Enable([bool]$on) { # 電子雞（含丟食物、追球、打怪獸）整套開／關；關掉時桌面上只剩原本的圖示
	$wasOn = [bool]$script:set.pet; $script:set.pet = $on; Save-Settings
	if (-not $on) { Game-Reset; $petBubble.Hide(); $item.Hide(); Go-Home }
	elseif (-not $wasOn) { $script:pet.last = (Now-Sec); Save-Pet; Pet-Say ('我是{0}！右鍵點我選「電子雞」，可以餵我、陪我玩、找怪獸打架～' -f $script:pet.name) 7000 }
	Apply-Icon; Update-Look; Tray-Update
}
[void]$mp.DropDownItems.Add('-'); $mpi.off = $mp.DropDownItems.Add('關閉電子雞（遊戲也一起停，之後可再開）')
$mpi.off.Add_Click({ $panel.Hide(); Pet-Enable $false })
$mpOn = New-Object System.Windows.Forms.ToolStripMenuItem '開啟電子雞（餵食、丟球、打怪獸）'
$mpOn.Add_Click({ Pet-Enable $true })
[void]$menu.Items.Insert(1, $mpOn)
$menu.Add_Opening({ $mpOn.Visible = -not [bool]$script:set.pet })
function Pet-Reset { # 回到原本：丟出去的飯糰／皮球、怪獸、打架全部收掉，小橘走回原位（玩到一半卡住、或只想回平常的樣子時用）
	$panel.Hide(); Dock-Hide
	Game-Reset; Pet-Return
	Pet-Say '好～都收起來了，回到原本的樣子' 3000
}
$mReset = New-Object System.Windows.Forms.ToolStripMenuItem '回到原本（收起玩具／怪獸，小橘走回原位）'
$mReset.Add_Click({ Pet-Reset })
[void]$menu.Items.Insert(0, $mReset)
$menu.Add_Opening({ $mReset.Visible = [bool]$script:set.pet })
function Idle-Step { # 每 0.1 秒：滑鼠在牠身上／有新通知／玩東西＝醒著；沒人理 8 秒起偶爾做動作，20 秒起慢慢縮小並把小工具收起來
	if ($Snap -or $script:shooting) { return }
	$now = [Environment]::TickCount; $cp = [System.Windows.Forms.Cursor]::Position; $hover = $false
	foreach ($fm in @($iconForm, $bubble, $panel, $tray, $cam, $play, $dockF, $item)) { try { if ($fm.Visible -and $fm.Bounds.Contains($cp)) { $hover = $true } } catch { } }
	if ($panel.Visible) { if ($panel.Bounds.Contains($cp) -or $iconForm.Bounds.Contains($cp)) { $script:panelAt = $now } elseif ([int]$script:set.panelHide -gt 0 -and ($now - $script:panelAt) -gt ([int]$script:set.panelHide * 1000)) { $panel.Hide(); Update-Look; return } } else { $script:panelAt = $now } # 清單打開後：設定成幾秒沒碰就自動收起（0＝只有按「收起來」才收）
	if ($null -eq $script:hoverArmed) { $script:hoverArmed = $true; $script:hoverSince = 0 }
	if ($script:set.openOnHover -and $script:items.Count -gt 0 -and -not $panel.Visible -and -not $script:down -and -not $script:petBusy -and $iconForm.Visible) { # 有待決定＋設定成「碰到就打開」：游標停在小橘上 0.25 秒就開；關掉後要先離開再碰才會再開，不會一關就彈回來
		$over = $iconForm.Bounds.Contains($cp)
		if ($over -and $script:hoverArmed -and $script:hoverSince -gt 0 -and ($now - $script:hoverSince) -gt 250) { $script:hoverArmed = $false; $script:hoverSince = 0; $script:lastActive = $now; Show-Panel; return }
		if ($over) { if ($script:hoverSince -eq 0) { $script:hoverSince = $now } } else { $script:hoverSince = 0; $script:hoverArmed = $true }
	} elseif ($panel.Visible) { $script:hoverArmed = $false; $script:hoverSince = 0 }
	$active = [bool]($hover -or $script:petBusy -or $script:toy -or $script:fight -or $script:mon -or $script:carry -or $script:down -or $script:pd -or $panel.Visible -or $dockF.Visible)
	if ($active) { $script:lastActive = $now }
	$idle = $now - $script:lastActive
	$old = [int]($script:shrink * 10)
	if ($script:set.autoShrink -and $idle -gt ([int]$script:set.shrinkAfter * 1000)) { $script:shrink = [Math]::Min(1.0, $script:shrink + 0.025) } else { $script:shrink = [Math]::Max(0.0, $script:shrink - 0.2) }
	$col = ($script:shrink -ge 0.35)
	if ($col -ne $script:collapsed) { $script:collapsed = $col; Update-Look; Tray-Update }
	if ([int]($script:shrink * 10) -ne $old) { Show-Frame }
	if ($script:set.pet -and -not $active -and $idle -gt ([int]$script:set.idleAfter * 1000) -and -not (Pet-Asleep) -and -not (Pet-Fx-On) -and $now -ge $script:nextIdleAct) {
		$acts = @($script:set.idle); if ($acts.Count -gt 0) { Pet-Fx 4500 ([string]$acts[$rng.Next(0, $acts.Count)]) }
		$script:nextIdleAct = $now + $rng.Next(10000, 22000)
	}
}
$mIdle = New-Object System.Windows.Forms.ToolStripMenuItem '沒人理牠時會做什麼（可複選，點了先演一次）'
foreach ($d in $IdleActs) { $it = $mIdle.DropDownItems.Add($d[1]); $it.Tag = $d[0]
	$it.Add_Click({ param($s, $e) $k = [string]$s.Tag; $cur = @($script:set.idle); if ($cur -contains $k) { $cur = @($cur | Where-Object { $_ -ne $k }) } else { $cur = @($cur) + $k; Pet-Fx 4500 $k }; $script:set.idle = $cur; Save-Settings }) }
$mShr = New-Object System.Windows.Forms.ToolStripMenuItem '沒有新通知就自動縮小、收起小工具（滑鼠移上去恢復）'
$mShr.Add_Click({ $script:set.autoShrink = -not [bool]$script:set.autoShrink; Save-Settings; $script:lastActive = [Environment]::TickCount })
function Ask-Seconds([string]$askWhat, [int]$askCur, [int]$askMin, [int]$askMax, [string]$askNote) { # 跳出輸入框讓你打秒數；取消或亂打就不改。參數名故意取長：輸入框開著時計時器照跑，名字跟主程式的變數撞到（例如 $hint）會讓清單畫面出錯
	Add-Type -AssemblyName Microsoft.VisualBasic
	$askR = ([Microsoft.VisualBasic.Interaction]::InputBox(($askWhat + "`n" + $askNote), '設定秒數', [string]$askCur)).Trim()
	$askN = 0; if ($askR -and [int]::TryParse($askR, [ref]$askN) -and $askN -ge $askMin -and $askN -le $askMax) { return $askN }
	if ($askR) { Pet-Say ('請輸入 {0}～{1} 的整數' -f $askMin, $askMax) 4000 }
	return $null
}
$mPh = New-Object System.Windows.Forms.ToolStripMenuItem '待決定清單點開後幾秒自動收起…'
$mPh.Add_Click({ $v = Ask-Seconds '待決定清單點開後，沒碰它幾秒就自動收起？' ([int]$script:set.panelHide) 0 3600 '輸入 0＝只有按「收起來」才收（滑鼠停在清單上不算沒碰）'; if ($null -ne $v) { $script:set.panelHide = $v; Save-Settings; $script:panelAt = [Environment]::TickCount } })
$mSa = New-Object System.Windows.Forms.ToolStripMenuItem '沒人碰幾秒後開始縮小…'
$mSa.Add_Click({ $v = Ask-Seconds '沒有新通知、也沒碰牠，幾秒後開始慢慢縮小並收起小工具？' ([int]$script:set.shrinkAfter) 3 3600 '輸入 3～3600 的秒數（現在預設 20）'; if ($null -ne $v) { $script:set.shrinkAfter = $v; Save-Settings; $script:lastActive = [Environment]::TickCount } })
$mIa = New-Object System.Windows.Forms.ToolStripMenuItem '沒人碰幾秒後開始做動作…'
$mIa.Add_Click({ $v = Ask-Seconds '沒人碰牠，幾秒後開始偶爾做動作（托球、跳舞…）？' ([int]$script:set.idleAfter) 2 3600 '輸入 2～3600 的秒數（現在預設 8）'; if ($null -ne $v) { $script:set.idleAfter = $v; Save-Settings; $script:lastActive = [Environment]::TickCount } })
[void]$menu.Items.Insert(1, $mIdle); [void]$menu.Items.Insert(2, $mShr); [void]$menu.Items.Insert(3, $mPh); [void]$menu.Items.Insert(4, $mSa); [void]$menu.Items.Insert(5, $mIa)
$menu.Add_Opening({ $mIdle.Visible = [bool]$script:set.pet; $mShr.Checked = [bool]$script:set.autoShrink; $cur = @($script:set.idle); foreach ($x in $mIdle.DropDownItems) { $x.Checked = ($cur -contains [string]$x.Tag) }; $mPh.Text = '待決定清單點開後幾秒自動收起…（現在：' + $(if ([int]$script:set.panelHide -gt 0) { [string][int]$script:set.panelHide + ' 秒' } else { '按「收起來」才收' }) + '）'; $mSa.Text = '沒人碰幾秒後開始縮小…（現在：' + [int]$script:set.shrinkAfter + ' 秒）'; $mSa.Visible = [bool]$script:set.autoShrink; $mIa.Visible = [bool]$script:set.pet; $mIa.Text = '沒人碰幾秒後開始做動作…（現在：' + [int]$script:set.idleAfter + ' 秒）' })
$mHv = New-Object System.Windows.Forms.ToolStripMenuItem '有待決定時，滑鼠碰到小橘就打開清單（不勾＝點一下才開）'
$mHv.Add_Click({ $script:set.openOnHover = -not [bool]$script:set.openOnHover; Save-Settings })
[void]$menu.Items.Insert(2, $mHv)
$menu.Add_Opening({ $mHv.Checked = [bool]$script:set.openOnHover })
$idleTimer = New-Object System.Windows.Forms.Timer
$idleTimer.Interval = 100
$idleTimer.Add_Tick({ try { Idle-Step } catch { } })
$SkinNames = @{ 'gemini-star@1.png' = 'Gemini（四角星星符號）'; 'chatgpt-knot@1.png' = 'ChatGPT（綠底六環符號）'; 'orange-mascot@1.png' = '橘色吉祥物（Claude 風，動畫）' }
$mSkin = New-Object System.Windows.Forms.ToolStripMenuItem '換造型（ChatGPT／Gemini 符號／你自己的圖）'
[void]$menu.Items.Insert(1, $mSkin)
$menu.Add_Opening({ # 每次開選單時重列：內建造型＋你自己放進去的圖（也可以把圖檔直接拖到小橘身上換）
	$mSkin.DropDownItems.Clear()
	foreach ($f in @(Icon-Files)) {
		$label = if ($SkinNames.ContainsKey($f.Name)) { $SkinNames[$f.Name] } else { [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
		$it = $mSkin.DropDownItems.Add($label); $it.Tag = $f.Name; $it.Checked = ($f.Name -eq [string]$script:set.icon)
		$it.Add_Click({ param($s, $e) $script:set.icon = [string]$s.Tag; Save-Settings; Apply-Icon; Update-Look })
	}
})
$mpi.food.Add_Click({ $panel.Hide(); Toy-Menu 0 }); $mpi.ball.Add_Click({ $panel.Hide(); Toy-Menu 1 }); $mpi.mon.Add_Click({ $panel.Hide(); Mon-Spawn $false })

# ---------- 玩具箱：圖示旁邊的小手把鈕，點開就是一排大按鈕（遊戲、摸摸、睡覺、造型、設定、開關），不用再找右鍵選單 ----------
$DockCols = 5; $DockCW = 66; $DockCH = 74; $DockPad = 8
$script:dockCells = @(); $script:dockBmp = $null; $script:dockKey = ''
$play = New-Object PopForm
$play.NoActivate = $true; $play.Shadow = $false; $play.Layered = $true
$play.FormBorderStyle = 'None'; $play.TopMost = $true; $play.ShowInTaskbar = $false; $play.StartPosition = 'Manual'; $play.Size = New-Object System.Drawing.Size(30, 30); $play.Cursor = 'Hand'
$script:playBmp = New-Object System.Drawing.Bitmap(30, 30, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$pg = [System.Drawing.Graphics]::FromImage($script:playBmp); $pg.SmoothingMode = 'AntiAlias'; $pg.Clear([System.Drawing.Color]::Transparent)
$pg.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#26344A'))), 1, 1, 28, 28); $pg.DrawEllipse((New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)), 2, 2, 26, 26)
$gp2 = Rounded-Path 16 10 5; $pg.TranslateTransform(7, 10); $pg.FillPath([System.Drawing.Brushes]::White, $gp2); $pg.ResetTransform()
$dk = New-Object System.Drawing.SolidBrush((RGB '#26344A'))
$pg.FillRectangle($dk, 10, 14, 5, 2); $pg.FillRectangle($dk, 11.5, 12.5, 2, 5); $pg.FillEllipse($dk, 18, 13, 3, 3); $pg.FillEllipse($dk, 21, 16, 3, 3)
$pg.Dispose()
$dockF = New-Object PopForm
$dockF.NoActivate = $true; $dockF.Shadow = $false; $dockF.Layered = $true
$dockF.FormBorderStyle = 'None'; $dockF.TopMost = $true; $dockF.ShowInTaskbar = $false; $dockF.StartPosition = 'Manual'; $dockF.Cursor = 'Hand'
$dockHide = New-Object System.Windows.Forms.Timer
$dockHide.Interval = 14000
$dockHide.Add_Tick({ $dockHide.Stop(); try { $dockF.Hide() } catch { } })
function Dock-Cells {
	if (-not $script:set.pet) { return @(@('開啟電子雞', 'on'), @('換造型', 'skin'), @('設定', 'set')) }
	$sl = [bool]$script:pet.sleeping
	return @(@('丟飯糰', 'food'), @('丟皮球', 'ball'), @('打怪獸', 'mon'), @('摸摸', 'pat'), @($(if ($sl) { '叫醒' } else { '睡覺' }), $(if ($sl) { 'wake' } else { 'sleep' })), @('看狀態', 'status'), @('回原本', 'reset'), @('換造型', 'skin'), @('設定', 'set'), @('關電子雞', 'off'))
}
function Dock-Icon($g, [string]$key, [int]$x, [int]$y) { # 在 (x,y) 起 40×40 的範圍畫圖示
	$w = [System.Drawing.Brushes]::White
	switch ($key) {
		'food' { $g.DrawImage((Build-Item 0), ($x + 1), ($y + 1), 38, 38) }
		'ball' { $g.DrawImage((Build-Item 1), ($x + 1), ($y + 1), 38, 38) }
		'mon' { $g.DrawImage((Build-Monster 0 1 0), $x, $y, 40, 40) }
		'pat' { $g.TranslateTransform(($x + 20), ($y + 22)); $g.FillPath((New-Object System.Drawing.SolidBrush((RGB '#FF6B7A'))), (Heart-Path 0 0 13)); $g.ResetTransform() }
		'sleep' { $g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#FFE08A'))), ($x + 7), ($y + 5), 28, 28); $g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#2B4C7E'))), ($x + 15), ($y + 1), 26, 26) }
		'wake' { $g.FillEllipse((New-Object System.Drawing.SolidBrush((RGB '#FFC933'))), ($x + 11), ($y + 11), 18, 18); $pen = New-Object System.Drawing.Pen((RGB '#FFC933'), 3); foreach ($a in 0..7) { $r = $a * [Math]::PI / 4; $g.DrawLine($pen, ($x + 20 + 12 * [Math]::Cos($r)), ($y + 20 + 12 * [Math]::Sin($r)), ($x + 20 + 17 * [Math]::Cos($r)), ($y + 20 + 17 * [Math]::Sin($r))) } }
		'status' { $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3); $g.DrawRectangle($pen, ($x + 7), ($y + 6), 26, 28); foreach ($k in 0..2) { $g.FillRectangle($w, ($x + 12), ($y + 12 + $k * 7), (10 + $k * 4), 3) } }
		'skin' { $pts = [System.Drawing.PointF[]]@((PF2 ($x + 20) ($y + 3)), (PF2 ($x + 25) ($y + 15)), (PF2 ($x + 37) ($y + 20)), (PF2 ($x + 25) ($y + 25)), (PF2 ($x + 20) ($y + 37)), (PF2 ($x + 15) ($y + 25)), (PF2 ($x + 3) ($y + 20)), (PF2 ($x + 15) ($y + 15))); $g.FillPolygon((New-Object System.Drawing.SolidBrush((RGB '#B79BFF'))), $pts) }
		'set' { $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 4); $g.DrawEllipse($pen, ($x + 11), ($y + 11), 18, 18); foreach ($a in 0..7) { $r = $a * [Math]::PI / 4; $g.DrawLine($pen, ($x + 20 + 11 * [Math]::Cos($r)), ($y + 20 + 11 * [Math]::Sin($r)), ($x + 20 + 17 * [Math]::Cos($r)), ($y + 20 + 17 * [Math]::Sin($r))) } }
		'off' { $pen = New-Object System.Drawing.Pen((RGB '#FF8B7E'), 4); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $g.DrawArc($pen, ($x + 8), ($y + 9), 24, 24, -60, 300); $g.DrawLine($pen, ($x + 20), ($y + 5), ($x + 20), ($y + 19)) }
		'reset' { $pen = New-Object System.Drawing.Pen((RGB '#8FD3FF'), 4); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $g.DrawArc($pen, ($x + 8), ($y + 9), 24, 24, 20, 290); $g.FillPolygon((New-Object System.Drawing.SolidBrush((RGB '#8FD3FF'))), [System.Drawing.PointF[]]@((PF2 ($x + 31) ($y + 4)), (PF2 ($x + 36) ($y + 17)), (PF2 ($x + 23) ($y + 15)))) }
		'on' { $pen = New-Object System.Drawing.Pen((RGB '#6BE3A8'), 4); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $g.DrawArc($pen, ($x + 8), ($y + 9), 24, 24, -60, 300); $g.DrawLine($pen, ($x + 20), ($y + 5), ($x + 20), ($y + 19)) }
	}
}
function PF2([double]$x, [double]$y) { New-Object System.Drawing.PointF([single]$x, [single]$y) }
function Build-Dock {
	$cells = @(Dock-Cells); $script:dockCells = $cells
	$rows = [int][Math]::Ceiling($cells.Count / [double]$DockCols); $cols = [Math]::Min($DockCols, $cells.Count)
	$W = $cols * $DockCW + $DockPad * 2; $H = $rows * $DockCH + $DockPad * 2
	$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([System.Drawing.Color]::Transparent)
	$g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(242, 31, 58, 95))), (Rounded-Path ($W - 1) ($H - 1) 14))
	$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'
	for ($i = 0; $i -lt $cells.Count; $i++) {
		$cx = $DockPad + ($i % $DockCols) * $DockCW; $cy = $DockPad + [int][Math]::Floor($i / $DockCols) * $DockCH
		$g.TranslateTransform($cx + 3, $cy + 3); $g.FillPath((New-Object System.Drawing.SolidBrush((RGB '#2B4C7E'))), (Rounded-Path ($DockCW - 7) ($DockCH - 7) 10)); $g.ResetTransform()
		Dock-Icon $g $cells[$i][1] ($cx + [int](($DockCW - 40) / 2)) ($cy + 8)
		$g.DrawString($cells[$i][0], $hudFont2, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($cx, ($cy + 50), $DockCW, 20)), $sf)
	}
	$g.Dispose(); return $bmp
}
function Dock-Hide { $dockHide.Stop(); try { $dockF.Hide() } catch { } }
function Dock-Toggle {
	if ($dockF.Visible) { Dock-Hide; return }
	$bmp = Build-Dock; $script:dockBmp = $bmp
	$dockF.Size = New-Object System.Drawing.Size($bmp.Width, $bmp.Height)
	$wa = [System.Windows.Forms.Screen]::FromControl($iconForm).WorkingArea
	$x = [Math]::Min([Math]::Max($wa.Left, $play.Left + 15 - [int]($bmp.Width / 2)), $wa.Right - $bmp.Width)
	$top = $iconForm.Top; if ($bubble.Visible) { $top = [Math]::Min($top, $bubble.Top) }
	$y = [Math]::Max($wa.Top, $top - $bmp.Height - 8)
	$dockF.Location = New-Object System.Drawing.Point($x, $y); $dockF.Show(); $dockF.SetSprite($bmp, [byte]250)
	$dockHide.Stop(); $dockHide.Start()
}
function Skin-Next {
	$fs = @(Icon-Files); if ($fs.Count -eq 0) { return }
	$i = 0; for ($k = 0; $k -lt $fs.Count; $k++) { if ($fs[$k].Name -eq [string]$script:set.icon) { $i = $k } }
	$n = $fs[($i + 1) % $fs.Count]; $script:set.icon = $n.Name; Save-Settings; Apply-Icon; Update-Look
	$label = if ($SkinNames.ContainsKey($n.Name)) { $SkinNames[$n.Name] } else { [System.IO.Path]::GetFileNameWithoutExtension($n.Name) }
	Pet-Say ('造型：{0}（再按一次換下一個）' -f $label) 3000
}
function Dock-Act([string]$key) {
	if ($key -ne 'skin') { Dock-Hide }
	switch ($key) {
		'food' { Toy-Menu 0 } 'ball' { Toy-Menu 1 } 'mon' { Mon-Spawn $false } 'pat' { Pet-Pat } 'sleep' { Pet-ToggleSleep } 'wake' { Pet-ToggleSleep }
		'status' { Pet-Status } 'reset' { Pet-Reset } 'skin' { Skin-Next; $dockHide.Stop(); $dockHide.Start() } 'set' { Show-Settings } 'off' { Pet-Enable $false } 'on' { Pet-Enable $true }
	}
}
$dockF.Add_MouseUp({
	param($s, $e)
	if ($e.Button -ne 'Left') { return }
	$col = [int][Math]::Floor(($e.X - $DockPad) / $DockCW); $row = [int][Math]::Floor(($e.Y - $DockPad) / $DockCH)
	if ($col -lt 0 -or $col -ge $DockCols -or $row -lt 0) { return }
	$idx = $row * $DockCols + $col
	if ($idx -lt $script:dockCells.Count) { Dock-Act ([string]$script:dockCells[$idx][1]) }
})
$play.Add_MouseUp({ param($s, $e) if ($e.Button -eq 'Left' -and -not $script:pdMoved) { if ($panel.Visible) { $panel.Hide(); Update-Look }; Dock-Toggle } })

# ---------- 任何地方按住左鍵都能拖著整個浮窗走（清單、標題、分頁、底部、對話框、小條、鈕；只點一下照舊）----------
$script:pd = $null; $script:pdMoved = $false; $script:pdStart = $null
function Attach-Drag($c) {
	$c.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:pd = [System.Windows.Forms.Cursor]::Position; $script:pdMoved = $false; $script:pdStart = $iconForm.Location } })
	$c.Add_MouseMove({ param($s, $e)
		if (-not $script:pd -or $e.Button -ne 'Left') { return }
		$p = [System.Windows.Forms.Cursor]::Position
		$dx = $p.X - $script:pd.X; $dy = $p.Y - $script:pd.Y
		if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 5) { $script:pdMoved = $true }
		if ($script:pdMoved) {
			$iconForm.Location = New-Object System.Drawing.Point(($script:pdStart.X + $dx), ($script:pdStart.Y + $dy))
			Place-Around; Place-Tray; if ($petBubble.Visible) { Place-PetBubble }
		}
	})
	$c.Add_MouseUp({ param($s, $e)
		if ($e.Button -ne 'Left' -or -not $script:pd) { return }
		$script:pd = $null
		if ($script:pdMoved) { Snap-OnScreen; $script:set.x = $iconForm.Left; if (-not $script:set.walk) { $script:set.y = $iconForm.Top }; Save-Settings }
	})
}
foreach ($dc in @($panel, $head, $tabs, $foot, $hint, $list, $bubble, $bl, $petBubble, $pl, $tray, $cam, $play)) { if ($dc) { Attach-Drag $dc } }
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
$UsagePollJs = Join-Path $PSScriptRoot 'usage-poll.mjs'
$script:usageProc = $null
function Run-UsagePoll { # 每 5 分鐘查一次每週用量（要先在終端機 claude auth login；沒登入就什麼都不會發生）
	if (-not $script:nodeOk) { return }
	if ($script:usageProc -and -not $script:usageProc.HasExited) { return }
	try {
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		$psi.FileName = 'node'; $psi.Arguments = '"' + $UsagePollJs + '"'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
		$script:usageProc = [System.Diagnostics.Process]::Start($psi)
	} catch { }
}
$AgentJs = Join-Path $PSScriptRoot 'pd-agent.mjs'
$script:agentProc = $null
function Run-Agent { # 手機鏡像＋遙控的常駐小程式（pd-agent.mjs）：自己用本機埠當鎖，只會有一個；已經在跑就馬上結束。每分鐘確認一次
	if (-not $script:nodeOk -or $Snap) { return }
	if ($script:agentProc -and -not $script:agentProc.HasExited) { return }
	try {
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		$psi.FileName = 'node'; $psi.Arguments = '"' + $AgentJs + '"'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
		$script:agentProc = [System.Diagnostics.Process]::Start($psi)
	} catch { }
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$script:tick = 0
$ErrLog = Join-Path $DataDir 'error.log'
function Flush-Errors { # 事件裡出的錯不會跳視窗：每輪把累積的錯誤寫進 error.log（最多留最近 3 筆，避免洗版）
	if ($list.LastError) { try { Add-Content -Path $ErrLog -Value ("{0} list-paint: {1}" -f (Get-Date -Format s), $list.LastError) -Encoding UTF8 } catch { }; $list.LastError = ''; $list.Invalidate() }
	if ($Error.Count -eq 0) { return }
	try { $Error | Select-Object -First 3 | ForEach-Object { Add-Content -Path $ErrLog -Value ("{0} widget: {1} @ {2}" -f (Get-Date -Format s), $_.Exception.Message, $_.InvocationInfo.PositionMessage) -Encoding UTF8 } } catch { }
	$Error.Clear()
}
$timer.Add_Tick({ $script:tick++; if ($script:tick % 2 -eq 0) { Run-Scan }; if ($script:tick % 100 -eq 2) { Run-UsagePoll }; if ($script:tick % 20 -eq 3) { Run-Agent }; Refresh-Data; Flush-Errors })

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
Run-Agent
Refresh-Data
$timer.Start()
$petTimer.Start()
if ($script:set.walk) { Go-Home }
$walk.Start()
$idleTimer.Start()
$iconForm.Add_FormClosed({ if ($script:set.pet) { Save-Pet }; $panel.Close(); $bubble.Close(); $petBubble.Close(); $tray.Close(); $item.Close(); $cam.Close(); $toyF.Close(); $monF.Close(); $hudF.Close(); $play.Close(); $dockF.Close() })
[System.Windows.Forms.Application]::Run($iconForm)
$mutex.ReleaseMutex()
