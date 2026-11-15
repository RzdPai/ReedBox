// 分拣受损行：A=字符串行（必须人工回填正确文案） B=纯注释行（可直接删除） C=代码+注释（保留代码） D=可疑（需人工看）
const fs = require('fs');
const src = process.argv[2];
const lines = fs.readFileSync(src, 'utf8').split('\n');

const hasNonAscii = (s) => /[^\x00-\x7F]/.test(s);
const A = [], B = [], C = [], D = [];

lines.forEach((line, i) => {
  if (!hasNonAscii(line)) return;
  const t = line.trim();
  const quoted = /['`"]/.test(line);
  const commentOnly = /^(\/\/|\/\*|\*)/.test(t) && !/;\s*$/.test(t.replace(/\/\/.*$/, ''));
  if (quoted) { A.push([i + 1, line]); return; }
  if (commentOnly) { B.push([i + 1, line]); return; }
  if (/\/\//.test(line)) { C.push([i + 1, line]); return; }
  D.push([i + 1, line]);
});

const dump = (tag, arr) => {
  console.log(`\n===== ${tag} (${arr.length}) =====`);
  for (const [n, l] of arr) console.log(`${n}|${l}`);
};
dump('A 字符串行', A);
dump('C 代码+注释', C);
dump('D 可疑', D);
console.log(`\nB 纯注释行: ${B.length} 行（可自动删除）`);
