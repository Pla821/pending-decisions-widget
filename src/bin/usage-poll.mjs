// usage-poll.mjs — 浮窗每 5 分鐘叫一次：用「終端機版 claude 登入後留在本機的登入檔」向 Anthropic 查每週用量，寫成 data/usage.json（source: oauth）。
// 只讀 %USERPROFILE%\.claude\.credentials.json 裡的 access token，只送去 api.anthropic.com，不印出、不存別處。
// 用的是非公開網址（社群工具都這樣用），哪天改了就查不到：這時不寫檔、永遠 exit 0，浮窗會退回顯示 ~ 的約略值。
// 沒登入終端機版 claude（`claude auth login`）就什麼都不做。不會呼叫任何模型，不花額度。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { DATA } from './lib.mjs';

const CRED = path.join(process.env.CLAUDE_DIR || path.join(os.homedir(), '.claude'), '.credentials.json');
const readToken = () => { const o = JSON.parse(fs.readFileSync(CRED, 'utf8')).claudeAiOauth || {}; return o.accessToken ? o : null; };

async function main() {
	let o = readToken();
	if (!o) return;
	if (o.expiresAt && o.expiresAt < Date.now() + 60000) { // 快過期：叫 claude 自己刷新一次（它用到就會換新 token），再讀
		try { execFileSync(process.platform === 'win32' ? 'claude.cmd' : 'claude', ['auth', 'status'], { stdio: 'ignore', timeout: 20000, shell: process.platform === 'win32' }); } catch { /* 刷新不了就用舊的試試 */ }
		o = readToken() || o;
	}
	const r = await fetch('https://api.anthropic.com/api/oauth/usage', { headers: { Authorization: 'Bearer ' + o.accessToken, 'anthropic-beta': 'oauth-2025-04-20' }, signal: AbortSignal.timeout(15000) });
	if (!r.ok) return;
	const j = await r.json();
	const lim = Array.isArray(j.limits) ? j.limits.find((l) => l.kind === 'weekly_all') : null; // 新格式；舊格式在 seven_day
	const pct = lim ? lim.percent : (j.seven_day ? j.seven_day.utilization : null);
	const resets = lim ? lim.resets_at : (j.seven_day ? j.seven_day.resets_at : null);
	if (typeof pct !== 'number') return;
	const five = j.five_hour && typeof j.five_hour.utilization === 'number' ? { pct: j.five_hour.utilization, resets_at: j.five_hour.resets_at ? Date.parse(j.five_hour.resets_at) / 1000 : null } : null;
	fs.mkdirSync(DATA, { recursive: true });
	fs.writeFileSync(path.join(DATA, 'usage.json'), JSON.stringify({ at: Date.now(), source: 'oauth', five_hour: five, seven_day: { pct, resets_at: resets ? Date.parse(resets) / 1000 : null } }), 'utf8');
}
try { await main(); } catch { /* 查不到就算了 */ }
process.exitCode = 0; // 不用 process.exit()：Windows 上 fetch 還沒收尾時會噴 libuv 斷言訊息
