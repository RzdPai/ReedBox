// SettingsTab 收尾（按行处理，兼容 CRLF）：删掉「选项面板」那套，只留「文本输入面板」。
const fs = require('node:fs');
const path = require('node:path');
const file = path.resolve(__dirname, '..', 'entry', 'src', 'main', 'ets', 'ui', 'neko', 'SettingsTab.ets');
const raw = fs.readFileSync(file, 'utf8');
const eol = raw.includes('\r\n') ? '\r\n' : '\n';
let lines = raw.split(/\r?\n/);

function findLine(pred, from = 0) {
  for (let i = from; i < lines.length; i++) {
    if (pred(lines[i])) {
      return i;
    }
  }
  return -1;
}

function dropMethod(signatureFragment) {
  const start = findLine(l => l.includes(signatureFragment));
  if (start < 0) {
    return false;
  }
  let end = -1;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i] === '  }') {
      end = i;
      break;
    }
  }
  if (end < 0) {
    return false;
  }
  // 往上吃掉 @Builder 与紧邻的空行
  let from = start;
  if (lines[start - 1] !== undefined && lines[start - 1].trim() === '@Builder') {
    from = start - 1;
  }
  lines.splice(from, end - from + 1);
  return true;
}

// 1) pickSheet 只留文本面板
const sheetIdx = findLine(l => l.includes('private pickSheet() {'));
if (sheetIdx >= 0) {
  let end = -1;
  for (let i = sheetIdx + 1; i < lines.length; i++) {
    if (lines[i] === '  }') {
      end = i;
      break;
    }
  }
  lines.splice(sheetIdx, end - sheetIdx + 1, '  private pickSheet() {', '    this.textPanel()', '  }');
}

// 2) 删三个方法
dropMethod('private openPick(title: string');
dropMethod('private pickStrategy(title: string');
dropMethod('private pickParam(): PickSheetParam');

// 3) 删残留状态行
const dropPatterns = [
  /@Local pickOpen: boolean = false;/,
  /@Local sheetKind: string = 'pick';/,
  /@Local pickTitle: string = '';/,
  /@Local pickCurrent: string = '';/,
  /@Local pickOptions: Array<PickOption> = \[\];/,
  /@Local sheetKind: string = '';/,
  /private pickAction: \(value: string\) => void = \(value: string\): void => \{/,
  /^\s*PickOption,$/,
  /^\s*PickSheetParam,$/,
  /^\s*PickSheetPanel,$/,
  /this\.sheetKind = 'text';/
];
lines = lines.filter((l, i) => {
  if (dropPatterns.some(p => p.test(l))) {
    return false;
  }
  // pickAction 的空实现体：`  };` 前面是 pickAction 声明行时一起删
  return true;
});
// pickAction 的 `  };` 收尾（剩下孤立的）——只删紧跟在删除标记后的空实现
lines = lines.filter((l, i) => !(l.trim() === '};' && lines[i - 1] !== undefined && lines[i - 1].trim() === ''));

fs.writeFileSync(file, lines.join(eol), 'utf8');
console.log('SETTINGS_PICK_CLEANUP2 done');
