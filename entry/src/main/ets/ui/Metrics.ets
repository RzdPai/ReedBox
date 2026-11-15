import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Metrics';

/**
 * 让位尺寸的**运行时实测**（不再靠猜常量）。
 *
 * 为什么必须有它：HDS 标题栏在不同容器里的几何不一样（页签页 vs push 进来的二级页），
 * 写死 56/94 总有一边错；浮动胶囊底栏到屏幕底占多高也只有量了才知道。
 * 做法：启动时量一次系统避让区（状态栏 / 手势条 / 屏幕高），据此推算三类让位；
 * 页面一律读这里的 `@Trace` 字段（量完自动重绘）。
 */
@ObservedV2
export class Metrics {
  private static instance: Metrics = new Metrics();

  /**
   * 页签页 / 二级页统一的内容顶部让位（vp）= 状态栏 + HDS 标题栏 56 ≈ 94。
   * 口径：标题栏用 `avoidLayoutSafeArea: true` 时，标题/按钮退到状态栏下方（38..94），
   *      内容让 94 正好接在标题下沿（详见 `CommonUi.hdsPageBar` 函数头）。
   */
  @Trace topInset: number = 94;
  /**
   * 二级页（push 进来的 HdsNavDestination）内容顶部让位。
   * 与页签页同值 94：二级页的顶栏基座自带一个状态栏，`avoidLayoutSafeArea=false` 时
   * 顶栏同样落在 38..94，内容让 94 才接得上下沿（给 56 会被顶栏压住半截）。
   */
  @Trace detailTopInset: number = 94;
  /** 列表底部留白 = 浮动胶囊 56 + 离底 16 + 呼吸 16 ≈ 88；只加在滚动内容自己的 padding 上 */
  @Trace bottomInset: number = 88;
  /** 系统栏实测完成 */
  @Trace ready: boolean = false;
  /** 诊断用：状态栏 / 手势条 / 屏幕高（vp） */
  @Trace statusBar: number = 38;
  @Trace navBottom: number = 24;
  @Trace screenH: number = 0;

  static get(): Metrics {
    return Metrics.instance;
  }

  /** 启动时量一次系统栏（幂等） */
  init(ctx: UIContext): void {
    if (this.ready) {
      return;
    }
    try {
      const host: Context | undefined = ctx.getHostContext();
      if (host === undefined) {
        hilog.warn(DOMAIN, TAG, 'init: no host context');
        return;
      }
      window.getLastWindow(host).then((win: window.Window) => {
        try {
          const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          const topVp: number = ctx.px2vp(sys.topRect.height);
          const navVpRaw: number = ctx.px2vp(nav.bottomRect.height);
          const navVp: number = navVpRaw > 4 ? navVpRaw : 24;
          this.statusBar = topVp > 0 ? topVp : 38;
          this.navBottom = navVp;
          this.topInset = this.statusBar + 56;
          this.detailTopInset = this.topInset;
          this.bottomInset = 56 + 16 + 16;
          try {
            this.screenH = ctx.px2vp(display.getDefaultDisplaySync().height);
          } catch (e) {
            this.screenH = 0;
          }
          this.ready = true;
          hilog.info(DOMAIN, TAG, 'insets statusBar=%{public}f nav=%{public}f screenH=%{public}f top=%{public}f',
            topVp, navVp, this.screenH, this.topInset);
        } catch (e2) {
          hilog.warn(DOMAIN, TAG, 'avoid area failed: %{public}s', (e2 as Error).message);
        }
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'init failed: %{public}s', (e as Error).message);
    }
  }
}
