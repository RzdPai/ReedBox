// 生成"乱码行 -> 正确行"的修复补丁（不直接改文件，先出报告人工核对）。
// 思路：对每条含非 ASCII 的行，取它的最长 ASCII 片段去参考文件里找候选行；
//       候选唯一（或候选的非 ASCII 段数量一致）时，把参考行的文本段按位置搬过来。
// 用法：node tools/make-text-patch.cjs <broken.ets> <reference.ts> [--apply]
const fs = require('fs');

const [brokenPath, refPath, flag] = process.argv.slice(2);
const apply = flag === '--apply';
if (!brokenPath || !refPath) {
  console.error('usage: node tools/make-text-patch.cjs <broken.ets> <reference.ts> [--apply]');
  process.exit(2);
}

const splitRuns = (line) => {
  const runs = [];
  let buf = '';
  let inText = false;
  const flush = () => { if (buf) runs.push(buf); buf = ''; };
  for (const ch of line) {
    const t = ch.charCodeAt(0) > 127;
    if (t !== inText) { flush(); inText = t; }
    buf += ch;
  }
  flush();
  return runs;
};
const textRuns = (line) => splitRuns(line).filter((r) => r.charCodeAt(0) > 127);
const asciiFrag = (line) => Math.max(0, ...splitRuns(line).filter((r) => r.charCodeAt(0) <= 127).map((r) => r.length));

const broken = fs.readFileSync(brokenPath, 'utf8').split('\n');
const ref = fs.readFileSync(refPath, 'utf8').split('\n');

// 参考行的 ASCII 片段索引（取每行最长的 ASCII 片段做键，便于反查）
const refIndex = new Map();
ref.forEach((line, idx) => {
  if (!/[^\x00-\x7F]/.test(line)) return;
  for (const frag of splitRuns(line).filter((r) => r.charCodeAt(0) <= 127)) {
    if (frag.length < 8) continue;
    if (!refIndex.has(frag)) refIndex.set(frag, new Set());
    refIndex.get(frag).add(idx);
  }
});

const report = [];
let patched = 0;
const out = broken.map((line, idx) => {
  if (!/[^\x00-\x7F]/.test(line)) return line;
  const runs = splitRuns(line);
  const frags = runs.filter((r) => r.charCodeAt(0) <= 127).sort((a, b) => b.length - a.length);
  let best = -1;
  for (const frag of frags) {
    if (frag.length < 8) break;
    const cands = refIndex.get(frag);
    if (!cands) continue;
    const filtered = [...cands].filter((ci) => textRuns(ref[ci]).length === textRuns(line).length);
    if (filtered.length === 1) { best = filtered[0]; break; }
  }
  if (best < 0) {
    report.push({ line: idx + 1, status: 'MANUAL', now: line.trim(), cand: '' });
    return line;
  }
  // 逐个文本段替换
  const goodRuns = textRuns(ref[best]);
  let k = 0;
  let rebuilt = '';
  for (const run of runs) {
    if (run.charCodeAt(0) > 127) {
      rebuilt += goodRuns[k++] ?? run;
    } else {
      rebuilt += run;
    }
  }
  patched++;
  report.push({ line: idx + 1, status: 'OK', now: line.trim(), cand: rebuilt.trim() });
  return rebuilt;
});

if (apply) fs.writeFileSync(brokenPath, out.join('\n'), 'utf8');

console.log(`auto: ${patched}  manual: ${report.filter((r) => r.status === 'MANUAL').length}  apply=${apply}`);
for (const r of report.filter((x) => x.status === 'MANUAL')) console.log(`  MANUAL L${r.line}: ${r.now}`);
