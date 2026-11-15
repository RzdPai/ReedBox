import { hilog } from '@kit.PerformanceAnalysisKit';
import bundleManager from '@ohos.bundle.bundleManager';
import common from '@ohos.app.ability.common';
import { AppState } from '../../core/AppState';
import { setClipboardText } from '../../utils/ClipboardHelper';
import { PageHeader } from '../CommonUi';
import { Space, Theme } from '../Theme';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-About';
const PROJECT_REPO: string = 'https://github.com/RzdPai/ReedBox';
const UPSTREAM_REPO: string = 'https://github.com/MatsuriDayo/NekoBoxForAndroid';
const KERNEL_VERSION: string = 'sing-box 1.14.0';

/**
 * 关于页：照 `AboutFragment.AboutContent` 的条目组织（`layout_about.xml` + 那串 Preference）。
 *
 * 原版条目：应用版本 / 检查更新（正式、预览）/ sing-box 版本 / 捐赠 / 忽略电池优化 /
 * 项目（GitHub、Telegram）/ 作者 / 许可协议。
 * 本仓去掉 Android 专属项（忽略电池优化、捐赠、作者墙），把更新检查如实标为未接入，
 * 链接改为复制到剪贴板（不擅自拉起浏览器）。
 */
@ComponentV2
export struct AboutPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Event onDrawer: () => void = (): void => {
  };
  @Local app: AppState = AppState.get();
  @Local version: string = '';
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.version = this.readVersion();
  }

  private readVersion(): string {
    const ctx: common.UIAbilityContext | undefined = this.app.uicontext();
    if (ctx === undefined) {
      return '';
    }
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return `${info.versionName} (${info.versionCode})`;
    } catch (e) {
      return '';
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }

  private copy(text: string, what: string): void {
    setClipboardText(text).then(() => {
      this.toast(`${what}已复制`);
    }).catch((e: Error) => {
      this.toast(`复制失败：${e.message}`);
    });
  }

  /** 一行「标题 + 副标题 + 右侧值」（对应原版 Preference 的 title / summary / summaryProvider） */
  @Builder
  private itemRow(title: string, summary: string, value: string, onClick: () => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.TEXT_1)
        if (summary.length > 0) {
          Text(summary)
            .fontSize(11)
            .fontColor(Theme.TEXT_3)
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (value.length > 0) {
        Text(value)
          .fontSize(13)
          .fontColor(Theme.TEXT_3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.TEXT_3])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      onClick();
    })
  }

  @Builder
  private pageRoot() {
    Column() {
      PageHeader({
        title: '关于',
        subtitle: this.version.length > 0 ? `v${this.version}` : '',
        onDrawer: () => {
          this.onDrawer();
        }
      })
      Scroll(this.scroller) {
        Column({ space: 10 }) {
          Column({ space: 8 }) {
            // 应用图标（就是桌面那张），别再画一个符号图标
            Image($r('app.media.icon'))
              .width(72)
              .height(72)
              .borderRadius(20)
              .objectFit(ImageFit.Cover)
              .alt($r('app.media.icon'))

            Text('ReedBox for HarmonyOS')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_1)
            Text('sing-box · 单进程 c-shared')
              .fontSize(12)
              .fontColor(Theme.TEXT_3)
          }
          .width('100%')
          .padding({ top: 20, bottom: 12 })
          .alignItems(HorizontalAlign.Center)

          Column() {
            this.itemRow('版本', '', this.version.length > 0 ? this.version : '0.5.x', () => {
              this.copy(this.version, '版本号');
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.itemRow('sing-box', '', KERNEL_VERSION, () => {
              this.toast('内核随 HAP 分发');
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.itemRow('检查更新（正式版）', '本仓尚未接入更新检查', '', () => {
              this.toast('暂未接入更新检查');
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.itemRow('检查更新（预览版）', '本仓尚未接入更新检查', '', () => {
              this.toast('暂未接入更新检查');
            })
          }
          .width('100%')
          .borderRadius(18)
          .backgroundColor(Theme.SURFACE)

          Column() {
            this.itemRow('项目地址', PROJECT_REPO, '', () => {
              this.copy(PROJECT_REPO, '仓库地址');
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.itemRow('上游项目', UPSTREAM_REPO, '', () => {
              this.copy(UPSTREAM_REPO, '仓库地址');
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.itemRow('许可协议', '', 'GPL-3.0', () => {
              this.toast('GPL-3.0：修改与再分发需遵循同一协议');
            })
          }
          .width('100%')
          .borderRadius(18)
          .backgroundColor(Theme.SURFACE)

          Column() {
            this.itemRow('节点协议', '导入 / 手填支持的协议', '13 种', () => {
              this.toast('SS / VMess / VLESS / Trojan / Hysteria2 / TUIC / WireGuard / SOCKS / HTTP / SSH / '
                + 'ShadowTLS / AnyTLS / Snell');
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.itemRow('路由说明', '', '', () => {
              this.toast('订阅只贡献节点，路由由分流页决定');
            })
          }
          .width('100%')
          .borderRadius(18)
          .backgroundColor(Theme.SURFACE)

          Text('个人项目 · 内核与协议解析沿用上游')
            .fontSize(11)
            .fontColor(Theme.TEXT_3)
            .width('100%')
            .padding({ top: 4 })
        }
        .width('100%')
        .padding({ left: Space.PAGE, right: Space.PAGE, top: 4, bottom: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  build() {
    this.pageRoot()
  }
}
