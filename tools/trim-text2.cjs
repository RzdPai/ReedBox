// 第二轮文案精简：分组新建面板 + 节点编辑（链式代理）等（甲方：还有一堆多余说明）。
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');

const jobs = [
  {
    file: 'entry/src/main/ets/ui/neko/GroupsPage.ets',
    pairs: [
      ["placeholder: this.typeIndex === 1 ? '订阅名称（建议填机场名）' : '分组名称'", "placeholder: this.typeIndex === 1 ? '订阅名称' : '分组名称'"],
      ["TextInput({ text: this.url, placeholder: '订阅地址 https://…' })", "TextInput({ text: this.url, placeholder: 'https://…' })"],
      ["summary: '按间隔自动拉取',", "summary: '',"],
      ["summary: '把域名解析成 IP',", "summary: '',"],
      ["summary: '按 类型+服务器+端口+UUID 去重',", "summary: '',"],
      ["summary: '未连接时跳过',", "summary: '',"],
      ["summary: '操作时轻微振动',", "summary: '',"],
      ["Text('订阅只取节点，分组/规则由本应用决定')", "Text('')"],
      ["Text('只用来归类节点')", "Text('')"],
      ["Text('用节点卡的 ⋯ → 移动到分组 加进来')", "Text('')"],
      ["summary: '按间隔自动拉取',", "summary: '',"],
      ["TextInput({ text: this.optUa, placeholder: '留空用默认 UA 链' })", "TextInput({ text: this.optUa, placeholder: '默认 UA' })"]
    ]
  },
  {
    file: 'entry/src/main/ets/ui/neko/ProfileEditPage.ets',
    pairs: [
      ["placeholder: '给这个节点起个名字'", "placeholder: '名称'"],
      ["placeholder: '与出站对象浅合并（…", "placeholder: '浅合并 JSON'"],
      ["Text('数据依次经过第 1 跳 → 最后一跳 → 目标（每跳都是「配置项」里已有的普通节点）。同一节点不能在一条链里出现两次；删掉被引用的节点，这条链会失效。')", "Text('按顺序串起已有节点')"],
      ["Text('手填只覆盖常用字段；导入订阅时会用完整解析器（13 种协议）把字段填满，改完记得保存。')", "Text('改完记得保存')"]
    ]
  },
  {
    file: 'entry/src/main/ets/ui/neko/SettingsTab.ets',
    pairs: [
      ["summary: '把流量累加到节点记录',", "summary: '',"],
      ["summary: '启动时自动连接',", "summary: '',"],
      ["summary: '启用 IPv6',", "summary: '',"],
      ["summary: '国内走直连 DNS',", "summary: '',"],
      ["summary: '私网地址直连',", "summary: '',"],
      ["summary: '先解析目标域名再匹配规则',", "summary: '',"],
      ["summary: '假 IP 加速首包',", "summary: '',"],
      ["summary: '出站绑定物理网卡',", "summary: '',"],
      ["summary: '改端口需重连生效',", "summary: '',"],
      ["summary: '网络切换后自动重连',", "summary: '',"],
      ["summary: '回前台时自动重连',", "summary: '',"],
      ["summary: '放行自签证书',", "summary: '',"],
      ["summary: '拉订阅时忽略证书错误',", "summary: '',"],
      ["summary: '开关与切换节点时的轻微振动',", "summary: '',"],
      ["summary: '节点卡显示 server:port',", "summary: '',"]
    ]
  }
];

let changed = 0;
for (const job of jobs) {
  const file = path.join(root, job.file);
  let text = fs.readFileSync(file, 'utf8');
  for (const [from, to] of job.pairs) {
    if (text.includes(from)) {
      text = text.split(from).join(to);
      changed++;
    }
  }
  fs.writeFileSync(file, text, 'utf8');
}
console.log(`TEXT_TRIM2 replacements=${changed}`);
