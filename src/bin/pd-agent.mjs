// pd-agent.mjs — 待決定浮窗的「手機鏡像＋遙控」常駐小程式（由 widget.ps1 啟動，單一實例）。
//   1. 鏡像：每 5 秒看一次 data/pending.json + data/recent.json，有變就（至少每 30 秒）把「待決定」「中斷」快照 POST 到飛傳信箱 /pd/api/state，手機 /pd/ 頁讀。
//   2. 遙控：長輪詢 GET /pd/api/cmd/next 領手機下的指令。唯一允許的動作是 wake＝「叫醒指定的中斷對話」（等同小工具「全部重新啟動」那一招），
//      其餘一律拒絕。指令內容只有 sid；提示詞、claude.exe 路徑、參數全部寫死在這裡，手機傳什麼都不會被當成指令執行。
// 安全閘（每一道都在電腦端再驗一次，不信伺服器）：
//   - action 必須是 wake；sid 必須是 UUID，且必須在「本機 recent.json 目前的中斷清單」裡、對話不是正在跑
//   - 一次最多 3 個；任何 10 分鐘內，所有來源（小工具＋手機）加起來最多叫醒 3 個（看 data/restart.log）；同一對話 10 分鐘內不重複叫
//   - 用量 ≥98%（data/usage.json）一律不叫醒
//   - 第二種動作 reply＝替「收尾提問卡」按下卡片上的某個按鈕：手機只傳「卡片編號＋第幾個按鈕」，按鈕文字、對話編號都由這裡從 pending.json 查；
//     卡片必須還在等、對話不是正在跑；10 分鐘內最多 5 次
//   - 第三、四種動作 pause／resume（2026-11-08）＝關機前「全部暫停」：逐個切到 recent.json 裡正在跑的對話、替使用者按「停止」鍵（uia-stop.ps1）；
//     「全部繼續」只叫醒 paused.json 清單裡、真的停成功的對話（固定文字，同 wake 那一招）。指令不帶任何文字／對話編號，清單全由電腦端自己查；
//     一次最多 20 個、逐個間隔 1 秒；在等使用者回答的對話不碰；來源有兩個：手機（信箱 cmd）與小工具（data\ctl-request.json），共用同一把鎖
//   - 指令從伺服器領到起算超過 3 分鐘就作廢；密碼只放 Authorization header、不寫 log
// 設定沿用 config.json 的 push.server / push.secret（和 hook 同一組）；沒設就直接結束。
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { DATA, CONFIG, CLAUDE_DIR, PROJECTS, logError, loadState, saveState } from './lib.mjs';

const P = CONFIG.push;
if (!P || P.provider !== 'feichuan' || !P.server || typeof P.secret !== 'string' || P.secret.length < 32 || P.mirror === false) { process.exit(0); }
const SERVER = String(P.server).replace(/\/+$/, '');
if (!/^https:\/\//i.test(SERVER) && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i.test(SERVER)) { process.exit(0); }
const SECRET = P.secret;
const PORT = Number(CONFIG.pdAgentPort) || 47831;
const TEST_EXE = process.env.PDW_CLAUDE_EXE || ''; // 測試用：指到假的 claude 程式（只有設了這個才會多吃 PDW_CLAUDE_PREARGS）
const TEST_PRE = TEST_EXE && process.env.PDW_CLAUDE_PREARGS ? JSON.parse(process.env.PDW_CLAUDE_PREARGS) : [];
const EXE = TEST_EXE || path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'npm', 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe');
const WAKE_TEXT = '剛剛好像斷線或中斷了。請先看紀錄，確認你上一步做到哪，已經做完的不要重做，沒做完的從那裡接著做，做完用一句話跟我說。';
const SID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COOLDOWN_MS = 10 * 60 * 1000;
const PERM_LABELS = ['允許一次', '拒絕']; // 手機上「要你允許」卡片的兩個按鈕（文字寫死；Claude 視窗裡的按鈕就叫這兩個名字）
const UIA_PS1 = path.join(path.dirname(fileURLToPath(import.meta.url)), 'uia-click.ps1');
const STOP_PS1 = path.join(path.dirname(fileURLToPath(import.meta.url)), 'uia-stop.ps1');
const RESUME_TEXT = '剛剛因為要關機，我請你先暫停了。現在可以繼續：請先看紀錄，確認你上一步做到哪，已經做完的不要重做，沒做完的從那裡接著做，做完用一句話跟我說。';
const CTL_RESUME_GAP_MS = Number(process.env.PDW_CTL_GAP) > 0 && TEST_EXE ? Number(process.env.PDW_CTL_GAP) : 2000;
const CTL_MAX = 20; // 一次暫停／繼續最多處理幾個對話
const PAUSED_JSON = path.join(DATA, 'paused.json'), PAUSE_LOG = path.join(DATA, 'pause.log'), CTL_REQ = path.join(DATA, 'ctl-request.json'), CTL_RES = path.join(DATA, 'ctl-result.json');
const PERM_MAX_AGE_MS = 10 * 60 * 1000; // 權限卡超過 10 分鐘就不替人按（對話多半已經換了請求）
const PERM_MAX_PER_WINDOW = 8;
const CMD_MAX_AGE_MS = 3 * 60 * 1000;
const MAX_PER_WINDOW = 3;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8').replace(/^﻿/, '')); } catch { return null; } };
const LOG = path.join(DATA, 'agent.log');
const RESTART_LOG = path.join(DATA, 'restart.log');
const log = (s) => { try { fs.appendFileSync(LOG, new Date().toISOString() + ' ' + s + '\n'); } catch { /* 診斷紀錄寫不了就算了 */ } };

// 單一實例：綁本機埠當鎖（被占用＝已有一個在跑）
const lock = net.createServer();
await new Promise((resolve) => { lock.once('error', () => process.exit(0)); lock.listen(PORT, '127.0.0.1', resolve); });
fs.mkdirSync(DATA, { recursive: true });
log('start pid=' + process.pid + ' server=' + SERVER);

function call(method, pathAndQuery, body, timeoutMs) {
	return new Promise((resolve, reject) => {
		const u = new URL(SERVER + '/pd/api/' + pathAndQuery);
		const data = body ? Buffer.from(JSON.stringify(body)) : null;
		const req = (u.protocol === 'https:' ? https : http).request(u, {
			method, agent: false, timeout: timeoutMs || 15000,
			headers: { Authorization: 'Bearer ' + SECRET, Connection: 'close', ...(data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {}) }
		}, (res) => {
			const chunks = [];
			res.on('data', (c) => { if (chunks.length < 64) { chunks.push(c); } });
			res.on('end', () => { let j = null; try { j = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* 沒有 JSON */ } resolve({ status: res.statusCode, ok: res.statusCode >= 200 && res.statusCode < 300, j }); });
			res.on('error', reject);
		});
		req.on('timeout', () => req.destroy(new Error('timeout')));
		req.on('error', reject);
		if (data) { req.write(data); }
		req.end();
	});
}

// ── 1. 鏡像 ─────────────────────────────
function isNoiseBroken(x) { return !x.sid || x.run || (/^你說：/.test(String(x.stopped || '')) && /system-reminder/.test(String(x.stopped || ''))); } // 與 widget 的 Restart-AllBroken 相同的過濾
function brokenNow() {
	const r = readJson(path.join(DATA, 'recent.json'));
	return (r && Array.isArray(r.broken) ? r.broken : []).filter((x) => !isNoiseBroken(x) && SID_RE.test(String(x.sid)));
}
function buildSnapshot() {
	const now = Date.now();
	const st = readJson(path.join(DATA, 'pending.json'));
	const pending = [];
	for (const it of (st && Array.isArray(st.items) ? st.items : [])) {
		if (it.status !== 'pending' || !it.id) { continue; }
		const kind = it.kind === 'permission' ? 'permission' : it.kind === 'wrapup' ? 'wrapup' : (!it.kind || it.kind === 'question') ? 'q' : null;
		if (!kind) { continue; } // fable／proposal／usage 之類只在電腦上有意義
		const q0 = it.questions && it.questions[0];
		const text = kind === 'permission' ? ((it.tool || '') + ' ' + (it.detail || '')).trim() : (q0 && q0.question) || '';
		const id = cardId(it.id);
		const title = it.title || (it.cwd ? path.basename(String(it.cwd).replace(/[\\/]+$/, '')) : '') || '對話';
		pending.push({ id, kind, title, text, at: it.at || 0, options: kind === 'permission' ? PERM_LABELS.slice() : kind === 'q' || kind === 'wrapup' ? ((q0 && q0.options) || []).filter((o) => typeof o === 'string').slice(0, 4) : [], live: !!(it.qid && it.qUntil > now) });
	}
	pending.sort((a, b) => b.at - a.at);
	const broken = brokenNow().sort((a, b) => b.at - a.at).map((x) => ({ sid: String(x.sid).toLowerCase(), title: x.title || '(未命名)', stopped: x.stopped || '', at: x.at || 0 }));
	return { pending: pending.slice(0, 15), broken: broken.slice(0, 15), usage: usageSnap(), ctl: ctlSnap() };
}
// ── 暫停／繼續：清單與快照 ─────────────────────────────
function runningNow() { // recent.json 裡「正在跑」的對話（資料超過 3 分鐘沒更新就當沒有，不憑舊資料動手）
	const r = readJson(path.join(DATA, 'recent.json'));
	if (!r || !Array.isArray(r.sessions) || Date.now() - Number(r.at) > 3 * 60 * 1000) { return []; }
	return r.sessions.filter((x) => x && x.run && SID_RE.test(String(x.sid))).map((x) => ({ sid: String(x.sid).toLowerCase(), title: String(x.title || ''), local: String(x.local || ''), cwd: String(x.cwd || ''), at: Number(x.at) || 0 }));
}
function waitingSids() { // 正在等使用者回答（選項框／權限／收尾提問）的對話：它們本來就停著，沒有停止鍵，不碰
	const st = readJson(path.join(DATA, 'pending.json')); const s = new Set();
	for (const it of (st && Array.isArray(st.items) ? st.items : [])) { if (it.status === 'pending' && it.sid && ['question', 'permission', 'wrapup', undefined].includes(it.kind)) { s.add(String(it.sid).toLowerCase()); } }
	return s;
}
function readPaused() { const j = readJson(PAUSED_JSON); return j && Array.isArray(j.items) ? j : { at: 0, items: [] }; }
function ctlSnap() { // 手機顯示用：進行中幾個、已暫停可繼續幾個、上次沒停成功的有哪些
	const wait = waitingSids(); const run = runningNow(); const p = readPaused();
	return { run: run.filter((x) => !wait.has(x.sid)).length, waiting: run.filter((x) => wait.has(x.sid)).length, paused: p.items.filter((x) => x.ok && !x.resumed).length, failed: p.items.filter((x) => !x.ok && !x.resumed).slice(0, 8).map((x) => String(x.title || x.sid).slice(0, 40)), at: Number(p.at) || 0 };
}
let lastHash = '', lastPostAt = 0, failStreak = 0;
async function mirrorTick() {
	try {
		const snap = buildSnapshot();
		const h = crypto.createHash('sha1').update(JSON.stringify(snap)).digest('hex');
		const now = Date.now();
		if (h === lastHash && now - lastPostAt < 30000) { return; }
		const r = await call('POST', 'state', snap, 20000);
		if (r.ok) { lastHash = h; lastPostAt = now; failStreak = 0; } else { failStreak++; if (r.status === 401 || r.status === 503) { log('state 被拒絕 ' + r.status); } }
	} catch (e) { failStreak++; if (failStreak % 10 === 1) { log('state 失敗 ' + (e && e.message)); } }
}

// ── 2. 遙控：叫醒中斷的對話 ─────────────────────────────
function recentWakes() { // 解析 restart.log 最近 10 分鐘的「叫醒」行 → [{sid, at}]（小工具與手機共用這份紀錄）
	let txt = ''; try { txt = fs.readFileSync(RESTART_LOG, 'utf8'); } catch { return []; }
	const out = [], now = Date.now();
	for (const line of txt.split(/\r?\n/).slice(-200)) {
		const m = /^\uFEFF?(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) 叫醒 ([0-9a-f-]{36})/i.exec(line);
		if (!m) { continue; }
		const t = new Date(m[1] + 'T' + m[2]).getTime();
		if (Number.isFinite(t) && now - t < COOLDOWN_MS && now >= t - 60000) { out.push({ sid: m[3].toLowerCase(), at: t }); }
	}
	return out;
}
function usagePct() { // data/usage.json：取兩個窗口較高的；資料太舊（>12 小時）或窗口已重置不算
	const u = readJson(path.join(DATA, 'usage.json')); const now = Date.now();
	if (!u || now - Number(u.at) > 12 * 3600000) { return 0; }
	let best = 0;
	for (const k of ['five_hour', 'seven_day', 'manual']) { const w = u[k]; if (!w || w.pct == null) { continue; } if (w.resets_at && Number(w.resets_at) * 1000 < now && k !== 'manual') { continue; } best = Math.max(best, Number(w.pct) || 0); }
	return best;
}
function findCwd(sid, fallback) {
	let cwd = '';
	try {
		for (const d of fs.readdirSync(PROJECTS, { withFileTypes: true })) {
			if (!d.isDirectory()) { continue; }
			const f = path.join(PROJECTS, d.name, sid + '.jsonl');
			if (!fs.existsSync(f)) { continue; }
			const fd = fs.openSync(f, 'r'); const buf = Buffer.alloc(262144); const n = fs.readSync(fd, buf, 0, buf.length, 0); fs.closeSync(fd);
			const m = /"cwd":"((?:[^"\\]|\\.)*)"/.exec(buf.slice(0, n).toString('utf8'));
			if (m) { try { cwd = JSON.parse('"' + m[1] + '"'); } catch { cwd = m[1].replace(/\\\\/g, '\\'); } }
			break;
		}
	} catch { /* 找不到就用備案 */ }
	if (!cwd || !fs.existsSync(cwd)) { cwd = fallback && fs.existsSync(fallback) ? fallback : os.homedir(); }
	return cwd;
}
function wakeOne(x, text = WAKE_TEXT, tag = '（手機）') {
	const sid = String(x.sid).toLowerCase(), cwd = findCwd(sid, String(x.cwd || ''));
	const out = path.join(DATA, 'restart_' + sid.slice(0, 8) + '.out');
	const fo = fs.openSync(out, 'w'), fe = fs.openSync(out + '.err', 'w');
	const child = spawn(EXE, [...TEST_PRE, '-p', text, '--resume', sid, '--output-format', 'json'], { cwd, detached: true, stdio: ['ignore', fo, fe], windowsHide: true });
	child.on('error', (e) => log('spawn 失敗 ' + sid.slice(0, 8) + ' ' + e.message));
	child.unref(); fs.closeSync(fo); fs.closeSync(fe);
	const d = new Date(), p2 = (n) => String(n).padStart(2, '0');
	const stamp = d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
	fs.appendFileSync(RESTART_LOG, stamp + ' 叫醒 ' + sid + ' ' + String(x.title || '') + ' @ ' + cwd + tag + '\n', 'utf8');
	return cwd;
}
function uiaStop(title, local) { // 呼叫 uia-stop.ps1 替使用者按那個對話的「停止」鍵 → {ok, note}
	const script = TEST_EXE && process.env.PDW_UIA_STOP ? process.env.PDW_UIA_STOP : STOP_PS1; // 測試模式（有設假 claude）才能換成假的按鈕程式
	return runPs(['-Title', title, '-Local', local], script);
}
function uiaClick(title, local, buttons, expect) { // 呼叫 uia-click.ps1 替使用者按 Claude 視窗裡的按鈕 → {ok, note}
	return new Promise((resolve) => {
		const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', UIA_PS1, '-Title', title, '-Local', local, '-ButtonsStr', buttons.join('|')];
		if (expect) { args.push('-Expect', expect); }
		let out = '', done = false;
		const fin = (r) => { if (!done) { done = true; resolve(r); } };
		const ch = spawn('powershell.exe', args, { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
		const timer = setTimeout(() => { try { ch.kill(); } catch { /* 已結束 */ } fin({ ok: false, note: '按鈕程式逾時' }); }, 45000);
		ch.stdout.setEncoding('utf8'); ch.stdout.on('data', (d) => { if (out.length < 4000) { out += d; } });
		ch.on('error', (e) => { clearTimeout(timer); fin({ ok: false, note: '啟動失敗：' + String(e && e.message).slice(0, 60) }); });
		ch.on('close', () => { clearTimeout(timer); let j = null; try { j = JSON.parse(out.trim().split(/\r?\n/).pop()); } catch { /* 沒有 JSON */ } fin(j && typeof j.ok === 'boolean' ? { ok: j.ok, note: String(j.note || '').slice(0, 120) } : { ok: false, note: '按鈕程式沒有回報' }); });
	});
}
// ── 3. 同步選項框：手機／小工具答了，電腦替使用者在 Claude 視窗點同一個選項 ─────────────────────────────
// hook（同步模式）把選項框推到信箱（sync:true）後立刻放行，所以原生框馬上可以點。這裡長輪詢那個信箱項目：
// 手機／小工具答了第 N 題（先答先贏）→ 用 uia-q.ps1 在 Claude 視窗選好那題、按「下一步」（最後一題按「提交」）。
// 在電腦原生框先答 → hook 的 PostToolUse 把 pending.json 標成 answered、撤掉信箱項目，這裡就停手。
const syncWatchers = new Set();
const syncClicks = []; // 最近的點擊時間，10 分鐘最多 40 次
function uiaQ(it, qi, ans, final) { // → Promise<{ok, note}>
	const q = it.questions && it.questions[qi];
	const labels = (ans.sel || []).map((k) => q && q.options && q.options[k]).filter((x) => typeof x === 'string' && x);
	if (!q || typeof q.question !== 'string' || labels.length !== (ans.sel || []).length) { return Promise.resolve({ ok: false, note: '題目與選項對不上' }); }
	const title = String(it.title || ''), local = String(it.local || '');
	if (!title || !/^local_[0-9a-f-]{36}$/.test(local)) { return Promise.resolve({ ok: false, note: '找不到是哪個對話' }); }
	const other = String(ans.other || '').replace(/[\r\n\t]+/g, ' ').slice(0, 200);
	if (!labels.length && !other) { return Promise.resolve({ ok: false, note: '沒有答案' }); }
	return runPs(['-Title', title, '-Local', local, '-Question', q.question.slice(0, 60), '-Pick', labels.join('|'), ...(other ? ['-Other', other] : []), ...(final ? ['-Final'] : [])], TEST_EXE && process.env.PDW_UIA_Q ? process.env.PDW_UIA_Q : path.join(path.dirname(UIA_PS1), 'uia-q.ps1')); // 測試模式（有設假 claude）才能換成假的按鈕程式
}
function runPs(args, script) {
	return new Promise((resolve) => {
		const a = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];
		let out = '', done = false;
		const fin = (r) => { if (!done) { done = true; resolve(r); } };
		const ch = spawn('powershell.exe', a, { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
		const timer = setTimeout(() => { try { ch.kill(); } catch { /* 已結束 */ } fin({ ok: false, note: '按鈕程式逾時' }); }, 60000);
		ch.stdout.setEncoding('utf8'); ch.stdout.on('data', (d) => { if (out.length < 4000) { out += d; } });
		ch.on('error', (e) => { clearTimeout(timer); fin({ ok: false, note: '啟動失敗：' + String(e && e.message).slice(0, 60) }); });
		ch.on('close', () => { clearTimeout(timer); let j = null; try { j = JSON.parse(out.trim().split(/\r?\n/).pop()); } catch { /* 沒有 JSON */ } fin(j && typeof j.ok === 'boolean' ? { ok: j.ok, note: String(j.note || '').slice(0, 120) } : { ok: false, note: '按鈕程式沒有回報' }); });
	});
}
async function watchSync(itemId, qid) {
	try {
		let have = 0;
		for (let guard = 0; guard < 400; guard++) {
			const st = loadState(); const it = st.items.find((i) => i.id === itemId);
			if (!it || it.status !== 'pending' || it.qid !== qid) { return; } // 原生框已經答了／取消了
			const r = await call('GET', 'wait?id=' + encodeURIComponent(qid) + '&timeout=20&have=' + have, null, 32000).catch(() => null);
			if (!r) { await sleep(2000); continue; }
			if (r.status === 404) { return; }
			if (!r.ok) { await sleep(3000); continue; }
			const j = r.j || {};
			if (j.gone) { return; }
			const raw = Array.isArray(j.raw) ? j.raw : null;
			if (!raw) { continue; }
			have = raw.filter(Boolean).length;
			let driven = Number(it.syncDriven) || 0;
			while (driven < raw.length && raw[driven]) {
				const cur = loadState().items.find((i) => i.id === itemId);
				if (!cur || cur.status !== 'pending') { return; }
				const now = Date.now();
				while (syncClicks.length && now - syncClicks[0] > COOLDOWN_MS) { syncClicks.shift(); }
				if (syncClicks.length >= 40) { log('sync 10 分鐘內點太多次，停手'); return; }
				syncClicks.push(now);
				let res = await uiaQ(cur, driven, raw[driven], driven === raw.length - 1);
				if (!res.ok && /逾時|沒有回報|切不到|沒反應/.test(res.note)) { await sleep(2500); res = await uiaQ(cur, driven, raw[driven], driven === raw.length - 1); }
				log('sync ' + qid.slice(0, 10) + ' 第' + (driven + 1) + '題 ' + (res.ok ? 'ok ' : '失敗 ') + res.note);
				const st2 = loadState(); const it2 = st2.items.find((i) => i.id === itemId);
				if (!it2) { return; }
				if (!res.ok) { it2.syncNote = '手機答了第 ' + (driven + 1) + ' 題，但電腦沒點成功：' + res.note + '（請直接在電腦框點）'; saveState(st2); return; }
				driven++; it2.syncDriven = driven; delete it2.syncNote; saveState(st2);
			}
			if (j.verb === 'answered' && driven >= raw.length) { return; }
		}
	} catch (e) { logError(e); }
	finally { syncWatchers.delete(itemId); }
}
function syncScan() {
	const st = readJson(path.join(DATA, 'pending.json'));
	for (const it of (st && Array.isArray(st.items) ? st.items : [])) {
		if (it.status === 'pending' && it.sync === true && typeof it.qid === 'string' && it.qid && !syncWatchers.has(it.id)) { syncWatchers.add(it.id); watchSync(it.id, it.qid); }
	}
}
async function runPermission(it, idx, key) { // 權限卡：手機按「允許一次／拒絕」→ 在電腦 Claude 視窗替使用者按同一個鈕
	const fail = (note) => [{ sid: key, ok: false, note }];
	const label = PERM_LABELS[idx];
	if (!label || !Number.isInteger(idx)) { return fail('沒有這個按鈕'); }
	if (Date.now() - Number(it.at) > PERM_MAX_AGE_MS) { return fail('這個請求超過 10 分鐘了，請回電腦看'); }
	const title = String(it.title || ''), local = String(it.local || '');
	if (!title || !/^local_[0-9a-f-]{36}$/.test(local)) { return fail('找不到是哪個對話，請回電腦按'); }
	if (!fs.existsSync(UIA_PS1)) { return fail('電腦缺少按鈕程式'); }
	let txt = ''; try { txt = fs.readFileSync(RESTART_LOG, 'utf8'); } catch { /* 沒紀錄 */ }
	const nowMs = Date.now(); let n = 0;
	for (const line of txt.split(/\r?\n/).slice(-300)) { const m = /(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) 授權 /.exec(line); if (m && nowMs - new Date(m[1] + 'T' + m[2]).getTime() < COOLDOWN_MS) { n++; } }
	if (n >= PERM_MAX_PER_WINDOW) { return fail('10 分鐘內已按 ' + PERM_MAX_PER_WINDOW + ' 次，先等等'); }
	const detail = String(it.detail || '').replace(/\s+/g, ' ').trim();
	const expect = label === '允許一次' ? (detail.length >= 6 ? detail.slice(0, 40) : String(it.tool || '')) : ''; // 按「允許」前，畫面上必須看得到同一段指令
	if (label === '允許一次' && !expect) { return fail('這個請求沒有可核對的內容，請回電腦按'); }
	const r = await uiaClick(title, local, [label], expect);
	const d = new Date(), p2 = (v) => String(v).padStart(2, '0');
	const stamp = d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
	try { fs.appendFileSync(RESTART_LOG, stamp + ' 授權 ' + label + ' ' + title.slice(0, 40) + ' ' + (r.ok ? '成功' : '失敗') + '（手機）\n', 'utf8'); } catch { /* 寫不了就算了 */ }
	if (!r.ok) { return fail(r.note); }
	const st = loadState(); const it2 = st.items.find((i) => i.id === it.id && i.status === 'pending');
	if (it2) { it2.status = 'answered'; it2.answer = label; saveState(st); }
	return [{ sid: key, ok: true, note: '已在電腦上按「' + label + '」' }];
}
async function runReply(c) { // 收尾提問卡／權限卡按鈕 → [{sid: 卡片編號, ok, note}]
	const key = String((c.sids && c.sids[0]) || ''), idx = Number(c.idx);
	const fail = (note) => [{ sid: key, ok: false, note }];
	if (Date.now() - Number(c.createdAt) > CMD_MAX_AGE_MS) { return fail('指令太舊，作廢'); }
	{ const st0 = loadState(); const pit = st0.items.find((i) => i.status === 'pending' && i.kind === 'permission' && cardId(i.id) === key); if (pit) { return runPermission(pit, idx, key); } }
	if (!TEST_EXE && !fs.existsSync(EXE)) { return fail('電腦找不到 claude.exe'); }
	if (usagePct() >= 98) { return fail('用量已 ≥98%，先不送（電腦端守門）'); }
	const st = loadState();
	const it = st.items.find((i) => i.status === 'pending' && i.kind === 'wrapup' && cardId(i.id) === key);
	if (!it) { return fail('這張卡已經不在等你了（可能已在電腦上回答）'); }
	const label = it.questions && it.questions[0] && it.questions[0].options && it.questions[0].options[idx];
	const sid = String(it.sid || '').toLowerCase();
	if (typeof label !== 'string' || !label || !Number.isInteger(idx)) { return fail('沒有這個按鈕'); }
	if (!SID_RE.test(sid)) { return fail('找不到對話編號'); }
	const rc = readJson(path.join(DATA, 'recent.json'));
	if (rc && Array.isArray(rc.sessions) && rc.sessions.some((x) => String(x.sid).toLowerCase() === sid && x.run)) { return fail('那個對話正在跑，先不插話'); }
	let txt = ''; try { txt = fs.readFileSync(RESTART_LOG, 'utf8'); } catch { /* 沒紀錄 */ }
	const nowMs = Date.now(); let n = 0;
	for (const line of txt.split(/\r?\n/).slice(-200)) {
		const m = /(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) 回覆 /.exec(line);
		if (m && nowMs - new Date(m[1] + 'T' + m[2]).getTime() < COOLDOWN_MS) { n++; }
	}
	if (n >= 5) { return fail('10 分鐘內已送出 5 次，先等等'); }
	const cwd = findCwd(sid, String(it.cwd || ''));
	const out = path.join(DATA, 'reply_' + sid.slice(0, 8) + '.out');
	const fo = fs.openSync(out, 'w'), fe = fs.openSync(out + '.err', 'w');
	const child = spawn(EXE, [...TEST_PRE, '-p', label, '--resume', sid, '--output-format', 'json'], { cwd, detached: true, stdio: ['ignore', fo, fe], windowsHide: true });
	child.on('error', (e) => log('spawn 失敗 ' + sid.slice(0, 8) + ' ' + e.message));
	child.unref(); fs.closeSync(fo); fs.closeSync(fe);
	const d = new Date(), p2 = (v) => String(v).padStart(2, '0');
	const stamp = d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
	fs.appendFileSync(RESTART_LOG, stamp + ' 回覆 ' + sid + ' 「' + label.slice(0, 40) + '」 @ ' + cwd + '（手機）\n', 'utf8');
	it.status = 'answered'; it.answer = label; saveState(st); // 卡片馬上從清單消失
	return [{ sid: key, ok: true, note: '已在背景送出「' + label.slice(0, 30) + '」' }];
}
const cardId = (rawId) => 'pd-' + crypto.createHash('sha1').update(String(rawId)).digest('hex').slice(0, 20);
function usageSnap() { // data/usage.json → 手機顯示用的每週／5 小時用量（只有百分比與重置時間）
	const u = readJson(path.join(DATA, 'usage.json'));
	if (!u || Date.now() - Number(u.at) > 12 * 3600000) { return null; }
	const w = (x) => (x && x.pct != null ? { pct: Number(x.pct), resetsAt: x.resets_at ? Number(x.resets_at) : null } : null);
	return { week: w(u.seven_day), five: w(u.five_hour), at: Number(u.at) || 0 };
}
// ── 4. 全部暫停／全部繼續 ─────────────────────────────
let ctlBusy = false;
const stamp = () => { const d = new Date(), p2 = (v) => String(v).padStart(2, '0'); return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds()); };
const pauseLog = (s) => { try { fs.appendFileSync(PAUSE_LOG, stamp() + ' ' + s + '\n', 'utf8'); } catch { /* 寫不了就算了 */ } };
async function runPause(src) { // → {ok, note, stopped, failed:[{title,note}], waiting:[title]}
	const wait = waitingSids();
	const all = runningNow();
	const todo = all.filter((x) => !wait.has(x.sid)), waiting = all.filter((x) => wait.has(x.sid));
	if (!todo.length) { return { ok: true, note: all.length ? '沒有要停的（' + waiting.length + ' 個在等使用者回答，本來就停著）' : '目前沒有正在跑的對話', stopped: 0, failed: [], waiting: waiting.map((x) => x.title) }; }
	const batch = todo.slice(0, CTL_MAX);
	const prev = readPaused(); const items = new Map(prev.items.filter((x) => x.ok && !x.resumed).map((x) => [x.sid, x])); // 上次停成功還沒繼續的，保留（連按兩次暫停不會丟清單）
	const failed = []; let stopped = 0;
	for (const x of batch) {
		if (!x.title || !/^local_[0-9a-f-]{36}$/.test(x.local)) { failed.push({ title: x.title || x.sid.slice(0, 8), note: '找不到是哪個對話，請自己按停止' }); pauseLog('暫停 ' + x.sid + ' 失敗 缺標題或連結（' + src + '）'); continue; }
		let r = await uiaStop(x.title, x.local);
		if (!r.ok && /逾時|沒有回報|切不到/.test(r.note)) { await sleep(2000); r = await uiaStop(x.title, x.local); }
		pauseLog('暫停 ' + x.sid + ' ' + x.title.slice(0, 40) + ' ' + (r.ok ? '成功' : '失敗') + ' ' + r.note + '（' + src + '）');
		if (r.ok) { stopped++; items.set(x.sid, { sid: x.sid, title: x.title, local: x.local, cwd: x.cwd, ok: true, resumed: false, at: Date.now() }); }
		else { failed.push({ title: x.title, note: r.note }); items.set(x.sid, { sid: x.sid, title: x.title, local: x.local, cwd: x.cwd, ok: false, note: r.note, resumed: false, at: Date.now() }); }
		await sleep(1000);
	}
	try { fs.writeFileSync(PAUSED_JSON, JSON.stringify({ at: Date.now(), items: [...items.values()] }), 'utf8'); } catch (e) { logError(e); }
	const extra = todo.length - batch.length;
	const note = '已停 ' + stopped + ' 個' + (failed.length ? '；停不了 ' + failed.length + ' 個：' + failed.map((f) => f.title).join('、') : '') + (waiting.length ? '；另 ' + waiting.length + ' 個在等回答' : '') + (extra > 0 ? '；還有 ' + extra + ' 個這次沒處理，再按一次' : '');
	return { ok: stopped > 0 || !failed.length, note: note.slice(0, 120), stopped, failed, waiting: waiting.map((x) => x.title) };
}
async function runResume(src) {
	if (!TEST_EXE && !fs.existsSync(EXE)) { return { ok: false, note: '電腦找不到 claude.exe', woke: 0 }; }
	if (usagePct() >= 98) { return { ok: false, note: '用量已 ≥98%，先不叫醒（電腦端守門）', woke: 0 }; }
	const p = readPaused();
	const todo = p.items.filter((x) => x.ok && !x.resumed && SID_RE.test(String(x.sid))).slice(0, CTL_MAX);
	if (!todo.length) { return { ok: false, note: '沒有可以繼續的（清單是空的，或已經繼續過了）', woke: 0 }; }
	const runningAt = new Map(runningNow().map((x) => [x.sid, x.at])); // recent.json 的 run 在按停止後還會亮一陣子，所以只有「停了之後又有新動靜」才算已經自己接著跑
	let woke = 0; const skipped = [];
	for (const x of todo) {
		if (runningAt.has(x.sid) && runningAt.get(x.sid) > Number(x.at) + 20000) { skipped.push(x.title + '（已自己接著跑）'); x.resumed = true; continue; }
		try { const cwd = wakeOne(x, RESUME_TEXT, '（繼續）'); x.resumed = true; woke++; pauseLog('繼續 ' + x.sid + ' ' + String(x.title).slice(0, 40) + ' @ ' + cwd + '（' + src + '）'); }
		catch (e) { skipped.push(x.title + '（啟動失敗）'); pauseLog('繼續 ' + x.sid + ' 失敗 ' + String(e && e.message).slice(0, 60)); }
		try { fs.writeFileSync(PAUSED_JSON, JSON.stringify(p), 'utf8'); } catch { /* 下一輪再寫 */ }
		await sleep(CTL_RESUME_GAP_MS); // 每個要重讀整段對話，錯開啟動
	}
	try { fs.writeFileSync(PAUSED_JSON, JSON.stringify(p), 'utf8'); } catch (e) { logError(e); }
	const note = '已叫醒 ' + woke + ' 個' + (skipped.length ? '；略過：' + skipped.join('、') : '');
	return { ok: woke > 0, note: note.slice(0, 120), woke };
}
async function runCtl(action, src) { // 手機與小工具共用；同一時間只做一件
	if (ctlBusy) { return { ok: false, note: '上一個暫停／繼續還在做，等它做完' }; }
	ctlBusy = true; lastHash = '';
	try { return action === 'pause' ? await runPause(src) : await runResume(src); }
	catch (e) { logError(e); return { ok: false, note: '失敗：' + String(e && e.message).slice(0, 80) }; }
	finally { ctlBusy = false; lastHash = ''; }
}
function ctlScan() { // 小工具把請求寫成 data\ctl-request.json {action, at}；這裡領走（刪檔）→ 執行 → 結果寫 data\ctl-result.json
	let req; try { req = JSON.parse(fs.readFileSync(CTL_REQ, 'utf8').replace(/^\uFEFF/, '')); } catch { return; }
	try { fs.unlinkSync(CTL_REQ); } catch { return; }
	if (!req || !['pause', 'resume'].includes(req.action) || !Number.isFinite(Number(req.at)) || Date.now() - Number(req.at) > CMD_MAX_AGE_MS) { return; }
	const at = Number(req.at);
	runCtl(req.action, '小工具').then((r) => { try { fs.writeFileSync(CTL_RES, JSON.stringify({ action: req.action, reqAt: at, doneAt: Date.now(), ...r }), 'utf8'); } catch (e) { logError(e); } }).catch((e) => logError(e));
}
async function runCmd(c) { // → [{sid, ok, note}]
	if (c.action === 'reply') { return runReply(c); }
	if (c.action === 'pause' || c.action === 'resume') { // 手機來的：不帶任何內容，清單全由這裡查
		if (Date.now() - Number(c.createdAt) > CMD_MAX_AGE_MS) { return [{ sid: c.action, ok: false, note: '指令太舊，作廢' }]; }
		const r = await runCtl(c.action, '手機'); log(c.action + ' ' + r.note);
		return [{ sid: c.action, ok: r.ok, note: r.note }];
	}
	const results = [];
	const sids = Array.isArray(c.sids) ? [...new Set(c.sids.map((s) => String(s).toLowerCase()))] : [];
	const reject = (note) => sids.map((sid) => ({ sid, ok: false, note }));
	if (c.action !== 'wake') { return reject('不支援的動作'); }
	if (sids.length < 1 || sids.length > MAX_PER_WINDOW || !sids.every((s) => SID_RE.test(s))) { return reject('指令格式不對'); }
	if (Date.now() - Number(c.createdAt) > CMD_MAX_AGE_MS) { return reject('指令太舊，作廢'); }
	if (!TEST_EXE && !fs.existsSync(EXE)) { return reject('電腦找不到 claude.exe'); }
	if (usagePct() >= 98) { return reject('用量已 ≥98%，先不叫醒（電腦端守門）'); }
	const broken = new Map(brokenNow().map((x) => [String(x.sid).toLowerCase(), x]));
	const woke = recentWakes();
	let slots = MAX_PER_WINDOW - woke.length;
	for (const sid of sids) {
		const x = broken.get(sid);
		if (!x) { results.push({ sid, ok: false, note: '已經不在中斷清單（可能已恢復或正在跑）' }); continue; }
		if (woke.some((w) => w.sid === sid)) { results.push({ sid, ok: false, note: '10 分鐘內叫過了' }); continue; }
		if (slots <= 0) { results.push({ sid, ok: false, note: '10 分鐘內已叫醒 3 個，先等等' }); continue; }
		try { const cwd = wakeOne(x); slots--; results.push({ sid, ok: true, note: '已在背景叫醒' }); log('叫醒 ' + sid.slice(0, 8) + ' @ ' + cwd); }
		catch (e) { results.push({ sid, ok: false, note: '啟動失敗：' + String(e && e.message).slice(0, 80) }); }
	}
	return results;
}
async function cmdLoop() {
	for (;;) {
		try {
			const r = await call('GET', 'cmd/next?timeout=25', null, 40000);
			if (!r.ok) { await sleep(r.status === 401 || r.status === 503 ? 30000 : 5000); continue; }
			for (const c of (r.j && Array.isArray(r.j.cmds) ? r.j.cmds : [])) {
				let results;
				try { results = await runCmd(c); } catch (e) { logError(e); results = []; }
				log('cmd ' + c.id + ' ' + results.map((x) => x.sid.slice(0, 8) + (x.ok ? ':ok' : ':' + x.note)).join(' '));
				await call('POST', 'cmd/done', { id: c.id, results }, 15000).catch(() => {});
				lastHash = ''; // 馬上重送快照（中斷清單可能變了）
			}
		} catch { await sleep(5000); }
	}
}
setInterval(() => { mirrorTick(); }, 5000);
setInterval(() => { try { syncScan(); ctlScan(); } catch (e) { logError(e); } }, 1500);
mirrorTick();
cmdLoop();
