// 冒煙測試：用假的對話紀錄＋暫存資料夾，檢查三種「Claude 在等你」都抓得到、回了之後會消失。
// 執行：node tests/scan-test.mjs   （不碰你真正的 ~/.claude）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const BIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src', 'bin');
const T = fs.mkdtempSync(path.join(os.tmpdir(), 'pdw-test-'));
const env = { ...process.env, PDW_HOME: path.join(T, 'home'), PDW_CLAUDE_DIR: path.join(T, 'claude'), PDW_SESSIONS: path.join(T, 'none'), LOCALAPPDATA: path.join(T, 'nolocal') };
const proj = path.join(T, 'claude', 'projects', 'demo');
fs.mkdirSync(proj, { recursive: true });
const run = (file, input) => spawnSync(process.execPath, [path.join(BIN, file)], { env, input: input ? JSON.stringify(input) : undefined, encoding: 'utf8' });
const items = () => JSON.parse(fs.readFileSync(path.join(T, 'home', 'data', 'pending.json'), 'utf8')).items;
const ts = (s) => new Date(Date.now() - s * 1000).toISOString();
const line = (o) => JSON.stringify(o) + '\n';

// 1) 選項框：問了、沒有 tool_result
const A = 'aaaaaaaa-0000-0000-0000-000000000001', fa = path.join(proj, A + '.jsonl');
fs.writeFileSync(fa, line({ type: 'assistant', timestamp: ts(300), cwd: 'C:\\demo\\app', message: { content: [{ type: 'tool_use', id: 'q1', name: 'AskUserQuestion', input: { questions: [{ question: '要公開還是私有？', options: [{ label: '公開' }, { label: '私有' }] }] } }] } }));
// 2) 收尾提問卡：wrap_up 有 ask，之後沒有人說話
const B = 'bbbbbbbb-0000-0000-0000-000000000002', fb = path.join(proj, B + '.jsonl');
fs.writeFileSync(fb, line({ type: 'assistant', timestamp: ts(200), cwd: 'C:\\demo\\site', message: { content: [{ type: 'tool_use', id: 'w1', name: 'mcp__ccd_turn__wrap_up', input: { recap: '做完了。', ask: '要不要上線？', actions: [{ label: '上線' }, { label: '再等等' }] } }] } })
	+ line({ type: 'user', timestamp: ts(199), message: { content: [{ type: 'tool_result', tool_use_id: 'w1', content: 'shown' }] } }));
// 3) 權限確認：hook 收到 PermissionRequest，紀錄裡那個 Bash 還沒有結果
const C = 'cccccccc-0000-0000-0000-000000000003', fc = path.join(proj, C + '.jsonl');
fs.writeFileSync(fc, line({ type: 'assistant', timestamp: ts(100), cwd: 'C:\\demo\\tool', message: { content: [{ type: 'tool_use', id: 'b1', name: 'Bash', input: { command: 'rm -rf build' } }] } }));
run('decision-log.mjs', { hook_event_name: 'PermissionRequest', session_id: C, cwd: 'C:\\demo\\tool', tool_name: 'Bash', tool_input: { command: 'rm -rf build' } });
run('decision-log.mjs', { hook_event_name: 'Notification', notification_type: 'permission_prompt', session_id: C }); // 備援通知不該重複建立

run('decision-scan.mjs');
let it = items().filter((i) => i.status === 'pending');
assert.equal(it.length, 3, '三種都要抓到：' + JSON.stringify(it.map((i) => i.kind || 'ask')));
assert.equal(it.find((i) => i.sid === A).questions[0].options.join(), '公開,私有');
assert.equal(it.find((i) => i.sid === B).kind, 'wrapup');
assert.equal(it.find((i) => i.sid === B).questions[0].question, '要不要上線？');
assert.equal(it.find((i) => i.sid === C).kind, 'permission');
assert.equal(it.find((i) => i.sid === C).detail, 'rm -rf build');

// 回答：選項框得到 tool_result、提問卡出現本人訊息、權限確認得到 tool_result
fs.appendFileSync(fa, line({ type: 'user', timestamp: ts(10), message: { content: [{ type: 'tool_result', tool_use_id: 'q1', content: 'ok' }] } }));
fs.appendFileSync(fb, line({ type: 'user', timestamp: ts(9), origin: { kind: 'human' }, message: { content: [{ type: 'text', text: '上線' }] } }));
fs.appendFileSync(fc, line({ type: 'user', timestamp: ts(8), message: { content: [{ type: 'tool_result', tool_use_id: 'b1', content: 'done' }] } }));
run('decision-scan.mjs');
it = items().filter((i) => i.status === 'pending');
assert.equal(it.length, 0, '都回答了就不該還在清單：' + JSON.stringify(it));

// 空狀態與網頁清單
const html = fs.readFileSync(path.join(T, 'home', 'data', 'pending.html'), 'utf8');
assert.ok(html.includes('目前沒有等你回答的選項框'));
// 沒有對話紀錄資料夾：要回報原因而不是壞掉
fs.rmSync(path.join(T, 'claude'), { recursive: true });
run('decision-scan.mjs');
assert.equal(JSON.parse(fs.readFileSync(path.join(T, 'home', 'data', 'status.json'), 'utf8')).error, 'no-projects');

fs.rmSync(T, { recursive: true, force: true });
console.log('scan-test: 全部通過');
