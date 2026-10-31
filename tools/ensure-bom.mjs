// ensure-bom.mjs — Windows PowerShell 5.1 會把「沒有 BOM 的 UTF-8」當成系統碼頁（繁中是 Big5）讀，中文就亂碼、甚至整行被吃掉。
// 所以所有含中文的 .ps1 都要存成 UTF-8 with BOM。改完 .ps1 後跑一次：node tools/ensure-bom.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
let fixed = 0;
(function walk(d) {
	for (const e of fs.readdirSync(d, { withFileTypes: true })) {
		if (e.name === '.git' || e.name === 'node_modules') { continue; }
		const p = path.join(d, e.name);
		if (e.isDirectory()) { walk(p); continue; }
		if (!p.endsWith('.ps1')) { continue; }
		const b = fs.readFileSync(p);
		if (b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF) { continue; }
		fs.writeFileSync(p, Buffer.concat([Buffer.from([0xEF, 0xBB, 0xBF]), b]));
		fixed++; console.log('加上 BOM：' + path.relative(root, p));
	}
})(root);
console.log(fixed ? '完成（' + fixed + ' 個）' : '全部都已有 BOM');
