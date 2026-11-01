<div align="center">

# 待決定浮窗 · Pending Decisions Widget

**Claude 在等你回答的時候，桌面上有一個小圖示提醒你。**
同時開很多個 Claude Code 對話，再也不會漏看選項框、權限確認和「要不要上線」這種等你決定的問題。

[English](README.en.md) · 繁體中文

![浮窗與清單（淺色）](docs/assets/panel-light.png)

</div>

---

## 它解決什麼痛點

同時開十個、一百個 Claude Code 對話時，Claude 常常用**選項框**問你一個決定、或停下來等你**允許執行某個指令**。對話一多，那個框就藏在某個你沒在看的對話裡——Claude 在等你，你以為它還在工作，半小時就這樣過去了。

這個小工具把「Claude 在等你」集中到一個地方：

| 圖示 | 種類 | 長什麼樣子 |
|---|---|---|
| 🔴 選項框 | Claude 用選項框問你問題（`AskUserQuestion`） | 「首頁主視覺要用照片還是插畫？」 |
| 🟠 要你允許 | 「是否允許 Claude 執行此指令？」權限確認 | `Bash  npm run build && rm -rf dist/old` |
| 🔵 要你決定 | Claude 桌面版收尾時附帶的「問題＋按鈕」提問卡 | 「分類規則要先上線，還是再多測幾家銀行？」 |

- **浮窗**：螢幕角落一個小圖示（右上角有紅色數字）。有新的就抖一下、叮一聲、冒出對話框；點圖展開清單，**雙擊一列直接打開那個對話**。
- **Windows 通知**：問題一冒出來就跳一則通知，點它開網頁清單。
- **網頁清單**：一頁卡片，每 20 秒自己更新，淺色／深色模式自動切換。
- 圖示可以換成你喜歡的圖（拖一張圖到浮窗上就行），說的話也能自己改。

| 對話框與數字 | 網頁清單 |
|---|---|
| ![冒泡](docs/assets/bubble-light.png) | ![網頁清單](docs/assets/web-light.png) |

> 截圖是用程式把真正的視窗畫成圖（資料為示範用的假對話），不是設計稿。深色模式、設定視窗、空狀態見 [docs/screenshots.md](docs/screenshots.md)。

## 前置需求

- **Windows 10／11**（浮窗用 Windows PowerShell 5.1 + WinForms，通知用 Windows Toast；目前不支援 macOS／Linux）
- **Node.js 18 以上**（掃描對話紀錄與 hook 腳本用；安裝程式會檢查）
- **Claude Code**（CLI 或桌面版皆可。桌面版會多出「點一下直接打開對話」和對話標題；CLI 版標題顯示為「資料夾名（前 8 碼）」，點擊改開網頁清單）

## 安裝

```powershell
git clone https://github.com/Pla821/pending-decisions-widget.git
cd pending-decisions-widget
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart
```

- `-Autostart`：開機自動啟動浮窗（不加的話，互動模式會問你；`-NoAutostart` 就不問）。
- 安裝程式會：複製程式到 `~\.claude\pending-decisions\`、**先備份**你的 `settings.json` 再把 5 個 hook **合併**進去（不動你原有的任何設定與 hook、可重複執行）、啟動浮窗。
- 已經開著的 Claude 對話要重開，才會載入新的 hook。不過**浮窗本身不靠 hook 也看得到選項框與提問卡**（它直接掃對話紀錄）；hook 負責即時的 Windows 通知與「權限確認」。
- 之前用過沒打包的舊版 `decision-log.mjs`？加 `-ReplaceLegacy` 一起換掉，避免重複通知。

### 移除

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\pending-decisions\install.ps1" -Uninstall
```

只拿掉本工具的 hook、捷徑與程式；`settings.json` 如果自安裝後沒被改過，會**原封不動還原成安裝前的樣子**。你的資料（`data\`：清單、你放的圖、設定）預設保留，不要了加 `-Purge`。

## 使用

| 操作 | 效果 |
|---|---|
| 點圖示 | 展開／收起清單 |
| 雙擊清單一列 | 打開那個對話（桌面版）；CLI 使用者開網頁清單 |
| 拖著圖示 | 搬位置（會記住） |
| 把圖檔拖到圖示上 | 換成那張圖（照片會自動裁成置中的圓形頭像） |
| 右鍵圖示 | 設定／網頁清單／開啟資料夾／結束 |
| 設定視窗 | 換圖、改說的話、沒待決定時是否隱藏、提示音、開機自動啟動、讓圖示走來走去、養電子雞 |
| 清單上方的分頁 | **待決定**／**中斷**（疑似斷線的對話：點一下開對話並複製「請從中斷處接著做」）／**最近對話**／**專案**／**最近檔案**／**資料夾**（點一下就開） |
| 右鍵 →「電子雞」 | 餵食、陪玩、摸摸、哄睡覺、看狀態、取名字（設定裡勾「養電子雞」才有） |

### 中斷偵測
對話紀錄的最後一筆停在「正在做事」「工具剛跑完」「你剛說完話沒回」「回答寫到一半」，而且安靜超過 5 分鐘，就會列在「中斷」分頁，標出它停在哪一步。浮窗不能替你送出訊息，所以點一下只會開對話並把接續指令放進剪貼簿，由你貼上送出。

### 額度警示（選用）
`install.ps1 -UsageGuard` 會把 Claude Code 狀態列接到 `usage-feed.mjs`（已有自己的狀態列就不動）。用量 ≥90% 浮窗提醒「只做明確要的事」，≥98% 提醒「全面停止」。只有 Pro／Max 帳號的狀態列才有用量數字；沒有的話可在右鍵「回報額度 %」手動填。另外，有對話正在用 Fable 模型（走另一個額度池）時會提醒，已經換掉就不再顯示。

## 設定

大部分在浮窗的「設定」視窗裡改。進階選項在 `~\.claude\pending-decisions\config.json`：

```json
{
  "toast": true,
  "theme": "auto",
  "dataDir": null,
  "claudeDir": null,
  "sessionsDir": null
}
```

| 欄位 | 說明 |
|---|---|
| `toast` | `false` 關掉 Windows 通知 |
| `theme` | `auto`（跟 Windows）／`light`／`dark` |
| `dataDir` | 清單、設定、圖放哪，預設 `<安裝資料夾>\data` |
| `claudeDir` | Claude 設定資料夾，預設 `%USERPROFILE%\.claude`（掃描 `projects\*\*.jsonl`） |
| `sessionsDir` | Claude 桌面版對話中繼檔資料夾，預設自動找 `%LOCALAPPDATA%\Claude-Data\*\claude-code-sessions`；沒有就降級 |

環境變數 `PDW_HOME`、`PDW_DATA`、`PDW_CLAUDE_DIR`、`PDW_SESSIONS`、`PDW_THEME` 可以覆蓋（測試用）。

## 運作原理（一分鐘版）

```
Claude Code 對話 ──寫入──▶ ~/.claude/projects/*/*.jsonl      （每個對話的完整紀錄）
        │                          ▲
        │ hook（即時）              │ 每 6 秒掃一次尾端：問了、還沒有回答的 = 在等你
        ▼                          │
 decision-log.mjs ──▶ data/pending.json ◀── decision-scan.mjs
        │                    │
        ▼                    ├──▶ widget.ps1  浮窗（抖動、冒泡、清單、雙擊開對話）
  Windows 通知               └──▶ pending.html  網頁清單
```

- **掃描（decision-scan）**：不靠 hook。每個對話的紀錄裡，「問了」和「回了」都有；沒配到回答的就是在等你。所以新舊對話、有沒有載入 hook 都抓得到。
- **hook（decision-log）**：選項框一問出來就即時通知；**權限確認**只有 hook 看得到（`PermissionRequest`），之後由掃描發現「這個指令已經有結果了」才算處理掉。
- 詳細說明見 [docs/how-it-works.md](docs/how-it-works.md)。

## 隱私

- **只讀你本機的對話紀錄**，只為了找出「問了還沒回答」的問題；不連網、不上傳、沒有遙測。
- 清單裡會有對話標題、問題文字和指令摘要，**全都只存在你電腦的 `data\` 資料夾**。這個資料夾已在 `.gitignore`，不會被推上 GitHub。
- hook 腳本永遠 `exit 0` 且不輸出任何東西：它**不會替你做任何允許或拒絕**，也不會擋住任何對話。
- 想看它做了什麼：整個專案不到 1,500 行，程式都在 `src\bin\`。

## 疑難排解

| 狀況 | 怎麼辦 |
|---|---|
| 浮窗沒出現 | 看 `~\.claude\pending-decisions\data\error.log`；確認 `node -v` 有輸出；重跑 `install.ps1` |
| 清單顯示「找不到 Node.js」 | 安裝 Node.js LTS（https://nodejs.org），重開浮窗 |
| 清單顯示「找不到對話紀錄資料夾」 | Claude 資料不在 `%USERPROFILE%\.claude`；在 `config.json` 設 `claudeDir` |
| 權限確認沒跳通知 | 需要已重開的 Claude 對話才載入 hook；確認 `settings.json` 的 `hooks.PermissionRequest` 有本工具那一筆（`node ~\.claude\pending-decisions\bin\settings-hooks.mjs check ~\.claude\settings.json`）；你的 Claude Code 版本需支援 `PermissionRequest` hook |
| 每個通知跳兩次 | 舊版 hook 還在：`install.ps1 -ReplaceLegacy` |
| 標題只顯示「資料夾（8碼）」 | 你用的是 CLI 版（沒有桌面版對話中繼檔），這是預期行為 |
| 中文變亂碼 | `.ps1` 檔必須是「UTF-8 with BOM」：`node tools/ensure-bom.mjs` |
| 想完全重來 | `install.ps1 -Uninstall -Purge` 再重裝 |

## 開發

```powershell
node tests/scan-test.mjs                                   # 掃描／三種待決定的冒煙測試（用假紀錄，不碰你的 ~/.claude）
powershell -File tests/install-test.ps1                    # 安裝／重複安裝／移除，全部在暫存資料夾
node tools/make-demo.mjs demo                              # 建示範環境（假對話），試用或拍截圖
powershell -File tools/make-icons.ps1                      # 重新產生內建圖示
```

`extras/claude-panel-mod/` 是一個**實驗性**的 Claude 桌面版側邊面板 mod（讀同一份 `pending.json`），尚未完整驗證，見該資料夾說明。

## 授權

[MIT](LICENSE)。內建圖示為本專案以向量繪製，可自由使用。
