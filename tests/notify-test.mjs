// 測試 config.json 的 notify 開關：預設全開；關掉的種類，hook 不記錄、掃描不列入。
// 另外測「建議任務卡片」的已處理判斷（紀錄裡 dismiss_task／桌面版對話檔的 spawnedFrom.taskId）。
// 執行：node tests/notify-test.mjs   （用假紀錄＋暫存資料夾，不碰你真正的 ~/.claude；config 設 toast:false，不會真的跳通知）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const BIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src', 'bin');
const ts = (s) => new Date(Date.now() - s * 1000).toISOString();
const line = (o) => JSON.stringify(o) + '\n';

// 做一個獨立環境：notify 為 config.json 的 notify 欄位（undefined＝完全不寫這個欄位）
function makeEnv(notify) {
	const T = fs.mkdtempSync(path.join(os.tmpdir(), 'pdw-notify-'));
	const home = path.join(T, 'home'), sessions = path.join(T, 'sessions'), proj = path.join(T, 'claude', 'projects', 'demo');
	fs.mkdirSync(home, { recursive: true }); fs.mkdirSync(sessions, { recursive: true }); fs.mkdirSync(proj, { recursive: true });
	fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify(notify === undefined ? { toast: false } : { toast: false, notify }));
	const env = { ...process.env, PDW_HOME: home, PDW_CLAUDE_DIR: path.join(T, 'claude'), PDW_SESSIONS: sessions, LOCALAPPDATA: path.join(T, 'nolocal') };
	const run = (file, input) => spawnSync(process.execPath, [path.join(BIN, file)], { env, input: input ? JSON.stringify(input) : undefined, encoding: 'utf8' });
	const items = () => { try { return JSON.parse(fs.readFileSync(path.join(home, 'data', 'pending.json'), 'utf8')).items.filter((i) => i.status === 'pending'); } catch { return []; } };
	return { T, sessions, proj, run, items };
}

// 假對話：每種各一個
function seed(e) {
	const f = (sid) => path.join(e.proj, sid + '.jsonl');
	const SID = { ask: 'a1111111-0000-0000-0000-000000000001', wrap: 'b2222222-0000-0000-0000-000000000002', perm: 'c3333333-0000-0000-0000-000000000003', prop: 'd4444444-0000-0000-0000-000000000004', fable: 'e5555555-0000-0000-0000-000000000005', propDone: 'f6666666-0000-0000-0000-000000000006', propSpawned: 'a7777777-0000-0000-0000-000000000007' };
	fs.writeFileSync(f(SID.ask), line({ type: 'assistant', timestamp: ts(300), cwd: 'C:\\demo\\ask', message: { content: [{ type: 'tool_use', id: 'q1', name: 'AskUserQuestion', input: { questions: [{ question: '要公開還是私有？', options: [{ label: '公開' }, { label: '私有' }] }] } }] } }));
	fs.writeFileSync(f(SID.wrap), line({ type: 'assistant', timestamp: ts(200), cwd: 'C:\\demo\\wrap', message: { content: [{ type: 'tool_use', id: 'w1', name: 'mcp__ccd_turn__wrap_up', input: { recap: '做完了。', ask: '要不要上線？', actions: [{ label: '上線' }] } }] } }));
	fs.writeFileSync(f(SID.perm), line({ type: 'assistant', timestamp: ts(100), cwd: 'C:\\demo\\perm', message: { content: [{ type: 'tool_use', id: 'b1', name: 'Bash', input: { command: 'rm -rf build' } }] } }));
	// 建議任務卡片：start_session(own_initiative)，結果文字帶 task_id；還沒人處理
	fs.writeFileSync(f(SID.prop), line({ type: 'assistant', timestamp: ts(90), cwd: 'C:\\demo\\prop', message: { content: [{ type: 'tool_use', id: 'p1', name: 'mcp__ccd_session__start_session', input: { initiation: 'own_initiative', title: '整理舊檔', prompt: '把舊的紀錄檔整理到封存資料夾' } }] } })
		+ line({ type: 'user', timestamp: ts(89), cwd: 'C:\\demo\\prop', message: { content: [{ type: 'tool_result', tool_use_id: 'p1', content: [{ type: 'text', text: 'Proposed. task_id: task_aaa111' }] }] } }));
	// 同樣是卡片，但後來被 dismiss_task 撤回：不該列
	fs.writeFileSync(f(SID.propDone), line({ type: 'assistant', timestamp: ts(90), cwd: 'C:\\demo\\done', message: { content: [{ type: 'tool_use', id: 'p2', name: 'mcp__ccd_session__start_session', input: { initiation: 'own_initiative', title: '撤回的卡', prompt: '這張卡後來撤回了' } }] } })
		+ line({ type: 'user', timestamp: ts(89), cwd: 'C:\\demo\\done', message: { content: [{ type: 'tool_result', tool_use_id: 'p2', content: 'task_id: task_bbb222' }] } })
		+ line({ type: 'assistant', timestamp: ts(80), cwd: 'C:\\demo\\done', message: { content: [{ type: 'tool_use', id: 'p2d', name: 'mcp__ccd_session__dismiss_task', input: { task_id: 'task_bbb222' } }] } }));
	// 同樣是卡片，但桌面版對話檔記了「這張卡已經被開成新對話」(spawnedFrom.taskId)：不該列
	fs.writeFileSync(f(SID.propSpawned), line({ type: 'assistant', timestamp: ts(90), cwd: 'C:\\demo\\spawned', message: { content: [{ type: 'tool_use', id: 'p3', name: 'mcp__ccd_session__start_session', input: { initiation: 'own_initiative', title: '已開始的卡', prompt: '這張卡使用者按了開始' } }] } })
		+ line({ type: 'user', timestamp: ts(89), cwd: 'C:\\demo\\spawned', message: { content: [{ type: 'tool_result', tool_use_id: 'p3', content: 'task_id: task_ccc333' }] } }));
	fs.writeFileSync(path.join(e.sessions, 'local_spawned.json'), JSON.stringify({ sessionId: 'local_spawned', cliSessionId: 'zzzzzzzz-0000-0000-0000-000000000009', title: '新開的對話', spawnedFrom: JSON.stringify({ taskId: 'task_ccc333' }) }));
	// Fable：最近一則回覆是 Fable 模型回的
	fs.writeFileSync(f(SID.fable), line({ type: 'assistant', timestamp: ts(60), cwd: 'C:\\demo\\fable', message: { model: 'claude-fable-5-1', stop_reason: 'end_turn', content: [{ type: 'text', text: '好了。' }] } }));
	const hookPerm = () => e.run('decision-log.mjs', { hook_event_name: 'PermissionRequest', session_id: SID.perm, cwd: 'C:\\demo\\perm', tool_name: 'Bash', tool_input: { command: 'rm -rf build' } });
	const hookAsk = () => e.run('decision-log.mjs', { hook_event_name: 'PreToolUse', session_id: SID.ask, cwd: 'C:\\demo\\ask', tool_name: 'AskUserQuestion', tool_use_id: 'q1', tool_input: { questions: [{ question: '要公開還是私有？', options: [{ label: '公開' }] }] } });
	const hookWrap = () => e.run('decision-log.mjs', { hook_event_name: 'PreToolUse', session_id: SID.wrap, cwd: 'C:\\demo\\wrap', tool_name: 'mcp__ccd_turn__wrap_up', tool_use_id: 'w1', tool_input: { ask: '要不要上線？', recap: '做完了。', actions: [{ label: '上線' }] } });
	return { SID, hookPerm, hookAsk, hookWrap };
}
const kindOf = (i) => i.kind || 'question';

// A) 沒寫 notify（舊設定檔）＝全開：五種都要出現，已處理的兩張卡不該出現
{
	const e = makeEnv(undefined), s = seed(e);
	s.hookPerm(); s.hookAsk(); s.hookWrap();
	e.run('decision-scan.mjs');
	const got = e.items().map(kindOf).sort();
	assert.deepEqual(got, ['fable', 'permission', 'proposal', 'question', 'wrapup'], '預設要全開，且被 dismiss_task／spawnedFrom 處理掉的卡不該列：' + got);
	assert.equal(e.items().find((i) => i.kind === 'proposal').sid, s.SID.prop);
	fs.rmSync(e.T, { recursive: true, force: true });
}

// B) 全部關掉：hook 不記錄、掃描不列入
{
	const e = makeEnv({ permission: false, question: false, wrapup: false, proposal: false, fable: false, usage: false });
	const s = seed(e);
	s.hookPerm(); s.hookAsk(); s.hookWrap();
	assert.equal(fs.existsSync(path.join(e.T, 'home', 'data', 'pending.json')), false, 'hook 該直接結束，連狀態檔都不用寫');
	e.run('decision-scan.mjs');
	assert.deepEqual(e.items(), [], '全部關掉就一件都不該列：' + JSON.stringify(e.items().map(kindOf)));
	fs.rmSync(e.T, { recursive: true, force: true });
}

// C) 只關其中一種：其他照舊（逐一檢查五個開關各自只影響自己）
for (const kind of ['permission', 'question', 'wrapup', 'proposal', 'fable']) {
	const e = makeEnv({ [kind]: false }), s = seed(e);
	s.hookPerm(); s.hookAsk(); s.hookWrap();
	e.run('decision-scan.mjs');
	const got = e.items().map(kindOf).sort();
	const want = ['fable', 'permission', 'proposal', 'question', 'wrapup'].filter((k) => k !== kind);
	assert.deepEqual(got, want, '只關 ' + kind + ' 時：' + got);
	fs.rmSync(e.T, { recursive: true, force: true });
}

// D) 非 false 的值（true、字串、null）都當作開，不能因為設定寫怪就把通知弄不見
{
	const e = makeEnv({ permission: true, question: 'no', wrapup: null, proposal: 0, fable: 'false' }), s = seed(e);
	s.hookPerm(); s.hookAsk(); s.hookWrap();
	e.run('decision-scan.mjs');
	assert.equal(e.items().length, 5, '只有布林 false 才算關');
	fs.rmSync(e.T, { recursive: true, force: true });
}

console.log('notify-test: 全部通過');
