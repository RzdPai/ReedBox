// 把 SettingsTab 里 "FormRow + openPick 半模态" 的行，机械转换成 "SelectRow + 系统 Select"。
// 只在一次迁移中使用；跑完保留作审计（grep SELECTROW_MIGRATION）。
const fs = require('node:fs');
const path = require('node:path');

const file = path.resolve(__dirname, '..', 'entry', 'src', 'main', 'ets', 'ui', 'neko', 'SettingsTab.ets');
let text = fs.readFileSync(file, 'utf8');

function matchClose(src, openIndex, openChar, closeChar) {
  let depth = 0;
  for (let i = openIndex; i < src.length; i++) {
    const ch = src[i];
    if (ch === openChar) {
      depth++;
    } else if (ch === closeChar) {
      depth--;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

function splitTopLevel(args, sep) {
  const out = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < args.length; i++) {
    const ch = args[i];
    if (ch === '(' || ch === '[' || ch === '{') {
      depth++;
    } else if (ch === ')' || ch === ']' || ch === '}') {
      depth--;
    } else if (ch === sep && depth === 0) {
      out.push(args.slice(start, i));
      start = i + 1;
    }
  }
  out.push(args.slice(start));
  return out;
}

let converted = 0;
let index = text.indexOf('FormRow({');
while (index >= 0) {
  const openBrace = text.indexOf('{', index);
  const closeBrace = matchClose(text, openBrace, '{', '}');
  if (closeBrace < 0) {
    break;
  }
  const block = text.slice(index, closeBrace + 1);
  if (block.indexOf('this.openPick(') < 0) {
    index = text.indexOf('FormRow({', closeBrace);
    continue;
  }
  // 取 label: '...'
  const labelMatch = /label:\s*(['"])([\s\S]*?)\1/.exec(block);
  if (labelMatch === null) {
    index = text.indexOf('FormRow({', closeBrace);
    continue;
  }
  const label = labelMatch[2];
  // 取 openPick 的实参
  const callStart = block.indexOf('this.openPick(') + 'this.openPick('.length;
  const callEnd = matchClose(block, callStart - 1, '(', ')');
  const argsText = block.slice(callStart, callEnd);
  const args = splitTopLevel(argsText, ',').map(s => s.trim());
  if (args.length < 5) {
    index = text.indexOf('FormRow({', closeBrace);
    continue;
  }
  const labels = args[1];
  const values = args[2];
  const current = args[3];
  const callbackText = args.slice(4).join(',');
  // 回调是 (value: string) => { ... }，取花括号里的内容
  const cbOpen = callbackText.indexOf('{', callbackText.indexOf('=>'));
  const cbClose = matchClose(callbackText, cbOpen, '{', '}');
  const body = callbackText.slice(cbOpen + 1, cbClose).replace(/^\s*\n/, '').replace(/\s*$/, '');
  if (cbOpen < 0 || cbClose < 0) {
    index = text.indexOf('FormRow({', closeBrace);
    continue;
  }
  const replacement = [
    'SelectRow({',
    `                label: '${label}',`,
    `                labels: ${labels},`,
    `                values: ${values},`,
    `                current: ${current},`,
    '                lightLevel: this.s.lightLevel,',
    '                onPick: (value: string) => {',
    body,
    '                }',
    '              })'
  ].join('\n');
  text = text.slice(0, index) + replacement + text.slice(closeBrace + 1);
  converted++;
  index = text.indexOf('FormRow({', index + replacement.length);
}
fs.writeFileSync(file, text, 'utf8');
console.log(`SELECTROW_MIGRATION converted=${converted}`);
