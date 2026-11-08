// question-mode.mjs — 選項框（AskUserQuestion）要出現在哪裡。Claude 原生對話框一定會跳（除非開「可答模式」）。
//   node question-mode.mjs                 顯示目前狀態（JSON 一行：phone / answerable / widget）
//   node question-mode.mjs phone on|off    手機：on＝選項框也出現在手機（鎖屏提醒＋/pd/ 頁清單）；off＝不推手機
//   node question-mode.mjs answerable on|off  可答模式：on＝手機／小工具可以直接點選項，原生框延後（等不到才跳）；off＝原生框立刻跳、手機／小工具只顯示（預設）
//   node question-mode.mjs sync            三處同步：原生框立刻跳、手機＋小工具同時有卡片，任一處答了電腦自動替點、其他處消失（pd-agent 要在跑）
//   node question-mode.mjs widget on|off   小工具：on＝選項框列在小工具「待決定」；off＝不列
//   舊用法 wait|notify|off 仍可：wait＝手機開＋可答；notify＝手機開＋不可答；off＝手機關
// 設定存在 config.json：push.question = wait|notify|off（手機＋可答模式）、widgetQuestions = false（小工具不列選項框）。改完下一個選項框起生效。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const file = path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), 'config.json');
const cfg = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
cfg.push = cfg.push || {};
const mode = () => (cfg.push.question === false || cfg.push.question === 'off') ? 'off' : (cfg.push.question === 'wait' ? 'wait' : cfg.push.question === 'sync' ? 'sync' : 'notify');
const status = () => ({ phone: mode() !== 'off', answerable: mode() === 'wait', sync: mode() === 'sync', widget: cfg.widgetQuestions !== false });
const [a, b] = [process.argv[2], process.argv[3]];
if (!a) { console.log(JSON.stringify(status())); process.exit(0); }
const on = b === 'on';
if (['wait', 'notify', 'off', 'sync'].includes(a)) { cfg.push.question = a; }
else if (['phone', 'answerable', 'widget'].includes(a) && ['on', 'off'].includes(b)) {
	const s = status();
	if (a === 'widget') { cfg.widgetQuestions = on; }
	else {
		const phone = a === 'phone' ? on : s.phone, ans = a === 'answerable' ? on : s.answerable;
		cfg.push.question = !phone ? 'off' : (ans ? 'wait' : (s.sync ? 'sync' : 'notify'));
		if (a === 'answerable' && on && !s.phone) { cfg.push.question = 'wait'; } // 開可答模式一定要手機開著
	}
} else { console.error('用法：phone|answerable|widget on|off，或 wait|notify|off'); process.exit(2); }
fs.copyFileSync(file, file + '.bak_' + Date.now());
fs.writeFileSync(file, JSON.stringify(cfg, null, 2), 'utf8');
console.log(JSON.stringify(status()));
