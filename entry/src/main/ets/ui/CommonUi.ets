import { ColorMetrics, LengthMetrics } from '@ohos.arkui.node';
import {
  CapsuleSegmentButtonV2,
  SegmentButtonV2ItemOptions,
  SegmentButtonV2Items
} from '@ohos.arkui.advanced.SegmentButtonV2';
import {
  BlurStrategy,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleBarOptions,
  ScrollEffectType,
  TitleBarContentOptions,
  TitleSize,
  hdsEffect,
  hdsMaterial
} from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ComponentContent, UIContext } from '@kit.ArkUI';
import { Radius, Space, Theme } from './Theme';
import { HdsSelectMenuMaterial, immersiveMedium } from './SelectMaterial';
import { HAND_RIGHT, Handedness } from '../core/Handedness';

const DOMAIN: number = 0x4e4b;
const MENU_TAG: string = 'NekoBox-Menu';

/** HDS 标题栏本体高度（vp） */
export const TITLE_BAR_HEIGHT: number = 56;
/** 自绘页头高度（抽屉壳层用；与 HDS 标题栏同高，视觉一致） */
export const HEADER_HEIGHT: number = 56;

/**
 * 页头（抽屉壳层版）：`☰ + 标题(+副标题) + 右侧最多三颗动作`。
 *
 * 对齐原版 OwnBox 的首页头部：`☰  OwnBox        🔍  ＋  ⋮`
 * 为什么自绘而不挂 HDS 标题栏：本工程是"侧栏 + 单页内容"，页头右侧的 ⋮ 需要一个**稳定的菜单锚点 id**；
 * 自绘页头在流内、几何完全可控，不必再和 HDS 标题栏的 overlay / 安全区行为较劲
 * （上一代工程为此反复 5 轮）。图标按钮走 `onTouch` 的 Up，避免某些容器里 onClick 不回调。
 */
/** 页头图标按钮（裸图标 + 40vp 点击区，按下有底色反馈；菜单锚点 id 挂在根节点上） */
@ComponentV2
export struct HeaderIconButton {
  @Param symbol: Resource = $r('sys.symbol.plus');
  @Param anchorId: string = '';
  @Event onTap: () => void = (): void => {
  };
  @Local pressed: boolean = false;

  build() {
    Row() {
      SymbolGlyph(this.symbol)
        .fontSize(21)
        .fontColor([Theme.TEXT_1])
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.pressed ? Theme.SURFACE_2 : Color.Transparent)
    .id(this.anchorId)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up) {
        this.pressed = false;
        this.onTap();
      } else if (event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

/** 页头几何常量（vp）：图标点击区 / 图标组内间距 / 图标层左右边距 */
const HDR_ICON_SIZE: number = 40;
const HDR_ICON_GAP: number = 6;
const HDR_EDGE: number = Space.PAGE - 4;
/** 标题层左右让位 = 边距 + ☰ 点击区 + 间隔（换手后左右对称，两边都留这么多） */
const HDR_TITLE_INSET: number = HDR_EDGE + HDR_ICON_SIZE + HDR_ICON_GAP;
/** 换手时图标"飞出/飞回"的位移量（vp） */
const HDR_FLY: number = 72;
const HEADER_TAG: string = 'NekoBox-Header';

@ComponentV2
export struct PageHeader {
  /** 智感握姿单例（@Trace side）：换手触发标题平移 + 图标淡入淡出 */
  @Local handedness: Handedness = Handedness.get();
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 搜索（点一下由页面自己决定是展开搜索栏还是弹面板） */
  @Param showSearch: boolean = false;
  @Param searchSymbol: Resource = $r('sys.symbol.magnifyingglass');
  /** 添加（原版那颗"文档＋"图标：快捷导入） */
  @Param showAdd: boolean = false;
  @Param addSymbol: Resource = $r('sys.symbol.doc_text');
  /** 更多（⋮ 菜单；锚点 id 必须挂在这一颗上） */
  @Param showMenu: boolean = false;
  @Param menuSymbol: Resource = $r('sys.symbol.circle_grid_2x2');
  @Param menuAnchorId: string = '';
  /** 镜像态（右手操作 ⇒ ☰ 在右、动作组在左；默认 ☰ 在左） */
  @Local mirrored: boolean = false;
  /** 图标"飞出"进度：0 = 在位，1 = 已飞到边界外（飞的过程同时淡出，回来时淡入） */
  @Local iconFly: number = 0;
  /** 标题层水平位移（vp）：换手时在 animateTo 里改它 ⇒ 标题**滑**到另一侧 */
  @Local titleShift: number = 0;
  /** 实测宽度（vp）：页头整体 / 标题块，算位移量用 */
  @Local boxW: number = 0;
  @Local titleW: number = 0;
  /**
   * 换手动画代号：每次触发 +1，`setTimeout` 里的旧任务发现代号变了就直接放弃。
   * 组件销毁时也 +1（见 aboutToDisappear），避免回调操作已卸载的节点。
   */
  private animGeneration: number = 0;
  /**
   * 换手（智感握姿）动效（甲方 2026-11-01 第二次定稿）：
   *   **左侧的往左飞、右侧的往右飞，然后从新的一侧飞回来**（不要整层淡入淡出）。
   *
   * 做法：`iconFly` 0→1 时两侧图标各自向自己那一侧 `translate` 出去并同步淡出（所以看不出瞬移），
   *      然后在**看不见的那一刻**翻 `mirrored`（换边），再让 `iconFly` 1→0 ⇒
   *      图标从**新位置的外侧**飞回原位；标题同时在 300ms 里滑到另一侧。
   * 时序：150ms 飞出 → 160ms 换边 + 标题 300ms 滑动 + 图标 200ms 飞回。
   *
   * ⚠️ 延迟任务必须带**代号**并复核当前状态：连点开关/连换手时，旧任务不能把页头翻到过期的一侧
   *    （之前关掉智感握姿后仍可能被排队的旧动画翻回右边，就是这个）。
   */
  @Monitor('handedness.side', 'handedness.enabled')
  onHandSideChanged(): void {
    const target: boolean = this.handRight();
    if (target === this.mirrored) {
      // 当前视觉已经是目标侧：只需把可能飞在半路的图标收回来
      const generation: number = ++this.animGeneration;
      if (this.iconFly !== 0) {
        this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
          this.iconFly = 0;
        });
      }
      hilog.info(DOMAIN, HEADER_TAG, 'hand side settled mirrored=%{public}s gen=%{public}d',
        `${target}`, generation);
      return;
    }
    const generation: number = ++this.animGeneration;
    hilog.info(DOMAIN, HEADER_TAG, 'hand side change -> mirrored=%{public}s gen=%{public}d',
      `${target}`, generation);
    const ui: UIContext = this.getUIContext();
    // ① 两侧图标各往自己那边飞出去（同时淡出）
    ui.animateTo({ duration: 150, curve: Curve.EaseIn }, () => {
      this.iconFly = 1;
    });
    // ② 此刻图标不可见：换边 + 标题滑过去 + 图标从新的一侧飞回来
    setTimeout(() => {
      if (generation !== this.animGeneration) {
        hilog.info(DOMAIN, HEADER_TAG, 'header task dropped (stale gen=%{public}d)', generation);
        return;
      }
      // 复核：从排队到现在，目标侧可能又变了（比如反向连点、或关掉智感握姿要求回左侧）
      const latest: boolean = this.handRight();
      if (latest !== target) {
        hilog.info(DOMAIN, HEADER_TAG, 'header task superseded target=%{public}s latest=%{public}s',
          `${target}`, `${latest}`);
        this.mirrored = latest;
        this.titleShift = this.shiftFor(latest);
        ui.animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
          this.iconFly = 0;
        });
        return;
      }
      this.mirrored = target;
      ui.animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
        this.titleShift = this.shiftFor(target);
      });
      ui.animateTo({ duration: 200, curve: Curve.Friction }, () => {
        this.iconFly = 0;
      });
    }, 160);
  }
  @Event onDrawer: () => void = (): void => {
  };
  @Event onSearch: () => void = (): void => {
  };
  @Event onAdd: () => void = (): void => {
  };
  @Event onMenu: () => void = (): void => {
  };

  aboutToAppear(): void {
    // 握姿可能在本组件创建之前就已识别完（那时没有 change 事件）⇒ 首帧直接对齐到正确的一侧
    this.mirrored = this.handRight();
    hilog.info(DOMAIN, HEADER_TAG, 'header appear mirrored=%{public}s', `${this.mirrored}`);
  }

  aboutToDisappear(): void {
    // 组件销毁时作废所有排队任务，避免回调操作已卸载的节点
    this.animGeneration++;
  }

  /** 智感握姿：右手操作时 ☰ 挪到右侧（左侧/未识别保持原来的左侧） */
  private handRight(): boolean {
    return Handedness.get().uiSide === HAND_RIGHT;
  }

  /** 动作组里有几个图标（算标题可用宽度用） */
  private iconCount(): number {
    let count: number = 0;
    if (this.showSearch) {
      count++;
    }
    if (this.showAdd) {
      count++;
    }
    if (this.showMenu) {
      count++;
    }
    return count;
  }

  /**
   * 镜像态标题要右移多少（vp）：目标左边界 = 页头宽 − 让位 − 标题宽。
   * 非镜像时标题本来就在让位后面 ⇒ 位移 0。
   */
  private shiftFor(mirrored: boolean): number {
    if (!mirrored || this.boxW <= 0 || this.titleW <= 0) {
      return 0;
    }
    const shift: number = this.boxW - HDR_TITLE_INSET * 2 - this.titleW;
    return shift > 0 ? shift : 0;
  }

  /** 宽/标题宽变化后重算位移（不在 animateTo 里 ⇒ 首帧直接到位，不闪） */
  private syncShift(): void {
    const shift: number = this.shiftFor(this.mirrored);
    if (Math.abs(shift - this.titleShift) >= 0.5) {
      this.titleShift = shift;
      hilog.info(DOMAIN, HEADER_TAG, 'title shift=%{public}f box=%{public}f titleW=%{public}f',
        shift, this.boxW, this.titleW);
    }
  }

  /** 标题可用宽度：两侧都要给图标让位（换手是对称的，所以同一个上限两边都够用） */
  private titleMaxWidth(): Length {
    const count: number = this.iconCount();
    const iconsW: number = count > 0 ? count * HDR_ICON_SIZE + (count - 1) * HDR_ICON_GAP : 0;
    if (this.boxW <= 0) {
      return '50%';
    }
    const avail: number = this.boxW - HDR_TITLE_INSET - HDR_EDGE - iconsW - 4;
    return avail > 96 ? avail : 96;
  }

  @Builder
  private drawerButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.line_3_horizontal'))
        .fontSize(21)
        .fontColor([Theme.TEXT_1])
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Up) {
        this.onDrawer();
      }
    })
  }

  /** 右侧（镜像态在左侧）动作组：搜索 / 添加 / 更多 */
  @Builder
  private actionGroup() {
    Row({ space: HDR_ICON_GAP }) {
      if (this.showSearch) {
        HeaderIconButton({
          symbol: this.searchSymbol,
          anchorId: "hdr_search",
          onTap: () => {
            this.onSearch();
          }
        })
      }
      if (this.showAdd) {
        HeaderIconButton({
          symbol: this.addSymbol,
          anchorId: "hdr_add",
          onTap: () => {
            this.onAdd();
          }
        })
      }
      if (this.showMenu) {
        HeaderIconButton({
          symbol: this.menuSymbol,
          anchorId: this.menuAnchorId,
          onTap: () => {
            this.onMenu();
          }
        })
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 图标飞出的方向位移：`onLeft` 的往左飞（负），另一侧往右飞（正） */
  private flyX(onLeft: boolean): number {
    return (onLeft ? -HDR_FLY : HDR_FLY) * this.iconFly;
  }

  /** 飞出/飞回时同步淡出淡入（避免在屏幕边上硬切） */
  private iconFade(): number {
    const opacity: number = 1 - this.iconFly;
    return opacity > 0 ? opacity : 0;
  }

  /**
   * 图标层：☰ 与动作组分居**两端**（中间 Blank 撑开）。
   * 换手时两侧各往自己那边飞出去、再换边从新的一侧飞回来（`translate` + `opacity` 都挂在**外层包裹**上，
   * 因为 `@Builder` 的调用结果不能直接接链式属性）。
   */
  @Builder
  private iconLayer() {
    Row() {
      if (this.mirrored) {
        Column() {
          this.actionGroup()
        }
        .translate({ x: this.flyX(true) })
        .opacity(this.iconFade())

        Blank()

        Column() {
          this.drawerButton()
        }
        .translate({ x: this.flyX(false) })
        .opacity(this.iconFade())
      } else {
        Column() {
          this.drawerButton()
        }
        .translate({ x: this.flyX(true) })
        .opacity(this.iconFade())

        Blank()

        Column() {
          this.actionGroup()
        }
        .translate({ x: this.flyX(false) })
        .opacity(this.iconFade())
      }
    }
    .width("100%")
    .height(HEADER_HEIGHT)
    .padding({ left: HDR_EDGE, right: HDR_EDGE })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 页头两**层**（原来在同一行 ⇒ 图标压在标题上、换手也不动）：
   *   ① 标题层：只有标题/副标题，位置 = 左侧让位 + `translate(titleShift)`（换手时滑过去）；
   *   ② 图标层：☰ + 动作组分居两端，换手时各往自己那一侧飞出去、再从新的一侧飞回来。
   * 两层都是 `width('100%')` 铺满同一个 Stack，互不参与对方的布局 ⇒ 不可能重叠。
   */
  build() {
    Stack({ alignContent: Alignment.Start }) {
      // ① 标题层
      Row() {
        Column({ space: 1 }) {
          Text(this.title)
            .fontSize(21)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(11)
              .fontColor(Theme.TEXT_3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(this.mirrored ? HorizontalAlign.End : HorizontalAlign.Start)
        .constraintSize({ maxWidth: this.titleMaxWidth() })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const w: number = Number(newArea.width);
          if (w > 0 && Math.abs(w - this.titleW) >= 0.5) {
            this.titleW = w;
            this.syncShift();
          }
        })
      }
      .width("100%")
      .height(HEADER_HEIGHT)
      .padding({ left: HDR_TITLE_INSET, right: HDR_TITLE_INSET })
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .translate({ x: this.titleShift })

      // ② 图标层
      this.iconLayer()
    }
    .width("100%")
    .height(HEADER_HEIGHT)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = Number(newArea.width);
      if (w > 0 && Math.abs(w - this.boxW) >= 0.5) {
        this.boxW = w;
        this.syncShift();
      }
    })
  }
}

/**
 * 分组页签条（原版首页那排"edge / free18 / v2"）：**下划线指示器**，不是胶囊。
 * 用 Scroll + Row 手搓而不是 Tabs：分组数量随订阅变化，Tabs 的 index 同步在增删时容易错位。
 *
 * ★ 2026-11-01（甲方："切换分组的时候没有动画"）：指示器改成**一根会滑的横条**。
 *   每个页签的 x/宽用 `onAreaChange` 的 `globalPosition` 实测（减去本组件原点 ⇒ 与滚动无关），
 *   `selected` 一变就在 `animateTo` 里改 `translateX` + 宽度 ⇒ 横条从上一个字滑到下一个字下面。
 */
@ComponentV2
export struct GroupTabs {
  @Param items: Array<string> = [];
  @Param selected: number = 0;
  @Event onSelect: (index: number) => void = (index: number): void => {
  };
  /** 指示器：水平位移 + 宽度（vp，都可补间） */
  @Local barX: number = 0;
  @Local barW: number = 0;
  /** 各页签实测几何（只给算位移用，不参与渲染 ⇒ 普通字段即可） */
  private tabX: Array<number> = [];
  private tabW: Array<number> = [];
  private originX: number = 0;

  @Monitor('selected')
  onSelectedChanged(): void {
    this.placeBar(true);
  }

  /** 把横条摆到第 `selected` 个页签下面（居中对齐文字） */
  private placeBar(animate: boolean): void {
    const index: number = this.selected;
    if (index < 0 || index >= this.tabW.length) {
      return;
    }
    const width: number = this.tabW[index];
    if (width <= 0) {
      return;
    }
    const barWidth: number = width < 32 ? width : 32;
    const target: number = this.tabX[index] + (width - barWidth) / 2;
    if (!animate) {
      this.barX = target;
      this.barW = barWidth;
      return;
    }
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.barX = target;
      this.barW = barWidth;
    });
  }

  build() {
    Scroll() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Row({ space: 26 }) {
          ForEach(this.items, (label: string, index: number) => {
            Column({ space: 7 }) {
              Text(label)
                .fontSize(16)
                .fontWeight(this.selected === index ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.selected === index ? Theme.TEXT_1 : Theme.TEXT_3)
                .maxLines(1)
              // 占位：保持"文字 + 7 + 3"的节奏（真正的指示器是下面那根横条）
              Row()
                .width(1)
                .height(3)
                .opacity(0)
            }
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              const width: number = Number(newArea.width);
              if (width > 0) {
                this.tabX[index] = Number(newArea.globalPosition.x) - this.originX;
                this.tabW[index] = width;
                this.placeBar(false);
              }
            })
            .onClick(() => {
              this.onSelect(index);
            })
          }, (label: string, index: number) => `tab_${index}_${label}`)
        }
        .padding({ left: Space.PAGE, right: Space.PAGE })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.originX = Number(newArea.globalPosition.x);
        })

        Row()
          .width(this.barW)
          .height(3)
          .borderRadius(2)
          .backgroundColor(Theme.BRAND)
          .translate({ x: this.barX })
          .opacity(this.barW > 0 ? 1 : 0)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(40)
    .align(Alignment.Start)
    // 分组页签左右滑到头有回弹（甲方 2026-11-01）。`alwaysEnabled` = 内容比一屏窄时也给回弹，
    // 否则分组少（不溢出）时手感是"硬的"，跟系统其它横向容器不一致。
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }
}

// ------------------------------------------------------------------ 光感 / 点光

/** 光感强度档位 → HDS 材质等级（0 自适应 / 1 柔滑 / 2 温润 / 3 精致） */
export function hdsLevel(lightLevel: number): hdsMaterial.MaterialLevel {
  if (lightLevel === 1) {
    return hdsMaterial.MaterialLevel.SMOOTH;
  }
  if (lightLevel === 2) {
    return hdsMaterial.MaterialLevel.GENTLE;
  }
  if (lightLevel === 3) {
    return hdsMaterial.MaterialLevel.EXQUISITE;
  }
  return hdsMaterial.MaterialLevel.ADAPTIVE;
}

/** 菜单背板模糊档跟随光感强度 */
export function menuBlurStyle(lightLevel: number): BlurStyle {
  if (lightLevel === 1) {
    return BlurStyle.COMPONENT_THIN;
  }
  if (lightLevel === 3) {
    return BlurStyle.COMPONENT_THICK;
  }
  return BlurStyle.COMPONENT_REGULAR;
}

/**
 * 点光"按下才亮"的唯一正确写法：
 * `sourceType` 优先级高于 `options`（同时给会被吃 ⇒ 常亮），所以只用 sourceType；
 * `pressShadow` 只在 Button 上生效；`illuminatedType` = 自己等着被旁边的光源照亮。
 */
export function pressLightEffect(pressed: boolean, isButton: boolean): VisualEffect {
  return new hdsEffect.HdsEffectBuilder()
    .pressShadow(pressed && isButton ? hdsEffect.PressShadowType.BLEND_GRADIENT : hdsEffect.PressShadowType.NONE)
    .pointLight({
      sourceType: pressed ? hdsEffect.PointLightSourceType.BRIGHT : hdsEffect.PointLightSourceType.NONE,
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
    })
    .buildEffect();
}

/** 只受光不发光（宿主白名单：Button/Toggle/Row/Column/Image/Flex/Stack/Select/Menu/MenuItem，**不含 Text**） */
export function illuminatedEffect(): VisualEffect {
  return new hdsEffect.HdsEffectBuilder()
    .pointLight({ illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT })
    .buildEffect();
}

// ------------------------------------------------------------------ 沉浸光感菜单

export class MenuItemData {
  label: string = '';
  selected: boolean = false;
  /** 可选：图标（system symbol），空则不画 */
  symbol: Resource | undefined = undefined;

  constructor(label: string, selected: boolean = false, symbol?: Resource) {
    this.label = label;
    this.selected = selected;
    this.symbol = symbol;
  }
}

export class SimpleMenuParam {
  items: Array<MenuItemData> = [];
  onPick: (index: number) => void = (index: number): void => {
  };
}

@Builder
export function simpleMenuPanel(param: SimpleMenuParam) {
  /* 导入菜单有十几项，必须可滚：固定 46vp × 13 ≈ 600vp，加上安全区会顶出屏幕 */
  Scroll() {
    Column() {
      ForEach(param.items, (it: MenuItemData, index: number) => {
        Row({ space: 10 }) {
          if (it.symbol !== undefined) {
            SymbolGlyph(it.symbol)
              .fontSize(16)
              .fontColor([Theme.TEXT_2])
          }
          Text(it.label)
            .fontSize(15)
            .fontColor(it.selected ? Theme.BRAND : Theme.TEXT_1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (it.selected) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(15)
              .fontColor([Theme.BRAND])
          }
        }
        .width('100%')
        .height(46)
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          param.onPick(index);
        })
      }, (it: MenuItemData, index: number) => `menu_${index}_${it.label}_${it.selected}`)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
  .width(232)
  .constraintSize({ maxHeight: 520 })
  .scrollBar(BarState.Off)
}

/**
 * "沉浸光感"菜单：系统菜单窗口 + 自绘面板。
 * 三要素：`promptAction.openMenu` + `backgroundBlurStyle` + `backgroundBlurStyleOptions.adaptiveColor = AVERAGE`
 * （默认 `DEFAULT` 是固定色蒙版，看起来"菜单完全没有光感"）。`placement` 必须显式给，否则会铺到左边。
 */
export class HdsMenu {
  private node: ComponentContent<SimpleMenuParam> | undefined = undefined;
  private shown: boolean = false;
  private closing: boolean = false;

  open(ctx: UIContext, anchorId: string, items: Array<MenuItemData>,
    onPick: (index: number) => void, lightLevel: number): void {
    if (items.length === 0) {
      return;
    }
    const param: SimpleMenuParam = new SimpleMenuParam();
    param.items = items;
    param.onPick = (index: number): void => {
      this.close(ctx);
      onPick(index);
    };
    const node: ComponentContent<SimpleMenuParam> = new ComponentContent(ctx, wrapBuilder(simpleMenuPanel), param);
    /**
     * ★ API 26 起 `MenuOptions`（`ContextMenuOptions`）自带 **`systemMaterial`** —— 真"玻璃菜单"。
     *   材质会接管背景/描边/投影，所以**不能再同时给** `backgroundBlurStyle` / `backgroundColor`，
     *   否则两套叠在一起会发灰（老版本 SDK 没这个字段，之前只能用 blur 凑，注释也留在了这里）。
     *   设备不支持时系统会忽略这个字段 ⇒ 自动退回系统默认菜单底，不会崩也不会花。
     */
    const options: MenuOptions = {
      mask: false,
      placement: Placement.BottomRight,
      systemMaterial: immersiveMedium(),
      onWillDisappear: (): void => {
        this.node = undefined;
        this.shown = false;
        this.closing = false;
      },
      onDisappear: (): void => {
        this.node = undefined;
        this.shown = false;
        this.closing = false;
      }
    };
    this.node = node;
    this.shown = false;
    this.closing = false;
    ctx.getPromptAction().openMenu(node, { id: anchorId }, options)
      .then(() => {
        if (this.node === node && !this.closing) {
          this.shown = true;
          hilog.info(DOMAIN, MENU_TAG, 'menu open anchor=%{public}s', anchorId);
        }
      })
      .catch((err: BusinessError) => {
        if (this.node === node) {
          this.node = undefined;
          this.shown = false;
        }
        hilog.warn(DOMAIN, MENU_TAG, 'openMenu failed: %{public}s', err.message);
      });
  }

  /** 只对"确认已弹出"的节点发关闭：对未弹出的内容节点调 closeMenu 会报 103303 */
  close(ctx: UIContext): void {
    const node: ComponentContent<SimpleMenuParam> | undefined = this.node;
    if (node === undefined || !this.shown || this.closing) {
      this.node = undefined;
      this.shown = false;
      return;
    }
    this.closing = true;
    try {
      ctx.getPromptAction().closeMenu(node);
    } catch (e) {
      hilog.warn(DOMAIN, MENU_TAG, 'closeMenu failed: %{public}s', (e as Error).message);
    }
    this.node = undefined;
    this.shown = false;
    this.closing = false;
  }
}

// ------------------------------------------------------------------ 标准 HDS 标题栏

/** 顶栏右上角的一个图标动作 */
export class BarAction {
  icon: Resource = $r('sys.symbol.plus');
  label: string = '';
  action: () => void = (): void => {
  };

  constructor(icon: Resource, label: string, action: () => void) {
    this.icon = icon;
    this.label = label;
    this.action = action;
  }
}

/**
 * 标准 HDS 标题栏：标题走 `content.title`、右上动作用 `content.menu`（官方槽，比自绘顶栏稳）。
 *
 * 几何口径（RzdCard/RzdMusic 真机反复验证过的那一套，别推翻）：
 *   · `avoidLayoutSafeArea: immersive`
 *       - 页签页（TabContent 里）传 true ⇒ 顶栏材质铺到屏幕顶，标题/按钮退到状态栏下方（38..94）；
 *       - 二级页（push 进来的 HdsNavDestination）传 false ⇒ 顶栏基座自带一个状态栏，同样是 38..94。
 *   · 内容让位一律 `Metrics.topInset`（= 状态栏 + 56），且**加在滚动容器自己的内容里**
 *     （List 的 padding 只缩 viewport，不移动内容 ⇒ 会让首项被顶栏切一半）。
 *   · 底色/模糊全部交给 `systemMaterialEffect` + `IMMERSIVE_GRADIENT_BLUR`：
 *     不要写 `originalStyle.backgroundStyle`（显式 Transparent 会把材质顶掉），
 *     也不要写 `scrollEffectStyle.backgroundStyle`（纯色背板会把渐隐盖掉 ⇒ 内容在顶栏下沿硬切一刀）。
 */
export function hdsPageBar(title: ResourceStr, lightLevel: number, actions: Array<BarAction> = [],
  stack?: NavPathStack, showBack: boolean = false, immersive: boolean = true): HdsNavigationTitleBarOptions {
  const content: TitleBarContentOptions = {
    title: { mainTitle: title, mainTitleSize: TitleSize.TITLE_ML }
  };
  if (showBack && stack !== undefined) {
    content.backIcon = {
      icon: $r('sys.symbol.chevron_left'),
      label: 'back',
      isEnabled: true,
      action: (): void => {
        stack.pop();
      }
    };
  }
  if (actions.length > 0) {
    const items: Array<HdsNavigationMenuItemOptions> = [];
    for (const a of actions) {
      const item: HdsNavigationMenuItemOptions = {
        content: {
          icon: a.icon,
          label: a.label,
          isEnabled: true,
          action: a.action
        }
      };
      items.push(item);
    }
    content.menu = { maxCount: items.length, value: items };
  }
  return {
    padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
    avoidLayoutSafeArea: immersive,
    style: {
      blurStrategy: BlurStrategy.ENABLE,
      scrollEffectOpts: {
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
      },
      originalStyle: {
        contentStyle: {
          titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
          backIconStyle: { iconColor: $r('sys.color.font_primary'), backgroundColor: '#1AFFFFFF' },
          menuStyle: {
            textColor: $r('sys.color.font_primary'),
            iconColor: $r('sys.color.font_primary'),
            backgroundColor: '#1AFFFFFF'
          }
        }
      },
      scrollEffectStyle: {
        contentStyle: {
          titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
          backIconStyle: { iconColor: $r('sys.color.font_primary'), backgroundColor: '#1AFFFFFF' },
          menuStyle: {
            textColor: $r('sys.color.font_primary'),
            iconColor: $r('sys.color.font_primary'),
            backgroundColor: '#1AFFFFFF'
          }
        }
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsLevel(lightLevel)
      }
    },
    content: content
  };
}

// ------------------------------------------------------------------ 通用小件

/**
 * 圆角胶囊图标按钮（顶栏 / 工具条，按下发光）。
 * ★ 触发点走 `onTouch` 的 Up 而不是 `onClick`：HDS 顶栏自绘区里 `onClick` 有回调不到的情况，
 *   `onTouch` 稳定可用（NekoBox 上一轮"侧边栏怎么都打不开"就是这个坑）。
 */
@ComponentV2
export struct TitleIconButton {
  @Param symbol: Resource = $r('sys.symbol.plus');
  @Param diameter: number = 36;
  @Param iconSize: number = 20;
  @Param tint: ResourceColor = $r('sys.color.font_primary');
  @Event onTap: () => void = (): void => {
  };
  @Local pressed: boolean = false;

  build() {
    Row() {
      SymbolGlyph(this.symbol)
        .fontSize(this.iconSize)
        .fontColor([this.tint])
    }
    .width(this.diameter)
    .height(this.diameter)
    .borderRadius(this.diameter / 2)
    .backgroundColor('#1A808080')
    .backgroundBlurStyle(BlurStyle.Regular)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .visualEffect(pressLightEffect(this.pressed, false))
    .onTouch((event: TouchEvent) => {
      /* 图标按钮常常嵌在"整行可点"的卡片里：这里必须掐断冒泡，
         否则点「⋮」会同时触发外层卡片（在节点卡上就是"顺手连上了别的节点"）。 */
      event.stopPropagation();
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up) {
        this.pressed = false;
        this.onTap();
      } else if (event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

/** 发光按钮：按下那一刻成为点光源并照亮周边受光体，松手即灭 */
@ComponentV2
export struct GlowButton {
  @Param label: string = '';
  @Param buttonColor: ResourceColor = Theme.BRAND;
  @Param labelColor: ResourceColor = Theme.ON_BRAND;
  @Param buttonHeight: number = 44;
  @Param labelSize: number = 15;
  @Param radius: number = 24;
  @Param fillWidth: boolean = false;
  @Param grow: boolean = false;
  @Param tapEnabled: boolean = true;
  @Event onTap: () => void = (): void => {
  };
  @Local lit: boolean = false;

  build() {
    Button(this.label)
      .fontSize(this.labelSize)
      .fontWeight(FontWeight.Medium)
      .height(this.buttonHeight)
      .backgroundColor(this.buttonColor)
      .fontColor(this.labelColor)
      .borderRadius(this.radius)
      .enabled(this.tapEnabled)
      .width(this.fillWidth ? '100%' : undefined)
      .layoutWeight(this.grow ? 1 : 0)
      .visualEffect(pressLightEffect(this.lit, true))
      .onTouch((event: TouchEvent) => {
        if (!this.tapEnabled) {
          return;
        }
        if (event.type === TouchType.Down) {
          this.lit = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.lit = false;
        }
      })
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 描边胶囊按钮（卡片里的小动作） */
@ComponentV2
export struct OutlineButton {
  @Param label: string = '';
  @Param inkColor: ResourceColor = Theme.BRAND;
  @Param buttonHeight: number = 32;
  @Event onTap: () => void = (): void => {
  };
  @Local pressed: boolean = false;

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.inkColor)
      .height(this.buttonHeight)
      .padding({ left: 14, right: 14 })
      .borderRadius(this.buttonHeight / 2)
      .border({ width: 1, color: this.inkColor })
      .backgroundColor(this.pressed ? Theme.BRAND_SOFT : Color.Transparent)
      .textAlign(TextAlign.Center)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
        }
      })
      .onClick(() => {
        this.onTap();
      })
  }
}

/**
 * 分段条（规则 / 全局 / 直连这种二三选一）。
 *
 * ★ 2026-11-01（甲方："那个胶囊选择器有系统组件的，像 RzdMusic 设置页全是这玩意"）：
 *   自绘版整个撤掉，改用官方高级组件 **`CapsuleSegmentButtonV2`**（`@ohos.arkui.advanced.SegmentButtonV2`）。
 *   选中胶囊的滑动/回弹由系统组件自己带，我们只喂 items + selectedIndex，并把颜色换成主题色。
 *   `items` 必须是 `@Local`（V2 细粒度刷新，就地改数组不生效），`labels` 变了要重建。
 */
@ComponentV2
export struct SegmentedRow {
  @Param labels: Array<string> = [];
  @Param selected: number = 0;
  @Event onSelect: (index: number) => void = (index: number): void => {
  };
  @Local items: SegmentButtonV2Items = new SegmentButtonV2Items([]);
  @Local current: number = 0;

  aboutToAppear(): void {
    this.current = this.selected;
    this.rebuildItems();
  }

  @Monitor('selected')
  onSelectedChanged(): void {
    this.current = this.selected;
  }

  @Monitor('labels')
  onLabelsChanged(): void {
    this.rebuildItems();
  }

  private rebuildItems(): void {
    const options: Array<SegmentButtonV2ItemOptions> = [];
    for (const label of this.labels) {
      options.push({ text: label });
    }
    this.items = new SegmentButtonV2Items(options);
  }

  build() {
    CapsuleSegmentButtonV2({
      items: this.items,
      selectedIndex: this.current,
      onItemClicked: (index: number): void => {
        this.current = index;
        this.onSelect(index);
      },
      buttonBackgroundColor: ColorMetrics.resourceColor(Theme.SURFACE_2),
      buttonMinHeight: LengthMetrics.vp(40),
      buttonBorderRadius: LengthMetrics.vp(20),
      itemMinHeight: LengthMetrics.vp(40),
      itemBorderRadius: LengthMetrics.vp(20),
      itemFontSize: LengthMetrics.fp(14),
      itemSelectedFontSize: LengthMetrics.fp(14),
      itemFontColor: ColorMetrics.resourceColor(Theme.TEXT_2),
      itemSelectedFontColor: ColorMetrics.resourceColor(Theme.ON_BRAND),
      itemSelectedBackgroundColor: ColorMetrics.resourceColor(Theme.BRAND)
    })
    .width('100%')
  }
}

/** 设置页 / 详情页的键值行（点一下触发 onTap） */
@ComponentV2
export struct FormRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param placeholder: string = '未设置';
  @Param showArrow: boolean = true;
  @Param valueColor: ResourceColor = Theme.TEXT_2;
  @Param labelWidth: number = 104;
  @Event onTap: () => void = (): void => {
  };
  @Local pressed: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor(Theme.TEXT_1)
        .width(this.labelWidth)
      Text(this.value.length > 0 ? this.value : this.placeholder)
        .fontSize(14)
        .fontColor(this.value.length > 0 ? this.valueColor : Theme.TEXT_3)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.showArrow) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([Theme.TEXT_3])
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.pressed ? Theme.SURFACE_2 : Color.Transparent)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 开关行（设置页） */
@ComponentV2
export struct ToggleRow {
  @Param label: string = '';
  @Param summary: string = '';
  @Param checked: boolean = false;
  @Event onToggle: (checked: boolean) => void = (checked: boolean): void => {
  };

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.label)
          .fontSize(15)
          .fontColor(Theme.TEXT_1)
        if (this.summary.length > 0) {
          Text(this.summary)
            .fontSize(12)
            .fontColor(Theme.TEXT_3)
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .selectedColor(Theme.BRAND)
        .onChange((on: boolean) => {
          this.onToggle(on);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }
}

/** 小节标题（列表前面那种灰字） */
@ComponentV2
export struct SectionHeader {
  @Param title: string = '';
  @Param trailing: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_3)
      Blank()
      if (this.trailing.length > 0) {
        Text(this.trailing)
          .fontSize(12)
          .fontColor(Theme.TEXT_3)
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 2 })
  }
}

/** 空态 */
@ComponentV2
export struct EmptyState {
  @Param symbol: Resource = $r('sys.symbol.list_bullet');
  @Param title: string = '';
  @Param hint: string = '';
  @Param actionLabel: string = '';
  @Event onAction: () => void = (): void => {
  };

  build() {
    Column({ space: 10 }) {
      SymbolGlyph(this.symbol)
        .fontSize(42)
        .fontColor([Theme.TEXT_3])
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(13)
          .fontColor(Theme.TEXT_3)
          .textAlign(TextAlign.Center)
      }
      if (this.actionLabel.length > 0) {
        OutlineButton({ label: this.actionLabel, onTap: () => this.onAction() })
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ top: 56, bottom: 40, left: 24, right: 24 })
    .alignItems(HorizontalAlign.Center)
  }
}

/** 键值小格（首页四个统计位） */
@ComponentV2
export struct StatCell {
  @Param label: string = '';
  @Param value: string = '';
  @Param valueColor: ResourceColor = Theme.TEXT_1;
  @Param cellAlign: HorizontalAlign = HorizontalAlign.Start;

  build() {
    Column({ space: 2 }) {
      Text(this.value)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.valueColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.label)
        .fontSize(11)
        .fontColor(Theme.TEXT_3)
    }
    .alignItems(this.cellAlign)
    .layoutWeight(1)
  }
}

/** 横向滚动胶囊条（分组切换） */
@ComponentV2
export struct ChipBar {
  @Param items: Array<string> = [];
  @Param selected: number = 0;
  @Event onSelect: (index: number) => void = (index: number): void => {
  };

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.items, (label: string, index: number) => {
          Text(label)
            .fontSize(13)
            .fontColor(this.selected === index ? Theme.ON_BRAND : Theme.TEXT_2)
            .height(32)
            .padding({ left: 14, right: 14 })
            .borderRadius(Radius.CHIP)
            .backgroundColor(this.selected === index ? Theme.BRAND : Theme.SURFACE_2)
            .visualEffect(illuminatedEffect())
            .onClick(() => {
              this.onSelect(index);
            })
        }, (label: string, index: number) => `chip_${index}_${label}_${this.selected === index}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
  }
}

// ------------------------------------------------------------------ 选择器 Sheet

export class PickOption {
  label: string = '';
  value: string = '';
  hint: string = '';

  constructor(label: string, value: string, hint: string = '') {
    this.label = label;
    this.value = value;
    this.hint = hint;
  }
}

export class PickSheetParam {
  title: string = '选择';
  options: Array<PickOption> = [];
  current: string = '';
  onPick: (value: string) => void = (value: string): void => {
  };
}

/** 通用选择面板（圆角卡片行 + 选中描边圆勾）：少选项选择器一律用它，不做通栏分割线列表 */
@ComponentV2
export struct PickSheetPanel {
  @Param param: PickSheetParam = new PickSheetParam();
  @Event onClose: () => void = (): void => {
  };

  build() {
    Column() {
      Text(this.param.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
        .width('100%')
        .padding({ left: 4, top: 6, bottom: 10 })

      List({ space: 8 }) {
        ForEach(this.param.options, (opt: PickOption) => {
          ListItem() {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(opt.label)
                  .fontSize(15)
                  .fontColor(Theme.TEXT_1)
                if (opt.hint.length > 0) {
                  Text(opt.hint)
                    .fontSize(12)
                    .fontColor(Theme.TEXT_3)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (opt.value === this.param.current) {
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(20)
                  .fontColor([Theme.BRAND])
              }
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .borderRadius(Radius.TILE)
            .backgroundColor(Theme.SURFACE_2)
            .border({
              width: opt.value === this.param.current ? 1.5 : 0,
              color: Theme.BRAND
            })
            .onClick(() => {
              this.param.onPick(opt.value);
              this.onClose();
            })
          }
        }, (opt: PickOption) => `pick_${opt.value}_${this.param.current}`)
      }
      .width('100%')
      .constraintSize({ maxHeight: 380 })
      .scrollBar(BarState.Off)

      GlowButton({
        label: '取消',
        fillWidth: true,
        buttonColor: Theme.SURFACE_2,
        labelColor: Theme.TEXT_1,
        onTap: () => this.onClose()
      })
        .margin({ top: 12 })
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, top: 20, bottom: 16 })
  }
}

/** 文本输入 Sheet 的参数 */
export class TextInputSheetParam {
  title: string = '';
  placeholder: string = '';
  initial: string = '';
  hint: string = '';
  confirmLabel: string = '确定';
  onConfirm: (text: string) => void = (text: string): void => {
  };
}

/** 单行文本输入面板（新建分组 / 改名字 / 填 URL 都用它） */
@ComponentV2
export struct TextInputSheetPanel {
  @Param param: TextInputSheetParam = new TextInputSheetParam();
  @Event onClose: () => void = (): void => {
  };
  @Local text: string = '';

  aboutToAppear(): void {
    this.text = this.param.initial;
  }

  build() {
    Column({ space: 12 }) {
      Text(this.param.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_1)
        .width('100%')
        .padding({ left: 4, top: 6 })

      TextArea({ text: this.text, placeholder: this.param.placeholder })
        .height(96)
        .fontSize(14)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(Radius.TILE)
        .onChange((value: string) => {
          this.text = value;
        })

      if (this.param.hint.length > 0) {
        Text(this.param.hint)
          .fontSize(12)
          .fontColor(Theme.TEXT_3)
          .width('100%')
      }

      Row({ space: 12 }) {
        GlowButton({
          label: '取消',
          grow: true,
          buttonColor: Theme.SURFACE_2,
          labelColor: Theme.TEXT_1,
          onTap: () => this.onClose()
        })
        GlowButton({
          label: this.param.confirmLabel,
          grow: true,
          onTap: () => {
            this.param.onConfirm(this.text);
            this.onClose();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, top: 20, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }
}

/**
/* 破坏性操作的二次确认（系统 AlertDialog）。
 * 甲方反馈过"点一下就把东西删了"不可接受：删订阅分组会连订阅记录和节点一起删。
 * 弹窗异常时直接执行，避免按钮"点了没反应"。
 */
export function confirmDestructive(ctx: UIContext, title: string, message: string, okLabel: string,
  onOk: () => void): void {
  try {
    ctx.showAlertDialog({
      title: title,
      message: message,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: okLabel,
        fontColor: Theme.DANGER,
        action: () => {
          onOk();
        }
      }
    });
  } catch (e) {
    onOk();
  }
}

/**
 * 信息型提示弹窗（主按钮 = 可选动作，次按钮 = 关闭）。
 * 与 `confirmDestructive` 同一套 `showAlertDialog`，用完就地销毁，不占页面状态。
 */
export function showNotice(ctx: UIContext, title: string, message: string,
  actionLabel: string, onAction: () => void): void {
  try {
    ctx.showAlertDialog({
      title: title,
      message: message,
      autoCancel: true,
      primaryButton: {
        value: actionLabel,
        action: () => {
          onAction();
        }
      },
      secondaryButton: {
        value: '关闭',
        action: () => {
        }
      }
    });
  } catch (e) {
    // 弹窗起不来时把动作直接做掉（例如复制链接），别让用户点了没反应
    onAction();
  }
}

/**
 * 设置行 + 系统 `Select`（替代原来的半模态选择弹窗）。
 * 甲方 2026-11-01："这种选择的窗口别用半模态了，参考 RzdMusic 回响页的年月切换，用系统组件并且接入光感"。
 *
 * 为什么用 `Select`：只有 Select 的下拉菜单支持 `menuSystemMaterial`（系统沉浸材质 = 真光感），
 * `bindMenu` 的 MenuOptions 里没有材质字段。材质见 `ui/SelectMaterial.ets`。
 */
@ComponentV2
export struct SelectRow {
  @Param label: string = '';
  @Param summary: string = '';
  /** 显示文案 */
  @Param labels: Array<string> = [];
  /** 与 labels 一一对应的取值（提交用） */
  @Param values: Array<string> = [];
  @Param current: string = '';
  @Param lightLevel: number = 3;
  @Event onPick: (value: string) => void = (value: string): void => {
  };
  @Local selectedIndex: number = 0;

  aboutToAppear(): void {
    this.syncIndex();
  }

  @Monitor('current', 'values')
  onCurrentChanged(): void {
    this.syncIndex();
  }

  private syncIndex(): void {
    const index: number = this.values.indexOf(this.current);
    this.selectedIndex = index >= 0 ? index : 0;
  }

  private selectOptions(): Array<SelectOption> {
    const out: Array<SelectOption> = [];
    for (const text of this.labels) {
      out.push({ value: text } as SelectOption);
    }
    return out;
  }

  private currentText(): string {
    return this.selectedIndex >= 0 && this.selectedIndex < this.labels.length
      ? this.labels[this.selectedIndex] : this.current;
  }

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(15)
          .fontColor(Theme.TEXT_1)
          .width('100%')
        if (this.summary.length > 0) {
          Text(this.summary)
            .fontSize(11)
            .fontColor(Theme.TEXT_3)
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Select(this.selectOptions())
        .selected(this.selectedIndex)
        .value(this.currentText())
        .font({ size: 13 })
        .fontColor(Theme.TEXT_1)
        .selectedOptionFont({ size: 14 })
        .optionFont({ size: 14 })
        .height(32)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(16)
        .attributeModifier(new HdsSelectMenuMaterial(this.lightLevel))
        .onSelect((index: number) => {
          this.selectedIndex = index;
          if (index >= 0 && index < this.values.length) {
            this.onPick(this.values[index]);
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
