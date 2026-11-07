// decision-log.mjs — Claude Code hook：記下「Claude 在等你」的事，並跳 Windows 通知。
//   1. 選項框（AskUserQuestion）：問了什麼、你答了沒（PreToolUse／PostToolUse／PostToolUseFailure）
//   2. 收尾提問卡（桌面版 wrap_up 的問題＋按鈕）：PreToolUse（有 ask 才算）；怎麼算「回了」交給掃描
//   3. 權限確認（「是否允許 Claude 執行此指令？」）：PermissionRequest，以及 Notification 的 permission_prompt 當備援
// 由 install.ps1 接進 settings.json。輸出：data/pending.json（狀態）＋ data/pending.html（一頁清單）。
// 這支永遠 exit 0，壞了也不會擋住任何對話。預設不印東西、不替你做任何允許／拒絕的決定；
// 唯一例外：config.json 設 ntfy.approve=true 或 push.approve=true（飛傳信箱）、且人不在電腦前時，才會等你在手機上按「允許／拒絕」並照你按的回答（見 askPhone／askFeichuan）；沒人回、逾時、任何錯誤都不輸出＝不放行。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import https from 'node:https';
import { HERE, DATA, HTML, CONFIG, DAY, loadState, saveState, writeHtml, sessionInfo, fallbackTitle, toolSig, toolDetail, settlePermissions, logError } from './lib.mjs';

function readStdin() {
	try { return JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return null; }
}
const HOOK_T0 = Date.now();
const pushes = []; // 還在送的手機推播；結束前要等它們（最多 4 秒）
// ── 飛傳「待決定信箱」provider（config.json 的 push.provider = "feichuan"；預設關閉）─────────────────────────────
// 電腦端 POST /pd/api/push → 手機（鎖屏推播或 /pd/ 頁）按「允許／拒絕」→ 這裡長輪詢 GET /pd/api/wait 拿到答案。
// 密碼只放 Authorization header、不寫 log；伺服器位址必須是 https（或本機 localhost／127.0.0.1，測試用），否則整個 provider 停用。
const FC = (() => {
	const p = CONFIG.push;
	if (!p || p.provider !== 'feichuan' || !p.server || typeof p.secret !== 'string' || p.secret.length < 32) { return null; }
	const server = String(p.server).replace(/\/+$/, '');
	if (!/^https:\/\//i.test(server) && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i.test(server)) { return null; }
	return { server, secret: p.secret, approve: p.approve === true, awaySeconds: (p.awaySeconds != null && Number.isFinite(Number(p.awaySeconds))) ? Math.max(0, Number(p.awaySeconds)) : 60, waitSeconds: Math.max(5, Math.min(100, Number(p.waitSeconds) || 100)), onlyWhenAway: p.onlyWhenAway !== false };
})();
let idleMemo = null;
const idleOnce = () => (idleMemo === null ? (idleMemo = idleSeconds()) : idleMemo);
const fcAway = () => !!FC && (!FC.onlyWhenAway || idleOnce() >= FC.awaySeconds);
// 用 node:http(s) 而不是 fetch：每次 Connection: close，沒有殘留連線，process.exit 時在 Windows 上不會當掉（用 fetch+process.exit 實測會 0xC0000409）。
function fcCall(method, pathAndQuery, body, timeoutMs) {
	return new Promise((resolve, reject) => {
		const u = new URL(FC.server + '/pd/api/' + pathAndQuery);
		const data = body ? Buffer.from(JSON.stringify(body)) : null;
		const req = (u.protocol === 'https:' ? https : http).request(u, {
			method, agent: false, timeout: timeoutMs || 10000,
			headers: { Authorization: 'Bearer ' + FC.secret, Connection: 'close', ...(data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {}) }
		}, (res) => {
			const chunks = [];
			res.on('data', (c) => { if (chunks.length < 64) { chunks.push(c); } });
			res.on('end', () => { let j = null; try { j = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* 沒有 JSON 內容 */ } resolve({ status: res.statusCode, ok: res.statusCode >= 200 && res.statusCode < 300, j }); });
			res.on('error', reject);
		});
		req.on('timeout', () => req.destroy(new Error('timeout')));
		req.on('error', reject);
		if (data) { req.write(data); }
		req.end();
	});
}
// 只通知（不等回覆）：預設只送標題；push.detail=true 才附內文
function fcInfo(title, body, detail) {
	const id = 'info-' + crypto.randomBytes(8).toString('hex');
	pushes.push(fcCall('POST', 'push', { id, kind: 'info', title: String(title).slice(0, 120), message: detail ? String(body || '').slice(0, 300) : '回電腦看待決定清單' }, 30000).catch((e) => logError(e)));
}
// 手機核准：推一則 permission 項目，然後分段長輪詢（每段 25 秒，免得被代理的逾時切掉），最多等 waitSeconds 秒。
// 只有拿到 verb=allow／deny 才回傳；逾時、網路錯、401／404／任何非預期回應一律回 null（電腦上照常跳視窗，絕不替你放行）。
async function askFeichuan(title, tool, detail, name) {
	const deadline = Math.min(Date.now() + FC.waitSeconds * 1000, HOOK_T0 + 118000); // 離開電腦的判斷與伺服器喚醒也佔時間；settings 的 hook timeout 是 130 秒，這裡最晚 118 秒收尾
	const id = 'perm-' + crypto.randomBytes(8).toString('hex');
	const msg = ('【' + name + '】' + (tool ? tool + '：' : '') + (detail || '')).slice(0, 400); // approve 開啟才會走到這：附上工具與指令內容
	const p = await fcCall('POST', 'push', { id, kind: 'permission', title: String(title).slice(0, 120), message: msg }, 30000).catch(() => null);
	if (!p || !p.ok) { return null; }
	let answered = false;
	try {
		while (Date.now() < deadline) {
			const secs = Math.max(1, Math.min(25, Math.ceil((deadline - Date.now()) / 1000)));
			const w = await fcCall('GET', 'wait?id=' + id + '&timeout=' + secs, null, (secs + 8) * 1000).catch(() => null);
			if (!w) { await new Promise((r) => setTimeout(r, 1500)); continue; } // 網路瞬斷：稍等再試，到期為止
			if (!w.ok) { return null; }
			if (w.j && (w.j.verb === 'allow' || w.j.verb === 'deny')) { answered = true; return w.j.verb; }
			if (w.j && w.j.gone) { return null; }
		}
		return null;
	} finally {
		if (!answered) { await fcCall('POST', 'cancel', { id }, 4000).catch(() => {}); } // 沒人回（逾時）就把手機上的卡片撤掉；有回的留著顯示「已允許／已拒絕」，10 分鐘後自己消失
	}
}
function phonePush(title, body) { // 選填：config.json 設 ntfy.topic 才會送；預設只送標題（不含對話名稱與指令細節），ntfy.detail=true 才附內文
	if (FC && fcAway()) { fcInfo(title, body, CONFIG.push.detail === true); }
	const n = CONFIG.ntfy;
	if (!n || !n.topic) { return; }
	try {
		const msg = n.detail === true ? String(body || '').slice(0, 300) : '回電腦看待決定清單';
		pushes.push(fetch((n.server || 'https://ntfy.sh').replace(/\/+$/, '') + '/', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ topic: n.topic, title, message: msg, priority: 4, tags: ['bell'] }),
			signal: AbortSignal.timeout(4000)
		}).catch((e) => logError(e)));
	} catch (e) { logError(e); }
}
function idleSeconds() { // 電腦多久沒人動滑鼠鍵盤（Windows GetLastInputInfo）；查不到回 0＝當作人在電腦前
	try {
		const code = "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class Idl{[StructLayout(LayoutKind.Sequential)]struct L{public uint cb;public uint t;}[DllImport(\"user32.dll\")]static extern bool GetLastInputInfo(ref L p);public static uint S(){L l=new L();l.cb=8;GetLastInputInfo(ref l);return ((uint)Environment.TickCount-l.t)/1000;}}'; [Idl]::S()";
		const r = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', code], { encoding: 'utf8', windowsHide: true, timeout: 8000 });
		const v = parseInt(String(r.stdout).trim(), 10);
		return Number.isFinite(v) ? v : 0;
	} catch { return 0; }
}
// 手機核准（ntfy.approve=true 才會用）：人不在電腦前時，推一則帶「允許／拒絕」按鈕的通知，等你在手機上按（最多 waitSeconds 秒）。
// 按鈕會 POST 到另一個專用的回覆主題（<topic>-r），內容 "allow <一次性碼>"／"deny <一次性碼>"；沒人按就什麼都不回，電腦上照常跳出原本的允許視窗。
async function askPhone(title, tool, detail, name) {
	const n = CONFIG.ntfy, server = (n.server || 'https://ntfy.sh').replace(/\/+$/, '');
	const wait = Math.max(5, Math.min(110, Number(n.waitSeconds) || 100));
	const nonce = crypto.randomBytes(6).toString('hex'), replyTopic = n.topic + '-r', since = Math.floor(Date.now() / 1000) - 1;
	const act = (label, verb) => ({ action: 'http', label, url: server + '/' + replyTopic, method: 'POST', body: verb + ' ' + nonce, clear: true });
	const msg = ('【' + name + '】' + (tool ? tool + '：' : '') + (detail || '')).slice(0, 400);
	await fetch(server + '/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(4000),
		body: JSON.stringify({ topic: n.topic, title, message: msg, priority: 5, tags: ['warning'], actions: [act('允許', 'allow'), act('拒絕', 'deny')] }) });
	const res = await fetch(server + '/' + replyTopic + '/json?since=' + since, { signal: AbortSignal.timeout(wait * 1000) }).catch(() => null);
	if (!res || !res.body) { return null; }
	const dec = new TextDecoder(); let buf = '';
	try {
		for await (const chunk of res.body) {
			buf += dec.decode(chunk, { stream: true });
			let k;
			while ((k = buf.indexOf('\n')) >= 0) {
				const line = buf.slice(0, k).trim(); buf = buf.slice(k + 1);
				if (!line) { continue; }
				let ev; try { ev = JSON.parse(line); } catch { continue; }
				const m = ev.event === 'message' && /^(allow|deny) ([0-9a-f]{12})$/.exec(String(ev.message || '').trim());
				if (m && m[2] === nonce) { return m[1]; }
			}
		}
	} catch { /* 逾時或斷線：當作沒人回 */ }
	return null;
}
function toast(title, body, noPhone) {
	if (!noPhone) { phonePush(title, body); }
	if (CONFIG.toast === false) { return; }
	try { // 跳 Windows 通知（停在螢幕上；點它開待決定清單網頁）。失敗不影響記錄
		spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', path.join(HERE, 'toast.ps1'), '-Title', title, '-Body', body.slice(0, 200), '-Url', 'file:///' + HTML.replace(/\\/g, '/')], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
	} catch { /* 通知失敗就算了 */ }
}
const pendingCount = (st) => st.items.filter((i) => i.status === 'pending').length;

let approveReq = null;
try {
	const inp = readStdin();
	if (!inp) { process.exit(0); }
	const ev = inp.hook_event_name;
	const isPerm = ev === 'PermissionRequest' || (ev === 'Notification' && inp.notification_type === 'permission_prompt');
	const isWrap = /wrap_up$/.test(inp.tool_name || '');
	if (isWrap && !(ev === 'PreToolUse' && inp.tool_input && inp.tool_input.ask)) { process.exit(0); } // 提問卡工具呼叫馬上就回傳，Post 事件不代表你回答了
	if (!isPerm && !isWrap && inp.tool_name !== 'AskUserQuestion') { process.exit(0); }
	fs.mkdirSync(DATA, { recursive: true });
	const st = loadState();
	const s = sessionInfo(inp.session_id) || { local: '', title: '' };
	const name = s.title || fallbackTitle(inp.session_id, inp.cwd);

	if (isPerm) {
		settlePermissions(st); // 順手清掉已經處理掉的舊權限確認
		const recent = st.items.find((i) => i.kind === 'permission' && i.status === 'pending' && i.sid === inp.session_id && Date.now() - i.at < 60000);
		const tool = inp.tool_name || '';
		if (recent) { // PermissionRequest 與 Notification 會各來一次：補上工具資訊就好，不重複通知
			if (tool && !recent.tool) { recent.tool = tool; recent.sig = toolSig(tool, inp.tool_input); recent.detail = toolDetail(tool, inp.tool_input); recent.questions = [{ question: '需要你的允許：' + tool + (recent.detail ? ' — ' + recent.detail : ''), options: [] }]; }
		} else {
			const detail = toolDetail(tool, inp.tool_input);
			st.items.push({
				id: 'perm:' + inp.session_id + ':' + Date.now(), kind: 'permission', sid: inp.session_id, local: s.local, title: s.title, cwd: inp.cwd || '', at: Date.now(), status: 'pending',
				tool, sig: tool ? toolSig(tool, inp.tool_input) : '', detail,
				questions: [{ question: '需要你的允許：' + (tool || 'Claude 的操作') + (detail ? ' — ' + detail : ''), options: [] }]
			});
			const ptitle = 'Claude 需要你的允許（共 ' + pendingCount(st) + ' 件）';
			const nt = CONFIG.ntfy;
			const viaFc = !!(FC && FC.approve && ev === 'PermissionRequest' && fcAway()); // 飛傳信箱優先於 ntfy
			const viaNtfy = !viaFc && !!(nt && nt.topic && nt.approve === true && ev === 'PermissionRequest' && (nt.onlyWhenAway === false || idleOnce() >= (Number(nt.awaySeconds) || 60)));
			const away = viaFc || viaNtfy;
			if (away) { approveReq = { title: ptitle, tool, detail, name, via: viaFc ? 'feichuan' : 'ntfy' }; }
			toast(ptitle, '【' + name + '】' + (tool ? tool + '：' : '') + (detail || (inp.message || '')), away);
		}
	} else if (isWrap) {
		const ti = inp.tool_input, id = inp.tool_use_id || ('wrap:' + inp.session_id + ':' + Date.now());
		const qs = [{ question: String(ti.ask), options: (ti.actions || []).map((x) => x.label).filter(Boolean) }];
		st.items = st.items.filter((i) => i.id !== id);
		st.items.push({ id, kind: 'wrapup', sid: inp.session_id, local: s.local, title: s.title, cwd: inp.cwd || '', at: Date.now(), status: 'pending', detail: String(ti.recap || '').slice(0, 400), questions: qs });
		toast('有問題等你決定（共 ' + pendingCount(st) + ' 件）', '【' + name + '】' + qs[0].question);
	} else {
		const id = inp.tool_use_id || (inp.session_id + ':' + JSON.stringify(inp.tool_input || {}).length);
		if (ev === 'PreToolUse') {
			const qs = ((inp.tool_input && inp.tool_input.questions) || []).map((q) => ({ question: q.question, options: (q.options || []).map((o) => o.label) }));
			st.items = st.items.filter((i) => i.id !== id);
			st.items.push({ id, sid: inp.session_id, local: s.local, title: s.title, cwd: inp.cwd || '', at: Date.now(), status: 'pending', questions: qs });
			toast('有選項框等你回答（共 ' + pendingCount(st) + ' 件）', '【' + name + '】' + ((qs[0] && qs[0].question) || ''));
		} else {
			const it = st.items.find((i) => i.id === id) || st.items.filter((i) => i.sid === inp.session_id && i.status === 'pending' && i.kind !== 'permission').pop();
			if (it) {
				it.status = ev === 'PostToolUse' ? 'answered' : 'cancelled';
				if (ev === 'PostToolUse') {
					const r = inp.tool_response;
					const a = r && r.answers ? Object.values(r.answers).join('；') : (typeof r === 'string' ? r : '');
					it.answer = String(a).slice(0, 300);
				} else { it.answer = '（沒回答／被取消）'; }
			}
		}
	}
	const now = Date.now();
	st.items = st.items.filter((i) => now - i.at < (i.status === 'pending' ? 14 * DAY : 3 * DAY));
	saveState(st);
	writeHtml(st);
	if (approveReq) { // 人不在電腦前：等手機回；按了才替 Claude 回答，沒回就不輸出（電腦上照常跳出允許視窗）
		const verb = await (approveReq.via === 'feichuan' ? askFeichuan : askPhone)(approveReq.title, approveReq.tool, approveReq.detail, approveReq.name).catch((e) => { logError(e); return null; });
		if (verb) {
			const decision = verb === 'allow' ? { behavior: 'allow' } : { behavior: 'deny', message: '你在手機上按了「拒絕」' };
			process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision } }));
		}
	}
} catch (e) { logError(e); }
await Promise.allSettled(pushes);
process.stdout.write('', () => process.exit(0)); // 等 stdout 寫完才結束，免得回覆被截斷
