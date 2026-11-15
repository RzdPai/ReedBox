import { Accent } from './Accent';

/**
 * NekoBox for HarmonyOS · 主题 token（唯一颜色出处）
 *
 * 规则：页面里不写十六进制色值，一律从这里取 `app.color.*`；
 * `resources/base/element/color.json` 与 `resources/dark/element/color.json` 同名同键，
 * 深浅色切换由系统资源自动完成。**强调色（BRAND）例外**：它运行期可换（设置 → 主题色），
 * 走 `Accent` 单例的 getter，颜色本身存在 `AppSettings.themeColor`。
 */
export class Theme {
  /** 页面底色 */
  static readonly BG: Resource = $r('app.color.bg_page');
  /** 卡片 */
  static readonly SURFACE: Resource = $r('app.color.surface');
  /** 次级卡片 / 内嵌块 */
  static readonly SURFACE_2: Resource = $r('app.color.surface_2');
  /** 正文字色（三级） */
  static readonly TEXT_1: Resource = $r('app.color.text_1');
  static readonly TEXT_2: Resource = $r('app.color.text_2');
  static readonly TEXT_3: Resource = $r('app.color.text_3');
  /** 分隔线 */
  static readonly HAIRLINE: Resource = $r('app.color.hairline');
  /**
   * 品牌色（强调色）：**运行期可取**（设置 → 主题色）。
   * getter 读 `Accent` 的 `@Trace color`，在 build 里读它会建立依赖 ⇒ 换色所有用到的地方一起变。
   */
  static get BRAND(): ResourceColor {
    return Accent.get().color;
  }
  static readonly BRAND_PRESSED: Resource = $r('app.color.primary_pressed');
  /**
   * 选中态浅底：**中性灰**（甲方 2026-11-01："选中节点 / 侧栏怎么是屎绿色，这种地方直接用灰色"）。
   * 曾经用"强调色 12% 透明"，但 ArkUI 的 8 位色串是 **#AARRGGBB（阿尔法在前）**，
   * 我写成 #RRGGBBAA 被解析成深绿 ⇒ 整片发绿。这里直接用资源里的灰，跟着主题色也不该染。
   */
  static readonly BRAND_SOFT: Resource = $r('app.color.brand_soft');
  /** 品牌色上的前景色 */
  static readonly ON_BRAND: Resource = $r('app.color.on_brand');
  /** 状态色 */
  static readonly OK: Resource = $r('app.color.dot_live');
  static readonly OK_SOFT: Resource = $r('app.color.ok_soft');
  static readonly WARN: Resource = $r('app.color.warning');
  static readonly WARN_SOFT: Resource = $r('app.color.warn_soft');
  static readonly DANGER: Resource = $r('app.color.error');
  static readonly DANGER_SOFT: Resource = $r('app.color.danger_soft');
  /** 速率 */
  static readonly SPEED_UP: Resource = $r('app.color.speed_up');
  static readonly SPEED_DOWN: Resource = $r('app.color.speed_down');
  /** 首页 hero 渐变（neko: 紫→蓝；modern: 蓝→青，见 accentOf） */
  static readonly HERO_FROM: Resource = $r('app.color.hero_from');
  static readonly HERO_TO: Resource = $r('app.color.hero_to');
  static readonly HERO_INK: Resource = $r('app.color.hero_ink');
  static readonly HERO_INK_SUB: Resource = $r('app.color.hero_ink_sub');
  /** 悬浮按钮 */
  static readonly FAB: Resource = $r('app.color.fab_bg');
  static readonly FAB_RUNNING: Resource = $r('app.color.fab_running');

  /** 强调色：统一走运行期主题色（皮肤差异已去掉） */
  static accentOf(skin: string): ResourceColor {
    return Theme.BRAND;
  }

  /** 强调色的浅底 */
  static accentSoftOf(skin: string): ResourceColor {
    return Theme.BRAND_SOFT;
  }
}

/** 统一圆角 */
export class Radius {
  static readonly CARD: number = 18;
  static readonly TILE: number = 14;
  static readonly CHIP: number = 16;
  static readonly SHEET: number = 24;
}

/** 统一间距 */
export class Space {
  static readonly PAGE: number = 16;
  static readonly CARD_GAP: number = 12;
  static readonly ROW: number = 12;
  static readonly SECTION: number = 22;
}
