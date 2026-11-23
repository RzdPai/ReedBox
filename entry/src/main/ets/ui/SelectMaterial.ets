import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme } from './Theme';

/**
 * 下拉选择菜单的"光感"材质（照 RzdMusic「回响页」年月切换那套做法）。
 *
 * 关键结论（本机 SDK 26 已核对）：
 *  · `Select` 的 menu 专属属性支持**系统沉浸材质**：`menuSystemMaterial(Optional<SystemUiMaterial>)`；
 *  · `bindMenu` 的 `MenuOptions` **没有**材质字段 ⇒ 真光感只能用 `Select`；
 *  · 兜底链：`menuSystemMaterial`（真光感）→ `menuBackgroundBlurStyle` + `menuBackgroundColor`（厚模糊）
 *    → 只剩纯色底；`menuOutline` 需要 API 20+。
 *
 * ⚠️⚠️ 上架检测退回来的真机崩溃（2026-11-23，MatePad Pro 11 / HarmonyOS 6.1 / API 24）：
 *   `JsCrash: at immersiveMedium (src/main/ets/ui/SelectMaterial.ts:39:1)`
 *   根因：`@ohos.arkui.uiMaterial` 与 `Select.menuSystemMaterial` **都是 API 26 才有的**。
 *   本工程 minAPI 是 24，设备上没有这个模块 ⇒ 一旦代码碰到 `uiMaterial.*` 就是 `undefined` 属性访问，
 *   直接 TypeError。**而且第一版把它写在 try 外面**：`immersiveMedium()` 里 `uiMaterial.ImmersiveStyle.REGULAR`
 *   是**实参表达式**，在进入 `immersiveMaterial()` 的 try 之前就求值了 ⇒ 兜不住，必崩。
 *
 *   现在的铁律：
 *    ① 所有 API 26 的东西都先看 `deviceInfo.sdkApiVersion >= 26`，且**第一次接触就在 try 里**；
 *    ② 枚举值不许出现在实参位置（那是在调用方求值），一律在 try 内部取；
 *    ③ `menuSystemMaterial()` 这种"方法可能不存在"的调用也要 try 住（老系统上它不是函数，不是空值）。
 *
 * 用法：`Select(options).attributeModifier(new HdsSelectMenuMaterial())`
 * 排查：`hilog | grep NekoBox-Material`
 */

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Material';

/** 系统沉浸材质（`menuSystemMaterial`）从 API 26 开始有 */
const MATERIAL_MIN_API: number = 26;

/**
 * 取沉浸材质；设备/系统不支持时返回 undefined
 * （`menuSystemMaterial(undefined)` = 不用材质，由 `menuBackgroundBlurStyle` 那层兜底）。
 */
export function immersiveMaterial(style?: uiMaterial.ImmersiveStyle): SystemUiMaterial | undefined {
  if (deviceInfo.sdkApiVersion < MATERIAL_MIN_API) {
    return undefined;
  }
  try {
    // ★ 只有在 try 内部才允许碰 uiMaterial（老系统上它整个模块都是 undefined）
    if (!uiMaterial.isImmersiveMaterialSupported()) {
      hilog.info(DOMAIN, TAG, 'immersive material unsupported, fallback to blur');
      return undefined;
    }
    const useStyle: uiMaterial.ImmersiveStyle = style === undefined
      ? uiMaterial.ImmersiveStyle.REGULAR : style;
    return new uiMaterial.ImmersiveMaterial({
      style: useStyle,
      applyShadow: true,
      interactive: true
    });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'build material failed: %{public}s', `${(e as Error).message}`);
    return undefined;
  }
}

/** 中等厚度（最常用）。★ 不传枚举实参：枚举要在 try 里取，不许在调用方求值 */
export function immersiveMedium(): SystemUiMaterial | undefined {
  return immersiveMaterial();
}

/** 把 HDS 的"光感下拉"样式挂到任意 Select 上 */
export class HdsSelectMenuMaterial implements AttributeModifier<SelectAttribute> {
  private readonly lightLevel: number;

  constructor(lightLevel: number = 3) {
    this.lightLevel = lightLevel;
  }

  applyNormalAttribute(instance: SelectAttribute): void {
    // 选项：透明底、无分隔线，选中项用品牌浅底 + 正文色（不用系统蓝）
    // 这一批是 API 11~20 就有的老属性，老设备一定有；仍然整体 try 住，任何一条不支持都只丢样式不崩
    try {
      instance.optionBgColor(Color.Transparent);
      instance.divider(null);
      instance.selectedOptionBgColor(Theme.BRAND_SOFT);
      instance.selectedOptionFontColor(Theme.TEXT_1);
      instance.optionFontColor(Theme.TEXT_1);
      instance.menuBackgroundColor(Theme.SURFACE);
      instance.menuBackgroundBlurStyle(BlurStyle.COMPONENT_THICK);
      if (deviceInfo.sdkApiVersion >= 20) {
        instance.menuOutline({ width: 0.5, color: Theme.HAIRLINE });
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'apply menu style failed: %{public}s', `${(e as Error).message}`);
    }
    // 真光感：仅 API 26+；老系统上 menuSystemMaterial 根本不存在，调用会抛 TypeError
    if (deviceInfo.sdkApiVersion < MATERIAL_MIN_API) {
      return;
    }
    try {
      instance.menuSystemMaterial(immersiveMedium());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'menuSystemMaterial unsupported: %{public}s', `${(e as Error).message}`);
    }
  }
}
