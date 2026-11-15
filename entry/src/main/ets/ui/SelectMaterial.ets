import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme } from './Theme';

/**
 * 下拉选择菜单的"光感"材质（照 RzdMusic「回响页」年月切换那套做法）。
 *
 * 关键结论（本机 SDK 26 已核对）：
 *  · `Select` 的 menu 专属属性支持**系统沉浸材质**：`menuSystemMaterial(Optional<SystemUiMaterial>)`（API 26）；
 *  · `bindMenu` 的 `MenuOptions` **没有**材质字段 ⇒ 真光感只能用 `Select`；
 *  · 兜底链：`menuSystemMaterial`（真光感）→ `menuBackgroundBlurStyle` + `menuBackgroundColor`（厚模糊）
 *    → 只剩纯色底；`menuOutline` 需要 API 20+。
 *
 * 用法：`Select(options).attributeModifier(new HdsSelectMenuMaterial())`
 * 排查：`hilog | grep NekoBox-Material`
 */

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Material';

/** 取沉浸材质；设备不支持时返回 undefined（`menuSystemMaterial(undefined)` = 不用材质，安全降级） */
export function immersiveMaterial(style: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.REGULAR):
  SystemUiMaterial | undefined {
  try {
    if (!uiMaterial.isImmersiveMaterialSupported()) {
      hilog.info(DOMAIN, TAG, 'immersive material unsupported, fallback to blur');
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: style,
      applyShadow: true,
      interactive: true
    });
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'build material failed: %{public}s', `${(e as Error).message}`);
    return undefined;
  }
}

/** 中等厚度（最常用） */
export function immersiveMedium(): SystemUiMaterial | undefined {
  return immersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR);
}

/** 把 HDS 的"光感下拉"样式挂到任意 Select 上 */
export class HdsSelectMenuMaterial implements AttributeModifier<SelectAttribute> {
  private readonly lightLevel: number;

  constructor(lightLevel: number = 3) {
    this.lightLevel = lightLevel;
  }

  applyNormalAttribute(instance: SelectAttribute): void {
    // 选项：透明底、无分隔线，选中项用品牌浅底 + 正文色（不用系统蓝）
    instance.optionBgColor(Color.Transparent);
    instance.divider(null);
    instance.selectedOptionBgColor(Theme.BRAND_SOFT);
    instance.selectedOptionFontColor(Theme.TEXT_1);
    instance.optionFontColor(Theme.TEXT_1);
    // 菜单底板：面板色 + 厚模糊兜底，再叠系统沉浸材质（真光感，不支持时自动忽略）
    instance.menuBackgroundColor(Theme.SURFACE);
    instance.menuBackgroundBlurStyle(BlurStyle.COMPONENT_THICK);
    instance.menuSystemMaterial(immersiveMedium());
    if (deviceInfo.sdkApiVersion >= 20) {
      instance.menuOutline({ width: 0.5, color: Theme.HAIRLINE });
    }
  }
}
