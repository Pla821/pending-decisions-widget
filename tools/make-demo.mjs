// make-demo.mjs — 建一個「示範用」的獨立環境（假的對話紀錄＋假的桌面版中繼檔），拍 README 截圖／試用浮窗時用，不碰你真正的 ~/.claude。
// 用法：node tools/make-demo.mjs <資料夾> [empty]
// 之後用：  $env:PDW_HOME = '<資料夾>\home'; powershell -STA -File src\bin\widget.ps1
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const out = path.resolve(process.argv[2] || 'demo');
const empty = process.argv[3] === 'empty'; // 第二個參數 empty：不放任何待決定（拍「都回完了」空狀態）
const SRC = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src');
const home = path.join(out, 'home'), claude = path.join(out, 'claude'), sess = path.join(out, 'sessions', 'demo');
for (const d of [home, path.join(claude, 'projects', 'demo'), sess]) { fs.mkdirSync(d, { recursive: true }); }
fs.cpSync(path.join(SRC, 'icons'), path.join(home, 'icons'), { recursive: true });
fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({ claudeDir: claude, sessionsDir: path.join(out, 'sessions'), toast: false }, null, 2));

const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const line = (o) => JSON.stringify(o) + '\n';
const demo = [
	{ sid: '11111111-aaaa-4aaa-8aaa-000000000001', title: '網站改版：首頁第一屏', cwd: 'C:\\work\\my-website', min: 7,
		use: { id: 'toolu_demo1', name: 'AskUserQuestion', input: { questions: [{ question: '首頁主視覺要用照片還是插畫？', options: [{ label: '照片（推薦）' }, { label: '插畫' }, { label: '兩個都做 A/B' }] }] } } },
	{ sid: '22222222-bbbb-4bbb-8bbb-000000000002', title: '週報產生器', cwd: 'C:\\work\\weekly-report', min: 25, permission: true,
		use: { id: 'toolu_demo2', name: 'Bash', input: { command: 'npm run build && rm -rf dist/old' } } },
	{ sid: '33333333-cccc-4ccc-8ccc-000000000003', title: '記帳 App：匯入銀行 CSV', cwd: 'C:\\work\\budget-app', min: 95, wrap: true,
		use: { id: 'toolu_demo3', name: 'mcp__ccd_turn__wrap_up', input: { recap: 'CSV 匯入與分類已完成，測試全過。', ask: '分類規則要先上線，還是再多測幾家銀行？', actions: [{ label: '先上線（推薦）' }, { label: '再多測' }] } } }
];
for (const d of (empty ? [] : demo)) {
	fs.writeFileSync(path.join(claude, 'projects', 'demo', d.sid + '.jsonl'),
		line({ type: 'user', timestamp: ago(d.min + 3), origin: { kind: 'human' }, cwd: d.cwd, message: { content: [{ type: 'text', text: '開始' }] } })
		+ line({ type: 'assistant', timestamp: ago(d.min), cwd: d.cwd, message: { content: [{ type: 'tool_use', ...d.use }] } }));
	const local = 'local_demo' + d.sid.slice(0, 4);
	fs.writeFileSync(path.join(sess, local + '.json'), JSON.stringify({ sessionId: local, cliSessionId: d.sid, title: d.title, isArchived: false }));
	if (d.permission) { // 權限確認要靠 hook 才知道；示範環境直接用 hook 腳本灌進去
		const hook = path.join(SRC, 'bin', 'decision-log.mjs');
		const r = { hook_event_name: 'PermissionRequest', session_id: d.sid, cwd: d.cwd, tool_name: d.use.name, tool_input: d.use.input };
		import('node:child_process').then(({ spawnSync }) => spawnSync(process.execPath, [hook], { input: JSON.stringify(r), env: { ...process.env, PDW_HOME: home, PDW_CLAUDE_DIR: claude, PDW_SESSIONS: path.join(out, 'sessions') } }));
	}
}
console.log('示範環境已建好：' + out + '\n用法：$env:PDW_HOME = \'' + home + '\'; powershell -STA -File src\\bin\\widget.ps1');
