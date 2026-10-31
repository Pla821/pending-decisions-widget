// decision-log.mjs — Claude Code hook：記下「Claude 在等你」的事，並跳 Windows 通知。
//   1. 選項框（AskUserQuestion）：問了什麼、你答了沒（PreToolUse／PostToolUse／PostToolUseFailure）
//   2. 收尾提問卡（桌面版 wrap_up 的問題＋按鈕）：PreToolUse（有 ask 才算）；怎麼算「回了」交給掃描
//   3. 權限確認（「是否允許 Claude 執行此指令？」）：PermissionRequest，以及 Notification 的 permission_prompt 當備援
// 由 install.ps1 接進 settings.json。輸出：data/pending.json（狀態）＋ data/pending.html（一頁清單）。
// 這支永遠 exit 0、不印東西（所以不會替你做任何允許／拒絕的決定），壞了也不會擋住任何對話。
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { HERE, DATA, HTML, CONFIG, DAY, loadState, saveState, writeHtml, sessionInfo, fallbackTitle, toolSig, toolDetail, settlePermissions, logError } from './lib.mjs';

function readStdin() {
	try { return JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return null; }
}
function toast(title, body) {
	if (CONFIG.toast === false) { return; }
	try { // 跳 Windows 通知（停在螢幕上；點它開待決定清單網頁）。失敗不影響記錄
		spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', path.join(HERE, 'toast.ps1'), '-Title', title, '-Body', body.slice(0, 200), '-Url', 'file:///' + HTML.replace(/\\/g, '/')], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
	} catch { /* 通知失敗就算了 */ }
}
const pendingCount = (st) => st.items.filter((i) => i.status === 'pending').length;

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
			toast('Claude 需要你的允許（共 ' + pendingCount(st) + ' 件）', '【' + name + '】' + (tool ? tool + '：' : '') + (detail || (inp.message || '')));
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
} catch (e) { logError(e); }
process.exit(0);
