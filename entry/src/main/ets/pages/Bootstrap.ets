import { HdsNavigation } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../core/AppState';
import { HAND_RIGHT, Handedness } from '../core/Handedness';
import { Metrics } from '../ui/Metrics';
import { Theme } from '../ui/Theme';
import { PAGE_PROFILE_EDIT, SEC_ABOUT, SEC_GROUPS, SEC_LOGS, SEC_PROFILES, SEC_ROUTE, SEC_SETTINGS } from '../ui/Routes';
import { ProfilesPage } from '../ui/neko/ProfilesPage';
import { GroupsPage } from '../ui/neko/GroupsPage';
import { ProfileEditPage } from '../ui/neko/ProfileEditPage';
import { RouteTab } from '../ui/neko/RouteTab';
import { SettingsTab } from '../ui/neko/SettingsTab';
import { LogsPage } from '../ui/neko/LogsPage';
import { AboutPage } from '../ui/neko/AboutPage';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Shell';

class DrawerItem {
  label: string = '';
  symbol: Resource = $r('sys.symbol.house');
  section: number = 0;

  constructor(label: string, symbol: Resource, section: number) {
    this.label = label;
    this.symbol = symbol;
    this.section = section;
  }
}

/**
 * 应用外壳：**侧栏 + 单页内容**，对齐 NekoBoxForAndroid / OwnBox 的信息结构。
 *
 * ★ 六个分区**全部在壳里直接切换**（甲方 2026-11-01："有推页的是二级页，把这套重构掉"）：
 *   路由/设置/日志/关于不再是 NavDestination 压栈页，而是和配置项/分组一样的 in-flow 页面，
 *   各自用自绘 `PageHeader`（☰ + 标题）。只有**节点编辑**这类详情页才压栈（`pagesMap`）。
 * ★ 平板/大屏：侧栏**常驻固定在左侧**（`isWide()`），手机才用抽屉 + 遮罩。
 */
@Entry
@ComponentV2
struct Bootstrap {
  @Local app: AppState = AppState.get();
  @Local section: number = SEC_PROFILES;
  @Local drawerOpen: boolean = false;
  @Local topSignal: number = 0;
  @Local handedness: Handedness = Handedness.get();
  /** 抽屉浮层实测宽度（换手时算平移量） */
  @Local overlayWidth: number = 0;
  private pathStack: NavPathStack = new NavPathStack();

  private readonly items: Array<DrawerItem> = [
    new DrawerItem('配置项', $r('sys.symbol.list_bullet'), SEC_PROFILES),
    new DrawerItem('分组', $r('sys.symbol.list_square'), SEC_GROUPS),
    new DrawerItem('路由', $r('sys.symbol.arrow_left_arrow_right'), SEC_ROUTE),
    new DrawerItem('设置', $r('sys.symbol.gearshape'), SEC_SETTINGS),
    new DrawerItem('日志', $r('sys.symbol.doc_text'), SEC_LOGS),
    new DrawerItem('关于', $r('sys.symbol.info_circle'), SEC_ABOUT)
  ];

  aboutToAppear(): void {
    Metrics.get().init(this.getUIContext());
    // 智感握姿：延后一帧订阅（见 core/Handedness.ets 头注释），失败不影响首帧
    this.handedness.start();
    this.app.ensureInit().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', e.message);
    });
  }

  /**
   * 平板/大屏：侧栏常驻左侧，不走抽屉。
   * ⚠️ 判据是**短边 ≥600vp**（平板级），不是 `breakpoint !== 'compact'`：
   * 手机横屏 780×360vp 的宽度落在 medium，但短边只有 360 ⇒ 手机仍应走抽屉。
   * （`AppState.shortSide` 由 EntryAbility 用 **vp** 算出来；曾经拿 px 比断点，1224px 手机被当成 large。）
   */
  private isWide(): boolean {
    return this.app.shortSide >= 600;
  }

  /** 侧栏宽度：手机 268 / 平板 300 / 大屏 320（原来 82% 在手机上≈295 太宽） */
  private drawerWidth(): number {
    const breakpoint: string = this.app.breakpoint;
    if (breakpoint === 'large') {
      return 320;
    }
    if (breakpoint === 'medium') {
      return 300;
    }
    return 268;
  }

  /** 平板/大屏把内容收成居中的一列，避免列表横向拉满 */
  private contentMaxWidth(): Length {
    const breakpoint: string = this.app.breakpoint;
    if (breakpoint === 'large') {
      return 760;
    }
    if (breakpoint === 'medium') {
      return 640;
    }
    return '100%';
  }

  /** 手机上才打开抽屉；平板上侧栏已常驻，☰ 不再弹层 */
  private openDrawer(): void {
    if (this.isWide()) {
      return;
    }
    this.drawerOpen = true;
  }

  @Monitor('app.pendingSection')
  onPendingSection(): void {
    const target: number = this.app.pendingSection;
    if (target < 0) {
      return;
    }
    this.app.pendingSection = -1;
    this.selectSection(target);
  }

  /** 只有详情页（节点编辑）压栈；六个分区都在壳里直接换 */
  @Builder
  pagesMap(name: string) {
    if (name === PAGE_PROFILE_EDIT) {
      ProfileEditPage({ pathStack: this.pathStack })
    }
  }

  private selectSection(target: number): void {
    this.drawerOpen = false;
    if (target === this.section) {
      // 重复点同一分区：滚回顶部
      this.topSignal++;
      return;
    }
    this.section = target;
    this.topSignal++;
    hilog.info(DOMAIN, TAG, 'section=%{public}d', target);
  }

  @Builder
  private sectionContent() {
    if (this.section === SEC_GROUPS) {
      GroupsPage({
        pathStack: this.pathStack,
        topSignal: this.topSignal,
        onDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.section === SEC_ROUTE) {
      RouteTab({
        pathStack: this.pathStack,
        topSignal: this.topSignal,
        onDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.section === SEC_SETTINGS) {
      SettingsTab({
        pathStack: this.pathStack,
        onDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.section === SEC_LOGS) {
      LogsPage({
        pathStack: this.pathStack,
        onDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.section === SEC_ABOUT) {
      AboutPage({
        pathStack: this.pathStack,
        onDrawer: () => {
          this.openDrawer();
        }
      })
    } else {
      ProfilesPage({
        pathStack: this.pathStack,
        onDrawer: () => {
          this.openDrawer();
        }
      })
    }
  }

  @Builder
  private drawerPanel() {
    Column() {
      Column({ space: 6 }) {
        // 侧栏头部就用应用图标（与桌面/关于页同一张）
        Image($r('app.media.icon'))
          .width(46)
          .height(46)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.icon'))

        Text('ReedBox')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
        Text(`${this.app.profiles.length} 个配置 · ${this.app.groups.length} 个分组`)
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 20, top: Metrics.get().statusBar + 18, bottom: 18 })

      ForEach(this.items, (item: DrawerItem) => {
        Row({ space: 12 }) {
          SymbolGlyph(item.symbol)
            .fontSize(19)
            .fontColor([this.section === item.section ? Theme.BRAND : Theme.TEXT_2])
          Text(item.label)
            .fontSize(15)
            .fontWeight(this.section === item.section ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.section === item.section ? Theme.BRAND : Theme.TEXT_1)
        }
        .width('100%')
        .height(48)
        .padding({ left: 20, right: 20 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.section === item.section ? Theme.BRAND_SOFT : Color.Transparent)
        .onClick(() => {
          this.selectSection(item.section);
        })
      }, (item: DrawerItem) => `drawer_${item.section}_${this.section === item.section}`)

      Blank()

      Text('sing-box · arm64')
        .fontSize(10)
        .fontColor(Theme.TEXT_3)
        .width('100%')
        .padding({ left: 20, bottom: 16 })
    }
    .width(this.drawerWidth())
    .height('100%')
    .backgroundColor(Theme.SURFACE)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 手机：抽屉盖在内容上（带遮罩 + 位移过渡） */
  /** 抽屉从**交互手那一侧**滑出（右手 ⇒ 右侧；左手/未识别 ⇒ 左侧） */
  private drawerAtRight(): boolean {
    return this.handedness.uiSide === HAND_RIGHT;
  }

  @Builder
  private drawerOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.drawerOpen = false;
        })
      Column() {
        this.drawerPanel()
      }
      .height('100%')
      // 换手时侧栏**平移**到另一侧（不是瞬间换位）
      .translate({ x: this.drawerAtRight() ? this.overlayWidth - this.drawerWidth() : 0 })
      .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      .shadow({ radius: 20, color: '#33000000' })
      .transition(TransitionEffect.move(this.drawerAtRight() ? TransitionEdge.END : TransitionEdge.START)
        .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.overlayWidth = Number(newValue.width);
    })
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 顶部让位（vp）= **实测**状态栏高（RzdMusic "状态栏三件套" 的第 2 件）。
   * 窗口开了全屏布局、页面根又 ignore 了 TOP ⇒ 盒子从屏幕 y=0 起排，这里补一个状态栏高，
   * 自绘页头正好落在状态栏下沿；**只补一次**（盒子已经让开的状态下再补就会多出 38vp 白条）。
   */
  private topInset(): number {
    const bar: number = Metrics.get().statusBar;
    return bar > 24 ? bar : 24;
  }

  @Builder
  private contentColumn() {
    Row() {
      Column() {
        this.sectionContent()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: this.contentMaxWidth() })
      .padding({ top: this.topInset() })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.BG)
    // 绘制也铺进系统栏：状态栏/手势条那两条显示的是页面底色，不是窗口底色
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  build() {
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.isWide()) {
          // 平板/大屏：侧栏常驻左侧
          Row() {
            this.drawerPanel()
            Column() {
              this.contentColumn()
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.BG)
        } else {
          this.contentColumn()
        }

        if (this.drawerOpen) {
          this.drawerOverlay()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .navDestination(this.pagesMap)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
    /* ★ 页面根 = 屏幕整窗（RzdMusic "状态栏三件套" 第 1 件）：
       `expandSafeArea` 只扩绘制；`ignoreLayoutSafeArea` 扩布局，而且 **TOP/BOTTOM 都要给** ——
       只给 BOTTOM 时盒子自己已经让开状态栏，再叠内容列的 `padding-top` 就会多出一条 38vp 白带
       （RzdMusic `LocalMusicView` 注释里专门记过这个坑）。
       顶部让位由 `contentColumn()` 的 `padding-top = 实测状态栏高` 承担；
       底部不再加任何留白 ⇒ 列表/卡片一直铺到屏幕物理底（手势条压在上面）。 */
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
