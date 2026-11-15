// 修复 ProfilesPage.ets 的乱码中文（PowerShell 5.1 按 GBK 读 UTF-8 导致的双重转码，不可逆）。
// 做法：字符串行按"上一版未损坏的转译产物"（ProfilesPage.ts）里的原文逐行回填，
//       每条替换都带 ASCII 校验片段，片段不匹配就中止（防止行号错位改坏代码）；
//       其余由纯注释组成的乱码行直接删除（注释丢失，代码不受影响）。
// 用法：node tools/repair-profiles-page.cjs <target.ets>
const fs = require('fs');

const target = process.argv[2];
if (!target) {
  console.error('usage: node tools/repair-profiles-page.cjs <target.ets>');
  process.exit(2);
}
const lines = fs.readFileSync(target, 'utf8').split(/\r?\n/);
const original = lines.slice();

// [行号(1-based), 必须包含的 ASCII 片段, 正确整行内容]
const REPLACE = [
  [56, "nodeName: string =", "  nodeName: string = '未选择节点';"],
  [58, "text: string =", "  text: string = '未连接';"],
  [59, "hint: string =", "  hint: string = '点击右下开关连接';"],
  [300, "next.text =", "        next.text = '正在断开…';"],
  [302, "next.text =", "        next.text = '正在切换节点…';"],
  [304, "next.text =", "        next.text = '正在建立 VPN…';"],
  [306, "next.text =", "        next.text = '正在载入配置…';"],
  [308, "next.text =", "        next.text = '正在保存选择…';"],
  [323, "next.nodeName =", "    next.nodeName = current === undefined ? '未选择节点' : current.name;"],
  [324, "next.hint =", "    next.hint = next.busy ? next.text : (next.running ? `${next.text} · 点击可断开` : '点击右下开关连接');"],
  [421, "this.toast(", "      this.toast(`切换失败：${(e as Error).message}`);"],
  [430, "this.toast(", "      this.toast('先导入或新建一个节点');"],
  [439, "this.toast(", "      this.toast(`操作失败：${(e as Error).message}`);"],
  [446, "confirmDestructive(", "    confirmDestructive(this.getUIContext(), '删除节点',"],
  [447, "profile.name", "      `「${profile.name.length > 0 ? profile.name : profile.server}」将从列表里移除。`, '删除', (): void => {"],
  [449, "this.toast(", "          this.toast(`已删除 ${profile.name}`);"],
  [451, "this.toast(", "          this.toast(`删除失败：${e.message}`);"],
  [472, "MenuItemData(", "      new MenuItemData('扫描二维码', false, $r('sys.symbol.scope')),"],
  [473, "MenuItemData(", "      new MenuItemData('从剪贴板导入', false, $r('sys.symbol.doc_plaintext')),"],
  [474, "MenuItemData(", "      new MenuItemData('从文件导入', false, $r('sys.symbol.doc_text')),"],
  [475, "MenuItemData(", "      new MenuItemData('手动设置 ▸', false, $r('sys.symbol.square_and_pencil'))"],
  [485, "this.toast(", "          this.toast(text.trim().length > 0 ? '已读取剪贴板' : '剪贴板为空');"],
  [487, "this.toast(", "          this.toast(`读取剪贴板失败：${e.message}`);"],
  [504, "MenuItemData(", "    items.push(new MenuItemData('自定义配置', false, $r('sys.symbol.doc_text')));"],
  [506, "MenuItemData(", "    items.push(new MenuItemData('链式代理', false, $r('sys.symbol.link')));"],
  [527, "MenuItemData(", "      new MenuItemData('更新当前订阅', false, $r('sys.symbol.arrow_clockwise')),"],
  [528, "MenuItemData(", "      new MenuItemData('清除流量统计', false, $r('sys.symbol.trash')),"],
  [529, "MenuItemData(", "      new MenuItemData('移除重复节点', false, $r('sys.symbol.doc_plaintext')),"],
  [530, "MenuItemData(", "      new MenuItemData('TCPing 测试', false, $r('sys.symbol.bolt')),"],
  [532, "MenuItemData(", "      new MenuItemData('清除测试结果', false, $r('sys.symbol.xmark')),"],
  [533, "MenuItemData(", "      new MenuItemData('删除不可用节点', false, $r('sys.symbol.trash')),"],
  [534, "MenuItemData(", "      new MenuItemData('排序 ▸', false, $r('sys.symbol.list_bullet'))"],
  [542, "this.toast(", "          this.toast(`更新失败：${e.message}`);"],
  [546, "this.toast(", "          this.toast(n > 0 ? `已清除 ${n} 个节点的流量统计` : '没有需要清除的流量统计');"],
  [550, "this.toast(", "          this.toast(n > 0 ? `已移除 ${n} 个重复节点` : '没有发现重复节点');"],
  [558, "this.toast(", "          this.toast(n > 0 ? `已清除 ${n} 个测试结果` : '没有测试结果');"],
  [562, "this.toast(", "          this.toast(n > 0 ? `已删除 ${n} 个不可用节点` : '没有不可用节点');"],
  [574, "MenuItemData(", "      new MenuItemData('原始顺序', current === 'manual', undefined),"],
  [575, "MenuItemData(", "      new MenuItemData('按名称', current === 'name', undefined),"],
  [576, "MenuItemData(", "      new MenuItemData('按延迟', current === 'latency', undefined)"],
  [584, "this.toast(", "        this.toast(`已切换为${items[index].label}`);"],
  [599, "this.toast(", "      this.toast('没有可测速的节点');"],
  [606, "this.toast(", "        this.toast('TCPing 完成');"],
  [608, "this.toast(", "        this.toast(`测速失败：${e.message}`);"],
  [616, "this.toast(", "      this.toast('没有可测速的节点');"],
  [623, "this.toast(", "        this.toast('URL Test 完成');"],
  [625, "this.toast(", "        this.toast(`测速失败：${e.message}`);"],
  [645, "this.toast(", "      this.toast(`扫码未完成：${(e as Error).message}`);"],
  [666, "this.toast(", "      this.toast(`读取文件失败：${(e as Error).message}`);"],
  [674, "MenuItemData(", "      new MenuItemData('测速', false, $r('sys.symbol.bolt')),"],
  [675, "MenuItemData(", "      new MenuItemData(p.pinned ? '取消置顶' : '置顶', false, $r('sys.symbol.pin')),"],
  [676, "MenuItemData(", "      new MenuItemData('编辑', false, $r('sys.symbol.square_and_pencil')),"],
  [677, "MenuItemData(", "      new MenuItemData('移动到分组', false, $r('sys.symbol.list_square')),"],
  [678, "MenuItemData(", "      new MenuItemData('复制分享链接', false, $r('sys.symbol.doc_plaintext')),"],
  [679, "MenuItemData(", "      new MenuItemData('删除', false, $r('sys.symbol.trash'))"],
  [684, "this.toast(", "          this.toast(`测速失败：${e.message}`);"],
  [688, "this.toast(", "          this.toast(`操作失败：${e.message}`);"],
  [699, "this.toast(", "          this.toast('该协议暂不支持导出链接');"],
  [703, "this.toast(", "          this.toast('节点链接已复制');"],
  [705, "this.toast(", "          this.toast(`复制失败：${e.message}`);"],
  [709, "this.toast(", "          this.toast('已删除');"],
  [711, "this.toast(", "          this.toast(`删除失败：${e.message}`);"],
  [724, "MenuItemData(", "      new MenuItemData('复制分享链接', false, $r('sys.symbol.doc_plaintext')),"],
  [725, "MenuItemData(", "      new MenuItemData('复制出站配置 JSON', false, $r('sys.symbol.doc_text'))"],
  [731, "this.toast(", "          this.toast('该协议暂不支持导出链接');"],
  [735, "this.toast(", "          this.toast('节点链接已复制');"],
  [737, "this.toast(", "          this.toast(`复制失败：${e.message}`);"],
  [744, "this.toast(", "          this.toast('出站配置已复制');"],
  [746, "this.toast(", "          this.toast(`复制失败：${e.message}`);"],
  [749, "this.toast(", "        this.toast(`生成配置失败：${(e as Error).message}`);"],
  [782, "this.toast(", "      this.toast('已保存排序');"],
  [784, "this.toast(", "      this.toast(`排序失败：${e.message}`);"],
  [792, "swipeButton(", "      this.swipeButton($r('sys.symbol.square_and_pencil'), '编辑', Theme.SURFACE_2, Theme.TEXT_1, () => {"],
  [795, "swipeButton(", "      this.swipeButton($r('sys.symbol.share'), '分享', Theme.SURFACE_2, Theme.TEXT_1, () => {"],
  [798, "swipeButton(", "      this.swipeButton($r('sys.symbol.trash'), '删除', Theme.DANGER, Color.White, () => {"],
  [862, "groupNodeCount", "        Text(`${this.app.groupNodeCount(group.id)} 个节点`)"],
  [873, "lastError", "        Text(`上次更新失败：${group.lastError}`)"],
  [898, "this.toast(", "      this.toast(`更新失败：${e.message}`);"],
  [905, "return ", "      return '长期有效';"],
  [908, "return days", "    return days > 0 ? `剩余 ${days} 天` : '已过期';"],
  [914, "return ", "      return '流量未知';"],
  [917, "return ", "      return '可用流量：无限';"],
  [919, "return ", "    return `已用 ${bytesText(info.download + info.upload)} / 共 ${bytesText(info.total)}`;"],
  [925, "return ", "      return '从未更新';"],
  [927, "return ", "    return `更新于 ${dateText(info.lastUpdate)}`;"],
  [1058, "this.toast(", "        this.toast('已复制');"],
  [1061, "this.toast(", "      this.toast(`操作失败：${(e as Error).message}`);"],
  [1071, "Text(", "        Text('从文本导入')"],
  [1076, "Text(", "        Text('支持订阅地址与节点链接（vmess:// vless:// ss:// …）、'"],
  [1077, "base64", "          + 'base64 整段订阅、Clash YAML、sing-box JSON。多条链接按行分隔。')"],
  [1081, "TextArea(", "        TextArea({ text: this.importText, placeholder: '粘贴链接或订阅地址' })"],
  [1091, "label:", "            label: '读取剪贴板',"],
  [1098, "this.toast(", "                this.toast(text.length > 0 ? '已读取剪贴板' : '剪贴板为空');"],
  [1100, "this.toast(", "                this.toast(`读取剪贴板失败：${e.message}`);"],
  [1105, "label:", "            label: this.busy ? '导入中…' : '导入',"],
  [1133, "param.title", "    param.title = '移动到分组';"],
  [1136, "PickOption", "      options.push(new PickOption(g.name, g.id, g.type === 'subscription' ? '订阅' : '基础'));"],
  [1150, "this.toast(", "            this.toast('已移动');"],
  [1152, "this.toast(", "            this.toast(`移动失败：${e.message}`);"],
  [1162, "this.toast(", "      this.toast('内容为空');"],
  [1219, "groupCount", "              ? (this.groupCount === 0 ? '还没有分组' : '这个分组还没有节点')"],
  [1220, "              : '", "              : '没有匹配的节点')"],
  [1272, "subtitle:", "          subtitle: this.profileCount === 0 ? '还没有配置' : `${this.profileCount} 个配置 · ${this.groupCount} 个分组`,"],
  [1314, "TextInput(", "            TextInput({ text: this.query, placeholder: '搜索名称 / 服务器 / 协议' })"],
];

let failures = [];
for (const [no, marker, text] of REPLACE) {
  const cur = lines[no - 1];
  if (cur === undefined) { failures.push(`L${no} 不存在`); continue; }
  if (!cur.includes(marker)) { failures.push(`L${no} 缺少片段 <<${marker}>>：${cur.trim()}`); continue; }
  lines[no - 1] = text;
}
if (failures.length > 0) {
  console.error('中止（有校验失败，未写文件）：');
  for (const f of failures) console.error('  ' + f);
  process.exit(1);
}

// 删除仍含非 ASCII 的纯注释行（注释内容已无从恢复；不动代码行）
const isCommentOnly = (s) => {
  const t = s.trim();
  if (t.length === 0) return false;
  if (t.startsWith('/**')) return true;
  if (t.startsWith('*')) return true;
  if (t.startsWith('//')) return true;
  return false;
};
let dropped = 0;
const out = [];
for (const line of lines) {
  const nonAscii = /[^\x00-\x7F]/.test(line);
  if (nonAscii && isCommentOnly(line)) {
    // 收尾行保留成 " */"，避免块注释不闭合
    if (line.includes('*/')) { out.push(line.replace(/^(\s*).*$/, '$1 */')); } else { dropped++; }
    continue;
  }
  out.push(line);
}

fs.writeFileSync(target, out.join('\r\n'), 'utf8');
console.log(`replaced: ${REPLACE.length}  dropped comment lines: ${dropped}`);
const left = out.map((l, i) => [i + 1, l]).filter(([, l]) => /[^\x00-\x7F]/.test(l));
console.log(`remaining non-ASCII lines: ${left.length}`);
for (const [n, l] of left) console.log(`  L${n}: ${l.trim()}`);
