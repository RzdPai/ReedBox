// 精简界面上的长文案（甲方：文字太长、很多说明是多余的）。逐一精确替换，不做正则。
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');

const jobs = [
  {
    file: 'entry/src/main/ets/ui/neko/SettingsTab.ets',
    pairs: [
      ["this.sectionCard('常规', '对齐原版 global_preferences.xml 的「常规」分组')", "this.sectionCard('常规', '')"],
      ["this.sectionCard('杂项', '测速 / Clash API / 连接重置')", "this.sectionCard('杂项', '')"],
      ["this.sectionCard('外观', '深浅色 / 光感强度 / 节点排序')", "this.sectionCard('外观', '')"],
      ["this.sectionCard('路由数据', 'cn 直连分流依赖这两个库')", "this.sectionCard('路由数据', '')"],
      ["this.sectionCard('其他', '日志 / 备份 / 关于')", "this.sectionCard('其他', '')"],
      ["summary: '启动时自动连接上次使用的节点',", "summary: '启动时自动连接',"],
      ["summary: '把本次会话流量累加到节点记录（节点卡第二行显示 ↑↓）',", "summary: '把流量累加到节点记录',"],
      ["summary: '为 TUN 与出站启用 IPv6（部分机场不支持）',", "summary: '启用 IPv6',"],
      ["summary: '国内域名走直连 DNS，其余走远程 DNS',", "summary: '国内走直连 DNS',"],
      ["summary: '私网地址直连，不走代理（route_opt_bypass_lan）',", "summary: '私网地址直连',"],
      ["summary: '把连接的目标域名先解析出来再匹配规则（resolveDestination）',", "summary: '先解析目标域名再匹配规则',"],
      ["summary: '用假 IP 加速首包（部分机场/应用不兼容）',", "summary: '假 IP 加速首包',"],
      ["summary: '把出站绑定物理网卡，避免\"节点套当前节点\"把延迟测高',", "summary: '出站绑定物理网卡',"],
      ["summary: '连接统计面板（yacd）依赖它；改端口要重连生效',", "summary: '改端口需重连生效',"],
      ["summary: 'Wi-Fi 与移动数据切换后自动重连（与其它 VPN 应用共存时建议关）',", "summary: '网络切换后自动重连',"],
      ["summary: '应用回到前台时自动重连（对齐 wakeResetConnections）',", "summary: '回前台时自动重连',"],
      ["summary: '调试自签证书节点时使用（globalAllowInsecure）',", "summary: '放行自签证书',"],
      ["summary: '拉订阅时忽略证书错误（对齐 allowInsecureOnRequest）',", "summary: '拉订阅时忽略证书错误',"],
      ["summary: '开关与切换节点时的轻微振动',", "summary: '操作时轻微振动',"],
      ["summary: '节点卡第二行改为 server:port',", "summary: '节点卡显示 server:port',"],
      ["Text('多个包名用逗号或换行分隔；包名可在系统「应用信息」里看到')", "Text('多个包名用逗号或换行分隔')"],
      ["placeholder: '实时查看内核与应用日志',", "placeholder: '',"],
      ["placeholder: '节点 / 分组 / 订阅 / 规则 / 设置',", "placeholder: '',"],
      ["placeholder: '粘贴备份 JSON',", "placeholder: '',"],
      ["placeholder: '复制为分享链接列表',", "placeholder: '',"],
      ["placeholder: '版本 / 内核 / 开源协议',", "placeholder: '',"]
    ]
  },
  {
    file: 'entry/src/main/ets/ui/neko/GroupsPage.ets',
    pairs: [
      ["Text('订阅里的 proxy-groups / rules 会被忽略：本应用用自己的路由体系。')", "Text('订阅只取节点，分组/规则由本应用决定')"],
      ["Text('基础分组只有名字；节点用「配置项」里的 ⋯ → 移动到分组 加进来。')", "Text('只用来归类节点')"],
      ["Text('基础分组只用来归类：节点通过节点卡片 ⋯ →「移动到分组」放进来。')", "Text('用节点卡的 ⋯ → 移动到分组 加进来')"],
      ["summary: '按下面的间隔自动拉取（App 启动/回前台时检查）',", "summary: '按间隔自动拉取',"],
      ["summary: '更新时把服务器域名解析成 IP（原域名保留为 SNI）',", "summary: '把域名解析成 IP',"],
      ["summary: '按 类型+服务器+端口+UUID 跳过重复节点（默认关闭，保留全部节点）',", "summary: '按 类型+服务器+端口+UUID 去重',"],
      ["summary: '按 类型+服务器+端口+UUID 跳过重复节点',", "summary: '按 类型+服务器+端口+UUID 去重',"],
      ["summary: '未连接 VPN 时跳过自动更新，省流量',", "summary: '未连接时跳过',"],
      ["new MenuItemData('改为基础分组（停止订阅更新）'", "new MenuItemData('改为基础分组'"],
      ["label: this.busy ? '处理中…' : (this.typeIndex === 1 ? '订阅并拉取' : '创建'),", "label: this.busy ? '处理中…' : (this.typeIndex === 1 ? '订阅并拉取' : '创建'),"]
    ]
  },
  {
    file: 'entry/src/main/ets/ui/neko/AboutPage.ets',
    pairs: [
      ["Text('sing-box 内核 · 单进程 c-shared，TUN 直交内核')", "Text('sing-box · 单进程 c-shared')"],
      ["this.itemRow('版本', '当前安装的应用版本', this.version.length > 0 ? this.version : '0.5.x', () => {", "this.itemRow('版本', '', this.version.length > 0 ? this.version : '0.5.x', () => {"],
      ["this.itemRow('sing-box 内核', '随 HAP 分发的冻结产物 libsingbox.so', KERNEL_VERSION, () => {", "this.itemRow('sing-box', '', KERNEL_VERSION, () => {"],
      ["this.toast('内核以 .so 形式随包分发，版本由构建时的产物决定');", "this.toast('内核随 HAP 分发');"],
      ["this.itemRow('许可协议', '内核 sing-box 与界面层均为 GPL-3.0', 'GPL-3.0', () => {", "this.itemRow('许可协议', '', 'GPL-3.0', () => {"],
      ["this.toast('侧栏抽屉 + 自绘页头（HdsNavigation.hideTitleBar）');", "this.toast('侧栏抽屉 + 自绘页头');"],
      ["this.itemRow('路由说明', '订阅里的 proxy-groups / rules 一律忽略', '', () => {", "this.itemRow('路由说明', '', '', () => {"],
      ["this.toast('订阅只贡献节点；路由由分流页决定（对齐 NekoBoxForAndroid）');", "this.toast('订阅只贡献节点，路由由分流页决定');"],
      ["Text('本应用为个人改造版：界面与业务层由本仓维护，内核与协议解析沿用上游实现。')", "Text('个人改造版 · 内核与协议解析沿用上游')"],
      ["this.toast('SS / VMess / VLESS / Trojan / Hysteria2 / TUIC / WireGuard / SOCKS / HTTP / SSH / '\n        + 'ShadowTLS / AnyTLS / Snell');", "this.toast('VMess / VLESS / SS / Trojan / Hysteria2 / TUIC / WG / AnyTLS …');"]
    ]
  },
  {
    file: 'entry/src/main/ets/ui/neko/ProfilesPage.ets',
    pairs: [
      ["Text('支持订阅地址（http…）、节点链接（vmess:// vless:// ss:// trojan:// …）、'", "Text('支持订阅地址与节点链接（vmess:// vless:// ss:// …）、'"],
      ["TextArea({ text: this.importText, placeholder: '粘贴到这里，或点下面的「读取剪贴板」' })", "TextArea({ text: this.importText, placeholder: '粘贴链接或订阅地址' })"],
      ["? (this.groupCount === 0 ? '点右上角 ＋ 导入节点，会自动建一个「未命名」分组'", "? (this.groupCount === 0 ? '点右上角 ＋ 导入节点'"],
      ["                  : '点右上角 ＋ 导入，节点会落进当前分组'))", "                  : '点右上角 ＋ 导入'))"]
    ]
  },
  {
    file: 'entry/src/main/ets/pages/Bootstrap.ets',
    pairs: [
      ["Text('sing-box 内核 · 仅在 arm64 真机可运行')", "Text('sing-box · arm64')"]
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
console.log(`TEXT_TRIM replacements=${changed}`);
