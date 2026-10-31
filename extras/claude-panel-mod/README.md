# Claude 桌面版側邊面板 mod（實驗性）

在 Claude 桌面版的側邊開一個「待決定」面板（`/pending` 指令），讀同一份 `pending.json`，每 5 秒更新。

> ⚠️ **實驗性**：作者本機的驗證工具版本太舊，沒有完整驗證過；mod 介面也可能隨桌面版更新而變。主程式不依賴它。

使用：把 `pending-decisions/` 放進你的 Claude 桌面版 mod 資料夾，並把 `hooks/register.tsx` 第一行附近的 `FILE` 改成你自己的 `pending.json` 完整路徑
（預設：`C:/Users/<你>/.claude/pending-decisions/data/pending.json`）。
