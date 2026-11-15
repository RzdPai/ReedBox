// 按"ASCII 骨架对齐"把损坏文件里的非 ASCII 段替换成参考文件里的正确文本。
// 适用：两个文件同一源、且只有中文（非 ASCII）被转码破坏，ASCII 代码基本一致。
// 用法：node tools/realign-text.cjs <broken.ets> <reference.ts>
const fs = require('fs');

const [brokenPath, refPath] = process.argv.slice(2);
if (!brokenPath || !refPath) {
  console.error('usage: node tools/realign-text.cjs <broken.ets> <reference.ts>');
  process.exit(2);
}

// 切成 [ {ascii}/{text} ] 段：非 ASCII 连续段算一段文本，其余算 ASCII 段
function segments(text) {
  const out = [];
  let buf = '';
  let isText = false;
  for (const ch of text) {
    const cur = ch.charCodeAt(0) > 127;
    if (cur !== isText && buf.length > 0) {
      out.push(isText ? { text: buf } : { ascii: buf });
      buf = '';
    }
    isText = cur;
    buf += ch;
  }
  if (buf.length > 0) out.push(isText ? { text: buf } : { ascii: buf });
  return out;
}

const A = segments(fs.readFileSync(brokenPath, 'utf8'));
const B = segments(fs.readFileSync(refPath, 'utf8'));

let i = 0;
let j = 0;
let replaced = 0;
let skippedA = 0;

while (i < A.length && j < B.length) {
  const a = A[i];
  const b = B[j];
  if (a.ascii !== undefined && b.ascii !== undefined) {
    if (a.ascii === b.ascii) {
      i++;
      j++;
      continue;
    }
    // ASCII 不一致：在有限窗口内找重新同步点（我这轮新增/删除的少数几行）
    let resync = false;
    for (let look = 1; look <= 40 && !resync; look++) {
      const bi = j + look;
      if (bi >= B.length || B[bi].ascii === undefined) continue;
      if (A[i].ascii === B[bi].ascii) { j = bi; resync = true; }
    }
    if (!resync) {
      for (let look = 1; look <= 40 && !resync; look++) {
        const ai = i + look;
        if (ai >= A.length || A[ai].ascii === undefined) continue;
        if (A[ai].ascii === B[j].ascii) { i = ai; skippedA++; resync = true; }
      }
    }
    if (!resync) { i++; j++; }
    continue;
  }
  if (a.text !== undefined && b.text !== undefined) {
    if (a.text !== b.text) {
      A[i] = { text: b.text };   // 用参考文本覆盖
      replaced++;
    }
    i++;
    j++;
    continue;
  }
  // 一边是文本、一边是 ASCII：错位，跳过较短的一侧
  if (a.text !== undefined) { i++; skippedA++; } else { j++; }
}

fs.writeFileSync(brokenPath, A.map((s) => (s.text !== undefined ? s.text : s.ascii)).join(''), 'utf8');
console.log(`replaced text runs: ${replaced}`);
console.log(`skipped broken-side segments: ${skippedA}`);
