// 清理删注释后留下的空 /** */ 对与孤立 */（否则会编译报错）。
// 规则：逐行扫描，维护"是否在块注释内"；孤立的 */ 直接丢弃；空的 /** ... */ 对整体丢弃。
const fs = require('fs');
const target = process.argv[2];
const raw = fs.readFileSync(target, 'utf8');
const lines = raw.split(/\r?\n/);

const out = [];
let inBlock = false;
let droppedOrphan = 0;
let droppedEmpty = 0;

for (let i = 0; i < lines.length; i++) {
  const t = lines[i].trim();
  if (!inBlock) {
    // 空块注释对：/** 紧跟 */
    if (t === '/**' && (lines[i + 1] || '').trim() === '*/') {
      droppedEmpty++;
      i++; // 跳过下一行
      continue;
    }
    if (t === '*/') { droppedOrphan++; continue; }   // 孤立收尾
    if (t.startsWith('/**') && !t.includes('*/')) inBlock = true;
    out.push(lines[i]);
    continue;
  }
  // 在块注释里
  if (t.includes('*/')) {
    inBlock = false;
    // 只剩收尾符的整行，且上一行也是空注释体 ⇒ 保留（正常收尾）
    out.push(lines[i]);
    continue;
  }
  out.push(lines[i]);
}

fs.writeFileSync(target, out.join('\r\n'), 'utf8');
console.log(`dropped empty pairs: ${droppedEmpty}  orphan closers: ${droppedOrphan}  lines: ${lines.length} -> ${out.length}`);
