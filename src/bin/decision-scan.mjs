// decision-scan.mjs — 掃「所有對話」的紀錄檔，找出問了選項框（AskUserQuestion）卻還沒回答的，寫進 data/pending.json。
// 不靠 hook：每個對話的紀錄（<claudeDir>/projects/*/*.jsonl）都有「問了」和「回了」，沒配到回答的就是還在等你。
// 所以新舊對話、有沒有載入 hook 都抓得到。由浮窗每 6 秒呼叫一次；也可手動：node decision-scan.mjs
// 永遠 exit 0、不印東西；出錯寫進 data/error.log。
import fs from 'node:fs';
import path from 'node:path';
import { DATA, PROJECTS, CACHE, DAY, loadState, saveState, writeStatus, writeHtml, sessionInfo, settlePermissions, logError } from './lib.mjs';

const TAIL = 600 * 1024;         // 只讀每個檔最後 600KB
const FRESH = 3 * DAY;           // 只看 3 天內有動過的對話
const now = Date.now();

function readTail(p, size) {
	const fd = fs.openSync(p, 'r');
	try {
		const n = Math.min(size, TAIL), buf = Buffer.alloc(n);
		fs.readSync(fd, buf, 0, n, size - n);
		let s = buf.toString('utf8');
		if (size > n) { s = s.slice(s.indexOf('\n') + 1); } // 第一行可能被切斷
		return s;
	} finally { fs.closeSync(fd); }
}
const WRAP = /wrap_up$/; // Claude 桌面版「收尾提問卡」（問題＋按鈕）：工具名結尾是 wrap_up，input 裡有 ask
function scanFile(p, size) { // → [{ id, at, questions, cwd, kind?, detail? }]（還在等你的）
	const asked = new Map(), answered = new Set();
	let cwd = '', wrap = null;
	for (const line of readTail(p, size).split('\n')) {
		if (!line || line.slice(0, 40).indexOf('"api-request') >= 0) { continue; } // 超大的請求快照，跳過
		if (line.indexOf('AskUserQuestion') < 0 && line.indexOf('tool_result') < 0 && line.indexOf('wrap_up') < 0 && line.indexOf('"human"') < 0 && line.indexOf('tool_use') < 0) { continue; }
		let j; try { j = JSON.parse(line); } catch { continue; }
		if (j.cwd) { cwd = j.cwd; }
		if (j.type === 'user' && j.origin && j.origin.kind === 'human') { wrap = null; } // 你本人回了話＝收尾提問卡處理掉了
		const c = j.message && j.message.content;
		if (!Array.isArray(c)) { continue; }
		for (const b of c) {
			if (b.type === 'tool_use' && b.name === 'AskUserQuestion') {
				const qs = ((b.input && b.input.questions) || []).map((q) => ({ question: q.question, options: (q.options || []).map((o) => o.label) }));
				asked.set(b.id, { id: b.id, at: j.timestamp ? Date.parse(j.timestamp) : now, questions: qs, cwd: j.cwd || '' });
			} else if (b.type === 'tool_use' && WRAP.test(b.name || '')) {
				const inp = b.input || {};
				wrap = inp.ask ? { id: b.id, at: j.timestamp ? Date.parse(j.timestamp) : now, kind: 'wrapup', detail: String(inp.recap || '').slice(0, 400), questions: [{ question: String(inp.ask), options: (inp.actions || []).map((x) => x.label).filter(Boolean) }], cwd: j.cwd || '' } : null;
			} else if (b.type === 'tool_use') { wrap = null; } // 提問卡之後它還在動手做事＝沒有停在等你
			else if (b.type === 'tool_result' && b.tool_use_id) { answered.add(b.tool_use_id); }
		}
	}
	const out = [...asked.values()].filter((a) => !answered.has(a.id));
	if (wrap) { out.push(wrap); }
	return out.map((a) => ({ ...a, cwd: a.cwd || cwd }));
}

try {
	fs.mkdirSync(DATA, { recursive: true });
	if (!fs.existsSync(PROJECTS)) { // 找不到對話紀錄資料夾：告訴浮窗，讓它顯示原因而不是空白
		writeStatus({ ok: false, error: 'no-projects', projects: PROJECTS });
		process.exit(0);
	}
	let cache = {}; try { cache = JSON.parse(fs.readFileSync(CACHE, 'utf8')); } catch { /* 第一次 */ }
	const nextCache = {}, found = [];
	let files = 0;
	for (const d of fs.readdirSync(PROJECTS, { withFileTypes: true })) {
		if (!d.isDirectory()) { continue; }
		const dp = path.join(PROJECTS, d.name);
		for (const f of fs.readdirSync(dp)) {
			if (!f.endsWith('.jsonl')) { continue; }
			const p = path.join(dp, f), st = fs.statSync(p);
			if (now - st.mtimeMs > FRESH) { continue; }
			files++;
			const key = st.mtimeMs + ':' + st.size;
			const c = cache[p];
			const pend = c && c.key === key ? c.pend : scanFile(p, st.size);
			nextCache[p] = { key, pend };
			for (const a of pend) { found.push({ ...a, sid: f.replace('.jsonl', '') }); }
		}
	}
	fs.writeFileSync(CACHE, JSON.stringify(nextCache), 'utf8');

	const st = loadState();
	const seen = new Set(found.map((x) => x.id));
	// hook 記的待決定：剛問出來（<90 秒）先留著；之後以掃描為準，掃描說沒了就是答了
	st.items.forEach((i) => { if (i.kind !== 'permission' && i.status === 'pending' && !seen.has(i.id) && now - i.at >= 90000) { i.status = 'answered'; } });
	settlePermissions(st); // 「是否允許…」的權限確認：紀錄裡有結果了就是處理掉了
	for (const f of found) {
		let it = st.items.find((i) => i.id === f.id);
		if (!it) {
			const s = sessionInfo(f.sid);
			if (s && s.archived) { continue; }
			it = { id: f.id, sid: f.sid, local: s ? s.local : '', title: s ? s.title : '', cwd: f.cwd, at: f.at, status: 'pending', questions: f.questions };
			if (f.kind) { it.kind = f.kind; it.detail = f.detail; }
			st.items.push(it);
		} else {
			if (it.status !== 'pending') { it.status = 'pending'; }
			if (!it.cwd && f.cwd) { it.cwd = f.cwd; }
		}
	}
	st.items = st.items.filter((i) => now - i.at < (i.status === 'pending' ? 14 * DAY : 3 * DAY));
	saveState(st);
	writeHtml(st);
	writeStatus({ ok: true, files, pending: st.items.filter((i) => i.status === 'pending').length });
} catch (e) { logError(e); }
process.exit(0);
