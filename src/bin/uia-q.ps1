# uia-q.ps1 — 在 Claude 桌面版視窗裡，替使用者答「選項框」（AskUserQuestion）的一題：切到那個對話→核對畫面上有同一題→點選項→按「下一步」或「提交」。
# 只由 pd-agent.mjs 呼叫；選項文字來自電腦本機 pending.json（不是手機傳來的自由文字），「其他」自己打的字只會填進選項框的輸入格。
# 用法：powershell -File uia-q.ps1 -Title <對話標題> -Local <local_...> -Question <題目文字> -Pick 'A|B' [-Other <文字>] [-Final] [-DryRun]
# 輸出：最後一行 JSON {"ok":true|false,"note":"..."}
param([string]$Title = '', [string]$Local = '', [string]$Question = '', [string]$Pick = '', [string]$Other = '', [switch]$Final, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
function Out-Json($ok, $note) { (@{ ok = $ok; note = $note } | ConvertTo-Json -Compress); exit 0 }
function Get-Win {
	$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'Chrome_WidgetWin_1')
	return ($AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) | Where-Object { $_.Current.Name -eq 'Claude' } | Select-Object -First 1)
}
function Buttons($w) { return $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button))) }
function Header-Matches($w) {
	if (-not $Title) { return $true }
	foreach ($b in (Buttons $w)) { $n = [string]$b.Current.Name; if ($n.EndsWith('，重新命名工作階段') -and $n.StartsWith($Title)) { return $true } }
	return $false
}
function Has-Text($w, [string]$want) {
	$want = ($want -replace '\s', '')
	$sb = New-Object System.Text.StringBuilder
	foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
		$n = [string]$e.Current.Name; if (-not $n) { continue }
		$ns = ($n -replace '\s', ''); if ($ns.Length -ge 4 -and $ns.Contains($want)) { return $true }
		if ($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $ns.Length -le 400) { [void]$sb.Append($ns) }
	}
	return $sb.ToString().Contains($want)
}
function Find-Option($w, [string]$label) { # 選項＝有 TogglePattern 的按鈕，名稱是「選項文字」或「選項文字＋空白＋說明」
	foreach ($b in (Buttons $w)) {
		$n = [string]$b.Current.Name
		if ($n -eq $label -or $n.StartsWith($label + ' ')) { if ($b.GetSupportedPatterns() | Where-Object { $_.ProgrammaticName -like '*TogglePattern*' }) { return $b } }
	}
	return $null
}
function Find-Btn($w, [string]$name) { foreach ($b in (Buttons $w)) { if ([string]$b.Current.Name -eq $name) { return $b } }; return $null }
function Toggle-On($b) {
	$p = $b.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
	if ($p.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $p.Toggle() }
	for ($k = 0; $k -lt 8; $k++) { Start-Sleep -Milliseconds 250; try { if ($b.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) { return $true } } catch { } }
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
$q = ($Question -replace '\s+', ' ').Trim(); if ($q.Length -gt 36) { $q = $q.Substring(0, 36) }
if ($q.Length -lt 4) { Out-Json $false '沒有題目文字可核對' }
$seen = $false
for ($i = 0; $i -lt 10 -and -not $seen; $i++) { $seen = (Has-Text $w $q); if (-not $seen) { Start-Sleep -Milliseconds 600 } }
if (-not $seen) { Out-Json $false '畫面上看不到這一題（可能已經在電腦上答了）' }
$done = @()
foreach ($label in @($Pick -split '\|' | Where-Object { $_ })) {
	$b = $null
	for ($i = 0; $i -lt 6 -and -not $b; $i++) { $b = Find-Option $w $label; if (-not $b) { Start-Sleep -Milliseconds 400 } }
	if (-not $b) { Out-Json $false ('畫面上找不到選項「' + $label + '」') }
	if ($DryRun) { $done += ($label + '(找到)'); continue }
	if (-not (Toggle-On $b)) { Out-Json $false ('選項「' + $label + '」點了沒反應') }
	$done += $label
}
if ($Other) {
	$ob = Find-Btn $w '其他'
	if (-not $ob) { Out-Json $false '畫面上找不到「其他」' }
	if ($DryRun) { $done += '其他(找到)' }
	else {
		if (-not (Toggle-On $ob)) { Out-Json $false '「其他」點了沒反應' }
		Start-Sleep -Milliseconds 400
		$or = $ob.Current.BoundingRectangle; $sb = Find-Btn $w '略過'; $lim = if ($sb) { $sb.Current.BoundingRectangle.Top } else { $or.Bottom + 400 }
		$edit = $null
		foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Edit)))) { $r = $e.Current.BoundingRectangle; if ($r.Top -ge ($or.Top - 4) -and $r.Top -lt $lim) { $edit = $e; break } } # 只認選項框範圍內的輸入格，不會填到下面的聊天輸入框
		if (-not $edit) { Out-Json $false '「其他」底下找不到輸入格' }
		try { $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Other) } catch { Out-Json $false ('填「其他」失敗：' + $_.Exception.Message) }
		$done += '其他'
		Start-Sleep -Milliseconds 300
	}
}
$bn = if ($Final) { '提交' } else { '下一步' }
$btn = $null
for ($i = 0; $i -lt 6 -and -not $btn; $i++) { $btn = Find-Btn $w $bn; if (-not $btn) { Start-Sleep -Milliseconds 400 } }
if (-not $btn) { Out-Json $false ('畫面上找不到按鈕「' + $bn + '」') }
if ($DryRun) { Out-Json $true ('試跑：' + ($done -join '、') + '，會按「' + $bn + '」') }
try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { Out-Json $false ('按「' + $bn + '」失敗：' + $_.Exception.Message) }
Out-Json $true ('已選：' + ($done -join '、') + '，已按「' + $bn + '」')
