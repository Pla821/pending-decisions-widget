// settings-hooks.mjs — 把本工具的 hook「合併」進 Claude Code 的 settings.json，或安全地拿掉。由 install.ps1 呼叫，也可手動用：
//   node settings-hooks.mjs add    <settings.json> <decision-log.mjs 的完整路徑> [--replace-legacy]
//   node settings-hooks.mjs remove <settings.json>
//   node settings-hooks.mjs check  <settings.json>        （看看目前接了幾個）
//   node settings-hooks.mjs statusline-add    <settings.json> <usage-feed.mjs 的完整路徑>   （額度警示用；你已經有自己的狀態列就不動）
//   node settings-hooks.mjs statusline-remove <settings.json>
// 原則：不碰你原有的任何設定與 hook；可重複執行（先拿掉自己舊的再加）；只認得「命令裡有 pending-decisions 與 decision-log.mjs」的那幾筆是自己的。
import fs from 'node:fs';
import path from 'node:path';

const [, , cmd, file, logPath, ...flags] = process.argv;
const MARK = (c) => /pending-decisions/i.test(c || '') && /decision-log\.mjs/i.test(c || '');
const OURS_SL = (c) => /pending-decisions/i.test(c || '') && /usage-feed.mjs/i.test(c || '');
const LEGACY = (c) => /decision-log\.mjs/i.test(c || '') && !MARK(c); // 本工具出現以前的舊版（沒打包的 decision-log.mjs）

// [事件, matcher]；PermissionRequest 不需要 matcher
const WANT = [
	['PreToolUse', 'AskUserQuestion|mcp__.*wrap_up'],     // 選項框＋桌面版「收尾提問卡」
	['PostToolUse', 'AskUserQuestion'],
	['PostToolUseFailure', 'AskUserQuestion'],
	['PermissionRequest', null],                          // 「是否允許 Claude 執行此指令？」
	['Notification', 'permission_prompt']                 // 上一個的備援
];

function read() {
	if (!fs.existsSync(file)) { return { obj: {}, raw: '', indent: '\t', eol: '\n', nl: true, existed: false }; }
	const raw = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
	let obj; try { obj = JSON.parse(raw); } catch (e) { console.error('settings.json 不是合法的 JSON，已停止（沒有改任何東西）：' + e.message); process.exit(2); }
	const m = raw.match(/\n([ \t]+)\S/);
	return { obj, raw, indent: m ? m[1] : '  ', eol: raw.includes('\r\n') ? '\r\n' : '\n', nl: /\n$/.test(raw), existed: true };
}
function write(st) {
	let out = JSON.stringify(st.obj, null, st.indent);
	if (st.eol === '\r\n') { out = out.replace(/\n/g, '\r\n'); }
	if (st.nl) { out += st.eol; }
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, out, 'utf8');
}
function strip(obj, pred) { // 拿掉符合 pred 的 hook；回傳拿掉幾個
	let n = 0;
	if (!obj.hooks) { return 0; }
	for (const ev of Object.keys(obj.hooks)) {
		const groups = obj.hooks[ev];
		if (!Array.isArray(groups)) { continue; }
		for (const g of groups) {
			if (!Array.isArray(g.hooks)) { continue; }
			const before = g.hooks.length;
			g.hooks = g.hooks.filter((h) => !pred(h.command));
			n += before - g.hooks.length;
		}
		obj.hooks[ev] = groups.filter((g) => !Array.isArray(g.hooks) || g.hooks.length > 0);
		if (obj.hooks[ev].length === 0) { delete obj.hooks[ev]; }
	}
	if (Object.keys(obj.hooks).length === 0) { delete obj.hooks; }
	return n;
}

const st = read();
if (cmd === 'add') {
	if (!logPath) { console.error('缺少 decision-log.mjs 路徑'); process.exit(2); }
	let removed = strip(st.obj, MARK);
	if (flags.includes('--replace-legacy')) { removed += strip(st.obj, LEGACY); }
	st.obj.hooks = st.obj.hooks || {};
	for (const [ev, matcher] of WANT) {
		const group = { hooks: [{ type: 'command', command: 'node "' + logPath + '"', timeout: ev === 'PermissionRequest' ? 130 : 15 }] }; // 權限確認可能要等手機核准（ntfy.approve），所以給長一點；沒開那個功能時照樣馬上結束
		if (matcher) { group.matcher = matcher; }
		(st.obj.hooks[ev] = st.obj.hooks[ev] || []).push(group);
	}
	write(st);
	console.log(JSON.stringify({ ok: true, added: WANT.length, replaced: removed }));
} else if (cmd === 'remove') {
	const n = st.existed ? strip(st.obj, flags.includes('--replace-legacy') ? (c) => MARK(c) || LEGACY(c) : MARK) : 0;
	if (n > 0) { write(st); }
	console.log(JSON.stringify({ ok: true, removed: n }));
} else if (cmd === 'statusline-add') {
	const cur = st.obj.statusLine && st.obj.statusLine.command;
	if (cur && !OURS_SL(cur)) { console.log(JSON.stringify({ ok: false, reason: 'existing-statusline', command: cur })); process.exit(0); } // 你已經有狀態列：不蓋掉
	st.obj.statusLine = { type: 'command', command: 'node "' + logPath + '"' };
	write(st); console.log(JSON.stringify({ ok: true }));
} else if (cmd === 'statusline-remove') {
	const cur = st.obj.statusLine && st.obj.statusLine.command;
	if (cur && OURS_SL(cur)) { delete st.obj.statusLine; write(st); console.log(JSON.stringify({ ok: true, removed: 1 })); } else { console.log(JSON.stringify({ ok: true, removed: 0 })); }
} else if (cmd === 'check') {
	let n = 0, legacy = 0;
	for (const groups of Object.values(st.obj.hooks || {})) { for (const g of groups) { for (const h of (g.hooks || [])) { if (MARK(h.command)) { n++; } else if (LEGACY(h.command)) { legacy++; } } } }
	console.log(JSON.stringify({ ok: true, installed: n, legacy, statusline: !!(st.obj.statusLine && OURS_SL(st.obj.statusLine.command)) }));
} else { console.error('用法：add | remove | check | statusline-add | statusline-remove'); process.exit(2); }
