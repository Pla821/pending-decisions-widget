<#
.SYNOPSIS
  Pending Decisions Widget 一鍵安裝／移除（Windows PowerShell 5.1＋Node.js）。
.DESCRIPTION
  安裝：複製程式到 <ClaudeDir>\pending-decisions、把 5 個 hook「合併」進 settings.json（先備份、不動你原有的 hook、可重複執行）、
        可選開機自動啟動，然後啟動浮窗。
  移除：-Uninstall，拿掉自己的 hook、捷徑與程式；你的設定與其他 hook 原樣保留。對話資料（data\）預設保留，加 -Purge 才一併刪除。
.PARAMETER Uninstall     移除。
.PARAMETER Autostart     開機自動啟動浮窗（不加這個也不加 -NoAutostart 時，互動模式會問你）。
.PARAMETER NoAutostart   不要開機自動啟動（也不問）。
.PARAMETER ReplaceLegacy 同時拿掉「沒打包的舊版 decision-log.mjs」hook，避免重複通知。
.PARAMETER NoLaunch      裝完不要馬上啟動浮窗。
.PARAMETER Purge         搭配 -Uninstall：連資料（對話清單、你放的圖、設定）一起刪。
.PARAMETER ClaudeDir     Claude 設定資料夾，預設 %USERPROFILE%\.claude。
.PARAMETER InstallDir    安裝位置，預設 <ClaudeDir>\pending-decisions。
.PARAMETER StartupDir    開機自動啟動捷徑放哪，預設 Windows 的「啟動」資料夾（測試用）。
.EXAMPLE
  .\install.ps1 -Autostart
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
	[switch]$Uninstall, [switch]$Autostart, [switch]$NoAutostart, [switch]$ReplaceLegacy, [switch]$NoLaunch, [switch]$Purge,
	[string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
	[string]$InstallDir = '',
	[string]$StartupDir = [Environment]::GetFolderPath('Startup')
)
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = Join-Path $ClaudeDir 'pending-decisions' }
$Settings = Join-Path $ClaudeDir 'settings.json'
$Lnk = Join-Path $StartupDir 'PendingDecisionsWidget.lnk'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir = Join-Path $Here 'src'
$LogJs = Join-Path $InstallDir 'bin\decision-log.mjs'
$HooksJs = Join-Path $InstallDir 'bin\settings-hooks.mjs'
$Widget = Join-Path $InstallDir 'bin\widget.ps1'

function Say([string]$m) { Write-Host $m }
function Stop-Widget { # 只停這份安裝目錄的浮窗
	Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Widget) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Backup-Settings {
	if (Test-Path $Settings) {
		$b = "$Settings.pdw-backup-" + (Get-Date -Format yyyyMMdd_HHmmss)
		Copy-Item $Settings $b; Say "  已備份 settings.json → $b"
	}
}

if ($Uninstall) {
	Say '移除 Pending Decisions Widget…'
	if (-not (Test-Path $HooksJs)) { $HooksJs = Join-Path $SrcDir 'bin\settings-hooks.mjs' } # 從原始碼資料夾執行也行
	Stop-Widget
	if (Test-Path $Settings) {
		Backup-Settings
		$PreFile = Join-Path $InstallDir 'datasettings.pre-install.json'; $PostFile = Join-Path $InstallDir 'datasettings.post-install.sha256'
		if ((Test-Path $PreFile) -and (Test-Path $PostFile) -and ((Get-FileHash $Settings -Algorithm SHA256).Hash -eq (Get-Content $PostFile -Raw).Trim())) {
			Copy-Item $PreFile $Settings -Force; Say '  settings.json 自安裝後沒被改過：已原封不動還原成安裝前的樣子'
		} else {
			$r = & node $HooksJs remove $Settings
			Say "  hook：$r（你安裝後改過 settings.json，所以只精準拿掉本工具的 hook，其餘保留）"
		}
	}
	if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Say '  已移除開機自動啟動捷徑' }
	if ($Purge) { if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Say "  已刪除 $InstallDir（含資料）" } }
	else {
		foreach ($d in 'bin', 'icons') { $p = Join-Path $InstallDir $d; if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
		Remove-Item (Join-Path $InstallDir 'install.ps1') -Force -ErrorAction SilentlyContinue
		Say "  程式已移除；你的資料還留在 $InstallDir\data（不要了加 -Purge 再跑一次）"
	}
	Say '完成。'
	return
}

Say 'Pending Decisions Widget 安裝'
# --- 前置檢查 ---
if ($PSVersionTable.PSVersion.Major -lt 5) { throw '需要 Windows PowerShell 5.1 以上。' }
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw '找不到 Node.js。請先安裝 LTS 版（https://nodejs.org），重開 PowerShell 後再跑一次。' }
$nv = (& node -v).TrimStart('v'); if ([int]($nv.Split('.')[0]) -lt 18) { throw "Node.js 版本太舊（$nv），需要 18 以上。" }
if (-not (Test-Path (Join-Path $SrcDir 'bin\widget.ps1'))) { throw "找不到 $SrcDir\bin\widget.ps1：請在完整下載的專案資料夾裡執行 install.ps1。" }
Say "  Node.js $nv ✓　PowerShell $($PSVersionTable.PSVersion) ✓"

# --- 複製程式（只動 bin、icons；你的 data、config.json 不碰）---
Stop-Widget
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
foreach ($d in 'bin', 'icons') {
	$dst = Join-Path $InstallDir $d
	if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
	Copy-Item (Join-Path $SrcDir $d) $dst -Recurse
}
Copy-Item (Join-Path $Here 'install.ps1') (Join-Path $InstallDir 'install.ps1') -Force
$cfg = Join-Path $InstallDir 'config.json'
if (-not (Test-Path $cfg)) { '{' + "`r`n" + '  "toast": true,' + "`r`n" + '  "theme": "auto"' + "`r`n" + '}' | Set-Content $cfg -Encoding UTF8 }
Say "  程式已複製到 $InstallDir"

# --- 合併 hook ---
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
$PreFile = Join-Path $InstallDir 'datasettings.pre-install.json'; $PostFile = Join-Path $InstallDir 'datasettings.post-install.sha256'
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'data') | Out-Null
$already = if (Test-Path $Settings) { (& node $HooksJs check $Settings | ConvertFrom-Json).installed } else { 0 }
if ($already -eq 0 -and (Test-Path $Settings)) { Copy-Item $Settings $PreFile -Force } # 第一次安裝前的原樣，移除時用來原封不動還原
Backup-Settings
$args2 = @($HooksJs, 'add', $Settings, $LogJs); if ($ReplaceLegacy) { $args2 += '--replace-legacy' }
$r = & node @args2
if ($LASTEXITCODE -ne 0) { throw "合併 settings.json 失敗：$r" }
Say "  hook 已合併：$r"
(Get-FileHash $Settings -Algorithm SHA256).Hash | Set-Content $PostFile -Encoding ASCII
$chk = & node $HooksJs check $Settings | ConvertFrom-Json
if ($chk.legacy -gt 0) { Say "  ⚠ 偵測到 $($chk.legacy) 個舊版 hook（沒打包的 decision-log.mjs），會造成重複通知；加 -ReplaceLegacy 再跑一次可換掉它們。" }

# --- 開機自動啟動 ---
$auto = $Autostart.IsPresent
if (-not $Autostart -and -not $NoAutostart -and [Environment]::UserInteractive) {
	try { $ans = Read-Host '開機時自動啟動浮窗？(Y/n)'; $auto = ($ans -eq '' -or $ans -match '^[Yy]') } catch { $auto = $false }
}
if ($auto) {
	New-Item -ItemType Directory -Force -Path $StartupDir | Out-Null
	$ws = New-Object -ComObject WScript.Shell; $l = $ws.CreateShortcut($Lnk)
	$l.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	$l.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Widget + '"'
	$l.WindowStyle = 7; $l.Description = 'Pending Decisions Widget'; $l.Save()
	Say '  已建立開機自動啟動捷徑'
} else { Say '  沒有設定開機自動啟動（之後可在浮窗右鍵「設定」勾選，或重跑 install.ps1 -Autostart）' }

# --- 啟動 ---
if (-not $NoLaunch) {
	Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $Widget + '"') -WindowStyle Hidden
	Say '  浮窗已啟動（螢幕右下角）。'
}
Say '完成。已經開著的 Claude 對話需要重開，才會載入新的 hook；浮窗本身不靠 hook 也看得到（它直接掃對話紀錄）。'
