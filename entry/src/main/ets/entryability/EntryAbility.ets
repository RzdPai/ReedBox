import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import window from '@ohos.window';
import display from '@ohos.display';
import { UIContext } from '@kit.ArkUI';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import BusinessError from '@ohos.base';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { initStore, loadSettings, LogStore } from '../model/Store';
import { publishAppForeground, subscribeVpnEvents, unsubscribeVpnEvents } from '../core/VpnIpc';
import { VpnService } from '../core/VpnService';
import { markSubFailure, markSubSuccess, needAutoUpdate, updateSubscription } from '../core/Subscriptions';
import { subErrorText } from '../utils/Subscription';
import { AppState } from '../core/AppState';
import { AppSettings } from '../model/Profile';
import { KeepAlive } from '../core/KeepAlive';
import { VpnRuntime } from '../core/VpnRuntime';

/**
 * 窗口/系统栏底色的**显式**取值，与 `resources/{base,dark}/element/color.json` 的 `bg_page` 逐字一致。
 *
 * 为什么不直接读资源：`setColorMode()` 是异步生效的，而 `onWindowStageCreate` 里
 * `getMainWindow().then(...)` 完全可能**先于**它跑到 —— 那时读到的还是上一个色彩模式的值。
 * 于是夜间模式会出现"内容已经是深色、状态栏与底部却是一块白色"。
 * 所以底色按判定结果走常量，读到的资源色只用来交叉验证。
 */
const WINDOW_BG_LIGHT: string = '#F5F5F6';
const WINDOW_BG_DARK: string = '#0E0E0F';
/** 官方断点（vp）：XS ≤320 / SM 320~600 / MD 600~840 / LG ≥840 */
const BREAKPOINT_MEDIUM: number = 600;
const BREAKPOINT_LARGE: number = 840;

export default class EntryAbility extends UIAbility {
  private backgroundUpdating: boolean = false;
  private mainWindow?: window.Window;
  /** 用来把 px 换 vp（断点判定见 publishBreakpoint） */
  private uiContext: UIContext | undefined = undefined;
  private darkTheme: boolean = false;
  /** 已经**下发过**的目标色彩模式（去重用的真源）。
   *  ⚠️ 不要拿 `this.context.config.colorMode` 当去重依据：它读的是"已解析"的档位
   *  （跟随系统时永远是 DARK/LIGHT），用它比对会让 setColorMode 每次都下发 ⇒
   *  setColorMode → onConfigurationUpdate → applyAppearance → setColorMode 自激死循环
   *  （真机现象：卡在开屏页，第一帧永远画不出来）。 */
  private desiredColorMode: ConfigurationConstant.ColorMode | undefined = undefined;
  private appearancePref: string = 'system';
  private appearanceApplying: boolean = false;
  private readonly windowSizeListener = (size: window.Size): void => {
    this.publishBreakpoint(size.width, size.height);
  };

  /**
   * 断点必须用 **vp** 比（官方 GridRow 默认断点 `["320vp","600vp","840vp"]`，枚举
   * XS ≤320vp / SM 320~600vp / MD 600~840vp / LG ≥840vp）。
   * ⚠️ `windowSizeChange` 的 `size.width` 与 `windowRect.width` 都是 **px**
   * （官方 window FAQ 原文："窗口宽度，单位px"）。之前直接拿 px 跟 600/900 比，
   * 1224px 的手机被算成 large ⇒ 手机上出现了"平板常驻侧栏"（甲方 2026-11-01 反馈）。
   */
  private pxToVp(px: number): number {
    if (this.uiContext !== undefined) {
      try {
        return this.uiContext.px2vp(px);
      } catch (e) {
        // 落到 display 的 densityPixels 兜底
      }
    }
    try {
      const info = display.getDefaultDisplaySync();
      const density: number = info.densityPixels > 0 ? info.densityPixels : 0;
      if (density > 0) {
        return px / density;
      }
    } catch (e) {
      // 最后兜底：当作已经是 vp
    }
    return px;
  }

  private publishBreakpoint(widthPx: number, heightPx: number = 0): void {
    const widthVp: number = this.pxToVp(widthPx);
    const heightVp: number = heightPx > 0 ? this.pxToVp(heightPx) : 0;
    const breakpoint: string = widthVp < BREAKPOINT_MEDIUM
      ? 'compact'
      : (widthVp < BREAKPOINT_LARGE ? 'medium' : 'large');
    const state: AppState = AppState.get();
    state.breakpoint = breakpoint;
    if (heightVp > 0) {
      // 侧栏"常驻"用短边判定：手机横屏（780x360vp）仍走抽屉，只有平板级设备才固定左栏
      state.shortSide = Math.min(widthVp, heightVp);
    }
    LogStore.addLog(`[ui] breakpoint=${breakpoint} w=${Math.round(widthVp)}vp h=${Math.round(heightVp)}vp`
      + ` short=${Math.round(state.shortSide)}vp`);
  }

  private async updateDueSubscriptionsInBackground(): Promise<void> {
    if (this.backgroundUpdating) {
      return;
    }
    this.backgroundUpdating = true;
    let backgroundRunning: boolean = false;
    try {
      /**
       * ★ 先让状态层把数据初始化完，再谈"自动更新订阅"。
       * 这里原来是自己 `initStore + loadSettings` 直接开工，和 `Bootstrap.ensureInit()`
       * 并行读/写同一份节点表（reloadData 里的 applySelection、孤儿归组都会写），
       * 谁后写谁赢 —— 表现就是"有时候进软件，节点上的延迟/流量是空的"。
       */
      const state: AppState = AppState.get();
      state.attachContext(this.context);
      await state.ensureInit();
      const settings: AppSettings = state.settings;
      if (!settings.autoUpdateSubs) {
        return;
      }
      const due = await needAutoUpdate();
      if (due.length === 0) {
        return;
      }
      /**
       * ★ 一个 UIAbility 同时只能挂一个长时任务（9800005）。VPN 连着时 KeepAlive 已经挂了一个，
       *   这里再挂会失败、而且 finally 里的 stop 会把 VPN 那个拆掉 ⇒ 保活白做。
       *   所以只有"当前没有任务"时才临时挂，结束时也只拆自己挂的那个。
       */
      if (KeepAlive.isActive()) {
        LogStore.addLog('[app] 已有长时任务（VPN 保活），更新订阅直接复用');
      } else {
        const agent = await wantAgent.getWantAgent({
          wants: [{
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: 'EntryAbility'
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 1003,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        backgroundRunning = true;
      }
      for (const sub of due) {
        try {
          const result = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          LogStore.addLog(`[app] 后台更新订阅 ${sub.name}：新增 ${result.added}、移除 ${result.removed}、共 ${result.total}`);
        } catch (e) {
          await markSubFailure(sub.url);
          LogStore.addLog(`[app] 后台更新订阅 ${sub.name} 失败：${subErrorText(e as Object)}`);
        }
      }
      await AppState.get().reloadData();
    } catch (e) {
      LogStore.addLog(`[app] 后台订阅更新任务失败：${e}`);
    } finally {
      if (backgroundRunning) {
        try {
          await backgroundTaskManager.stopBackgroundRunning(this.context);
        } catch (e) {
          LogStore.addLog(`[app] 释放后台订阅任务失败：${e}`);
        }
      }
      this.backgroundUpdating = false;
    }
  }

  private rgbHex(color: number): string {
    const hex = (value: number): string => value.toString(16).padStart(2, '0').toUpperCase();
    return `#${hex((color >> 16) & 0xFF)}${hex((color >> 8) & 0xFF)}${hex(color & 0xFF)}`;
  }

  private isDarkColor(color: number): boolean {
    const red = (color >> 16) & 0xFF;
    const green = (color >> 8) & 0xFF;
    const blue = color & 0xFF;
    return (red * 299 + green * 587 + blue * 114) / 1000 < 128;
  }

  private resolveDark(appearance: string, configColorMode?: ConfigurationConstant.ColorMode): boolean {
    if (appearance === 'dark') {
      return true;
    }
    if (appearance === 'light') {
      return false;
    }
    const mode: ConfigurationConstant.ColorMode | undefined = configColorMode ?? this.context.config.colorMode;
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return true;
    }
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      return false;
    }
    try {
      return this.isDarkColor(this.context.resourceManager.getColorSync($r('app.color.bg_page')));
    } catch (e) {
      return false;
    }
  }

  /** 同步窗口底色与系统栏颜色（幂等，配置变化时会再调一次） */
  private async syncWindowAppearance(win?: window.Window): Promise<void> {
    const target = win ?? this.mainWindow;
    if (target === undefined) {
      return;
    }
    try {
      const dark: boolean = this.darkTheme;
      let background: string = dark ? WINDOW_BG_DARK : WINDOW_BG_LIGHT;
      try {
        const resolved: number = this.context.resourceManager.getColorSync($r('app.color.bg_page'));
        if (this.isDarkColor(resolved) === dark) {
          background = this.rgbHex(resolved);
        } else {
          LogStore.addLog(`[app] 主题色与色彩模式不一致（资源=${this.rgbHex(resolved)}, dark=${dark}），按常量兜底`);
        }
      } catch (e) {
        // 读资源失败不影响：上面已有常量兜底
      }
      const contentColor: string = dark ? '#FFFFFFFF' : '#FF000000';
      target.setWindowBackgroundColor(background);
      /* 系统栏**必须透明**：写成不透明的页面底色时，系统会在窗口最上面画一条死色状态栏，
         画进状态栏区域的 HDS 材质会被整条盖住（表现为"状态栏像单独画了一条"）。 */
      target.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
      LogStore.addLog(`[app] 窗口外观：bg=${background} dark=${dark}`);
    } catch (e) {
      LogStore.addLog(`[app] 同步窗口主题失败：${e}`);
    }
  }

  private async applyAppearance(configColorMode?: ConfigurationConstant.ColorMode): Promise<void> {
    if (this.appearanceApplying) {
      return;
    }
    this.appearanceApplying = true;
    try {
      await initStore(this.context);
      const settings = await loadSettings();
      this.appearancePref = settings.appearance;
      const target: ConfigurationConstant.ColorMode = settings.appearance === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (settings.appearance === 'light'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      if (this.desiredColorMode !== target) {
        this.desiredColorMode = target;
        this.context.setColorMode(target);
      }
      this.darkTheme = this.resolveDark(settings.appearance, configColorMode);
      await this.syncWindowAppearance();
    } catch (e) {
      LogStore.addLog(`[app] 应用主题失败：${e}`);
    } finally {
      this.appearanceApplying = false;
    }
  }

  private handleAction(want: Want): void {
    if (want.parameters === undefined || `${want.parameters['action']}` !== 'disconnect') {
      return;
    }
    VpnService.disconnect(this.context).catch((e: Object) => {
      LogStore.addLog(`[app] 通知栏断开失败：${e}`);
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] ReedBox 启动');
    // 全局状态先拿到 context，页面侧就不必到处 getContext
    AppState.get().attachContext(this.context);
    this.handleAction(want);
    this.applyAppearance();
    this.updateDueSubscriptionsInBackground();
    try {
      notificationManager.requestEnableNotification(this.context, (err: BusinessError) => {
        if (err && err.code !== 0) {
          LogStore.addLog(`[app] 通知权限未授予：${err.code}`);
        }
      });
    } catch (e) {
      // 用户拒绝通知不影响功能
    }
    // 接收 :vpn 扩展进程发来的日志 / 状态 / 流量
    subscribeVpnEvents((line: string) => {
      LogStore.appendRemote(line);
    }, (status: string, running: boolean, profileId: string) => {
      const current: AppState = AppState.get();
      current.applyVpnStatus(status, running, profileId);
    }, (upSpeed: number, downSpeed: number, totalUp: number, totalDown: number,
      running: boolean, profileId: string) => {
      const current: AppState = AppState.get();
      // 流量事件带着会话状态(见 AppState.applyTraffic):UI 进程新起时靠它把"已连接"补回来
      current.applyTraffic(upSpeed, downSpeed, totalUp, totalDown, running, profileId);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] 收到新的 Want');
    this.handleAction(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Bootstrap', (err) => {
      if (err.code) {
        LogStore.addLog(`[app] 加载首页失败：${err.message}`);
        return;
      }
      windowStage.getMainWindow().then((win: window.Window) => {
        this.mainWindow = win;
        /* ★ 窗口级全屏布局（RzdMusic `WindowUtil.setFullScreen` / Neko4 同款）：
           不开它，窗口内容区就止于手势条上方，列表**永远**到不了屏幕最底下
           （甲方 2026-11-01 第五次反馈："Neko4 就是一直延伸到最底部的，RzdCard/RzdMusic 那些都是到最底部的"）。
           配套三件套（照 RzdMusic `LocalMusicView` 的注释）：
             · 页面根：`expandSafeArea(TOP,BOTTOM)` + `ignoreLayoutSafeArea(TOP,BOTTOM)` ⇒ 页面盒子从屏幕 y=0 起排；
             · 内容列：`padding({ top: 实测状态栏高 })` ⇒ 自绘页头正好落在状态栏下沿（不要再多让一次）；
             · 底部：**一律不加 navBottom 留白** ⇒ 列表直接铺到屏幕物理底（手势条压在上面）。
           排查：`hilog | grep '开启全屏布局失败'`（成功不打这行）。 */
        win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
          LogStore.addLog(`[app] 开启全屏布局失败：${e.message}`);
        });
        try {
          this.uiContext = win.getUIContext();
        } catch (e) {
          this.uiContext = undefined;
        }
        const rect: window.Rect = win.getWindowProperties().windowRect;
        // ⚠️ rect 是 px，publishBreakpoint 内部换算成 vp 再比断点
        this.publishBreakpoint(rect.width, rect.height);
        win.on('windowSizeChange', this.windowSizeListener);
        // 拿到窗口后重放一次主题（onCreate 那次只下发了色彩模式，窗口还没有）
        this.applyAppearance();
      }).catch((e: Object) => {
        LogStore.addLog(`[ui] 初始化窗口断点失败：${e}`);
      });
    });
  }

  /**
   * 色彩模式变化时**只重放窗口/系统栏颜色**：不调 setColorMode（会自激）、不读存储、不做异步 IO。
   * 这条回调在 UI 主线程上，必须是最轻的同步动作。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.darkTheme = this.resolveDark(this.appearancePref, newConfig.colorMode);
    this.syncWindowAppearance();
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined) {
      this.mainWindow.off('windowSizeChange', this.windowSizeListener);
      this.mainWindow = undefined;
    }
  }

  onDestroy(): void {
    unsubscribeVpnEvents();
  }

  onForeground(): void {
    this.applyAppearance();
    this.updateDueSubscriptionsInBackground();
    publishAppForeground();
  }

  onBackground(): void {
    this.updateDueSubscriptionsInBackground();
  }
}
