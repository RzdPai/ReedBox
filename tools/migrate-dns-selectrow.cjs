// 把 SettingsTab 里三段 "DNS 策略" 的 FormRow+pickStrategy 换成 SelectRow（按行号替换，替换前校验锚点）。
const fs = require('node:fs');
const path = require('node:path');
const file = path.resolve(__dirname, '..', 'entry', 'src', 'main', 'ets', 'ui', 'neko', 'SettingsTab.ets');
const lines = fs.readFileSync(file, 'utf8').split('\n');

const labels = "['auto（内核默认）', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only']";
const values = "['', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only']";

function block(label, field) {
  return [
    '              SelectRow({',
    `                label: '${label}',`,
    `                labels: ${labels},`,
    `                values: ${values},`,
    `                current: this.s.${field},`,
    '                lightLevel: this.s.lightLevel,',
    '                onPick: (value: string) => {',
    '                  this.app.patchSettings((s) => {',
    `                    s.${field} = value;`,
    '                  }).then(() => {',
    "                    this.toast('已保存，重新连接后生效');",
    '                  });',
    '                }',
    '              })'
  ];
}

// 从后往前替换，避免行号位移；每段 14 行（FormRow({ … })）
const jobs = [
  { label: '服务器 DNS 策略', field: 'serverDnsStrategy', startHint: 'FormRow({' },
  { label: '直连 DNS 策略', field: 'directDnsStrategy', startHint: 'FormRow({' },
  { label: '远程 DNS 策略', field: 'remoteDnsStrategy', startHint: 'FormRow({' }
];

let replaced = 0;
for (const job of jobs) {
  const idx = lines.findIndex(l => l.includes(`label: '${job.label}'`));
  if (idx < 0) {
    continue;
  }
  // 往上找 FormRow({
  let start = -1;
  for (let i = idx; i >= 0 && i > idx - 6; i--) {
    if (lines[i].trim() === 'FormRow({') {
      start = i;
      break;
    }
  }
  if (start < 0) {
    continue;
  }
  // 往下找闭合的 }) （该块内只有一个 })
  let end = -1;
  for (let i = idx; i < lines.length && i < idx + 20; i++) {
    if (lines[i].trim() === '})') {
      end = i;
      break;
    }
  }
  if (end < 0) {
    continue;
  }
  lines.splice(start, end - start + 1, ...block(job.label, job.field));
  replaced++;
}
fs.writeFileSync(file, lines.join('\n'), 'utf8');
console.log(`DNS_SELECTROW replaced=${replaced}`);
