// lib.mjs — 共用：路徑偵測、設定檔、狀態讀寫、對話中繼檔查詢、網頁清單。
// 沒有寫死任何使用者路徑：安裝位置由這支檔案自己的位置推出來，其餘走 config.json 或環境變數。
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = process.env.PDW_HOME || path.dirname(HERE); // bin 的上一層＝安裝資料夾
export const DAY = 86400000;

function readJson(p, fallback) {
	try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch { return fallback; }
}

// config.json 可設：dataDir／claudeDir／sessionsDir／toast。沒設的都自動偵測。
export const CONFIG = readJson(path.join(ROOT, 'config.json'), {});
export const DATA = process.env.PDW_DATA || CONFIG.dataDir || path.join(ROOT, 'data');
export const CLAUDE_DIR = process.env.PDW_CLAUDE_DIR || CONFIG.claudeDir || path.join(os.homedir(), '.claude');
export const PROJECTS = path.join(CLAUDE_DIR, 'projects');
export const STATE = path.join(DATA, 'pending.json');
export const HTML = path.join(DATA, 'pending.html');
export const STATUS = path.join(DATA, 'status.json');
export const CACHE = path.join(DATA, '.scan-cache.json');
export const ERROR_LOG = path.join(DATA, 'error.log');

export function logError(e) {
	try { fs.mkdirSync(DATA, { recursive: true }); fs.appendFileSync(ERROR_LOG, new Date().toISOString() + ' ' + ((e && e.stack) || e) + '\n'); } catch { /* 永遠不擋對話 */ }
}

// ---------- Claude 桌面版的對話中繼檔（有才用；CLI 使用者沒有就降級） ----------
function sessionRoots() {
	if (process.env.PDW_SESSIONS || CONFIG.sessionsDir) { return [process.env.PDW_SESSIONS || CONFIG.sessionsDir]; }
	const out = [];
	const base = process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Claude-Data');
	try {
		if (base) {
			for (const d of fs.readdirSync(base, { withFileTypes: true })) {
				const p = path.join(base, d.name, 'claude-code-sessions');
				if (d.isDirectory() && fs.existsSync(p)) { out.push(p); }
			}
		}
	} catch { /* 沒有桌面版 */ }
	return out;
}
let sessionIndex = null;
export function sessionInfo(cli) { // cliSessionId → { local, title, archived }；找不到回傳 null
	if (!sessionIndex) {
		sessionIndex = new Map();
		for (const root of sessionRoots()) {
			const stack = [root];
			while (stack.length) {
				const d = stack.pop();
				let ents = [];
				try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { continue; }
				for (const ent of ents) {
					const p = path.join(d, ent.name);
					if (ent.isDirectory()) { stack.push(p); continue; }
					if (!ent.name.startsWith('local_') || !ent.name.endsWith('.json')) { continue; }
					const j = readJson(p, null);
					if (j && j.cliSessionId) {
						sessionIndex.set(j.cliSessionId, { local: j.sessionId || ent.name.replace('.json', ''), title: j.title || '', archived: !!j.isArchived });
					}
				}
			}
		}
	}
	return sessionIndex.get(cli) || null;
}
export function fallbackTitle(sid, cwd) { // 沒有桌面版標題時：「資料夾名（前 8 碼）」
	const short = String(sid || '').slice(0, 8);
	const dir = cwd ? path.basename(String(cwd).replace(/[\\/]+$/, '')) : '';
	return dir ? dir + '（' + short + '）' : '對話 ' + short;
}

// ---------- 權限確認（「是否允許 Claude 執行此指令？」）----------
export function readTail(p, size, max = 600 * 1024) {
	const fd = fs.openSync(p, 'r');
	try {
		const n = Math.min(size, max), buf = Buffer.alloc(n);
		fs.readSync(fd, buf, 0, n, size - n);
		let s = buf.toString('utf8');
		if (size > n) { s = s.slice(s.indexOf('\n') + 1); } // 第一行可能被切斷
		return s;
	} finally { fs.closeSync(fd); }
}
export function findTranscript(sid) {
	try {
		for (const d of fs.readdirSync(PROJECTS, { withFileTypes: true })) {
			const p = path.join(PROJECTS, d.name, sid + '.jsonl');
			if (d.isDirectory() && fs.existsSync(p)) { return p; }
		}
	} catch { /* 沒有紀錄資料夾 */ }
	return '';
}
// 同一個工具呼叫在 hook 與對話紀錄裡的「指紋」：工具名＋最能代表它的那個欄位
export function toolSig(name, input) {
	const i = input || {};
	const key = i.command || i.file_path || i.path || i.url || i.pattern || i.query || JSON.stringify(i);
	return String(name || '') + '|' + String(key).slice(0, 300);
}
export function toolDetail(name, input) { // 給人看的一行摘要
	const i = input || {};
	const s = i.command || i.file_path || i.path || i.url || i.pattern || i.query || '';
	return String(s).replace(/\s+/g, ' ').slice(0, 160);
}
// 權限確認有沒有已經處理掉：回傳 'pending'（還在等）／'resolved'（已允許或拒絕）／'unknown'（紀錄裡還沒看到）
export function permissionState(it) {
	const p = findTranscript(it.sid);
	if (!p) { return 'unknown'; }
	let text = '';
	try { text = readTail(p, fs.statSync(p).size, 300 * 1024); } catch { return 'unknown'; }
	let lastUse = null, lastAt = 0;
	const results = new Set();
	for (const line of text.split('\n')) {
		if (!line || (line.indexOf('tool_use') < 0 && line.indexOf('tool_result') < 0 && !it.sig)) { continue; }
		let j; try { j = JSON.parse(line); } catch { continue; }
		if (j.timestamp) { lastAt = Math.max(lastAt, Date.parse(j.timestamp) || 0); }
		const c = j.message && j.message.content;
		if (!Array.isArray(c)) { continue; }
		for (const b of c) {
			if (b.type === 'tool_use' && it.sig && toolSig(b.name, b.input) === it.sig) { lastUse = b.id; }
			else if (b.type === 'tool_result' && b.tool_use_id) { results.add(b.tool_use_id); }
		}
	}
	if (it.sig) { return lastUse ? (results.has(lastUse) ? 'resolved' : 'pending') : 'unknown'; }
	return lastAt > it.at + 3000 ? 'resolved' : 'pending'; // 沒有工具資訊（只收到通知）：紀錄出現更新的內容就當處理了
}
// 掃一遍：把已處理的權限確認標成 answered；久久看不到對應紀錄的丟掉
export function settlePermissions(st) {
	const now = Date.now();
	for (const it of st.items) {
		if (it.kind !== 'permission' || it.status !== 'pending') { continue; }
		const s = permissionState(it);
		if (s === 'resolved' || (s === 'unknown' && now - it.at > 120000) || now - it.at > DAY) { it.status = 'answered'; it.answer = '已處理（允許或拒絕）'; }
	}
}

// ---------- 狀態檔 ----------
export function loadState() {
	const s = readJson(STATE, null);
	return s && Array.isArray(s.items) ? s : { items: [] };
}
export function saveState(st) {
	fs.mkdirSync(DATA, { recursive: true });
	fs.writeFileSync(STATE, JSON.stringify(st, null, 1), 'utf8');
}
export function writeStatus(obj) {
	try { fs.mkdirSync(DATA, { recursive: true }); fs.writeFileSync(STATUS, JSON.stringify({ at: Date.now(), ...obj }), 'utf8'); } catch { /* 算了 */ }
}

// ---------- 網頁清單 ----------
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const clock = (t) => new Date(t).toLocaleString('zh-TW', { hour12: false, month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });

function card(it) {
	const title = it.title || fallbackTitle(it.sid, it.cwd);
	const who = it.local ? '<a href="claude://claude.ai/epitaxy/' + esc(it.local) + '" title="在 Claude 桌面版打開這個對話">' + esc(title) + '</a>' : esc(title);
	const recap = it.kind === 'wrapup' && it.detail ? '<p class="recap">' + esc(it.detail) + '</p>' : '';
	const qs = recap + (it.kind === 'permission' ? '<div class="q"><p>需要你的允許：' + esc(it.tool || '工具') + '</p>' + (it.detail ? '<pre class="code">' + esc(it.detail) + '</pre>' : '') + '</div>' : (it.questions || []).map((q) => '<div class="q"><p>' + esc(q.question) + '</p>' + (q.options && q.options.length ? '<ul class="opts">' + q.options.map((o) => '<li>' + esc(o) + '</li>').join('') + '</ul>' : '') + '</div>').join(''));
	const pending = it.status === 'pending';
	const chip = pending
		? '<span class="chip warn">' + (it.kind === 'permission' ? '等你允許' : it.kind === 'wrapup' ? '等你決定' : '等你回答') + ' · <time data-wait="' + it.at + '"></time></span>'
		: it.status === 'answered' ? '<span class="chip ok">已回答</span>' : '<span class="chip">已取消</span>';
	return '<article class="card ' + esc(it.status) + '"><header><h2>' + who + '</h2>' + chip + '</header>'
		+ '<div class="meta">' + esc(clock(it.at)) + (it.cwd ? ' · <span class="cwd">' + esc(it.cwd) + '</span>' : '') + '</div>' + qs
		+ (it.answer ? '<p class="ans"><span>你的回答</span>' + esc(it.answer) + '</p>' : '') + '</article>';
}

const CSS = ':root{--bg:#F1F4F7;--paper:#fff;--ink:#16191F;--muted:#6B7280;--line:#E3E7EC;--navy:#1F3A5F;--red:#D94A3A;--redbg:#FDECEA;--okbg:#E8F3EC;--ok:#2F7D4F;--chip:#EEF1F5}'
	+ '@media(prefers-color-scheme:dark){:root{--bg:#12161B;--paper:#1B2128;--ink:#E8ECF1;--muted:#98A2B0;--line:#2B343E;--navy:#8DB4E8;--red:#F08A7E;--redbg:#3A2321;--okbg:#1F3327;--ok:#7CCB9A;--chip:#262E37}}'
	+ '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.65 "Microsoft JhengHei UI","Segoe UI","Noto Sans TC",system-ui,sans-serif}'
	+ 'main{max-width:780px;margin:0 auto;padding:28px 18px 56px}'
	+ '.top{display:flex;align-items:center;gap:12px;margin-bottom:6px}.dot{width:38px;height:38px;border-radius:12px;background:var(--navy);display:grid;place-items:center;color:#fff;font-weight:700;font-size:20px;flex:none}'
	+ '@media(prefers-color-scheme:dark){.dot{color:#10202F}}'
	+ 'h1{font-size:1.45rem;margin:0;letter-spacing:.02em}.count{background:var(--red);color:#fff;border-radius:999px;font-size:.85rem;font-weight:700;padding:1px 11px;margin-left:4px}.count.zero{background:var(--ok)}'
	+ '.sub{color:var(--muted);font-size:.85rem;margin:2px 0 22px 50px}'
	+ 'h3{margin:30px 0 10px;font-size:.9rem;color:var(--muted);font-weight:600;letter-spacing:.06em}'
	+ '.card{background:var(--paper);border:1px solid var(--line);border-radius:14px;padding:14px 18px 14px;margin:0 0 12px;box-shadow:0 1px 2px rgba(20,30,50,.05)}'
	+ '.card.pending{border-left:5px solid var(--red)}.card:not(.pending){opacity:.82}'
	+ '.card header{display:flex;align-items:center;justify-content:space-between;gap:10px}.card h2{font-size:1.02rem;margin:0;overflow-wrap:anywhere}.card h2 a{color:var(--navy);text-decoration:none;border-bottom:1px dashed currentColor}.card h2 a:hover{border-bottom-style:solid}'
	+ '.chip{flex:none;font-size:.78rem;border-radius:999px;padding:1px 10px;background:var(--chip);color:var(--muted)}.chip.warn{background:var(--redbg);color:var(--red);font-weight:600}.chip.ok{background:var(--okbg);color:var(--ok)}'
	+ '.meta{color:var(--muted);font-size:.8rem;margin-top:1px;overflow-wrap:anywhere}.cwd{font-family:Consolas,monospace}'
	+ '.q{margin-top:10px}.q p{margin:0;font-weight:600}.opts{list-style:none;margin:8px 0 0;padding:0;display:flex;flex-wrap:wrap;gap:6px}.opts li{background:var(--chip);border-radius:8px;padding:2px 10px;font-size:.85rem;color:var(--muted)}'
	+ '.recap{margin:10px 0 0;color:var(--muted);font-size:.88rem}'
	+ '.code{margin:8px 0 0;padding:8px 12px;background:var(--chip);border-radius:8px;font:.82rem/1.5 Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;color:var(--ink)}'
	+ '.ans{margin:10px 0 0;padding:8px 12px;background:var(--okbg);border-radius:8px;color:var(--ink);font-size:.9rem}.ans span{color:var(--ok);font-weight:700;margin-right:8px}'
	+ '.empty{text-align:center;padding:44px 20px;background:var(--paper);border:1px dashed var(--line);border-radius:14px;color:var(--muted)}.empty b{display:block;font-size:2.2rem;color:var(--ok);line-height:1.2}.empty p{margin:6px 0 0}'
	+ 'footer{margin-top:34px;color:var(--muted);font-size:.78rem;text-align:center}';

const JS = 'function t(){document.querySelectorAll("time[data-wait]").forEach(function(e){var m=Math.max(1,Math.round((Date.now()-Number(e.dataset.wait))/60000));e.textContent=m>=60?"已等 "+(m/60).toFixed(1)+" 小時":"已等 "+m+" 分鐘"})}t();setInterval(t,15000);';

export function render(st) {
	const pend = st.items.filter((i) => i.status === 'pending').sort((a, b) => b.at - a.at);
	const done = st.items.filter((i) => i.status !== 'pending').sort((a, b) => b.at - a.at).slice(0, 12);
	const h = '<!doctype html><html lang="zh-Hant-TW"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="20"><title>待決定清單</title><style>' + CSS + '</style></head><body><main>'
		+ '<div class="top"><div class="dot">!</div><h1>待決定清單<span class="count' + (pend.length ? '' : ' zero') + '">' + pend.length + '</span></h1></div>'
		+ '<p class="sub">Claude 用選項框問你、還在等你回答的事。這頁每 20 秒自己更新，全部資料只在這台電腦。</p>'
		+ (pend.length ? pend.map(card).join('')
			: '<div class="empty"><b>✓</b><p>目前沒有等你回答的選項框</p></div>')
		+ '<h3>最近回答過的</h3>' + (done.length ? done.map(card).join('') : '<div class="empty"><p>還沒有紀錄</p></div>')
		+ '<footer>pending-decisions-widget · 只讀本機對話紀錄，不連網、不上傳</footer></main><script>' + JS + '</script></body></html>';
	return h;
}
export function writeHtml(st) { // 內容沒變就不寫，少吵硬碟
	try {
		const h = render(st);
		let old = ''; try { old = fs.readFileSync(HTML, 'utf8'); } catch { /* 第一次 */ }
		if (old !== h) { fs.mkdirSync(DATA, { recursive: true }); fs.writeFileSync(HTML, h, 'utf8'); }
	} catch (e) { logError(e); }
}
