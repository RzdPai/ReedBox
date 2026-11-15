/**
 * 主题色（品牌强调色）单例。
 *
 * 为什么要单独一个单例：`Theme.BRAND` 以前是 `$r('app.color.primary')` 这种静态资源，
 * 资源值编译期就定死了，运行期换不了。把强调色挪到 `@ObservedV2` 的 `@Trace` 字段之后，
 * `Theme.BRAND` 改成 getter 读它 ⇒ 设置里一点，所有用到强调色的节点一起变（V2 细粒度刷新）。
 *
 * 取值口径：`AppSettings.themeColor`（空串 = 用默认蓝）；启动时由 `AppState` 回填。
 */
@ObservedV2
export class Accent {
  private static instance: Accent | undefined = undefined;

  /** 默认蓝：与 `resources/base/element/color.json` 的 `primary` 一致 */
  static readonly DEFAULT: string = '#2364D8';
  /** 深色模式默认蓝：与 `resources/dark/element/color.json` 的 `primary` 一致 */
  static readonly DEFAULT_DARK: string = '#6EA1FF';
  /** 预置主题色（设置页那一排圆点，参考 RzdMusic） */
  static readonly PRESETS: Array<string> = [
    '#2364D8', '#0A84FF', '#00A3A3', '#1F9D55', '#C42B1C', '#B26A00', '#7B4DFF', '#D6336C'
  ];

  /** 当前强调色（`#RRGGBB`） */
  @Trace color: string = Accent.DEFAULT;

  static get(): Accent {
    if (Accent.instance === undefined) {
      Accent.instance = new Accent();
    }
    return Accent.instance;
  }

  /** 空串 ⇒ 回默认色（深色模式用深色底那支蓝，保证对深底有足够对比度） */
  apply(color: string, dark: boolean): void {
    const fallback: string = dark ? Accent.DEFAULT_DARK : Accent.DEFAULT;
    const next: string = color.length > 0 ? color : fallback;
    if (next !== this.color) {
      this.color = next;
    }
  }

  /** 12% 透明度的同色浅底（卡片选中态/标签底色用） */
  soft(): string {
    return `${this.color}1F`;
  }
}
