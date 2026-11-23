import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../../core/AppState';
import { RouteRule } from '../../model/RouteRule';
import { GlowButton, OutlineButton, PageHeader, SegmentedRow, confirmDestructive } from '../CommonUi';
import { Space, Theme } from '../Theme';
import { immersiveMedium } from '../../ui/SelectMaterial';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Route';

const MODES: Array<string> = ['规则', '全局', '直连'];
const MODE_VALUES: Array<string> = ['rule', 'global', 'direct'];
const OUTBOUND_LABELS: Array<string> = ['代理', '直连', '拒绝'];
const OUTBOUND_VALUES: Array<string> = ['proxy', 'direct', 'reject'];

/**
 * 分流页：出站模式（规则 / 全局 / 直连）+ 自定义规则列表 + 直连域名/IP 段。
 *
 * 这一页就是 NekoBox 与 Clash 系客户端的根本区别：**订阅里的 proxy-groups / rules 被忽略**，
 * 路由完全由这里（`RouteRule[]` → `ConfigBuilder.buildCoreConfig` 的 `route.rules`）说了算。
 */
@ComponentV2
export struct RouteTab {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Param topSignal: number = 0;
  @Event onDrawer: () => void = (): void => {
  };
  @Local app: AppState = AppState.get();
  @Local showAdd: boolean = false;
  /** 正在编辑的规则下标（-1 = 新建） */
  @Local editingIndex: number = -1;
  @Local addDomains: string = '';
  @Local addIp: string = '';
  @Local addRemark: string = '';
  @Local addOutboundIndex: number = 0;
  private scroller: Scroller = new Scroller();

  /** 新建规则（原来挂在 HDS 标题栏的那颗 ⊕ 上） */
  private openAdd(): void {
    this.editingIndex = -1;
    this.addDomains = '';
    this.addIp = '';
    this.addRemark = '';
    this.addOutboundIndex = 0;
    this.showAdd = true;
  }

  @Monitor('topSignal')
  onTopSignal(): void {
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: true });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }

  private modeIndex(): number {
    const index: number = MODE_VALUES.indexOf(this.app.settings.mode);
    return index < 0 ? 0 : index;
  }

  private outboundLabel(rule: RouteRule): string {
    if (rule.outbound.startsWith('profile:')) {
      return '指定节点';
    }
    const index: number = OUTBOUND_VALUES.indexOf(rule.outbound);
    return index < 0 ? rule.outbound : OUTBOUND_LABELS[index];
  }

  private outboundColor(rule: RouteRule): ResourceColor {
    if (rule.outbound === 'direct') {
      return Theme.OK;
    }
    if (rule.outbound === 'reject') {
      return Theme.DANGER;
    }
    return Theme.BRAND;
  }

  private ruleTitle(rule: RouteRule): string {
    if (rule.remark.length > 0) {
      return rule.remark;
    }
    if (rule.domains.length > 0) {
      return rule.domains;
    }
    if (rule.ip.length > 0) {
      return rule.ip;
    }
    if (rule.packages.length > 0) {
      return `应用：${rule.packages}`;
    }
    return '（空规则）';
  }

  /**
   * 规则行：照 `RouteFragment.RuleHolder.bind` 的三段信息 + 开关 + 编辑。
   *   ① 名称（`rule.displayName()`）② 摘要（`rule.mkSummary()`）③ 出站（`rule.displayOutbound()`）
   *   右侧：启用开关（原版点整行就是切开关）+ 编辑 + 删除。
   */
  @Builder
  private ruleRow(rule: RouteRule, index: number) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(this.ruleTitle(rule))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.ruleSummary(rule))
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.outboundLabel(rule))
          .fontSize(12)
          .fontColor(this.outboundColor(rule))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
        .selectedColor(Theme.BRAND)
        .onChange((on: boolean) => {
          rule.enabled = on;
          this.app.upsertRule(rule, index).then(() => {
            this.toast(on ? '已启用该规则' : '已停用该规则');
          });
        })

      Row() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(16)
          .fontColor([Theme.TEXT_3])
      }
      .width(30)
      .height(30)
      .borderRadius(15)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openEditor(index, rule);
      })

      Row() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(16)
          .fontColor([Theme.DANGER])
      }
      .width(30)
      .height(30)
      .borderRadius(15)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        confirmDestructive(this.getUIContext(), '删除规则', '这条自定义路由规则会被删除。', '删除', (): void => {
          this.app.deleteRule(index).then(() => {
            this.toast('已删除该规则');
          }).catch((e: Error) => {
            this.toast(`删除失败：${e.message}`);
          });
        });
      })
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor(Theme.SURFACE)
    .alignItems(VerticalAlign.Center)
  }

  /** 规则摘要（对齐 `RuleEntity.mkSummary()` 的字段拼接口径：域名/端口/源/网络/应用） */
  private ruleSummary(rule: RouteRule): string {
    const parts: Array<string> = [];
    if (rule.domains.trim().length > 0) {
      parts.push(`域名 ${rule.domains.trim()}`);
    }
    if (rule.ip.trim().length > 0) {
      parts.push(`IP ${rule.ip.trim()}`);
    }
    if (rule.port.trim().length > 0) {
      parts.push(`端口 ${rule.port.trim()}`);
    }
    if (rule.source.trim().length > 0) {
      parts.push(`源 ${rule.source.trim()}`);
    }
    if (rule.network.trim().length > 0) {
      parts.push(rule.network.trim());
    }
    if (rule.packages.trim().length > 0) {
      parts.push(`应用 ${rule.packages.trim()}`);
    }
    return parts.length > 0 ? parts.join(' · ') : '匹配所有流量';
  }

  /** 编辑既有规则：把字段填回面板（sheetKind='edit'，保存时按下标覆盖） */
  private openEditor(index: number, rule: RouteRule): void {
    this.editingIndex = index;
    this.addDomains = rule.domains;
    this.addIp = rule.ip;
    this.addRemark = rule.remark;
    const outboundIndex: number = OUTBOUND_VALUES.indexOf(rule.outbound);
    this.addOutboundIndex = outboundIndex >= 0 ? outboundIndex : 0;
    this.showAdd = true;
  }

  @Builder
  private addPanel() {
    Column({ space: 10 }) {
      Text(this.editingIndex >= 0 ? '编辑路由规则' : '新建路由规则')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
        .width('100%')
      TextInput({ text: this.addDomains, placeholder: '域名（逗号分隔，支持 geosite:cn / domain:xx / full:xx）' })
        .height(44)
        .fontSize(13)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(12)
        .onChange((v: string) => {
          this.addDomains = v;
        })
      TextInput({ text: this.addIp, placeholder: '目的 IP CIDR（逗号分隔，支持 geoip:private）' })
        .height(44)
        .fontSize(13)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(12)
        .onChange((v: string) => {
          this.addIp = v;
        })
      TextInput({ text: this.addRemark, placeholder: '备注（可留空）' })
        .height(44)
        .fontSize(13)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(12)
        .onChange((v: string) => {
          this.addRemark = v;
        })
      SegmentedRow({
        labels: OUTBOUND_LABELS,
        selected: this.addOutboundIndex,
        onSelect: (index: number) => {
          this.addOutboundIndex = index;
        }
      })
      Row({ space: 10 }) {
        GlowButton({
          label: '取消',
          grow: true,
          buttonColor: Theme.SURFACE_2,
          labelColor: Theme.TEXT_1,
          onTap: () => {
            this.showAdd = false;
          }
        })
        GlowButton({
          label: '保存',
          grow: true,
          onTap: () => {
            this.saveRule();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, top: 20, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 重置路由（原版 `action_reset_route`：清空全部自定义规则） */
  private resetRoute(): void {
    if (this.app.rules.length === 0) {
      this.toast('没有可清空的规则');
      return;
    }
    confirmDestructive(this.getUIContext(), '清空全部规则',
      `${this.app.rules.length} 条自定义路由规则会被删除。`, '清空', (): void => {
        this.app.saveRules([]).then(() => {
          this.toast('已清空全部自定义规则');
        }).catch((e: Error) => {
          this.toast(`清空失败：${e.message}`);
        });
      });
  }

  private saveRule(): void {
    const rule: RouteRule = new RouteRule();
    rule.domains = this.addDomains.trim();
    rule.ip = this.addIp.trim();
    rule.remark = this.addRemark.trim();
    rule.outbound = OUTBOUND_VALUES[this.addOutboundIndex];
    rule.enabled = true;
    if (rule.domains.length === 0 && rule.ip.length === 0 && rule.packages.length === 0) {
      this.toast('域名或 IP 至少填一项');
      return;
    }
    this.showAdd = false;
    const index: number = this.editingIndex;
    this.editingIndex = -1;
    this.addDomains = '';
    this.addIp = '';
    this.addRemark = '';
    this.app.upsertRule(rule, index).then(() => {
      this.toast(index >= 0 ? '已保存修改' : '已保存，重新连接后生效');
    }).catch((e: Error) => {
      this.toast(`保存失败：${e.message}`);
    });
  }

  @Builder
  private pageRoot() {
    Column() {
      PageHeader({
        title: '分流',
        subtitle: `${this.app.rules.length} 条自定义规则`,
        showAdd: true,
        addSymbol: $r('sys.symbol.plus'),
        showMenu: true,
        menuSymbol: $r('sys.symbol.arrow_counterclockwise'),
        onDrawer: () => {
          this.onDrawer();
        },
        onAdd: () => {
          this.openAdd();
        },
        onMenu: () => {
          this.resetRoute();
        }
      })
      List({ space: 10, scroller: this.scroller }) {
          ListItem() {
            Column({ space: 12 }) {
              Text('出站模式')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT_3)
                .width('100%')
              SegmentedRow({
                labels: MODES,
                selected: this.modeIndex(),
                onSelect: (index: number) => {
                  const next: string = MODE_VALUES[index];
                  // 甲方 2026-11-01：切模式不弹提示、也不再解释模式含义（这类软件不需要科普文案）
                  this.app.patchSettings((s) => {
                    s.mode = next;
                  });
                }
              })
            }
            .width('100%')
            // 页头自绘在流内，内容不再需要 HDS 标题栏的顶部让位（原来这里是 topInset=94）
            .padding({ top: 4 })
          }

          ListItem() {
            Row() {
              Text('自定义规则')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.TEXT_3)
              Blank()
              Text(`${this.app.rules.length} 条`)
                .fontSize(12)
                .fontColor(Theme.TEXT_3)
            }
            .width('100%')
            .padding({ top: 2 })
          }

          if (this.app.rules.length === 0) {
            ListItem() {
              // 不给使用教程：这软件不需要科普文案（甲方 2026-11-01）
              Column() {
                Text('暂无自定义规则')
                  .fontSize(15)
                  .fontColor(Theme.TEXT_1)
              }
              .width('100%')
              .padding({ top: 40, bottom: 30 })
              .alignItems(HorizontalAlign.Center)
            }
          } else {
            ForEach(this.app.rules, (rule: RouteRule, index: number) => {
              ListItem() {
                this.ruleRow(rule, index)
              }
            }, (rule: RouteRule, index: number) => `rule_${index}_${rule.remark}_${rule.domains}_${rule.ip}_${rule.outbound}`)
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
    .bindSheet(this.showAdd!!, this.addPanel(), {
      // API 26：面板统一走系统沉浸材质（菜单同一套玻璃），设备不支持时系统自动忽略
      systemMaterial: immersiveMedium(),
      height: 420,
      dragBar: true,
      showClose: true,
      backgroundColor: Theme.BG,
      preferType: SheetType.BOTTOM,
      onDisappear: () => {
        this.showAdd = false;
      }
    })
  }

  build() {
    this.pageRoot()
  }
}
