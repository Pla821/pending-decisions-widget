# 運作原理

## 兩條資料來源

```
┌─────────────────────────┐   寫入    ┌──────────────────────────────────┐
│ Claude Code 對話（很多個）│ ───────▶ │ ~/.claude/projects/*/*.jsonl      │
└───────────┬─────────────┘           │ （每個對話的完整紀錄）             │
            │ hook 事件（即時）         └───────────────┬──────────────────┘
            ▼                                          │ 每 6 秒，只讀每個檔的最後 600 KB
   bin/decision-log.mjs                                ▼
   ├─ 選項框 PreToolUse                        bin/decision-scan.mjs
   ├─ 提問卡 PreToolUse（wrap_up）              ├─ 找「問了、沒回答」的選項框
   ├─ 權限確認 PermissionRequest／Notification  ├─ 找「停在提問卡、你還沒回話」
   └─ 跳 Windows 通知（toast.ps1）              └─ 結算權限確認（指令有結果了＝處理掉）
            │                                          │
            └────────────────┬─────────────────────────┘
                             ▼
                data/pending.json ─▶ data/pending.html（網頁清單）
                             │
                             ▼
                bin/widget.ps1（浮窗：每 3 秒讀 pending.json）
```

## 怎麼判斷「在等你」

| 種類 | 看什麼 | 怎麼算「你回了」 |
|---|---|---|
| 選項框 | 紀錄裡有 `AskUserQuestion` 的 `tool_use` | 出現同一個 `tool_use_id` 的 `tool_result` |
| 提問卡 | 最後一個 `wrap_up` 呼叫帶有 `ask` | 之後出現你本人的訊息（`origin.kind = "human"`），或 Claude 又開始呼叫別的工具 |
| 權限確認 | hook 收到 `PermissionRequest`（記下工具名＋指令指紋） | 紀錄裡同樣的工具呼叫出現 `tool_result`；超過 2 分鐘找不到對應紀錄就當作已處理 |

為什麼選項框與提問卡不靠 hook：hook 只在「載入之後才開的對話」生效，而紀錄檔每個對話都有。權限確認沒有「問了」的紀錄（Claude 只是在等），所以只能靠 hook 知道。

## 檔案

| 路徑 | 作用 |
|---|---|
| `src/bin/lib.mjs` | 路徑偵測、`config.json`、狀態讀寫、桌面版對話中繼檔查詢、網頁清單產生 |
| `src/bin/decision-scan.mjs` | 掃描（浮窗每 6 秒叫一次；有快取，只重讀有變動的檔） |
| `src/bin/decision-log.mjs` | hook 腳本（永遠 exit 0、不輸出） |
| `src/bin/settings-hooks.mjs` | 把 hook 合併進／移出 `settings.json` |
| `src/bin/widget.ps1` | 浮窗（WinForms） |
| `src/bin/toast.ps1` | Windows 通知 |
| `install.ps1` | 安裝／移除 |

## 對話標題與連結

Claude 桌面版把每個對話的標題與 id 存在 `%LOCALAPPDATA%\Claude-Data\*\claude-code-sessions\**\local_*.json`
（欄位 `cliSessionId`、`title`、`sessionId`、`isArchived`）。有的話用它顯示標題、略過已封存的對話，並用 `claude://claude.ai/epitaxy/<id>` 打開對話；
沒有的話（CLI）降級成「資料夾名（前 8 碼）」，雙擊改開網頁清單。

> `claude://…/epitaxy/…` 是桌面版目前的連結格式，不是公開保證的介面；桌面版改版時可能需要更新。
