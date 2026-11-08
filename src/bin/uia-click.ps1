# uia-click.ps1 — 在 Claude 桌面版視窗裡，替使用者按「指定對話」畫面上的按鈕（用 Windows UI 自動化的 InvokePattern，等於滑鼠點一下）。
# 只由 pd-agent.mjs 呼叫；按鈕名稱由 agent 從白名單挑（允許一次／拒絕／選項文字／提交…），這支不接受任何要執行的指令。
# 用法：powershell -File uia-click.ps1 -Title <對話標題> -Local <local_...> -ButtonsStr 'A|B' [-Expect <畫面上必須出現的文字>] [-DryRun]
# 輸出：最後一行 JSON {"ok":true|false,"note":"..."}
param([string]$Title = '', [string]$Local = '', [string]$ButtonsStr = '', [string]$Expect = '', [switch]$DryRun)
$Buttons = @($ButtonsStr -split '\|' | Where-Object { $_ })
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
function Find-Btn($w, [string]$name) {
	$c = New-Object System.Windows.Automation.AndCondition(
		(New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)),
		(New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
	return $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}
function Header-Matches($w) { # 視窗上方「<標題>，重新命名工作階段」按鈕＝目前顯示的對話
	if (-not $Title) { return $true }
	$all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
	foreach ($b in $all) { $n = [string]$b.Current.Name; if ($n.EndsWith('，重新命名工作階段') -and $n.StartsWith($Title)) { return $true } }
	return $false
}
$w = Get-Win
if (-not $w) { Out-Json $false '找不到 Claude 視窗（沒開？）' }
if (-not (Header-Matches $w)) {
	if ($Local -match '^local_[0-9a-f-]{36}$') { Start-Process ('claude://claude.ai/epitaxy/' + $Local) } else { Out-Json $false '目前顯示的不是那個對話，也沒有可切換的連結' }
	$ok = $false
	for ($i = 0; $i -lt 16 -and -not $ok; $i++) { Start-Sleep -Milliseconds 500; $w = Get-Win; if ($w -and (Header-Matches $w)) { $ok = $true } }
	if (-not $ok) { Out-Json $false '切不到那個對話' }
	Start-Sleep -Milliseconds 800
}
if ($Expect) { # 防呆：畫面上必須看得到這段指令文字，才按（避免對話已換成別的請求，按錯）
	$want = ($Expect -replace '\s', '')
	$found = $false
	$all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
	$sb = New-Object System.Text.StringBuilder
	foreach ($e in $all) { # 指令文字有語法上色，會被切成很多小段 Text：除了單一元素，也把所有 Text 依畫面順序串起來比對
		$n = [string]$e.Current.Name; if (-not $n) { continue }
		$ns = ($n -replace '\s', '')
		if ($ns.Length -ge 4 -and $ns.Contains($want)) { $found = $true; break }
		if ($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $ns.Length -le 400) { [void]$sb.Append($ns) }
	}
	if (-not $found -and $sb.ToString().Contains($want)) { $found = $true }
	if (-not $found) { Out-Json $false '畫面上的請求內容和手機上看到的對不上，為安全起見沒按' }
}
$done = @()
foreach ($name in $Buttons) {
	$btn = $null
	for ($i = 0; $i -lt 8 -and -not $btn; $i++) { $btn = Find-Btn $w $name; if (-not $btn) { Start-Sleep -Milliseconds 400 } }
	if (-not $btn) { Out-Json $false ('畫面上找不到按鈕「' + $name + '」' + $(if ($done.Count) { '（已按：' + ($done -join '、') + '）' } else { '' })) }
	if ($DryRun) { $done += ($name + '(找到)'); continue }
	try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { Out-Json $false ('按「' + $name + '」失敗：' + $_.Exception.Message) }
	$done += $name
	Start-Sleep -Milliseconds 400
}
Out-Json $true ($(if ($DryRun) { '試跑：' } else { '已按：' }) + ($done -join '、'))
