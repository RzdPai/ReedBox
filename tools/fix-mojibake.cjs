// 修复 ProfilesPage.ets 的中文乱码：
// 起因：PowerShell 5.1 的 Get-Content 默认按 GBK 解码 UTF-8 文件，整行重写后中文被双重转码。
// 做法：拿 hvigor 缓存里**上一版未损坏**的转译产物（*.ts，注释与中文都保留）当字典，
//       按"去掉非 ASCII 后的骨架"逐行匹配，把正确的中文行替换回去。
// 用法：node tools/fix-mojibake.cjs <broken.ets> <reference.ts>
const fs = require('fs');

const brokenPath = process.argv[2];
const refPath = process.argv[3];
if (!brokenPath || !refPath) {
  console.error('usage: node tools/fix-mojibake.cjs <broken.ets> <reference.ts>');
  process.exit(2);
}

const broken = fs.readFileSync(brokenPath, 'utf8').split('\n');
const ref = fs.readFileSync(refPath, 'utf8').split('\n');

// 乱码特征：GBK 解码 UTF-8 后常见的那批字（宁宽勿漏）
const MOJI = /[\u951F\u9351\u5A11\u95BA\u7F01\u95C2\u9225\u6D26\u93BF\u93C8\u93B4\u93C9\u9354\u9525\u95C3\u6D94]/;

const skeleton = (s) => s
  .replace(/[^\x00-\x7F]/g, '')   // 去掉所有非 ASCII（中文/全角标点）
  .replace(/[ \t]+/g, ' ')
  .trim();

// 建字典：骨架 -> 该骨架下出现过的中文内容（必须唯一）
const map = new Map();
for (const line of ref) {
  if (!/[^\x00-\x7F]/.test(line)) continue;
  const key = skeleton(line);
  if (key.length < 8) continue;              // 骨架太短容易误配
  if (!map.has(key)) map.set(key, new Set());
  map.get(key).add(line);
}

let fixed = 0;
const unresolved = [];
const out = broken.map((line, idx) => {
  if (!MOJI.test(line)) return line;
  const key = skeleton(line);
  const cands = map.get(key);
  if (cands && cands.size === 1) {
    const good = [...cands][0];
    if (good !== line) fixed++;
    return good;
  }
  unresolved.push({ line: idx + 1, text: line });
  return line;
});

fs.writeFileSync(brokenPath, out.join('\n'), 'utf8');
console.log(`restored lines: ${fixed}`);
console.log(`unresolved: ${unresolved.length}`);
for (const u of unresolved) console.log(`  L${u.line}: ${u.text.trim()}`);
