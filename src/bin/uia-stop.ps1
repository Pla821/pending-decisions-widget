# uia-stop.ps1 — 在 Claude 桌面版視窗裡，替使用者按「指定對話」輸入框右邊的「■ 停止」鍵（Windows UI 自動化的 InvokePattern，等於滑鼠點一下）。
# 只由 pd-agent.mjs 呼叫；只會按名稱剛好是「停止」的 Button（不會按「停止此任務」「停止 N 個巢狀工作階段」），不接受任何要執行的指令。
# 2026-11-08 實測：對話執行中，輸入框右邊有 Button Name='停止'、InvokePattern；對話閒置時沒有這顆。
# 用法：powershell -File uia-stop.ps1 -Title <對話標題> -Local <local_...> [-DryRun]
# 輸出：最後一行 JSON {"ok":true|false,"note":"..."}
param([string]$Title = '', [string]$Local = '', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
function Out-Json($ok, $note) { (@{ ok = $ok; note = $note } | ConvertTo-Json -Compress); exit 0 }
function Get-Win {
	$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'Chrome_WidgetWin_1')
	return ($AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) | Where-Object { $_.Current.Name -eq 'Claude' } | Select-Object -First 1)
}
function Find-Stop($w) {
	$c = New-Object System.Windows.Automation.AndCondition(
		(New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, '停止')),
		(New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
	return $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}
function Header-Matches($w) { # 視窗上方「<標題>，重新命名工作階段」按鈕＝目前顯示的對話
	if (-not $Title) { return $false } # 停止鍵一定要核對標題，避免停到別的對話
	$all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
	foreach ($b in $all) { $n = [string]$b.Current.Name; if ($n.EndsWith('，重新命名工作階段') -and $n.StartsWith($Title)) { return $true } }
	return $false
}
$w = Get-Win
if (-not $w) { Out-Json $false '找不到 Claude 視窗（沒開？）' }
if (-not $Title) { Out-Json $false '沒有對話標題，不敢亂按' }
if (-not (Header-Matches $w)) {
	if ($Local -match '^local_[0-9a-f-]{36}$') { Start-Process ('claude://claude.ai/epitaxy/' + $Local) } else { Out-Json $false '目前顯示的不是那個對話，也沒有可切換的連結' }
	$ok = $false
	for ($i = 0; $i -lt 16 -and -not $ok; $i++) { Start-Sleep -Milliseconds 500; $w = Get-Win; if ($w -and (Header-Matches $w)) { $ok = $true } }
	if (-not $ok) { Out-Json $false '切不到那個對話' }
	Start-Sleep -Milliseconds 800
}
$btn = $null
for ($i = 0; $i -lt 6 -and -not $btn; $i++) { $btn = Find-Stop $w; if (-not $btn) { Start-Sleep -Milliseconds 400 } }
if (-not $btn) { Out-Json $false '找不到停止鍵（對話已經停了，或正在等使用者回答）' }
if ($DryRun) { Out-Json $true '試跑：找到停止鍵' }
try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { Out-Json $false ('按停止失敗：' + $_.Exception.Message) }
for ($i = 0; $i -lt 16; $i++) { # 按下後，停止鍵應該消失（對話真的停了）；最多等 8 秒
	Start-Sleep -Milliseconds 500
	$w = Get-Win; if (-not $w) { break }
	if (-not (Find-Stop $w)) { Out-Json $true '已按停止' }
}
Out-Json $false '按了停止，但對話好像還在跑'
