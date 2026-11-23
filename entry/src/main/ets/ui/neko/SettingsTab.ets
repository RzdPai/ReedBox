import { hilog } from '@kit.PerformanceAnalysisKit';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import { AppState } from '../../core/AppState';
import { AppSettings } from '../../model/Profile';
import { ClashParseResult } from '../../utils/Subscription';
import { geoAssetInfos, geoReady, GeoAssetInfo } from '../../utils/GeoAssets';
import { exportProfileLink } from '../../utils/LinkExporter';
import { getClipboardText } from '../../utils/ClipboardHelper';
import { setClipboardText } from '../../utils/ClipboardHelper';
import { exportBackup, importBackup, BackupRestoreResult } from '../../core/Backup';
import {
  PageHeader,
  FormRow,
  GlowButton,
  OutlineButton,
  SectionHeader,
  SegmentedRow,
  SelectRow,
  ToggleRow
} from '../CommonUi';
import { bytesText } from '../Format';
import { Accent } from '../Accent';
import { Space, Theme } from '../Theme';
import { SEC_ABOUT, SEC_LOGS } from '../Routes';
import { immersiveMedium } from '../../ui/SelectMaterial';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Settings';

const APPEARANCE_LABELS: Array<string> = ['跟随系统', '浅色', '深色'];
const APPEARANCE_VALUES: Array<string> = ['system', 'light', 'dark'];
const LEVEL_LABELS: Array<string> = ['自适应', '柔滑', '温润', '精致'];
const SORT_LABELS: Array<string> = ['手动', '按延迟', '按名称'];
const SORT_VALUES: Array<string> = ['manual', 'latency', 'name'];
const SNIFF_LABELS: Array<string> = ['关闭', '仅用于路由', '嗅探并覆盖'];
const SNIFF_VALUES: Array<string> = ['off', 'route', 'override'];
const TESTMODE_LABELS: Array<string> = ['URL Test（真连接）', 'TCPing（仅握手）'];
const TESTMODE_VALUES: Array<string> = ['url', 'tcp'];

/**
 * 设置页：分组化的键值行 + 开关行，改动即存（`AppState.patchSettings`）。
 * 需要「重新连接后生效」的项在行下方标注，避免用户以为没生效就是坏了。
 */
@ComponentV2
export struct SettingsTab {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Event onDrawer: () => void = (): void => {
  };
  @Param topSignal: number = 0;
  @Local app: AppState = AppState.get();
  /** 文本输入面板（应用包名列表这类多行输入）。选项类设置已改成系统 Select，不再有半模态选项面板 */
  @Local pickOpen: boolean = false;
  @Local textTitle: string = '';
  @Local textValue: string = '';
  private textAction: (value: string) => void = (value: string): void => {
  };
  @Local geoInfo: Array<GeoAssetInfo> = [];
  @Local busyText: string = '';
  private scroller: Scroller = new Scroller();

  /**
   * 设置快照（**页面里一律读 `this.s`，不要直接读 `this.app.settings`**）。
   *
   * 甲方实测过"改了设置界面没变、重启才看到"。根因是这类页面依赖"深观察 + 细粒度通知"，
   * 一旦某处通知没触发，界面就停在旧值。这里把 `app.rev`（每次写操作 +1）显式写进依赖，
   * 任何写操作后 @Computed 都会重算、页面都会重绘 —— 不再赌单项通知。
   */
  @Computed
  get s(): AppSettings {
    if (this.app.rev < 0) {
      return this.app.settings;
    }
    return this.app.settings;
  }

  aboutToAppear(): void {
    this.refreshGeo();
  }

  @Monitor('topSignal')
  onTopSignal(): void {
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: true });
  }

  private refreshGeo(): void {
    const ctx = this.app.uicontext();
    if (ctx === undefined) {
      return;
    }
    try {
      this.geoInfo = geoAssetInfos(ctx);
    } catch (e) {
      this.geoInfo = [];
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }

  /** DNS 策略文案（空串 = 内核默认 auto） */
  private strategyLabel(value: string): string {
    if (value.length === 0 || value === 'auto') {
      return 'auto（内核默认）';
    }
    return value;
  }

  /**
   * 探测已安装应用（原版 AppListActivity 的 getInstalledApplications）。
   * HarmonyOS 上 getAllApplicationInfo 对普通应用可能受限；失败就如实告知改用手填包名，
   * 对应原版 string no_installed_apps_manual 的兜底语义。
   */
  private probeApps(): void {
    // HarmonyOS 的 bundleManager 不向普通应用开放“列出全部已安装应用”（getAllApplicationInfo/getAllBundleInfo 都不在公开 API 里），
    // 原版 AppListActivity 在拿不到列表时也是让用户手填包名（string no_installed_apps_manual）；这里如实照做。
    this.toast('无法列出已安装应用（系统未对外开放该接口），请在包名列表里手填');
  }

  private perAppLabel(mode: string): string {
    if (mode === 'exclude') {
      return '排除这些应用';
    }
    if (mode === 'include') {
      return '仅这些应用走代理';
    }
    return '关闭';
  }

  private labelOf(labels: Array<string>, values: Array<string>, current: string): string {
    const index: number = values.indexOf(current);
    return index < 0 ? current : labels[index];
  }

  /**
   * 主题色一行：左边标题，右边一排预置色点（点一下就换，当前色打勾）。
   * 参考 RzdMusic 设置页的色点样式（32vp 圆点 + 选中描边 + 勾）。
   */
  @Builder
  private themeColorRow() {
    Row() {
      Text('主题色')
        .fontSize(15)
        .fontColor(Theme.TEXT_1)
        .width(96)
      Scroll() {
        Row({ space: 10 }) {
          ForEach(Accent.PRESETS, (color: string) => {
            Row() {
              if (isSameColor(Accent.get().color, color)) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(14)
                  .fontColor([Theme.ON_BRAND])
              }
            }
            .width(28)
            .height(28)
            .borderRadius(14)
            .backgroundColor(color)
            .justifyContent(FlexAlign.Center)
            .border({
              width: 2,
              color: isSameColor(Accent.get().color, color) ? Theme.TEXT_1 : Color.Transparent
            })
            .onClick(() => {
              this.app.setThemeColor(color).then(() => {
                this.toast('主题色已切换');
              }).catch((e: Error) => {
                this.toast(`切换失败：${e.message}`);
              });
            })
          }, (color: string) => `accent_${color}`)
        }
        .padding({ left: 2, right: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height(40)
      .align(Alignment.End)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private sectionCard(title: string, summary: string) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
        if (summary.length > 0) {
          Text(summary)
            .fontSize(11)
            .fontColor(Theme.TEXT_3)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 6 })
  }

  @Builder
  private pageRoot() {
    Column() {
      PageHeader({
        title: '设置',
        subtitle: '改动即存',
        onDrawer: () => {
          this.onDrawer();
        }
      })
      List({ space: 0, scroller: this.scroller }) {
          ListItem() {
            Column() {
              this.sectionCard('常规', '')
            }
            .width('100%')
            .padding({ top: 4 })
          }

          ListItem() {
            Column() {
              ToggleRow({
                label: '自动连接',
                summary: '',
                checked: this.s.autoConnect,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.autoConnect = on;
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '日志级别',
                labels: ['trace', 'debug', 'info', 'warn', 'error'],
                values: ['trace', 'debug', 'info', 'warn', 'error'],
                current: this.s.logLevel,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.logLevel = value;
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              ToggleRow({
                label: '节点流量统计',
                summary: '',
                checked: this.s.profileTrafficStatistics,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.profileTrafficStatistics = on;
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: 'MTU',
                labels: ['1280', '1400', '1500'],
                values: ['1280', '1400', '1500'],
                current: `${this.s.mtu}`,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.mtu = Number(value);
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '混合端口',
                labels: ['关闭', '2080', '7890', '10808'],
                values: ['0', '2080', '7890', '10808'],
                current: `${this.s.mixedPort}`,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.mixedPort = Number(value);
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '远程 DNS',
                labels: ['tcp://8.8.8.8', 'https://1.1.1.1/dns-query', 'tls://dns.google'],
                values: ['tcp://8.8.8.8', 'https://1.1.1.1/dns-query', 'tls://dns.google'],
                current: this.s.remoteDns,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.remoteDns = value;
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '直连 DNS',
                labels: ['223.5.5.5', '119.29.29.29', '180.76.76.76'],
                values: ['223.5.5.5', '119.29.29.29', '180.76.76.76'],
                current: this.s.directDns,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.directDns = value;
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '嗅探',
                labels: SNIFF_LABELS,
                values: SNIFF_VALUES,
                current: this.s.sniffMode,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.sniffMode = value;
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                }
              })
              ToggleRow({
                label: 'IPv6',
                summary: '',
                checked: this.s.ipv6,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.ipv6 = on;
                  });
                }
              })
              ToggleRow({
                label: 'DNS 路由',
                summary: '',
                checked: this.s.dnsRouting,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.dnsRouting = on;
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              // 以下照 global_preferences.xml 的「路由」（cag_route）与「DNS」（cag_dns）两组补齐
              ToggleRow({
                label: '绕过局域网',
                summary: '',
                checked: this.s.bypassLan,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.bypassLan = on;
                  });
                }
              })
              ToggleRow({
                label: '解析目标地址',
                summary: '',
                checked: this.s.resolveDestination,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.resolveDestination = on;
                  });
                }
              })
              ToggleRow({
                label: 'FakeDNS',
                summary: '',
                checked: this.s.fakeDns,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.fakeDns = on;
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '远程 DNS 策略',
                labels: ['auto（内核默认）', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'],
                values: ['', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'],
                current: this.s.remoteDnsStrategy,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                  this.app.patchSettings((s) => {
                    s.remoteDnsStrategy = value;
                  }).then(() => {
                    this.toast('已保存，重新连接后生效');
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '直连 DNS 策略',
                labels: ['auto（内核默认）', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'],
                values: ['', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'],
                current: this.s.directDnsStrategy,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                  this.app.patchSettings((s) => {
                    s.directDnsStrategy = value;
                  }).then(() => {
                    this.toast('已保存，重新连接后生效');
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '服务器 DNS 策略',
                labels: ['auto（内核默认）', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'],
                values: ['', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'],
                current: this.s.serverDnsStrategy,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                  this.app.patchSettings((s) => {
                    s.serverDnsStrategy = value;
                  }).then(() => {
                    this.toast('已保存，重新连接后生效');
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '分应用代理',
                labels: ['关闭', '排除这些应用', '仅这些应用走代理'],
                values: ['off', 'exclude', 'include'],
                current: this.s.perAppMode,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.perAppMode = value;
                      }).then(() => {
                        this.toast(value === 'off'
                          ? '已关闭分应用代理'
                          : '已切换；包名列表编辑（读已安装应用）排在后续轮次');
                      });
                }
              })
              if (this.s.perAppMode !== 'off') {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                FormRow({
                  label: '应用包名列表',
                  value: this.s.perAppList.length > 0 ? ` 个` : '未填写',
                  onTap: () => {
                    this.openTextSheet('应用包名列表（proxyApps）', this.s.perAppList, (value: string) => {
                      this.app.patchSettings((s) => {
                        s.perAppList = value;
                      }).then(() => {
                        this.toast('已保存，重新连接后生效');
                      });
                    });
                  }
                })
              }
            }
            .width('100%')
            .borderRadius(18)
            .backgroundColor(Theme.SURFACE)
          }

          ListItem() {
            Column() {
              this.sectionCard('杂项', '')
            }
            .width('100%')
            .padding({ top: Space.SECTION })
          }

          ListItem() {
            Column() {
              SelectRow({
                label: '测速方式',
                labels: TESTMODE_LABELS,
                values: TESTMODE_VALUES,
                current: this.s.latencyTestMode,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.latencyTestMode = value;
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '测速地址',
                labels: ['gstatic generate_204', 'cloudflare trace', 'baidu'],
                values: ['https://www.gstatic.com/generate_204', 'https://cp.cloudflare.com/',
                      'https://www.baidu.com/robots.txt'],
                current: this.s.testUrl,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.testUrl = value;
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '超时',
                labels: ['2000 ms', '5000 ms', '10000 ms'],
                values: ['2000', '5000', '10000'],
                current: `${this.s.testTimeoutMs}`,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.testTimeoutMs = Number(value);
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '并发',
                labels: ['1', '3', '5', '8', '10'],
                values: ['1', '3', '5', '8', '10'],
                current: `${this.s.testConcurrent}`,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.testConcurrent = Number(value);
                      });
                }
              })
              ToggleRow({
                label: '测速绕过隧道',
                summary: '',
                checked: this.s.testBypassTunnel,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.testBypassTunnel = on;
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              // 以下六项照 global_preferences.xml 的「杂项」分组（enableClashAPI / 连接重置 / 不安全 TLS）
              ToggleRow({
                label: '启用 Clash API',
                summary: '',
                checked: this.s.clashApiEnabled,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.clashApiEnabled = on;
                  });
                }
              })
              if (this.s.clashApiEnabled) {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                SelectRow({
                label: 'Clash API 端口',
                labels: ['19290', '9090', '9097', '6170'],
                values: ['19290', '9090', '9097', '6170'],
                current: `${this.s.clashApiPort}`,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                        this.app.patchSettings((s) => {
                          s.clashApiPort = Number(value);
                        }).then(() => {
                          this.toast('已保存，重新连接后生效');
                        });
                }
              })
              }
              ToggleRow({
                label: '网络变化时重置连接',
                summary: '',
                checked: this.s.networkChangeResetConnections,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.networkChangeResetConnections = on;
                  });
                }
              })
              ToggleRow({
                label: '回到前台时重置连接',
                summary: '',
                checked: this.s.wakeResetConnections,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.wakeResetConnections = on;
                  });
                }
              })
              ToggleRow({
                label: '全局放行不安全 TLS',
                summary: '',
                checked: this.s.allowInsecureAll,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.allowInsecureAll = on;
                  });
                }
              })
              ToggleRow({
                label: '订阅请求放行不安全 TLS',
                summary: '',
                checked: this.s.subAllowInsecure,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.subAllowInsecure = on;
                  });
                }
              })
            }
            .width('100%')
            .borderRadius(18)
            .backgroundColor(Theme.SURFACE)
          }

          ListItem() {
            Column() {
              this.sectionCard('外观', '')
            }
            .width('100%')
            .padding({ top: Space.SECTION })
          }

          ListItem() {
            Column() {
              SelectRow({
                label: '深浅色',
                labels: APPEARANCE_LABELS,
                values: APPEARANCE_VALUES,
                current: this.s.appearance,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.appearance = value;
                      }).then(() => {
                        /* ★ 只存偏好不会换肤：真正生效要靠 Context.setColorMode。
                           之前这一步只在 EntryAbility 的生命周期里做，所以在设置页改完要"重启才看到"。
                           这里直接下发；配置变更回调里 EntryAbility 会同步窗口底色与系统栏。 */
                        const ctx: common.UIAbilityContext | undefined = this.app.uicontext();
                        if (ctx !== undefined) {
                          const mode: ConfigurationConstant.ColorMode = value === 'dark'
                            ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                            : (value === 'light'
                              ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                              : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
                          ctx.setColorMode(mode);
                        }
                        this.toast('主题已切换');
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '光感强度',
                labels: LEVEL_LABELS,
                values: ['0', '1', '2', '3'],
                current: `${this.s.lightLevel}`,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.lightLevel = Number(value);
                      });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              // 主题色：一排预置色点（参考 RzdMusic 设置页），点哪个立刻换强调色
              this.themeColorRow()
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              // 智感握姿总开关：关掉就退订系统服务、布局固定右手侧（省电 + 不跟着手乱换边）
              ToggleRow({
                label: '智感握姿',
                summary: '',
                checked: this.s.handAwareness,
                onToggle: (on: boolean) => {
                  this.app.setHandAwareness(on).catch((e: Error) => {
                    this.toast(`切换失败：${e.message}`);
                  });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              SelectRow({
                label: '节点排序',
                labels: SORT_LABELS,
                values: SORT_VALUES,
                current: this.s.profileSortMode,
                lightLevel: this.s.lightLevel,
                onPick: (value: string) => {
                      this.app.patchSettings((s) => {
                        s.profileSortMode = value;
                      });
                }
              })
              ToggleRow({
                label: '触感反馈',
                summary: '操作时轻微振动',
                checked: this.s.hapticFeedback,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.hapticFeedback = on;
                  });
                }
              })
              ToggleRow({
                label: '始终显示服务器地址',
                summary: '',
                checked: this.s.alwaysShowAddress,
                onToggle: (on: boolean) => {
                  this.app.patchSettings((s: AppSettings) => {
                    s.alwaysShowAddress = on;
                  });
                }
              })
            }
            .width('100%')
            .borderRadius(18)
            .backgroundColor(Theme.SURFACE)
          }

          ListItem() {
            Column() {
              this.sectionCard('路由数据', '')
            }
            .width('100%')
            .padding({ top: Space.SECTION })
          }

          ListItem() {
            Column() {
              ForEach(this.geoInfo, (info: GeoAssetInfo) => {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(info.kind === 'site' ? 'GeoSite 库' : 'GeoIP 库')
                      .fontSize(14)
                      .fontColor(Theme.TEXT_1)
                    Text(info.size > 0 ? `${bytesText(info.size)} · ${info.version}` : '未下载')
                      .fontSize(11)
                      .fontColor(info.size > 0 ? Theme.TEXT_3 : Theme.WARN)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  OutlineButton({
                    label: info.size > 0 ? '更新' : '下载',
                    buttonHeight: 28,
                    onTap: () => {
                      this.busyText = '正在下载 Geo 数据…';
                      this.app.downloadGeo(info.kind).then((message: string) => {
                        this.busyText = '';
                        this.toast(message);
                        this.refreshGeo();
                      }).catch((e: Error) => {
                        this.busyText = '';
                        this.toast(`下载失败：${e.message}`);
                      });
                    }
                  })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              }, (info: GeoAssetInfo) => `geo_${info.kind}_${info.size}_${info.version}`)
              if (this.busyText.length > 0) {
                Text(this.busyText)
                  .fontSize(12)
                  .fontColor(Theme.BRAND)
                  .padding({ left: 16, bottom: 10 })
              }
            }
            .width('100%')
            .borderRadius(18)
            .backgroundColor(Theme.SURFACE)
          }

          ListItem() {
            Column() {
              this.sectionCard('其他', '')
            }
            .width('100%')
            .padding({ top: Space.SECTION })
          }

          ListItem() {
            Column() {
              FormRow({
                label: '运行日志',
                value: '',
                placeholder: '',
                onTap: () => {
                  this.app.pendingSection = SEC_LOGS;
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              FormRow({
                label: '备份到剪贴板',
                value: '',
                placeholder: '',
                onTap: () => {
                  this.backupToClipboard();
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              Row() {
                Text('从剪贴板恢复')
                  .fontSize(15)
                  .fontColor(Theme.TEXT_1)
                  .layoutWeight(1)
                // 安全控件：点一下临时授权，之后才读得到剪贴板（不再申请 READ_PASTEBOARD）
                PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
                  .fontSize(13)
                  .constraintSize({ minWidth: 84, maxWidth: 108, minHeight: 34, maxHeight: 40 })
                  .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                    if (result === PasteButtonOnClickResult.SUCCESS) {
                      this.restoreFromClipboard();
                    } else {
                      this.toast('没拿到剪贴板授权');
                    }
                  })
              }
              .width('100%')
              .constraintSize({ minHeight: 52 })
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              FormRow({
                label: '导出全部节点',
                value: '',
                placeholder: '',
                onTap: () => {
                  this.exportAllLinks();
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              FormRow({
                label: '关于',
                value: '',
                placeholder: '',
                onTap: () => {
                  this.app.pendingSection = SEC_ABOUT;
                }
              })
            }
            .width('100%')
            .borderRadius(18)
            .backgroundColor(Theme.SURFACE)
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
    .bindSheet(this.pickOpen!!, this.pickSheet(), {
      // API 26：面板统一走系统沉浸材质（菜单同一套玻璃），设备不支持时系统自动忽略
      systemMaterial: immersiveMedium(),
      height: 420,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.BG,
      preferType: SheetType.BOTTOM,
      onDisappear: () => {
        this.pickOpen = false;
      }
    })
  }

  @Builder
  private pickSheet() {
    this.textPanel()
  }

  /** 文本面板（应用包名列表这类多行输入；与选项面板共用一个 bindSheet） */
  @Builder
  private textPanel() {
    Column({ space: 10 }) {
      Text(this.textTitle)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
        .width('100%')
      Text('多个包名用逗号或换行分隔')
        .fontSize(11)
        .fontColor(Theme.TEXT_3)
        .width('100%')
      TextArea({ text: this.textValue, placeholder: 'com.example.app' })
        .height(150)
        .fontSize(13)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(12)
        .onChange((v: string) => {
          this.textValue = v;
        })
      Row({ space: 10 }) {
        GlowButton({
          label: '取消',
          grow: true,
          buttonColor: Theme.SURFACE_2,
          labelColor: Theme.TEXT_1,
          onTap: () => {
            this.pickOpen = false;
          }
        })
        GlowButton({
          label: '保存',
          grow: true,
          onTap: () => {
            this.textAction(this.textValue);
            this.pickOpen = false;
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, top: 20, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  private openTextSheet(title: string, value: string, onSave: (value: string) => void): void {
    this.textTitle = title;
    this.textValue = value;
    this.textAction = onSave;
    this.pickOpen = true;
  }


  private async backupToClipboard(): Promise<void> {
    const ctx = this.app.uicontext();
    if (ctx === undefined) {
      return;
    }
    try {
      const json: string = await exportBackup(ctx);
      await setClipboardText(json);
      this.toast('备份已复制到剪贴板');
    } catch (e) {
      this.toast(`备份失败：${(e as Error).message}`);
    }
  }

  private async restoreFromClipboard(): Promise<void> {
    const ctx = this.app.uicontext();
    if (ctx === undefined) {
      return;
    }
    try {
      const text: string = await getClipboardText();
      if (text.trim().length === 0) {
        this.toast('剪贴板为空');
        return;
      }
      const result: BackupRestoreResult = await importBackup(ctx, text);
      await this.app.reloadData();
      this.toast(`已恢复 ${result.profiles} 个节点 / ${result.subscriptions} 个订阅`);
    } catch (e) {
      this.toast(`恢复失败：${(e as Error).message}`);
    }
  }

  private async exportAllLinks(): Promise<void> {
    if (this.app.profiles.length === 0) {
      this.toast('没有可导出的节点');
      return;
    }
    const lines: Array<string> = [];
    for (const p of this.app.profiles) {
      const link: string = exportProfileLink(p);
      if (link.length > 0) {
        lines.push(link);
      }
    }
    if (lines.length === 0) {
      this.toast('当前节点协议都不支持导出');
      return;
    }
    try {
      await setClipboardText(lines.join('\n'));
      this.toast(`已复制 ${lines.length} 条链接`);
    } catch (e) {
      this.toast(`复制失败：${(e as Error).message}`);
    }
  }

  build() {
    this.pageRoot()
  }
}

/** 颜色比较：忽略大小写（配置里存的是大写十六进制） */
function isSameColor(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}
