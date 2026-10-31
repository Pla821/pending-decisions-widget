# install-test.ps1 — 在暫時的資料夾裡測安裝／重複安裝／移除，不碰你真正的 ~/.claude 與「啟動」資料夾，也不啟動浮窗。
# 執行：powershell -NoProfile -ExecutionPolicy Bypass -File tests\install-test.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pdw-install-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$claude = Join-Path $tmp 'claude'; $startup = Join-Path $tmp 'startup'
New-Item -ItemType Directory -Force $claude, $startup | Out-Null
function Check([bool]$ok, [string]$msg) { if (-not $ok) { throw "失敗：$msg" } else { Write-Host "  ✓ $msg" } }

# 一份「已經有別的設定與 hook」的 settings.json（含一個舊版 decision-log hook）
$orig = @'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(git status)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo my-own-hook" } ] },
      { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "command": "node \"C:\\old\\decision-log.mjs\"", "timeout": 15 } ] }
    ],
    "SessionEnd": [ { "hooks": [ { "type": "command", "command": "echo bye" } ] } ]
  }
}
'@
$sp = Join-Path $claude 'settings.json'
[IO.File]::WriteAllText($sp, ($orig -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
$before = [IO.File]::ReadAllBytes($sp)
$ps = Join-Path $repo 'install.ps1'

Write-Host '1. 安裝'
& $ps -ClaudeDir $claude -StartupDir $startup -NoLaunch -Autostart | Out-Null
$j = Get-Content $sp -Raw | ConvertFrom-Json
Check (Test-Path (Join-Path $claude 'pending-decisions\bin\widget.ps1')) '程式已複製'
Check (Test-Path (Join-Path $claude 'pending-decisions\icons\bell.png')) '內建圖示已複製'
Check ($j.model -eq 'opus' -and $j.permissions.allow[0] -eq 'Bash(git status)') '原有設定沒被動到'
Check (@($j.hooks.PreToolUse | Where-Object { $_.hooks[0].command -eq 'echo my-own-hook' }).Count -eq 1) '原有 hook 還在'
Check ($j.hooks.PermissionRequest.Count -eq 1 -and $j.hooks.Notification.Count -eq 1) '權限確認的 hook 已加入'
Check ((@($j.hooks.PreToolUse | Where-Object { $_.hooks[0].command -match 'pending-decisions' })).Count -eq 1) '選項框／提問卡 hook 已加入'
Check (Test-Path (Join-Path $startup 'PendingDecisionsWidget.lnk')) '開機自動啟動捷徑已建立'
Check ((Get-ChildItem $claude -Filter 'settings.json.pdw-backup-*').Count -ge 1) 'settings.json 已先備份'

Write-Host '2. 重複安裝（不該重複加）'
& $ps -ClaudeDir $claude -StartupDir $startup -NoLaunch -NoAutostart | Out-Null
$j = Get-Content $sp -Raw | ConvertFrom-Json
Check ($j.hooks.PermissionRequest.Count -eq 1) 'PermissionRequest 還是只有 1 筆'
Check ((@($j.hooks.PreToolUse | Where-Object { $_.hooks[0].command -match 'pending-decisions' })).Count -eq 1) 'PreToolUse 還是只有 1 筆'

Write-Host '3. 偵測舊版（-ReplaceLegacy）'
& $ps -ClaudeDir $claude -StartupDir $startup -NoLaunch -NoAutostart -ReplaceLegacy | Out-Null
$j = Get-Content $sp -Raw | ConvertFrom-Json
Check ((@($j.hooks.PreToolUse | Where-Object { $_.hooks.Count -gt 0 -and $_.hooks[0].command -match 'old.decision-log' })).Count -eq 0) '舊版 hook 已換掉'
Check (@($j.hooks.PreToolUse | Where-Object { $_.hooks[0].command -eq 'echo my-own-hook' }).Count -eq 1) '你自己的 hook 仍在'

Write-Host '4. 移除'
# 先把舊版 hook 放回去，確認「移除」只拿自己的
[IO.File]::WriteAllBytes($sp, $before)
& $ps -ClaudeDir $claude -StartupDir $startup -NoLaunch -NoAutostart | Out-Null
& (Join-Path $claude 'pending-decisions\install.ps1') -Uninstall -ClaudeDir $claude -StartupDir $startup | Out-Null
$after = [IO.File]::ReadAllBytes($sp)
Check (([Convert]::ToBase64String($before)) -eq ([Convert]::ToBase64String($after))) 'settings.json 還原成安裝前（逐位元組相同）'
Check (-not (Test-Path (Join-Path $startup 'PendingDecisionsWidget.lnk'))) '捷徑已移除'
Check (-not (Test-Path (Join-Path $claude 'pending-decisions\bin'))) '程式已移除'

Remove-Item $tmp -Recurse -Force
Write-Host 'install-test: 全部通過'
