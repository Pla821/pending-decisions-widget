# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/)。

## [0.1.0] — 2026-11-01

第一個公開版本。

### 新增
- 浮窗：圖示＋紅色數字、有新的就抖動／提示音／冒泡、點開清單、雙擊開對話、可拖曳、可換圖（照片自動裁圓形）、淺色／深色。
- 三種「Claude 在等你」：選項框（`AskUserQuestion`）、權限確認（`PermissionRequest`／`Notification`）、桌面版收尾提問卡（問題＋按鈕）。
- 掃描所有對話的紀錄找「問了還沒回答」，不依賴 hook；hook 提供即時 Windows 通知。
- 網頁清單（卡片、狀態、淺色／深色、空狀態、等待時間即時更新）。
- `install.ps1`：一鍵安裝／`-Uninstall` 移除；合併 hook 前先備份、可重複執行、移除時原封不動還原 `settings.json`；`-Autostart`、`-ReplaceLegacy`、`-Purge`。
- 沒有 Claude 桌面版（CLI 使用者）時優雅降級：標題用「資料夾名（前 8 碼）」，雙擊改開網頁清單。
- 錯誤與空狀態文案：找不到 Node.js、找不到對話紀錄資料夾、掃描中、全部回完。
- 實驗性：`extras/claude-panel-mod/` 桌面版側邊面板 mod。
