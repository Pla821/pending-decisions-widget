// usage-feed.mjs — 當作 Claude Code 的「狀態列指令」（statusLine）：Claude 每次更新狀態列會把一包 JSON 從 stdin 餵進來，
// 如果裡面有 rate_limits（5 小時／每週用量，Pro／Max 才有），就存成 data/usage.json 給浮窗做「額度 90%／98%」警示。
// 同時印出一行簡短的狀態列（「5h 24% · 7d 89%」）。永遠 exit 0；拿不到數字就什麼都不印、不寫檔。
import fs from 'node:fs';
import path from 'node:path';
import { DATA } from './lib.mjs';

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
	try {
		const j = JSON.parse(raw || '{}');
		const rl = j.rate_limits || {};
		const win = (w) => (w && typeof w.used_percentage === 'number') ? { pct: Math.round(w.used_percentage * 10) / 10, resets_at: w.resets_at || w.reset_at || null } : null;
		const five = win(rl.five_hour), week = win(rl.seven_day);
		if (five || week) {
			fs.mkdirSync(DATA, { recursive: true });
			fs.writeFileSync(path.join(DATA, 'usage.json'), JSON.stringify({ at: Date.now(), source: 'statusline', five_hour: five, seven_day: week }), 'utf8');
			process.stdout.write([five ? '5h ' + Math.round(five.pct) + '%' : '', week ? '7d ' + Math.round(week.pct) + '%' : ''].filter(Boolean).join(' · '));
		}
	} catch { /* 不能害 Claude 的狀態列壞掉 */ }
	process.exit(0);
});
