// decision-scan.mjs — 掃「所有對話」的紀錄檔，找出問了選項框（AskUserQuestion）卻還沒回答的，寫進 data/pending.json。
// 不靠 hook：每個對話的紀錄（<claudeDir>/projects/*/*.jsonl）都有「問了」和「回了」，沒配到回答的就是還在等你。
// 所以新舊對話、有沒有載入 hook 都抓得到。由浮窗每 6 秒呼叫一次；也可手動：node decision-scan.mjs
// 永遠 exit 0、不印東西；出錯寫進 data/error.log。
import fs from 'node:fs';
import path from 'node:path';
import { DATA, PROJECTS, CACHE, DAY, loadState, saveState, writeStatus, writeHtml, sessionInfo, settlePermissions, logError } from './lib.mjs';

const TAIL = 600 * 1024;         // 只讀每個檔最後 600KB
const FRESH = 3 * DAY;           // 只看 3 天內有動過的對話
const STALL = 5 * 60000;         // 安靜超過 5 分鐘、最後一筆又不是「回完了」→ 疑似中斷（斷線／當機／關掉）
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
// 「最近」清單（給浮窗的 最近執行／最近檔案／資料夾 三個分頁）：順手從同一份紀錄撈出它跑過的指令、寫過的檔案
const NOISE = /[\\/](appdata[\\/]local[\\/]temp|\.claude[\\/](projects|file-history|shell-snapshots)|node_modules|\.git)([\\/]|$)|^[\\/]tmp[\\/]/i; // 暫存、對話紀錄本身、套件資料夾不算「生成的資料」
const FILE_TOOLS = { Write: 'file_path', Edit: 'file_path', MultiEdit: 'file_path', NotebookEdit: 'notebook_path' };
function cleanPath(x) { x = String(x || '').trim().replace(/^["']|["']$/g, ''); return path.isAbsolute(x) ? path.normalize(x) : ''; }
function scanFile(p, size) { // → { pend: [{ id, at, questions, cwd, kind?, detail? }]（還在等你的）, recent: { runs, files, dirs } }
	const asked = new Map(), answered = new Set(), runs = [], files = [], dirs = [];
	const props = new Map(), resolvedTasks = new Set(); // 「建議任務」卡片：Claude 用 start_session(own_initiative) 放出來、等你按「開始」的
	let cwd = '', wrap = null, model = null, tail = null, lastText = '', firstPrompt = '';
	for (const line of readTail(p, size).split('\n')) {
		if (!line || line.slice(0, 40).indexOf('"api-request') >= 0) { continue; } // 超大的請求快照，跳過
		if (!cwd) { const m = line.match(/"cwd":("(?:[^"\\]|\\.)*")/); if (m) { try { cwd = JSON.parse(m[1]); } catch { /* 跳過 */ } } } // 這個對話的工作資料夾（不用整行解析）
		if (line.indexOf('AskUserQuestion') < 0 && line.indexOf('tool_result') < 0 && line.indexOf('wrap_up') < 0 && line.indexOf('"human"') < 0 && line.indexOf('tool_use') < 0 && line.indexOf('"model"') < 0 && line.slice(0, 400).indexOf('"type":"user"') < 0) { continue; }
		let j; try { j = JSON.parse(line); } catch { continue; }
		if (j.cwd) { cwd = j.cwd; }
		if (j.type === 'assistant' && j.message && j.message.model && j.message.model !== '<synthetic>') { model = { name: String(j.message.model), at: j.timestamp ? Date.parse(j.timestamp) : now }; } // 這個對話最近一次是哪個模型回的
					if ((j.type === 'assistant' || j.type === 'user') && !j.isSidechain && j.message && !j.isMeta) { // 紀錄的最後一筆停在哪：回完話＝正常結束；停在動手做事、工具結果、或你剛講完話＝可能是中斷
				const cc = j.message.content, lb = Array.isArray(cc) ? cc[cc.length - 1] : null, at = j.timestamp ? Date.parse(j.timestamp) : now;
				if (j.type === 'assistant') {
					const txt = Array.isArray(cc) ? cc.filter((b) => b.type === 'text').map((b) => b.text).join(' ').replace(/\s+/g, ' ').trim() : '';
					if (txt) { lastText = txt.slice(0, 160); }
					if (lb && lb.type === 'tool_use') { const i2 = lb.input || {}; tail = { k: 'tool', at, what: lb.name + '：' + String(i2.description || i2.command || i2.file_path || i2.path || i2.prompt || '').replace(/\s+/g, ' ').slice(0, 120) }; }
					else if (lb && lb.type === 'text' && /^(end_turn|stop_sequence)$/.test(String(j.message.stop_reason || ''))) { tail = { k: 'done', at, what: '' }; }
					else { tail = { k: 'cut', at, what: '回答寫到一半' }; }
				} else if (lb && lb.type === 'tool_result') { tail = { k: 'result', at, what: '工具剛跑完，還沒接著做' }; }
				else if (typeof cc === 'string' && /^<(local-command|command-name|command-message)/.test(cc)) { /* 斜線指令的回音，不算你說話 */ }
				else if (typeof cc === 'string' && cc.startsWith('<task-notification>')) { tail = { k: 'user', at, what: '背景工作通知進來了，還沒接著處理' }; }
				else { const ut = typeof cc === 'string' ? cc : (Array.isArray(cc) ? cc.filter((b) => b.type === 'text').map((b) => b.text).join(' ') : ''); tail = { k: 'user', at, what: '你說：' + ut.replace(/\s+/g, ' ').slice(0, 100) }; }
			}
			if (j.type === 'user' && j.origin && j.origin.kind === 'human') { wrap = null; } // 你本人回了話＝收尾提問卡處理掉了
		if (j.type === 'user' && j.message) {
			const fc = j.message.content, ft = typeof fc === 'string' ? fc : (Array.isArray(fc) ? fc.filter((b) => b.type === 'text').map((b) => b.text).join(' ') : '');
			if (ft.indexOf('started your proposal') >= 0) { for (const m4 of ft.matchAll(/started your proposal (task_[0-9a-f]+)/g)) { resolvedTasks.add(m4[1]); } } // 你在卡片上按了「開始」：桌面版會在放卡片的那個對話裡留一句「The user started your proposal task_…」
			if (!firstPrompt && !j.isMeta && !j.isSidechain && ft && !/^<(local-command|command-name|command-message|task-notification|system-reminder)/.test(ft)) { firstPrompt = ft.replace(/\s+/g, ' ').slice(0, 600); } // 這個對話的第一句話（備援：卡片開出來的對話，第一句就是卡片裡的任務）
		}
		const c = j.message && j.message.content;
		if (!Array.isArray(c)) { continue; }
		for (const b of c) {
			if (b.type === 'tool_use') { // 順便記下它做了什麼（只收最近的，最後再截斷）
				const at = j.timestamp ? Date.parse(j.timestamp) : now, inp = b.input || {};
				if ((b.name === 'Bash' || b.name === 'PowerShell') && inp.command) {
					const cmd = String(inp.command);
					runs.push({ at, tool: b.name, named: !!inp.description, text: String(inp.description || cmd).replace(/\s+/g, ' ').slice(0, 160), cmd: cmd.replace(/\s+/g, ' ').slice(0, 300) });
					for (const m of cmd.matchAll(/mkdir\s+(?:-p\s+|-Force\s+|-ItemType\s+Directory\s+)*("[^"]+"|'[^']+'|[^\s;|&]+)/g)) { const d = cleanPath(m[1]); if (d && !NOISE.test(d)) { dirs.push({ at, path: d }); } }
				} else if (FILE_TOOLS[b.name] && inp[FILE_TOOLS[b.name]]) {
					const fp = cleanPath(inp[FILE_TOOLS[b.name]]);
					if (fp && !NOISE.test(fp)) { files.push({ at, path: fp, tool: b.name }); dirs.push({ at, path: path.dirname(fp) }); }
				}
			}
			if (b.type === 'tool_use' && /start_session$/.test(b.name || '')) { // 建議任務卡片：own_initiative 才是「放一張卡等你點」；之後 dismiss_task 或帶 proposal_id 再叫一次＝處理掉了
				const i3 = b.input || {};
				if (i3.proposal_id) { resolvedTasks.add(String(i3.proposal_id)); }
				else if (i3.initiation === 'own_initiative' && i3.prompt) {
					const at3 = j.timestamp ? Date.parse(j.timestamp) : now, head = String(i3.prompt).replace(/\s+/g, ' ').trim();
					props.set(b.id, { id: 'prop:' + b.id, at: at3, kind: 'proposal', headKey: head.slice(0, 40), detail: head.slice(0, 300), taskId: '', questions: [{ question: '建議任務等你按「開始」：' + String(i3.title || head.slice(0, 40)), options: ['開始'] }], cwd: j.cwd || '' });
				}
			} else if (b.type === 'tool_use' && /dismiss_task$/.test(b.name || '') && b.input && b.input.task_id) { resolvedTasks.add(String(b.input.task_id)); }
			else if (b.type === 'tool_result' && b.tool_use_id && props.has(b.tool_use_id)) { // 結果文字裡有 task_id：之後 dismiss／proposal_id 靠它對上
				const rc = b.content, rt = typeof rc === 'string' ? rc : (Array.isArray(rc) ? rc.map((x) => (x && x.text) || '').join(' ') : ''), m3 = /task_id:\s*(task_[0-9a-f]+)/.exec(rt);
				if (m3) { props.get(b.tool_use_id).taskId = m3[1]; }
			}
			if (b.type === 'tool_use' && b.name === 'AskUserQuestion') {
				const qs =((b.input && b.input.questions) || []).map((q) => ({ question: q.question, options: (q.options || []).map((o) => o.label) }));
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
	for (const pr of props.values()) { if (!(pr.taskId && resolvedTasks.has(pr.taskId))) { out.push(pr); } }
	return { model, cwd, tail, lastText, firstPrompt, pend: out.map((a) => ({ ...a, cwd: a.cwd || cwd })), recent: { runs: runs.slice(-40), files: files.slice(-60), dirs: dirs.slice(-60) } };
}

// 最近清單 → data/recent.json：最近執行的指令、最近寫過的檔案、最近動過的資料夾（新的在前；檔案／資料夾只留現在還在的）
function writeRecent(runs, files, dirs, sessions) {
	const meta = new Map();
	const info = (sid) => { if (!meta.has(sid)) { const s = sessionInfo(sid); meta.set(sid, { local: s ? s.local : '', title: s ? s.title : '', archived: !!(s && s.archived) }); } return meta.get(sid); };
	const decorate = (x) => { const m = info(x.sid); return m.archived ? null : { ...x, local: m.local, title: m.title }; };
	const newest = (arr) => arr.slice().sort((a, b) => b.at - a.at);
	const uniq = (arr, max, keep) => { const seen = new Set(), out = []; for (const x of newest(arr)) { const k = x.path.toLowerCase(); if (seen.has(k)) { continue; } seen.add(k); if (!keep(x)) { continue; } const d = decorate(x); if (d) { out.push(d); } if (out.length >= max) { break; } } return out; };
	const exists = (x) => { try { return fs.existsSync(x.path); } catch { return false; } };
	// 最近的對話（session）清單＋依專案資料夾（對話的工作資料夾）歸類的專案清單
	const sess = newest(sessions).map(decorate).filter(Boolean);
	const byCwd = new Map();
	// 專案＝對話的工作資料夾；放在「專案總管<專案名>」底下的，往上收成那一層（同一個專案不會被切成很多條）
	const projOf = (c) => { const m = c.match(/^(.*[\\/]專案總管[\\/][^\\/]+)/); return m ? m[1] : c; };
	for (const s of sess) { if (!s.cwd) { continue; } const pp = projOf(s.cwd); const k = pp.toLowerCase(); const p = byCwd.get(k) || { path: pp, at: 0, count: 0, titles: [] }; p.count++; p.at = Math.max(p.at, s.at); if (s.title && p.titles.length < 3) { p.titles.push(s.title); } byCwd.set(k, p); }
	const out = {
		at: now,
		sessions: sess.slice(0, 60),
		running: sess.filter((s) => s.run).slice(0, 30),
			broken: sess.filter((s) => s.broke).slice(0, 30),
		projects: [...byCwd.values()].sort((a, b) => b.at - a.at).slice(0, 30),
		runs: newest(runs).map(decorate).filter(Boolean).slice(0, 60),
		files: uniq(files, 60, exists),
		dirs: uniq(dirs, 40, (x) => { try { return fs.statSync(x.path).isDirectory(); } catch { return false; } }),
	};
	fs.writeFileSync(path.join(DATA, 'recent.json'), JSON.stringify(out), 'utf8');
}

try {
	fs.mkdirSync(DATA, { recursive: true });
	if (!fs.existsSync(PROJECTS)) { // 找不到對話紀錄資料夾：告訴浮窗，讓它顯示原因而不是空白
		writeStatus({ ok: false, error: 'no-projects', projects: PROJECTS });
		process.exit(0);
	}
	let dismissed = {}; try { dismissed = JSON.parse(fs.readFileSync(path.join(DATA, 'dismissed.json'), 'utf8')); } catch { /* 沒有就是都沒按過 */ }
	let cache = {}; try { cache = JSON.parse(fs.readFileSync(CACHE, 'utf8')); } catch { /* 第一次 */ }
	const nextCache = {}, found = [], runsAll = [], filesAll = [], dirsAll = [], sessAll = [], firstPrompts = [];
	let files = 0;
	for (const d of fs.readdirSync(PROJECTS, { withFileTypes: true })) {
		if (!d.isDirectory()) { continue; }
		const dp = path.join(PROJECTS, d.name);
		for (const f of fs.readdirSync(dp)) {
			if (!f.endsWith('.jsonl')) { continue; }
			const p = path.join(dp, f), st = fs.statSync(p);
			if (now - st.mtimeMs > FRESH) { continue; }
			files++;
			const key = st.mtimeMs + ':' + st.size + ':v6';
			const c = cache[p];
			const r = c && c.key === key && c.recent ? c : { key, ...scanFile(p, st.size) };
			const pend = r.pend, sid = f.replace('.jsonl', '');
			nextCache[p] = { key, pend, recent: r.recent, model: r.model, cwd: r.cwd, tail: r.tail, lastText: r.lastText, firstPrompt: r.firstPrompt };
				if (r.firstPrompt) { firstPrompts.push({ sid: f.replace('.jsonl', ''), text: r.firstPrompt }); }
			for (const a of pend) { found.push({ ...a, sid }); }
			// Fable 提醒：這個對話最近 20 分鐘內是 Fable 在回（Fable 走另一個額度池）→ 放進待決定，問你要不要繼續；你按「知道了」之後 12 小時內不再提醒
			const cur = sessionInfo(sid), stillFable = !cur || !cur.model || /fable/i.test(cur.model); // 桌面版記的「現在設定的模型」已經不是 Fable＝你已經換掉了，不要再提醒
				if (r.model && stillFable && /fable/i.test(r.model.name) && now - r.model.at < 20 * 60000 && !(dismissed[sid] > now)) {
				found.push({ id: 'fable:' + sid, kind: 'fable', sid, at: r.model.at, cwd: r.cwd || '', detail: r.model.name, questions: [{ question: '這個對話正在用 Fable（' + r.model.name + '）。要繼續用嗎？不用的話請在那個對話換回平常的模型。', options: [] }] });
			}
			const lastRun = [...r.recent.runs].reverse().find((x) => x.named), lastFile = r.recent.files[r.recent.files.length - 1];
			const idle = now - st.mtimeMs, broke = !!(r.tail && r.tail.k !== 'done' && pend.length === 0 && idle >= STALL); // 最後一筆不是「回完了」、沒有在等你回答、而且安靜超過 STALL＝疑似中斷
			const run = !!(r.tail && r.tail.k !== 'done' && pend.length === 0 && idle < STALL); // 最後一筆不是「回完了」、沒在等你、而且 5 分鐘內還有動靜＝正在跑
				sessAll.push({ sid, at: st.mtimeMs, cwd: r.cwd || '', last: lastRun ? lastRun.text : (lastFile ? path.basename(lastFile.path) : ''), broke, run, fable: !!(run && r.model && stillFable && /fable/i.test(r.model.name)), doing: run ? r.tail.what : '', stopped: broke ? r.tail.what : '', said: broke ? (r.lastText || '') : '' });
			for (const x of r.recent.runs) { runsAll.push({ ...x, sid }); }
			for (const x of r.recent.files) { filesAll.push({ ...x, sid }); }
			for (const x of r.recent.dirs) { dirsAll.push({ ...x, sid }); }
		}
	}
	for (let k = found.length - 1; k >= 0; k--) { // 建議任務卡片：有別的對話的第一句話就是這張卡的任務＝已經按過「開始」；卡片放超過 7 天也會過期
		const x = found[k];
		if (x.kind !== 'proposal') { continue; }
		if (now - x.at > 7 * DAY || dismissed[x.id] > now || firstPrompts.some((fp) => fp.sid !== x.sid && x.headKey && fp.text.indexOf(x.headKey) >= 0)) { found.splice(k, 1); }
	}
	fs.writeFileSync(CACHE, JSON.stringify(nextCache), 'utf8');
	writeRecent(runsAll, filesAll, dirsAll, sessAll);

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
