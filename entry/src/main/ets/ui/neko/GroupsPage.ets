import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProfileGroup } from '../../model/Profile';
import { AppState } from '../../core/AppState';
import { SubInfo } from '../../core/Subscriptions';
import { exportProfileLink } from '../../utils/LinkExporter';
import { setClipboardText } from '../../utils/ClipboardHelper';
import {
  confirmDestructive,
  GlowButton,
  HdsMenu,
  MenuItemData,
  OutlineButton,
  PageHeader,
  SegmentedRow,
  ToggleRow
} from '../CommonUi';
import { bytesText, dateText } from '../Format';
import { Space, Theme } from '../Theme';
import { immersiveMedium } from '../../ui/SelectMaterial';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Groups';

const TYPE_LABELS: Array<string> = ['基础分组', '订阅'];
const TYPE_VALUES: Array<string> = ['basic', 'subscription'];

/**
 * 分组页。**订阅不是独立功能**：新建分组时把类型选成「订阅」并填地址，
 * 这个分组就变成一个订阅（更新时节点自动落进本组）—— 对齐 NekoBoxForAndroid / OwnBox。
 */
@ComponentV2
export struct GroupsPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  /** 壳层每次切分区自增，用来把列表滚回顶部（与 RouteTab 一致） */
  @Param topSignal: number = 0;
  @Event onDrawer: () => void = (): void => {
  };
  @Local app: AppState = AppState.get();
  @Local sheetOpen: boolean = false;
  @Local typeIndex: number = 0;
  @Local name: string = '';
  @Local url: string = '';
  @Local autoUpdate: boolean = true;
  @Local busy: boolean = false;
  /** 面板类型：'add' 新建 / 'edit' 编辑（一个节点只能挂一个 bindSheet，用 kind 切内容） */
  @Local sheetKind: string = 'add';
  @Local editId: string = '';
  @Local editName: string = '';
  @Local editUrl: string = '';
  /** 编辑面板形态：'basic' 只改名字 / 'subscription' 名字 + 六项订阅设置 */
  @Local editKind: string = 'basic';
  @Local optAuto: boolean = true;
  @Local optForce: boolean = false;
  @Local optDedup: boolean = false;
  @Local optConnectedOnly: boolean = false;
  @Local optUa: string = '';
  @Local optHours: number = 12;
  @Local groupRows: Array<ProfileGroup> = [];
  @Local subscriptionCount: number = 0;
  private scroller: Scroller = new Scroller();
  private menu: HdsMenu = new HdsMenu();

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2400 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }

  private async commit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const kind: string = TYPE_VALUES[this.typeIndex];
    if (this.name.trim().length === 0) {
      this.toast('请填写分组名称');
      return;
    }
    this.busy = true;
    try {
      const message: string = await this.app.addGroup(this.name, kind, this.url, this.autoUpdate);
      // addGroup 失败时返回的是"已存在同名分组 / 订阅地址必须以 http(s):// 开头 / 创建分组失败"，
      // 这些情况不能关面板、也不能去改别的同名分组（原来会静默把旧组当新组写设置）。
      const created: boolean = message.startsWith('已创建分组') || message.startsWith('已创建订阅分组');
      if (!created) {
        this.toast(message);
        return;
      }
      if (kind === 'subscription') {
        // 面板填的其余五项在分组建好后补写（addGroup 只负责建组 + 首次拉取）
        for (const g of this.app.groups) {
          if (g.name === this.name.trim()) {
            const changes: Record<string, Object> = {
              'forceResolve': this.optForce,
              'deduplication': this.optDedup,
              'updateWhenConnectedOnly': this.optConnectedOnly,
              'userAgent': this.optUa.trim(),
              'updateIntervalHours': this.optHours
            };
            await this.app.saveGroupOptions(g, changes);
            break;
          }
        }
      }
      this.toast(message);
      this.sheetOpen = false;
      this.resetAddForm();
    } finally {
      this.busy = false;
    }
  }

  private resetAddForm(): void {
    this.name = '';
    this.url = '';
    this.typeIndex = 0;
    this.autoUpdate = true;
    this.optForce = false;
    this.optDedup = false;
    this.optConnectedOnly = false;
    this.optUa = '';
    this.optHours = 12;
  }

  @Builder
  private groupRow(g: ProfileGroup) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph(g.type === 'subscription' ? $r('sys.symbol.arrow_clockwise') : $r('sys.symbol.list_square'))
          .fontSize(15)
          .fontColor([g.type === 'subscription' ? Theme.BRAND : Theme.TEXT_2])
          .onClick(() => {
            if (g.type === 'subscription') {
              this.refreshGroup(g);
            }
          })
        Text(g.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(g.type === 'subscription' ? '订阅' : '基础')
          .fontSize(11)
          .fontColor(g.type === 'subscription' ? Theme.BRAND : Theme.TEXT_3)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(9)
          .backgroundColor(g.type === 'subscription' ? Theme.BRAND_SOFT : Theme.SURFACE_2)
        Text(`${this.app.groupNodeCount(g.id)} 个`)
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (g.type === 'subscription') {
        Text(g.url)
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 10 }) {
          Text(this.subLine(g))
            .fontSize(11)
            .fontColor(Theme.TEXT_3)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Toggle({ type: ToggleType.Switch, isOn: g.autoUpdate })
            .selectedColor(Theme.BRAND)
            .onChange((on: boolean) => {
              this.app.setGroupAutoUpdate(g, on).then(() => {
                this.toast(on ? '已开启自动更新' : '已关闭自动更新');
              }).catch((e: Error) => {
                this.toast(`设置失败：${e.message}`);
              });
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (g.lastError.length > 0) {
          Text(`上次更新失败：${g.lastError}`)
            .fontSize(11)
            .fontColor(Theme.DANGER)
            .maxLines(2)
            .width('100%')
        }
      }

      // 甲方：右下角那颗刷新删掉，这里放一根"流量使用"进度条（名字旁边那颗 ⟳ 才是更新）
      if (g.type === 'subscription') {
        Column({ space: 4 }) {
          Progress({ value: this.trafficPercent(g), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color(this.trafficPercent(g) >= 90 ? Theme.DANGER : Theme.BRAND)
            .backgroundColor(Theme.SURFACE_2)
          Text(this.trafficPercent(g) > 0 ? `已用 ${this.trafficUsedText(g)}` : '流量未知')
            .fontSize(10)
            .fontColor(Theme.TEXT_3)
            .width('100%')
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(18)
    .backgroundColor(Theme.SURFACE)
    // 分组菜单的锚点：`openGroupMenu()` 用的是 `group_menu_${g.id}`，以前没有任何节点挂这个 id，
    // 一旦接上入口就会"点了没反应"（与首页"分享"是同一类 bug，2026-11-21 一并补上）
    .id(`group_menu_${g.id}`)
  }

  /** 流量使用百分比（无流量信息时 0） */
  private trafficPercent(g: ProfileGroup): number {
    const info: SubInfo | undefined = this.app.groupSub(g);
    if (info === undefined || info.total <= 0) {
      return 0;
    }
    const used: number = info.download + info.upload;
    return Math.max(0, Math.min(100, Math.round(used * 100 / info.total)));
  }

  /** 已用 / 总量 */
  private trafficUsedText(g: ProfileGroup): string {
    const info: SubInfo | undefined = this.app.groupSub(g);
    if (info === undefined || info.total <= 0) {
      return '';
    }
    return `${bytesText(info.download + info.upload)} / ${bytesText(info.total)}`;
  }

  /** 刷新单个订阅分组（分组卡名字旁那颗 ⟳ 走这里） */
  private refreshGroup(g: ProfileGroup): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.app.refreshGroup(g).then((message: string) => {
      this.busy = false;
      this.toast(message);
    }).catch((e: Error) => {
      this.busy = false;
      this.toast(`更新失败：${e.message}`);
    });
  }

  /** 长按拖动的浮起预览 */
  @Builder
  private groupDragPreview(index: number) {
    Row() {
      Text(index >= 0 && index < this.groupRows.length ? this.groupRows[index].name : '')
        .fontSize(14)
        .fontColor(Theme.TEXT_1)
        .maxLines(1)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    }
    .borderRadius(14)
    .backgroundColor(Theme.SURFACE_2)
  }

  /** 拖动结束：按新顺序写分组 sortOrder */
  private reorderGroups(from: number, insert: number): void {
    const list: Array<ProfileGroup> = this.groupRows.slice();
    if (from < 0 || from >= list.length) {
      return;
    }
    const moved: ProfileGroup = list.splice(from, 1)[0];
    list.splice(Math.max(0, Math.min(insert, list.length)), 0, moved);
    const ids: Array<string> = [];
    for (const g of list) {
      ids.push(g.id);
    }
    this.app.applyGroupOrder(ids).then(() => {
      this.toast('已保存分组排序');
    }).catch((e: Error) => {
      this.toast(`排序失败：${e.message}`);
    });
  }

  /** 分组左滑：设置 / 删除（原来在卡片上占了两颗按钮） */
  @Builder
  private groupSwipe(g: ProfileGroup) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(19)
          .fontColor([Theme.TEXT_1])
        Text('设置')
          .fontSize(11)
          .fontColor(Theme.TEXT_1)
      }
      .width(64)
      .height(64)
      .borderRadius(18)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(Theme.SURFACE_2)
      .onClick(() => {
        this.openEditor(g);
      })

      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(19)
          .fontColor([Color.White])
        Text('删除')
          .fontSize(11)
          .fontColor(Color.White)
      }
      .width(64)
      .height(64)
      .borderRadius(18)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(Theme.DANGER)
      .onClick(() => {
        const count: number = this.app.groupNodeCount(g.id);
        const message: string = g.type === 'subscription'
          ? `「${g.name}」是订阅分组：订阅记录和它的 ${count} 个节点都会被删除。`
          : `「${g.name}」和里面的 ${count} 个节点都会被删除，无法恢复。`;
        confirmDestructive(this.getUIContext(), '删除分组', message, '删除', (): void => {
          this.app.deleteGroup(g).then(() => {
            this.toast(count > 0 ? `已删除分组「${g.name}」及其 ${count} 个节点` : `已删除分组「${g.name}」`);
          }).catch((e: Error) => {
            this.toast(`删除失败：${e.message}`);
          });
        });
      })
    }
    .height(80)
    .padding({ left: 6 })
  }

  /** 顶部"更新所有订阅"（原版 add_group_menu 的 action_update_all） */
  private async updateAll(): Promise<void> {
    if (this.busy) {
      return;
    }
    const subs: Array<ProfileGroup> = this.app.groups.filter((g: ProfileGroup) => g.type === 'subscription');
    if (subs.length === 0) {
      this.toast('还没有订阅分组');
      return;
    }
    this.busy = true;
    try {
      let ok: number = 0;
      let failed: number = 0;
      for (const g of subs) {
        const message: string = await this.app.refreshGroup(g);
        if (message.startsWith('更新失败')) {
          failed++;
        } else {
          ok++;
        }
      }
      this.toast(`订阅更新完成：成功 ${ok} / 失败 ${failed}`);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 分组长按菜单（对齐 `group_action_menu.xml`）：
   * 分享订阅链接（剪贴板）/ 导出组内节点链接（剪贴板）/ 清空分组。
   * 原版还有二维码与"导出到文件"，前者要二维码生成、后者要文件选择器，排在后续。
   */
  private openGroupMenu(g: ProfileGroup): void {
    const items: Array<MenuItemData> = [];
    const isSubLink: boolean = g.type === 'subscription' && g.url.length > 0;
    if (isSubLink) {
      items.push(new MenuItemData('复制订阅链接', false, $r('sys.symbol.link')));
    }
    const idxExport: number = items.length;
    items.push(new MenuItemData('导出组内节点链接', false, $r('sys.symbol.doc_plaintext')));
    const idxClear: number = items.length;
    items.push(new MenuItemData('清空分组', false, $r('sys.symbol.trash')));
    // 订阅分组 → 基础分组：保留节点、断开订阅关系（首页那张流量卡随之消失）
    const idxDemote: number = g.type === 'subscription' ? items.length : -1;
    if (idxDemote >= 0) {
      items.push(new MenuItemData('改为基础分组', false, $r('sys.symbol.list_square')));
    }
    this.menu.open(this.getUIContext(), `group_menu_${g.id}`, items, (index: number) => {
      if (isSubLink && index === 0) {
        setClipboardText(g.url).then(() => {
          this.toast('订阅链接已复制');
        }).catch((e: Error) => {
          this.toast(`复制失败：${e.message}`);
        });
        return;
      }
      if (index === idxExport) {
        const lines: Array<string> = [];
        for (const p of this.app.profilesOfGroup(g.id)) {
          const link: string = exportProfileLink(p);
          if (link.length > 0) {
            lines.push(link);
          }
        }
        if (lines.length === 0) {
          this.toast('该分组没有可导出的节点');
          return;
        }
        setClipboardText(lines.join('\n')).then(() => {
          this.toast(`已复制 ${lines.length} 条节点链接`);
        }).catch((e: Error) => {
          this.toast(`复制失败：${e.message}`);
        });
        return;
      }
      if (index === idxDemote) {
        this.app.demoteGroupToBasic(g).then((n: number) => {
          this.toast(`已改为基础分组，保留 ${n} 个节点`);
        }).catch((e: Error) => {
          this.toast(`转换失败：${e.message}`);
        });
        return;
      }
      if (index === idxClear) {
        const count: number = this.app.groupNodeCount(g.id);
        confirmDestructive(this.getUIContext(), '清空分组',
          `「${g.name}」里的 ${count} 个节点会被删除（订阅分组下次更新会重新拉回来）。`, '清空', (): void => {
            this.app.clearGroup(g.id).then((n: number) => {
              this.toast(n > 0 ? `已清空 ${n} 个节点` : '分组本来就是空的');
            }).catch((e: Error) => {
              this.toast(`清空失败：${e.message}`);
            });
          });
      }
    }, this.app.settings.lightLevel);
  }

  private subLine(g: ProfileGroup): string {
    const info: SubInfo | undefined = this.app.groupSub(g);
    if (info === undefined) {
      return '尚未拉取';
    }
    const traffic: string = info.total > 0
      ? `已用 ${bytesText(info.download + info.upload)} / ${bytesText(info.total)}` : '流量未知';
    const updated: string = info.lastUpdate > 0 ? `更新 ${dateText(info.lastUpdate)}` : '从未更新';
    return `${updated} · ${traffic}`;
  }

  /** 打开编辑面板：按分组类型决定内容（基础=只改名字；订阅=名字 + 六项订阅设置） */
  private openEditor(g: ProfileGroup): void {
    this.editId = g.id;
    this.editName = g.name;
    this.editUrl = g.url;
    const isSub: boolean = g.type === 'subscription' && g.url.length > 0;
    this.editKind = isSub ? 'subscription' : 'basic';
    this.optAuto = g.autoUpdate;
    this.optForce = false;
    this.optDedup = false;
    this.optConnectedOnly = false;
    this.optUa = '';
    this.optHours = 12;
    if (isSub) {
      const info: SubInfo | undefined = this.app.groupSub(g);
      if (info !== undefined) {
        this.optForce = info.forceResolve;
        this.optDedup = info.deduplication;
        this.optConnectedOnly = info.updateWhenConnectedOnly;
        this.optUa = info.userAgent;
        this.optHours = info.updateIntervalHours > 0 ? info.updateIntervalHours : 12;
      }
    }
    this.sheetKind = 'edit';
    this.sheetOpen = true;
  }

  private editedGroup(): ProfileGroup | undefined {
    for (const g of this.app.groups) {
      if (g.id === this.editId) {
        return g;
      }
    }
    return undefined;
  }

  /**
   * 保存分组设置。
   *   基础分组 → 只存名字（原来这里直接报"不是订阅"，等于基础分组根本改不了名）；
   *   订阅分组 → 名字 + `GroupSettingsActivity` 的六项：autoUpdate / forceResolve / deduplication /
   *              updateWhenConnectedOnly / customUserAgent / updateIntervalHours（link 只读）。
   */
  private async saveEdit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const g: ProfileGroup | undefined = this.editedGroup();
    if (g === undefined) {
      this.sheetOpen = false;
      return;
    }
    const newName: string = this.editName.trim();
    if (newName.length === 0) {
      this.toast('分组名称不能为空');
      return;
    }
    this.busy = true;
    try {
      if (newName !== g.name) {
        await this.app.renameGroup(g, newName);
      }
      if (this.editKind === 'subscription') {
        const changes: Record<string, Object> = {
          'autoUpdate': this.optAuto,
          'forceResolve': this.optForce,
          'deduplication': this.optDedup,
          'updateWhenConnectedOnly': this.optConnectedOnly,
          'userAgent': this.optUa.trim(),
          'updateIntervalHours': this.optHours
        };
        await this.app.saveGroupOptions(g, changes);
      }
      this.sheetOpen = false;
      this.toast('已保存');
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private addPanel() {
    Column({ space: 10 }) {
      Text('新建分组')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
        .width('100%')
      SegmentedRow({
        labels: TYPE_LABELS,
        selected: this.typeIndex,
        onSelect: (index: number) => {
          this.typeIndex = index;
        }
      })
      TextInput({ text: this.name, placeholder: this.typeIndex === 1 ? '订阅名称' : '分组名称' })
        .height(44)
        .fontSize(14)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(12)
        .onChange((v: string) => {
          this.name = v;
        })
      if (this.typeIndex === 1) {
        TextInput({ text: this.url, placeholder: 'https://…' })
          .height(44)
          .fontSize(13)
          .backgroundColor(Theme.SURFACE_2)
          .borderRadius(12)
          .onChange((v: string) => {
            this.url = v;
          })
        Column() {
          ToggleRow({
            label: '自动更新',
            summary: '按下面的间隔自动拉取',
            checked: this.autoUpdate,
            onToggle: (on: boolean) => {
              this.autoUpdate = on;
            }
          })
          Row({ space: 8 }) {
            Text('更新间隔')
              .fontSize(15)
              .fontColor(Theme.TEXT_1)
              .width(80)
            ForEach([6, 12, 24, 48], (hours: number) => {
              Text(`${hours}h`)
                .fontSize(13)
                .fontColor(this.optHours === hours ? Theme.ON_BRAND : Theme.TEXT_2)
                .height(30)
                .padding({ left: 12, right: 12 })
                .borderRadius(15)
                .backgroundColor(this.optHours === hours ? Theme.BRAND : Theme.SURFACE_2)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.optHours = hours;
                })
            }, (hours: number) => `hours_add_${hours}_${this.optHours === hours}`)
            Blank()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 10 })
          .alignItems(VerticalAlign.Center)
          ToggleRow({
            label: '强制解析',
            summary: '',
            checked: this.optForce,
            onToggle: (on: boolean) => {
              this.optForce = on;
            }
          })
          ToggleRow({
            label: '更新时去重',
            summary: '',
            checked: this.optDedup,
            onToggle: (on: boolean) => {
              this.optDedup = on;
            }
          })
          ToggleRow({
            label: '仅在已连接时更新',
            summary: '未连接 VPN 时跳过自动更新',
            checked: this.optConnectedOnly,
            onToggle: (on: boolean) => {
              this.optConnectedOnly = on;
            }
          })
          Row({ space: 8 }) {
            Text('User-Agent')
              .fontSize(15)
              .fontColor(Theme.TEXT_1)
              .width(80)
            TextInput({ text: this.optUa, placeholder: '默认 UA' })
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .backgroundColor(Theme.SURFACE_2)
              .borderRadius(10)
              .onChange((v: string) => {
                this.optUa = v;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 12 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor(Theme.SURFACE_2)
        Text('')
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .width('100%')
      } else {
        Text('')
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .width('100%')
      }
      Row({ space: 10 }) {
        GlowButton({
          label: '取消',
          grow: true,
          buttonColor: Theme.SURFACE_2,
          labelColor: Theme.TEXT_1,
          onTap: () => {
            this.sheetOpen = false;
          }
        })
        GlowButton({
          label: this.busy ? '处理中…' : (this.typeIndex === 1 ? '订阅并拉取' : '创建'),
          grow: true,
          onTap: () => {
            this.commit();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  aboutToAppear(): void {
    this.app.subscribe(this.onStateChanged);
    this.onStateChanged();
  }

  @Monitor('topSignal')
  onTopSignal(): void {
    try {
      this.scroller.scrollEdge(Edge.Top);
    } catch (e) {
      // 列表还没挂上 scroller 时忽略
    }
  }

  aboutToDisappear(): void {
    this.app.unsubscribe(this.onStateChanged);
  }

  private onStateChanged = (): void => {
    this.groupRows = this.app.groups.slice();
    this.subscriptionCount = this.app.subs.length;
  };

  /** 面板分派：@Builder 上下文里不能用三元表达式调 builder，必须写成 if/else */
  @Builder
  private sheetBuild() {
    if (this.sheetKind === 'edit') {
      this.editPanel()
    } else {
      this.addPanel()
    }
  }

  /** 编辑面板：基础分组只有名字；订阅分组再加六项订阅设置 */
  @Builder
  private editPanel() {
    Column({ space: 10 }) {
      Text(this.editKind === 'subscription' ? '订阅设置' : '分组设置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
        .width('100%')

      Row({ space: 8 }) {
        Text('名称')
          .fontSize(15)
          .fontColor(Theme.TEXT_1)
          .width(56)
        TextInput({ text: this.editName, placeholder: '分组名称' })
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .backgroundColor(Theme.SURFACE_2)
          .borderRadius(10)
          .onChange((v: string) => {
            this.editName = v;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.editKind === 'subscription') {
        Text(this.editUrl)
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else {
        Text('')
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .width('100%')
      }

      if (this.editKind === 'subscription') {
        Column() {
          ToggleRow({
            label: '自动更新',
            summary: '',
            checked: this.optAuto,
            onToggle: (on: boolean) => {
              this.optAuto = on;
            }
          })
          Row({ space: 8 }) {
            Text('更新间隔')
              .fontSize(15)
              .fontColor(Theme.TEXT_1)
              .width(80)
            ForEach([6, 12, 24, 48], (hours: number) => {
              Text(`${hours}h`)
                .fontSize(13)
                .fontColor(this.optHours === hours ? Theme.ON_BRAND : Theme.TEXT_2)
                .height(30)
                .padding({ left: 12, right: 12 })
                .borderRadius(15)
                .backgroundColor(this.optHours === hours ? Theme.BRAND : Theme.SURFACE_2)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.optHours = hours;
                })
            }, (hours: number) => `hours_${hours}_${this.optHours === hours}`)
            Blank()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 10 })
          .alignItems(VerticalAlign.Center)

          ToggleRow({
            label: '强制解析',
            summary: '更新时把节点服务器域名解析成 IP（原域名保留为 SNI）',
            checked: this.optForce,
            onToggle: (on: boolean) => {
              this.optForce = on;
            }
          })
          ToggleRow({
            label: '更新时去重',
            summary: '',
            checked: this.optDedup,
            onToggle: (on: boolean) => {
              this.optDedup = on;
            }
          })
          ToggleRow({
            label: '仅在已连接时更新',
            summary: '',
            checked: this.optConnectedOnly,
            onToggle: (on: boolean) => {
              this.optConnectedOnly = on;
            }
          })
          Row({ space: 8 }) {
            Text('User-Agent')
              .fontSize(15)
              .fontColor(Theme.TEXT_1)
              .width(80)
            TextInput({ text: this.optUa, placeholder: '默认 UA' })
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .backgroundColor(Theme.SURFACE_2)
              .borderRadius(10)
              .onChange((v: string) => {
                this.optUa = v;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor(Theme.SURFACE_2)
      }

      Blank()

      Row({ space: 10 }) {
        GlowButton({
          label: '取消',
          grow: true,
          buttonColor: Theme.SURFACE_2,
          labelColor: Theme.TEXT_1,
          onTap: () => {
            this.sheetOpen = false;
          }
        })
        if (this.editKind === 'subscription') {
          GlowButton({
            label: '立即更新',
            grow: true,
            buttonColor: Theme.SURFACE_2,
            labelColor: Theme.TEXT_1,
            onTap: () => {
              const g: ProfileGroup | undefined = this.editedGroup();
              if (g === undefined) {
                return;
              }
              this.sheetOpen = false;
              this.app.refreshGroup(g).then((message: string) => {
                this.toast(message);
              }).catch((e: Error) => {
                this.toast(`更新失败：${e.message}`);
              });
            }
          })
        }
        GlowButton({
          label: '保存',
          grow: true,
          tapEnabled: !this.busy,
          onTap: () => {
            this.saveEdit().catch((e: Error) => {
              this.toast(`保存失败：${e.message}`);
            });
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      PageHeader({
        title: '分组',
        subtitle: `${this.groupRows.length} 个分组 · ${this.subscriptionCount} 个订阅`,
        showSearch: true,
        searchSymbol: $r('sys.symbol.arrow_clockwise'),
        showAdd: true,
        addSymbol: $r('sys.symbol.plus'),
        showMenu: false,
        onSearch: () => {
          this.updateAll();
        },
        onDrawer: () => {
          this.onDrawer();
        },
        onAdd: () => {
          // 每次新建都清空上一次的残留（原来按空白区关掉后，再点「+」还是旧的名字/地址）
          this.resetAddForm();
          this.sheetKind = 'add';
          this.sheetOpen = true;
        }
      })

      List({ space: 10, scroller: this.scroller }) {
        if (this.groupRows.length === 0) {
          ListItem() {
            // 只留一句状态，不写"怎么新建"的教程（甲方 2026-11-01：不需要繁杂提示）
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.list_square'))
                .fontSize(38)
                .fontColor([Theme.TEXT_3])
              Text('还没有分组')
                .fontSize(15)
                .fontColor(Theme.TEXT_1)
            }
            .width('100%')
            .padding({ top: 70, bottom: 40 })
            .alignItems(HorizontalAlign.Center)
          }
        } else {
          ForEach(this.groupRows, (g: ProfileGroup) => {
            ListItem() {
              this.groupRow(g)
            }
            // 左滑：设置 / 删除
            .swipeAction({ end: this.groupSwipe(g), edgeEffect: SwipeEdgeEffect.Spring })
          }, (g: ProfileGroup) => `grp_${g.id}_${g.name}`)
            // 拖动排序：`onMove` 挂在 ForEach 上（与 RzdMusic 音源管理一致；List.onItemDrag 那套不跟手）
            .onMove((from: number, to: number) => {
              this.reorderGroups(from, to);
            })
        }


        // 末尾呼吸位用列表项给（padding 会连滚动视口一起裁掉，底部会露出页面底色）
        ListItem() {
          Row().width('100%').height(8)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: Space.PAGE, right: Space.PAGE })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
    .bindSheet(this.sheetOpen!!, this.sheetBuild(), {
      // API 26：面板统一走系统沉浸材质（菜单同一套玻璃），设备不支持时系统自动忽略
      systemMaterial: immersiveMedium(),
      height: this.sheetKind === 'edit' ? (this.editKind === 'subscription' ? 600 : 340)
        : (this.typeIndex === 1 ? 660 : 300),
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.BG,
      preferType: SheetType.BOTTOM,
      // !! 双向绑定已经会把 sheetOpen 同步成 false；这里再兜一次，杜绝"点空白关闭后打不开"
      onDisappear: () => {
        this.sheetOpen = false;
      }
    })
  }
}
