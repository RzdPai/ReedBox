import common from '@ohos.app.ability.common';
import { AppSettings, Profile, ProfileGroup } from '../model/Profile';
import {
  ensureGroupByName,
  getRunningProfileId,
  initStore,
  loadGroups,
  loadProfiles,
  loadSettings,
  LogStore,
  mutateProfiles,
  readPrefString,
  saveGroups,
  saveProfiles,
  saveSettings as persistSettings,
  writePrefString
} from '../model/Store';
import { RemoteRuleSet, RouteRule, loadRemoteRuleSets, loadRouteRules, saveRouteRules } from '../model/RouteRule';
import {
  listSubs,
  removeSub,
  saveSubSettings,
  setAppContext,
  SubInfo,
  updateSubscription,
  upsertSub
} from './Subscriptions';
import { VpnService } from './VpnService';
import { parseShareText } from '../utils/LinkParser';
import { subErrorText } from '../utils/Subscription';
import {
  LatencyPassCount,
  LatencyRunReport,
  LatencyTestOutcome,
  testProfiles,
  urlTestProfiles
} from '../utils/LatencyTester';
import { downloadGeoAsset } from '../utils/GeoAssets';
import { VpnRuntime } from './VpnRuntime';
import { Accent } from '../ui/Accent';
import { Handedness } from './Handedness';
import { KeepAlive } from './KeepAlive';
import { publishVpnLatency } from './VpnIpc';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-State';

/**
 * 老版本从 Clash 订阅里带进来的默认组名（一次性清理迁移用）。
 * 本工程**不再导入**这些东西：订阅只贡献节点，分组只来自用户或订阅本身。
 */
const CLASH_GROUP_NAMES: Array<string> = ['节点选择', '自动选择', '漏网之鱼', '全球直连', '全球拦截', '广告拦截',
  '微软服务', '苹果服务', '谷歌服务', '电报消息', '兜底分流', '国外流量', '国内流量', 'Proxy', 'Auto', 'Direct', 'REJECT'];
const KEY_CLASH_PURGED: string = 'clash_groups_purged_v1';
/** 智感握姿"默认关"的一次性迁移标记（只写一次，之后尊重用户手动开关） */
const MIGRATION_HAND_AWARENESS: string = 'migration_hand_awareness_default_off';
/** 没有分组可用时的兜底分组名（导入节点 / 删除基础分组后接收节点） */
const UNNAMED_GROUP: string = '未命名';

/**
 * 全局状态（V2：`@ObservedV2` + `@Trace`，模块级单例）。
 *
 * 这一层是 UI 与业务之间**唯一**的接口：
 *   · UI 只读这里的 `@Trace` 字段、只调这里的方法；
 *   · 业务层（core/ model/ utils/）里没有任何 `@Component`，所以两套界面可以共用同一份。
 *
 * 纪律：**数组类字段一律整表替换**（`this.profiles = next`），不要在 UI 里改元素字段后指望重绘 ——
 * `Profile` 是纯数据类（不是 `@ObservedV2`），改字段不会触发通知。
 */
@ObservedV2
export class AppState {
  /** Runtime is authoritative; these @Trace fields are the UI-facing V2 mirror. */
  private readonly runtime: VpnRuntime = VpnRuntime.get();
  @Trace vpnRunning: boolean = false;
  @Trace vpnStatus: string = 'disconnected';
  @Trace runningProfileId: string = '';
  @Trace upSpeed: number = 0;
  @Trace downSpeed: number = 0;
  @Trace totalUp: number = 0;
  @Trace totalDown: number = 0;
  @Trace connectedAt: number = 0;
  private runtimeSubscribed: boolean = false;
  /** 上一次镜像到的"是否在跑"，用来识别"刚断开"这个时刻（见 syncRuntimeMirror） */
  private mirroredRunning: boolean = false;
  private onRuntimeChanged = (): void => {
    this.syncRuntimeMirror();
  };

  private syncRuntimeMirror(): void {
    const wasRunning: boolean = this.mirroredRunning;
    this.vpnRunning = this.runtime.vpnRunning;
    this.vpnStatus = this.runtime.vpnStatus;
    this.runningProfileId = this.runtime.runningProfileId;
    this.upSpeed = this.runtime.upSpeed;
    this.downSpeed = this.runtime.downSpeed;
    this.totalUp = this.runtime.totalUp;
    this.totalDown = this.runtime.totalDown;
    this.connectedAt = this.runtime.connectedAt;
    this.mirroredRunning = this.vpnRunning;
    // 后台保活：连着的时候给 UI 进程挂一个"数据传递"长时任务（进程被回收 = 系统会停掉 VPN）
    if (this.vpnRunning) {
      KeepAlive.ensureStarted(this.context);
    } else {
      KeepAlive.ensureStopped(this.context);
    }
    if (wasRunning && !this.vpnRunning && this.ready) {
      // 断开时扩展进程会把本次会话流量累加进节点记录（profileTrafficStatistics）：
      // 重新读一次，节点卡上的 ↑tx ↓rx 才是最新值，而不是上次启动时的旧数。
      this.reloadProfiles().catch((e: Error): void => {
        this.log(`[ui] 断线后重读节点统计失败：${e.message}`);
      });
    }
    this.bump();
  }

  // ---------------- 业务数据 ----------------
  @Trace ready: boolean = false;
  @Trace bootError: string = '';
  @Trace profiles: Array<Profile> = [];
  @Trace groups: Array<ProfileGroup> = [];
  @Trace settings: AppSettings = new AppSettings();
  @Trace subs: Array<SubInfo> = [];
  @Trace rules: Array<RouteRule> = [];
  @Trace remoteSets: Array<RemoteRuleSet> = [];
  @Trace selectedId: string = '';
  /** 请求首页切到某个分组页签（导入落地后由页面消费并清空） */
  @Trace pendingGroupId: string = '';
  /**
   * 首页当前分组页签（真源）。
   * ⚠️ 以前这是 `ProfilesPage` 的 `@Local groupIndex` —— 组件一重建就归零：
   *   切到「设置」再切回来、或者重启软件，都会从 A 分组跳回第 1 个分组
   *   （甲方 2026-11-15 反馈）。现在按 **分组 id** 存在这里并落盘，
   *   页面只负责把它映射成下标（分组增删/排序后下标会变，存下标必然错位）。
   */
  @Trace selectedGroupId: string = '';

  // ---------------- 交互态 ----------------
  /** Business data revision. Notify only after the complete mutation is committed. */
  @Trace rev: number = 0;
  /** 窗口断点（compact / medium / large），由 EntryAbility 的 windowSizeChange 写入 */
  @Trace breakpoint: string = 'compact';
  /**
   * 窗口**短边**（vp）。侧栏"常驻左栏"只看这个：手机横屏（780×360vp）短边仍是 360 ⇒ 继续用抽屉，
   * 只有平板级设备（短边 ≥600vp）才固定左栏。
   */
  @Trace shortSide: number = 360;
  /** 请求外壳切侧栏分区（-1 = 无请求）。页面里不要直接改外壳状态，改这里由 Bootstrap 执行 */
  @Trace pendingSection: number = -1;
  /** 节点编辑页的目标 id（空串 = 新建）。页面跳转前由 gotoProfileEdit 写入 */
  @Trace editingProfileId: string = '';
  /** 新建节点时的预设协议（"添加 [VMess]" 这类入口用），空串 = 默认 VLESS */
  @Trace editingProfileType: string = '';
  /** 新建节点时要落进的分组（首页当前页签），空串 = 兜底到「未命名」 */
  @Trace editingGroupId: string = '';
  @Trace busyText: string = '';
  @Trace testing: boolean = false;
  @Trace testDone: number = 0;
  @Trace testTotal: number = 0;
  /** 正在跑的那一轮叫什么（'TCPing' / 'URL Test'），并发请求被拒时要靠它说清楚 */
  @Trace testLabel: string = '';

  /** ★ 变更订阅者：任何写操作末尾都会同步回调（页面据此自增 tick 重绘） */
  private listeners: Array<() => void> = [];

  subscribe(cb: () => void): void {
    if (this.listeners.indexOf(cb) < 0) {
      this.listeners.push(cb);
    }
  }

  unsubscribe(cb: () => void): void {
    const index: number = this.listeners.indexOf(cb);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private context: common.UIAbilityContext | undefined = undefined;
  private initStarted: boolean = false;
  private toastSeq: number = 0;

  /**
   * 标记「业务数据已变」。
   * 页面用 `this.app.rev` 建立显式依赖（@Computed / ForEach key），
   * 这样即使某个字段的细粒度通知有意外，界面也不会停在旧数据上
   * （甲方 2026-11-01 反馈：改完设置/导入后界面不刷新，要重启才看到）。
   */
  /** 页面需要强制刷新时用（例如只改了排序偏好） */
  requestRefresh(): void {
    this.bump();
  }

  private bump(): void {
    this.rev = this.rev + 1;
    // 同步回调：界面不依赖细粒度通知，收到就重绘（甲方反馈过"要切页才刷新"）
    const list: Array<() => void> = this.listeners.slice();
    for (const cb of list) {
      try {
        cb();
      } catch (e) {
        this.log(`[ui] 刷新回调异常：${(e as Error).message}`);
      }
    }
  }

  static get(): AppState {
    if (AppState.holder === undefined) {
      AppState.holder = new AppState();
    }
    return AppState.holder;
  }

  private static holder: AppState | undefined = undefined;

  // ------------------------------------------------------------------ 初始化

  /** 入口 Ability 在 onCreate 里注入 context（页面里不再到处 getContext） */
  attachContext(context: common.UIAbilityContext): void {
    this.context = context;
    if (!this.runtimeSubscribed) {
      this.runtime.subscribe(this.onRuntimeChanged);
      this.runtimeSubscribed = true;
    }
    this.syncRuntimeMirror();
  }

  uicontext(): common.UIAbilityContext | undefined {
    return this.context;
  }

  /** 幂等启动：读 store → 读业务数据 → 恢复上次节点 */
  async ensureInit(): Promise<void> {
    if (this.initStarted || this.context === undefined) {
      return;
    }
    this.initStarted = true;
    try {
      await initStore(this.context);
      setAppContext(this.context);
      this.settings = await loadSettings();
      // 智感握姿"默认关"的一次性迁移（只跑一次，见方法注释）
      await this.migrateHandAwarenessOnce();
      // 主题色：设置里存的是十六进制串（空串 = 默认蓝），启动就套上，页面一处不用改
      Accent.get().apply(this.settings.themeColor, this.resolveDarkTheme());
      // 智感握姿开关：关掉就不再订阅系统服务（布局固定「按钮右、其余左」）
      Handedness.get().setEnabled(this.settings.handAwareness);
      // ★ 必须在**第一次 reloadData 之前**读出上次选中：reloadData 里的 applySelection('') 会把
      //   选中项兜底成列表第一个，之后再读偏好就已经被覆盖了
      //   （甲方 2026-11-01：选中的是 A，重启后跳到列表第 1 个）。
      const runningId: string = await getRunningProfileId();
      const lastSelected: string = await readPrefString('selected_profile_id', '');
      const preferredId: string = lastSelected.length > 0 ? lastSelected : runningId;
      await this.reloadData();
      await this.purgeClashGroupsOnce();
      await this.reloadData();
      await this.repairDuplicateSubGroups();
      await this.adoptOrphans();
      this.applySelection(preferredId);
      await this.restoreSelectedGroup(this.selectedId);
      // 兜底结果也写回偏好，避免"上次选中被删 → 每次启动都重新猜"。
      await writePrefString('selected_profile_id', this.selectedId);
      this.ready = true;
      this.bump();
      this.log(`[ui] 状态初始化完成：节点 ${this.profiles.length}，分组 ${this.groups.length}，`
        + `订阅 ${this.subs.length}，选中 ${this.selectedId}，页签 ${this.selectedGroupId}`);
    } catch (e) {
      this.initStarted = false;
      this.bootError = `初始化失败：${(e as Error).message}`;
      this.log(`[ui] 初始化失败：${(e as Error).message}`);
    }
  }

  private log(line: string): void {
    LogStore.addLog(line);
  }

  /**
   * 智感握姿"默认关"的**一次性迁移**。
   *
   * 背景：这个字段是 0.5.55 才加的，之前不存在 ⇒ 老装机器的设置里没有它，`loadSettings()` 会填默认值。
   * 但**已经装过 0.5.55/0.5.56 的机器**把 `true` 存进去了 —— 只改默认值对他们无效（甲方 2026-11-01 要求"默认关"）。
   * 做法：用独立的偏好键当迁移标记，**只跑一次**：第一次启动把开关置 false 并落盘，
   * 之后用户手动打开就按用户的选择，不再被启动逻辑覆盖。
   * 排查：`hilog | grep '智感握姿迁移'`。
   */
  private async migrateHandAwarenessOnce(): Promise<void> {
    const migrated: string = await readPrefString(MIGRATION_HAND_AWARENESS, '');
    if (migrated === '1') {
      return;
    }
    const forcedOff: boolean = this.settings.handAwareness;
    if (forcedOff) {
      this.settings.handAwareness = false;
      await persistSettings(this.settings);
    }
    await writePrefString(MIGRATION_HAND_AWARENESS, '1');
    this.log(`[ui] 智感握姿迁移：默认关（原值=${forcedOff ? '开' : '本就关'}，仅此一次）`);
  }

  /**
   * 当前是否深色（`appearance` 跟随系统时按页面底色亮度判断）。
   * 只用来决定"主题色留空时用哪支默认蓝"，不需要绝对精确。
   */
  private resolveDarkTheme(): boolean {
    if (this.settings.appearance === 'dark') {
      return true;
    }
    if (this.settings.appearance === 'light') {
      return false;
    }
    try {
      if (this.context === undefined) {
        return false;
      }
      const value: number = this.context.resourceManager.getColorSync($r('app.color.bg_page'));
      const r: number = (value >> 16) & 0xFF;
      const g: number = (value >> 8) & 0xFF;
      const b: number = value & 0xFF;
      return (r * 299 + g * 587 + b * 114) / 1000 < 128;
    } catch (e) {
      return false;
    }
  }

  /** 设置 → 智感握姿开关：立即生效（含退订/重订系统服务）+ 落盘 */
  async setHandAwareness(enabled: boolean): Promise<void> {
    this.settings.handAwareness = enabled;
    Handedness.get().setEnabled(enabled);
    await persistSettings(this.settings);
    this.bump();
    this.log(`[ui] 智感握姿 = ${enabled ? 'on' : 'off'}`);
  }

  /** 设置 → 主题色：立即生效 + 落盘（空串 = 恢复默认蓝） */
  async setThemeColor(color: string): Promise<void> {
    this.settings.themeColor = color;
    Accent.get().apply(color, this.resolveDarkTheme());
    await persistSettings(this.settings);
    this.bump();
    this.log(`[ui] 主题色 = ${color.length > 0 ? color : '(默认)'}`);
  }

  // ------------------------------------------------------------------ 数据加载

  async reloadData(): Promise<void> {
    this.profiles = await loadProfiles();
    this.groups = await loadGroups();
    this.subs = await listSubs();
    this.rules = await loadRouteRules();
    this.remoteSets = await loadRemoteRuleSets();
    // 分组可能刚被删/改名：页签指向一个不存在的分组时退到"当前选中节点所在的分组"
    if (this.selectedGroupId.length > 0 && !this.hasGroup(this.selectedGroupId)) {
      this.selectedGroupId = this.groupOfProfile(this.selectedId);
    }
    this.applySelection(this.selectedId);
    this.bump();
  }

  async reloadProfiles(): Promise<void> {
    this.profiles = await loadProfiles();
    this.groups = await loadGroups();
    this.applySelection(this.selectedId);
    this.bump();
  }

  async reloadSubs(): Promise<void> {
    this.subs = await listSubs();
    this.bump();
  }

  async reloadRules(): Promise<void> {
    this.rules = await loadRouteRules();
    this.remoteSets = await loadRemoteRuleSets();
    this.bump();
  }

  /** 选中项自愈：选中的节点被删/被订阅替换掉时，退到第一个节点 */
  private applySelection(id: string): void {
    let found: Profile | undefined = undefined;
    for (const p of this.profiles) {
      if (p.id === id) {
        found = p;
        break;
      }
    }
    if (found === undefined && this.profiles.length > 0) {
      found = this.profiles[0];
    }
    this.selectedId = found === undefined ? '' : found.id;
  }

  selectedProfile(): Profile | undefined {
    for (const p of this.profiles) {
      if (p.id === this.selectedId) {
        return p;
      }
    }
    return this.profiles.length > 0 ? this.profiles[0] : undefined;
  }

  // ------------------------------------------------------------------ 分组页签

  private hasGroup(groupId: string): boolean {
    if (groupId.length === 0) {
      return false;
    }
    for (const g of this.groups) {
      if (g.id === groupId) {
        return true;
      }
    }
    return false;
  }

  /** 某个节点所在分组（没有归属/分组已删返回空串） */
  private groupOfProfile(profileId: string): string {
    if (profileId.length === 0) {
      return '';
    }
    for (const p of this.profiles) {
      if (p.id === profileId && this.hasGroup(p.groupId)) {
        return p.groupId;
      }
    }
    return '';
  }

  /**
   * 恢复上次停留的分组页签。
   * 优先级：偏好里存的 id（分组还存在）→ 当前选中节点所在的分组 → 空串（页面按第 1 个显示）。
   * 空串是合法结果（没有分组），不要在这里兜底成第 1 个 —— 页面自己能算。
   */
  private async restoreSelectedGroup(selectedProfileId: string): Promise<void> {
    const saved: string = await readPrefString('selected_group_id', '');
    if (saved.length > 0 && this.hasGroup(saved)) {
      this.selectedGroupId = saved;
      return;
    }
    this.selectedGroupId = this.groupOfProfile(selectedProfileId);
  }

  /**
   * 首页切分组页签：写状态 + 落盘。
   * 不阻塞点击（写偏好失败只记日志），页面靠 `selectedGroupId` 的回调重绘。
   */
  selectGroupById(groupId: string): void {
    if (groupId.length === 0 || !this.hasGroup(groupId)) {
      return;
    }
    if (this.selectedGroupId === groupId) {
      return;
    }
    this.selectedGroupId = groupId;
    this.bump();
    writePrefString('selected_group_id', groupId).catch((e: Error): void => {
      this.log(`[ui-data] 保存当前分组失败：${e.message}`);
    });
  }

  runningProfile(): Profile | undefined {
    for (const p of this.profiles) {
      if (p.id === this.runningProfileId) {
        return p;
      }
    }
    return undefined;
  }

  profilesOfGroup(groupId: string): Array<Profile> {
    const out: Array<Profile> = [];
    for (const p of this.profiles) {
      if (p.groupId === groupId) {
        out.push(p);
      }
    }
    return out;
  }

  groupName(groupId: string): string {
    for (const g of this.groups) {
      if (g.id === groupId) {
        return g.name;
      }
    }
    return '未分组';
  }

  /** 分组标题；找不到（含空 id）返回空串 —— 用于"导入到哪个分组"，不能拿"未分组"当名字 */
  groupTitle(groupId: string): string {
    for (const g of this.groups) {
      if (g.id === groupId) {
        return g.name;
      }
    }
    return '';
  }

  // ------------------------------------------------------------------ 连接控制

  async toggleConnection(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    if (this.runtime.isBusy()) {
      this.log(`[vpn-control] tap ignored while ${this.vpnStatus}`);
      return;
    }
    if (this.vpnRunning) {
      await VpnService.disconnect(this.context);
      return;
    }
    const target: Profile | undefined = this.selectedProfile();
    if (target === undefined) {
      this.busyText = '请先导入或新建一个节点';
      return;
    }
    await writePrefString('selected_profile_id', target.id);
    await VpnService.connect(this.context, target.id);
  }

  /** 点某个节点：未连接 ⇒ 选中并连接；已连接 ⇒ 无缝切换 */
  async pickProfile(p: Profile): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.selectedId = p.id;
    this.bump();
    this.log(`[ui-data] selection committed profile=${p.id}`);
    await writePrefString('selected_profile_id', p.id);
    if (this.vpnRunning) {
      if (this.runningProfileId === p.id) {
        return;
      }
      this.busyText = `正在切换到 ${p.name}`;
      await VpnService.switchTo(this.context, p.id);
    }
  }

  async connectSelected(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const target: Profile | undefined = this.selectedProfile();
    if (target === undefined) {
      return;
    }
    await this.pickProfile(target);
    if (!this.vpnRunning) {
      await this.toggleConnection();
    }
  }

  /** 底部"刷新"用：已连接时重连当前节点（换网/掉线后最快恢复） */
  async reconnect(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const running: Profile | undefined = this.runningProfile();
    const target: Profile | undefined = running !== undefined ? running : this.selectedProfile();
    if (target === undefined) {
      return;
    }
    this.busyText = `正在重连 ${target.name}`;
    await VpnService.switchTo(this.context, target.id);
  }

  // ------------------------------------------------------------------ 测速

  /**
   * 对给定节点做延迟测试（URL Test 优先，失败自动退 TCPing，实现见 utils/LatencyTester）。
   *
   * `mode` 显式传入（'tcp' / 'url'），空串 = 用设置里的测速方式。
   * ⚠️ 以前是"先 patchSettings 改全局设置，再 await testLatency"：
   *   ① 改设置那次 await 之后，正在跑的那轮已经起来了，第二次点击又被 `if (this.testing) return`
   *      静默吞掉，调用方照旧弹「URL Test 完成」—— 甲方 2026-11-15 报的
   *      "TCPing 还没跑完就点 URL Test，直接提示已完成"就是这个；
   *   ② 同一时刻把 `latencyTestMode` 改掉，等于"这轮跑 TCPing、设置里写 URL"。
   * 现在模式只作为参数传进来，跑不跑由 `LatencyTestOutcome` 如实回报：
   *   `ran=false` 的调用方**不允许**再说"完成"。
   */
  async testLatency(targets: Array<Profile>, mode: string = ''): Promise<LatencyTestOutcome> {
    const outcome: LatencyTestOutcome = new LatencyTestOutcome();
    const wantedMode: string = mode.length > 0 ? mode : this.settings.latencyTestMode;
    const ctx: common.UIAbilityContext | undefined = this.context;
    // URL Test 必须有 UI 进程的 context 来写临时配置/起测速内核；没有就只能 TCPing
    const urlCtx: common.UIAbilityContext | undefined = wantedMode !== 'tcp' ? ctx : undefined;
    outcome.urlMode = urlCtx !== undefined;
    if (this.testing) {
      // 并发请求必须说清楚"现在跑的是哪一轮、还剩几个"，不能静默丢弃
      const left: number = Math.max(0, this.testTotal - this.testDone);
      const running: string = this.testLabel.length > 0 ? this.testLabel : '测速';
      outcome.busy = true;
      outcome.reason = `正在 ${running}${left > 0 ? `（还剩 ${left} 个节点）` : ''}，请等它结束`;
      this.log(`[test] 忽略并发测速请求：${outcome.reason}`);
      return outcome;
    }
    if (targets.length === 0) {
      outcome.reason = '没有可测速的节点';
      this.busyText = outcome.reason;
      return outcome;
    }
    // ★ 先占位再 await：`patchSettings` 会落盘（有 await），两次快速点击若都卡在它前面
    //   就会各起一轮（`testing` 还是 false）—— 这正是"并发测速"最难查的那种残留。
    this.testing = true;
    this.testDone = 0;
    this.testTotal = targets.length;
    this.testLabel = urlCtx !== undefined ? 'URL Test' : 'TCPing';
    this.busyText = `正在 ${this.testLabel} 测速 ${targets.length} 个节点…`;
    this.lastLatencyFlushAt = 0;
    // 记住"上次用的测速方式"（设置页「测速方式」显示的就是它）；只影响下一轮，不影响本轮
    if (mode.length > 0 && this.settings.latencyTestMode !== mode) {
      try {
        await this.patchSettings((s: AppSettings) => {
          s.latencyTestMode = mode;
        });
      } catch (e) {
        this.log(`[test] 保存测速方式失败：${(e as Error).message}`);
      }
    }
    const onResult = (id: string, ms: number): void => {
      this.testDone++;
      this.commitLatency(id, ms);
    };
    try {
      if (urlCtx === undefined) {
        const counts: LatencyPassCount = await testProfiles(targets, onResult, this.settings.testConcurrent,
          this.settings.testTimeoutMs, this.settings.testRetries, this.settings.testSamples);
        outcome.ok = counts.ok;
      } else {
        const report: LatencyRunReport = await urlTestProfiles(targets, this.profiles, this.settings,
          urlCtx, onResult, this.settings.testConcurrent, this.groups);
        outcome.ok = report.ok;
        outcome.degraded = report.degraded;
        outcome.degradeReason = report.degradeReason;
        outcome.bindFallback = report.bindFallback;
        if (report.degraded) {
          this.log(`[ui] URL Test 降级：${report.degradeReason}`);
        }
        if (report.bindFallback) {
          this.log('[ui] 绑定物理网卡导致全组失败，已去掉绑定重测（这批结果不可当作测量结论）');
        }
      }
      outcome.ran = true;
      outcome.total = targets.length;
      this.log(`[ui] ${this.testLabel} 结束：可用 ${outcome.ok}/${outcome.total}`);
    } catch (e) {
      outcome.reason = `测速失败：${(e as Error).message}`;
      this.busyText = outcome.reason;
      this.log(`[ui] ${this.testLabel} 失败：${(e as Error).message}`);
    } finally {
      // 已测到的结果必须落库：这轮中途出错/被打断也不该让前面的测量白费
      await this.flushLatency();
      this.testing = false;
      this.testDone = 0;
      this.testTotal = 0;
      this.testLabel = '';
      this.busyText = '';
    }
    return outcome;
  }

  /** 待落库的延迟结果（按节点 id） */
  private pendingLatency: Map<string, number> = new Map<string, number>();
  /** 串行写盘队列（与 Store.mutateProfiles 的队列呼应，避免两批结果互相覆盖） */
  private latencyQueue: Promise<void> = Promise.resolve();
  private lastLatencyFlushAt: number = 0;

  /**
   * 单个节点延迟：先在内存里落值让界面立刻变色，再把"仅这个字段"交给写盘队列。
   *
   * ⚠️ 原来这里是"改完内存 → 测完 `saveProfiles(this.profiles)` 整表覆盖"：
   *   · 测一整组要几十秒，期间订阅更新/会话流量统计写进磁盘的东西，
   *     会在结束时被这份旧快照整表冲掉（延迟保住了、流量/新节点丢了）；
   *   · 进程中途被系统回收则整轮白测。
   * 现在按 1.2s 节流分批 `mutateProfiles`，只改 latencyMs/latencyTestedAt。
   */
  private commitLatency(id: string, ms: number): void {
    for (const p of this.profiles) {
      if (p.id === id) {
        p.latencyMs = ms;
        p.latencyTestedAt = Date.now();
        // 正在连着的那个节点：把新延迟同步给 VPN 通知（以前这套通道定义了却没人调，通知里永远是 "--"）
        if (id === this.runningProfileId && ms >= 0) {
          publishVpnLatency(id, p.name, ms);
        }
      }
    }
    this.pendingLatency.set(id, ms);
    this.profiles = this.profiles.slice();
    this.bump();
    const now: number = Date.now();
    if (now - this.lastLatencyFlushAt >= 1200) {
      this.lastLatencyFlushAt = now;
      this.queueLatencyFlush();
    }
  }

  private queueLatencyFlush(): void {
    if (this.pendingLatency.size === 0) {
      return;
    }
    const batch: Map<string, number> = new Map<string, number>();
    this.pendingLatency.forEach((ms: number, id: string): void => {
      batch.set(id, ms);
    });
    this.pendingLatency.clear();
    this.latencyQueue = this.latencyQueue
      .then((): Promise<void> => this.applyLatencyBatch(batch))
      .catch((e: Error): void => {
        this.log(`[ui] 延迟结果落库失败：${e.message}`);
      });
  }

  /** 只按 id 覆写延迟两列；不整表覆盖，也不替换内存里的 `this.profiles`（可能还有更新的结果没落库） */
  private async applyLatencyBatch(batch: Map<string, number>): Promise<void> {
    const testedAt: number = Date.now();
    await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      for (const p of list) {
        const ms: number | undefined = batch.get(p.id);
        if (ms !== undefined) {
          p.latencyMs = ms;
          p.latencyTestedAt = testedAt;
        }
      }
      return list;
    });
  }

  private async flushLatency(): Promise<void> {
    this.queueLatencyFlush();
    await this.latencyQueue;
  }

  /**
   * 新建分组。**订阅不是一个独立功能，而是分组的一种类型**（对齐 NekoBoxForAndroid / OwnBox）：
   *   type='basic'        → 空分组，节点靠"移动到分组"
   *   type='subscription' → 建组 + 记订阅（SubInfo.group 写成本组名，updateSubscription 就会把节点落进来）
   *
   * ⚠️ **一条订阅地址只能属于一个分组**（甲方 2026-11-01："同时添加两个链接相同的分组 Bug 较多"）：
   *   两个分组共用一个 URL 时，`SubInfo` 会被后建的那个覆盖 group/name，节点归属会来回打架
   *   （永远落进先建的那个组、后建的组永远是空、删任一个都会把订阅记录删掉）。
   *   所以这里**先校验再建组**（原来先建组后校验，非法地址会留下一个空分组）。
   */
  async addGroup(name: string, type: string, url: string, autoUpdate: boolean): Promise<string> {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return '请填写分组名称';
    }
    // 同名不能"就地改类型/地址"：那会把用户已有的分组悄悄变成订阅（改配置请用「设置」）
    for (const g of this.groups) {
      if (g.name.trim() === trimmed) {
        return `已存在同名分组「${trimmed}」，请换个名字或到「设置」里改`;
      }
    }
    const isSub: boolean = type === 'subscription';
    const subUrl: string = url.trim();
    if (isSub) {
      if (!subUrl.startsWith('http://') && !subUrl.startsWith('https://')) {
        return '订阅地址必须以 http(s):// 开头';
      }
      const owner: string = this.subscriptionOwnerName(subUrl);
      if (owner.length > 0) {
        return `这个订阅地址已经属于分组「${owner}」，不能重复添加（去那个分组里更新即可）`;
      }
    }
    const groupId: string = await ensureGroupByName(trimmed);
    const groups: Array<ProfileGroup> = await loadGroups();
    let target: ProfileGroup | undefined = undefined;
    for (const g of groups) {
      if (g.id === groupId) {
        target = g;
        g.type = isSub ? 'subscription' : 'basic';
        g.autoUpdate = autoUpdate;
        if (g.type === 'subscription') {
          g.url = subUrl;
        }
        g.updatedAt = Date.now();
      }
    }
    if (target === undefined) {
      return '创建分组失败';
    }
    if (!isSub) {
      await saveGroups(groups);
      await this.reloadData();
      return `已创建分组「${trimmed}」`;
    }
    await saveGroups(groups);
    await upsertSub(subUrl, '', trimmed);
    const changes: Record<string, Object> = { 'group': trimmed, 'autoUpdate': autoUpdate };
    await saveSubSettings(subUrl, changes);
    const result: string = await this.refreshSubscription(subUrl);
    if (result.startsWith('更新失败') || result.startsWith('订阅不可用')) {
      return `已创建订阅分组「${trimmed}」，但${result}`;
    }
    return `已创建订阅分组「${trimmed}」：${result}`;
  }

  /** 订阅地址对应的分组（`type='subscription' && url` 相同的第一条） */
  private subGroupForUrl(url: string): ProfileGroup | undefined {
    if (url.length === 0) {
      return undefined;
    }
    for (const g of this.groups) {
      if (g.type === 'subscription' && g.url === url) {
        return g;
      }
    }
    return undefined;
  }

  /** 该订阅地址现在的归属分组名（空串 = 没人用）；用于"一条订阅只能挂一个分组"的校验 */
  private subscriptionOwnerName(url: string): string {
    if (url.length === 0) {
      return '';
    }
    const group: ProfileGroup | undefined = this.subGroupForUrl(url);
    if (group !== undefined) {
      return group.name;
    }
    for (const s of this.subs) {
      if (s.url !== url || s.group.trim().length === 0) {
        continue;
      }
      for (const g of this.groups) {
        if (g.name.trim() === s.group.trim()) {
          return g.name;
        }
      }
    }
    return '';
  }

  /**
   * 订阅分组 → 基础分组：**保留节点**，断开订阅关系（`SubInfo` 删掉、节点 `subUrl` 清空），
   * 分组 type 改回 basic。首页那张订阅卡随之消失（甲方 2026-11-01：卡片只给真正的订阅分组）。
   * 返回保留下来的节点数。
   */
  async demoteGroupToBasic(g: ProfileGroup): Promise<number> {
    if (g.type !== 'subscription') {
      return 0;
    }
    const subUrl: string = g.url;
    if (subUrl.length > 0) {
      await removeSub(subUrl);
    }
    let kept: number = 0;
    await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      const next: Array<Profile> = list.slice();
      for (const p of next) {
        if (p.groupId === g.id) {
          kept++;
          if (p.subUrl === subUrl) {
            p.subUrl = '';
          }
        }
      }
      return next;
    });
    const groups: Array<ProfileGroup> = await loadGroups();
    for (const item of groups) {
      if (item.id === g.id) {
        item.type = 'basic';
        item.url = '';
        item.autoUpdate = false;
        item.lastError = '';
      }
    }
    await saveGroups(groups);
    await this.reloadData();
    this.log(`[ui-data] group ${g.id} demoted to basic, kept ${kept} nodes`);
    return kept;
  }

  /** 订阅分组对应的 SubInfo（更新状态/流量/错误都存那边，按 url 关联） */
  groupSub(g: ProfileGroup): SubInfo | undefined {
    for (const s of this.subs) {
      if (s.url === g.url) {
        return s;
      }
    }
    return undefined;
  }

  groupNodeCount(groupId: string): number {
    let count: number = 0;
    for (const p of this.profiles) {
      if (p.groupId === groupId) {
        count++;
      }
    }
    return count;
  }

  /** 更新订阅分组：拉一次 + 落库，并把 lastError 写回分组记录 */
  async refreshGroup(g: ProfileGroup): Promise<string> {
    if (g.type !== 'subscription' || g.url.length === 0) {
      return '该分组不是订阅';
    }
    const message: string = await this.refreshSubscription(g.url);
    const groups: Array<ProfileGroup> = await loadGroups();
    for (const item of groups) {
      if (item.id === g.id) {
        const sub: SubInfo | undefined = this.groupSub(item);
        item.lastError = sub !== undefined && sub.lastError.length > 0 ? sub.lastError : '';
      }
    }
    await saveGroups(groups);
    this.groups = await loadGroups();
    return message;
  }

  /**
   * 保存订阅分组的设置（对齐 GroupSettingsActivity 的订阅分类）。
   * 允许的 key：autoUpdate / forceResolve / deduplication / updateWhenConnectedOnly / userAgent / updateIntervalHours
   * 写入 SubInfo（抓取逻辑直接消费这些字段），同时把 autoUpdate 镜像到 ProfileGroup 上供列表显示。
   */
  async saveGroupOptions(g: ProfileGroup, changes: Record<string, Object>): Promise<void> {
    if (g.type !== 'subscription' || g.url.length === 0) {
      return;
    }
    await saveSubSettings(g.url, changes);
    if (changes['autoUpdate'] !== undefined) {
      const groups: Array<ProfileGroup> = await loadGroups();
      for (const item of groups) {
        if (item.id === g.id) {
          item.autoUpdate = changes['autoUpdate'] === true;
        }
      }
      await saveGroups(groups);
    }
    this.subs = await listSubs();
    this.groups = await loadGroups();
    this.bump();
  }

  async setGroupAutoUpdate(g: ProfileGroup, enabled: boolean): Promise<void> {
    if (g.type !== 'subscription' || g.url.length === 0) {
      return;
    }
    const changes: Record<string, Object> = { 'autoUpdate': enabled };
    await saveSubSettings(g.url, changes);
    const groups: Array<ProfileGroup> = await loadGroups();
    for (const item of groups) {
      if (item.id === g.id) {
        item.autoUpdate = enabled;
      }
    }
    await saveGroups(groups);
    this.groups = await loadGroups();
    this.subs = await listSubs();
    this.bump();
  }

  /** 清空分组（原版 `action_clear` / `clear_profiles`：只删组内节点，保留分组本身） */
  async clearGroup(groupId: string): Promise<number> {
    let removed: number = 0;
    const keep: Array<Profile> = [];
    const doomed: Array<string> = [];
    for (const p of this.profiles) {
      if (p.groupId === groupId) {
        removed++;
        doomed.push(p.id);
        continue;
      }
      keep.push(p);
    }
    if (removed > 0) {
      await this.disconnectIfRunningRemoved(doomed);
      await saveProfiles(keep);
      await this.reloadProfiles();
    }
    return removed;
  }

  /**
   * 批量删除节点前的安全闸：**正在运行的节点要是也在删除名单里，先断开**。
   * 否则内核会停在一条已经被删掉的配置上（日志/状态都会自相矛盾）。
   */
  private async disconnectIfRunningRemoved(ids: Array<string>): Promise<void> {
    if (this.context === undefined || this.runningProfileId.length === 0) {
      return;
    }
    if (ids.indexOf(this.runningProfileId) < 0) {
      return;
    }
    this.log(`[vpn-control] running profile ${this.runningProfileId} is being removed, disconnect first`);
    await VpnService.disconnect(this.context);
  }

  /**
   * 删除分组 = **连里面的节点一起删**（甲方 2026-11-01：不要再塞进「未分类/未命名」）。
   * 订阅分组同时删掉订阅记录 + 该订阅带来的节点；基础分组删掉组内节点。
   * 删除前先断开「正在运行的节点」，免得内核停在已删除的配置上。
   */
  async deleteGroup(g: ProfileGroup): Promise<void> {
    const isSub: boolean = g.type === 'subscription';
    if (isSub && g.url.length > 0) {
      await removeSub(g.url);
    }
    const doomed: Array<string> = [];
    for (const p of this.profiles) {
      if (p.groupId === g.id || (isSub && p.subUrl === g.url)) {
        doomed.push(p.id);
      }
    }
    await this.disconnectIfRunningRemoved(doomed);
    await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      const next: Array<Profile> = [];
      for (const p of list) {
        const owned: boolean = p.groupId === g.id || (isSub && p.subUrl === g.url);
        if (!owned) {
          next.push(p);
        }
      }
      return next;
    });
    const groups: Array<ProfileGroup> = await loadGroups();
    const kept: Array<ProfileGroup> = [];
    for (const item of groups) {
      if (item.id !== g.id) {
        kept.push(item);
      }
    }
    await saveGroups(kept);
    await this.reloadData();
    // 删掉的正好是选中项时 applySelection 已自愈，把结果同步落盘
    await writePrefString('selected_profile_id', this.selectedId);
    this.log(`[ui-data] group ${g.id} deleted with ${doomed.length} nodes`);
  }

  /**
   * 一次性清理：老版本把订阅里的 Clash `proxy-groups` 落成了分组（"节点选择 / 自动选择 / 漏网之鱼"…）。
   * 现在语义改了（订阅只贡献节点），所以升级后把这些组删掉、成员节点退回未分组。
   *
   * 判据三条同时满足才删，避免误删用户自己建的同名组：
   *   ① 名字在 Clash 默认组名表里；
   *   ② `isSelector` 或 `autoSelect` 为真（这两个只有 applyClashGroups 会写）；
   *   ③ 不是订阅分组（`type !== 'subscription'`）。
   * 用 preferences 里的标记位保证只跑一次。
   */
  private async purgeClashGroupsOnce(): Promise<void> {
    const done: string = await readPrefString(KEY_CLASH_PURGED, '');
    if (done === '1') {
      return;
    }
    const groups: Array<ProfileGroup> = await loadGroups();
    const kept: Array<ProfileGroup> = [];
    const removed: Array<string> = [];
    for (const g of groups) {
      const nameHit: boolean = CLASH_GROUP_NAMES.indexOf(g.name.trim()) >= 0;
      const flagHit: boolean = g.isSelector || g.autoSelect;
      if (nameHit && flagHit && g.type !== 'subscription') {
        removed.push(g.name);
      } else {
        kept.push(g);
      }
    }
    if (removed.length > 0) {
      await saveGroups(kept);
      await mutateProfiles((list: Array<Profile>): Array<Profile> => {
        const next: Array<Profile> = [];
        for (const p of list) {
          let stillExists: boolean = false;
          for (const g of kept) {
            if (g.id === p.groupId) {
              stillExists = true;
              break;
            }
          }
          if (!stillExists) {
            p.groupId = '';
          }
          next.push(p);
        }
        return next;
      });
      this.log(`[ui] 已清理 ${removed.length} 个 Clash 遗留分组：${removed.join('、')}`);
    }
    await writePrefString(KEY_CLASH_PURGED, '1');
  }

  /** 节点长按拖动排序后落库（按可见顺序重写 sortOrder，并把排序方式切到手动） */
  async applyManualOrder(ids: Array<string>): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    const index: Record<string, number> = {};
    for (let i = 0; i < ids.length; i++) {
      index[ids[i]] = i;
    }
    const next: Array<Profile> = [];
    for (const p of this.profiles) {
      const value: number | undefined = index[p.id];
      if (value !== undefined) {
        p.sortOrder = value;
      }
      next.push(p);
    }
    await saveProfiles(next);
    this.profiles = next.slice();
    await this.patchSettings((s: AppSettings) => {
      s.profileSortMode = 'manual';
    });
    this.log(`[ui-data] manual order applied ids=${ids.length}`);
  }

  /** 分组长按拖动排序后落库 */
  async applyGroupOrder(ids: Array<string>): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    const groups: Array<ProfileGroup> = await loadGroups();
    const index: Record<string, number> = {};
    for (let i = 0; i < ids.length; i++) {
      index[ids[i]] = i;
    }
    for (const g of groups) {
      const value: number | undefined = index[g.id];
      if (value !== undefined) {
        g.sortOrder = value;
      }
    }
    await saveGroups(groups);
    this.groups = await loadGroups();
    this.bump();
    this.log(`[ui-data] group order applied ids=${ids.length}`);
  }

  /**
   * 手动导入（文本/剪贴板/扫码/文件统一入口）：订阅地址走订阅，其余按节点链接解析。
   * `targetGroupId` = 首页当前选中的分组；**没有分组时自动建一个「未命名」分组**（甲方 2026-11-01）。
   */
  async importText(text: string, targetGroupId: string = ''): Promise<string> {
    const raw: string = text.trim();
    if (raw.length === 0) {
      return '内容为空';
    }
    // 没有目标分组（新装无分组 / 页面还没选中 / 目标组刚被删）⇒ 建一个「未命名」兜底，节点永远有归属
    let targetId: string = targetGroupId;
    if (targetId.length === 0 || this.groupTitle(targetId).length === 0) {
      targetId = await this.ensureUnnamedGroup();
    }
    const groupTitle: string = this.groupTitle(targetId);
    const groupSuffix: string = groupTitle.length > 0 ? `到分组「${groupTitle}」` : '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      // 一条订阅地址只能属于一个分组：已经在别的分组里挂过就别再改归属
      // （否则旧分组的 SubInfo.group 会被改掉，两边的节点归属互相打架 —— 甲方报的"链接相同分组"那堆 Bug）
      const owner: ProfileGroup | undefined = this.subGroupForUrl(raw);
      if (owner !== undefined && owner.id !== targetId) {
        this.pendingGroupId = owner.id;
        return `这个订阅地址已经属于分组「${owner.name}」，请到那个分组里更新`;
      }
      const subOwner: string = this.subscriptionOwnerName(raw);
      if (subOwner.length > 0 && subOwner !== groupTitle && owner === undefined) {
        // 地址挂在别的分组名下（基础分组里导入过订阅链接）
        return `这个订阅地址已经挂在分组「${subOwner}」里，请到那个分组里更新`;
      }
      // 订阅地址挂到当前分组：SubInfo.group = 分组名 ⇒ 拉下来的节点自动落进这个分组。
      // 注意：**不改分组的 type**（首页那张订阅卡只给真正的订阅分组）。
      await upsertSub(raw, '', groupTitle);
      // 先点名目标分组，再刷新 —— 刷新结尾的 bump 才能让首页跟着切过去
      this.pendingGroupId = targetId;
      const result: string = await this.refreshSubscription(raw);
      return groupTitle.length > 0 ? `${result}（已挂到分组「${groupTitle}」）` : result;
    }
    const parsed: Array<Profile> = parseShareText(raw);
    if (parsed.length === 0) {
      return '未识别到可导入的节点';
    }
    const now: number = Date.now();
    for (let i = 0; i < parsed.length; i++) {
      const p: Profile = parsed[i];
      if (p.id.length === 0) {
        p.id = `p_${now}_${i}_${Math.floor(Math.random() * 100000)}`;
      }
      p.updatedAt = now;
      p.groupId = targetId;
    }
    await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      const next: Array<Profile> = list.slice();
      for (const p of parsed) {
        next.push(p);
      }
      return next;
    });
    // 同上：点名要在 reloadProfiles 的 bump 之前写
    this.pendingGroupId = targetId;
    await this.reloadProfiles();
    this.log(`[ui-data] imported=${parsed.length} group=${groupTitle.length > 0 ? groupTitle : targetId}`);
    return `已导入 ${parsed.length} 个节点${groupSuffix}`;
  }

  /** 取（必要时创建）「未命名」分组，返回组 id */
  private async ensureUnnamedGroup(): Promise<string> {
    const id: string = await ensureGroupByName(UNNAMED_GROUP);
    this.groups = await loadGroups();
    return id;
  }

  /**
   * 修掉历史脏数据：**同一个订阅地址被建成了多个订阅分组**（老版本允许，之后两边互相抢节点归属：
   * 节点永远落进先建的那个组、后建的组永远是空、删掉任一个都会把订阅记录一起删）。
   * 只保留第一个用这个 URL 的订阅分组，其余降级成基础分组（节点保留，下次更新会重新落进保留组）。
   */
  private async repairDuplicateSubGroups(): Promise<void> {
    const groups: Array<ProfileGroup> = await loadGroups();
    const owner: Record<string, string> = {};
    let changed: boolean = false;
    for (const g of groups) {
      if (g.type !== 'subscription' || g.url.length === 0) {
        continue;
      }
      const seen: string | undefined = owner[g.url];
      if (seen === undefined) {
        owner[g.url] = g.name;
        continue;
      }
      g.type = 'basic';
      g.url = '';
      g.autoUpdate = false;
      g.lastError = '';
      changed = true;
      this.log(`[ui-data] demote duplicate subscription group ${g.name} (url owned by ${seen})`);
    }
    if (!changed) {
      return;
    }
    await saveGroups(groups);
    this.groups = await loadGroups();
  }

  /**
   * 把"没有归属"的节点收进「未命名」分组。
   * 首页已经没有「全部/未分组」页签，孤儿节点会看不见 —— 所以每次启动兜一次（无孤儿时零写盘）。
   */
  private async adoptOrphans(): Promise<void> {
    if (this.profiles.length === 0) {
      return;
    }
    const valid: Array<string> = [];
    for (const g of this.groups) {
      valid.push(g.id);
    }
    let hasOrphan: boolean = false;
    for (const p of this.profiles) {
      if (valid.indexOf(p.groupId) < 0) {
        hasOrphan = true;
        break;
      }
    }
    if (!hasOrphan) {
      return;
    }
    const target: string = await this.ensureUnnamedGroup();
    await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      const next: Array<Profile> = list.slice();
      for (const p of next) {
        if (valid.indexOf(p.groupId) < 0) {
          p.groupId = target;
        }
      }
      return next;
    });
    this.groups = await loadGroups();
    this.profiles = await loadProfiles();
    this.log(`[ui-data] adopted orphan nodes into group ${target}`);
  }

  /**
   * 重命名分组。
   * ⚠️ 订阅分组的节点归属靠 **`SubInfo.group` = 分组名** 关联（见 Subscriptions.updateSubscription），
   * 所以改名必须同步改 SubInfo，否则下一次订阅更新会把节点落到一个**同名新组**里、旧组变空。
   */
  async renameGroup(g: ProfileGroup, newName: string): Promise<void> {
    const trimmed: string = newName.trim();
    if (trimmed.length === 0 || trimmed === g.name) {
      return;
    }
    for (const other of this.groups) {
      if (other.id !== g.id && other.name.trim() === trimmed) {
        throw new Error(`已有同名分组「${trimmed}」`);
      }
    }
    if (g.type === 'subscription' && g.url.length > 0) {
      const subChanges: Record<string, Object> = { 'group': trimmed, 'name': trimmed };
      await saveSubSettings(g.url, subChanges);
    }
    const attached: SubInfo | undefined = this.subForGroupName(g.name);
    if (attached !== undefined && attached.url !== g.url) {
      // 基础分组上挂过订阅（首页导入订阅链接）时也要跟着改名
      const attachedChanges: Record<string, Object> = { 'group': trimmed };
      await saveSubSettings(attached.url, attachedChanges);
    }
    const groups: Array<ProfileGroup> = await loadGroups();
    for (const item of groups) {
      if (item.id === g.id) {
        item.name = trimmed;
        item.updatedAt = Date.now();
      }
    }
    await saveGroups(groups);
    await this.reloadData();
    this.log(`[ui-data] group ${g.id} renamed to ${trimmed}`);
  }

  /** 更新一条订阅（内部/订阅分组共用）；返回给用户看的**真实差异**，不是"删几条/加几条" */
  async refreshSubscription(url: string): Promise<string> {
    try {
      const result = await updateSubscription(url);
      await this.reloadData();
      if (result.notModified) {
        return '内容未变（服务端返回 304）';
      }
      if (result.total === 0 && result.note.length > 0) {
        return `订阅不可用：${result.note}（跳过 ${result.skipped}）`;
      }
      this.log(`[sub] ${url} added=${result.added} removed=${result.removed} total=${result.total}`);
      if (result.added === 0 && result.removed === 0) {
        return `内容未变（共 ${result.total} 个节点）`;
      }
      if (result.removed === 0) {
        return `新增 ${result.added} 个节点（共 ${result.total} 个）`;
      }
      if (result.added === 0) {
        return `移除 ${result.removed} 个失效节点（共 ${result.total} 个）`;
      }
      return `新增 ${result.added} 个、移除 ${result.removed} 个（共 ${result.total} 个）`;
    } catch (e) {
      await this.reloadSubs();
      return `更新失败：${subErrorText(e as Object)}`;
    }
  }

  // ------------------------------------------------------------------ 节点编辑

  async saveProfile(p: Profile): Promise<void> {
    const now: number = Date.now();
    p.updatedAt = now;
    if (p.id.length === 0) {
      // 新节点必须有归属：优先用"当前页签分组"，其次「未命名」（首页已没有全部/未分组页签）
      if (p.groupId.length === 0) {
        p.groupId = this.groupTitle(this.editingGroupId).length > 0
          ? this.editingGroupId : await this.ensureUnnamedGroup();
      }
      p.id = `p_${now}_${Math.floor(Math.random() * 100000)}`;
      await mutateProfiles((list: Array<Profile>): Array<Profile> => {
        const next: Array<Profile> = list.slice();
        next.push(p);
        return next;
      });
      this.selectedId = p.id;
    } else {
      await mutateProfiles((list: Array<Profile>): Array<Profile> => {
        const next: Array<Profile> = [];
        for (const item of list) {
          if (item.id !== p.id) {
            next.push(item);
            continue;
          }
          // 延迟/流量是运行期数据（编辑页根本没有这两个输入框），必须继承**磁盘上最新的**那份：
          // 拿页面打开时的旧快照覆盖，会把订阅更新后新测的延迟、扩展进程刚写回的会话流量一起抹掉。
          p.latencyMs = item.latencyMs;
          p.latencyTestedAt = item.latencyTestedAt;
          p.rx = item.rx;
          p.tx = item.tx;
          next.push(p);
        }
        return next;
      });
    }
    await this.reloadProfiles();
    this.applySelection(this.selectedId.length > 0 ? this.selectedId : p.id);
    // 选中项必须落盘，否则重启后回到列表第 1 个（甲方 2026-11-01 反馈）。
    await writePrefString('selected_profile_id', this.selectedId);
  }

  async deleteProfile(id: string): Promise<void> {
    await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      const next: Array<Profile> = [];
      for (const item of list) {
        if (item.id !== id) {
          next.push(item);
        }
      }
      return next;
    });
    if (this.runningProfileId === id && this.context !== undefined) {
      await VpnService.disconnect(this.context);
    }
    await this.reloadProfiles();
    // 被删的正好是选中项时，applySelection 已自愈到别的节点，把结果同步落盘。
    await writePrefString('selected_profile_id', this.selectedId);
  }

  async togglePin(p: Profile): Promise<void> {
    p.pinned = !p.pinned;
    await this.saveProfile(p);
  }

  async moveToGroup(p: Profile, groupId: string): Promise<void> {
    p.groupId = groupId;
    await this.saveProfile(p);
  }

  async createGroup(name: string): Promise<string> {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const id: string = await ensureGroupByName(trimmed);
    this.groups = await loadGroups();
    this.bump();
    return id;
  }

  // ------------------------------------------------------------------ 设置

  /**
   * 改一项设置并存盘。
   * ⚠️ 必须**换一个新的 AppSettings 实例**再赋回 `this.settings`：
   * 原地改字段（`this.settings.mtu = x`）不会触发 `@Trace`（AppSettings 是纯数据类），
   * 赋值同一个引用也不会通知 ⇒ 设置页改完数字不动。
   */
  async patchSettings(mutator: (s: AppSettings) => void): Promise<void> {
    const next: AppSettings = JSON.parse(JSON.stringify(this.settings)) as AppSettings;
    mutator(next);
    await persistSettings(next);
    this.settings = next;
    this.bump();
  }

  /** 下载 / 更新一个 geo 资产（site / ip），返回给 UI 的提示文本 */
  async downloadGeo(kind: string): Promise<string> {
    const ctx: common.UIAbilityContext | undefined = this.context;
    if (ctx === undefined) {
      return '尚未初始化';
    }
    await downloadGeoAsset(ctx, kind);
    return `已更新 ${kind === 'site' ? 'GeoSite' : 'GeoIP'} 库`;
  }

  // ------------------------------------------------------------------ 路由规则
  async saveRules(list: Array<RouteRule>): Promise<void> {
    await saveRouteRules(list);
    this.rules = await loadRouteRules();
    this.bump();
  }

  async deleteRule(index: number): Promise<void> {
    if (index < 0 || index >= this.rules.length) {
      return;
    }
    const next: Array<RouteRule> = this.rules.slice();
    next.splice(index, 1);
    await this.saveRules(next);
  }

  async upsertRule(rule: RouteRule, index: number): Promise<void> {
    const next: Array<RouteRule> = this.rules.slice();
    if (index >= 0 && index < next.length) {
      next[index] = rule;
    } else {
      next.push(rule);
    }
    await this.saveRules(next);
  }

  // ------------------------------------------------------------------ 杂项（原版 ⋮ 菜单）

  /** 该分组下的节点 id 集合；groupId='' 表示"全部/未分组"由调用方决定语义 */
  private inScope(groupId: string): Array<Profile> {
    const out: Array<Profile> = [];
    for (const p of this.profiles) {
      if (groupId.length === 0 || p.groupId === groupId) {
        out.push(p);
      }
    }
    return out;
  }

  /**
   * 清除流量统计（原版 action_clear_traffic_statistics）。
   * 只把命中节点的 rx/tx 归零：走 `mutateProfiles` 的读改写，别用"整表覆盖"——
   * 否则会把同时在跑的测速结果、会话流量统计一起冲掉。
   */
  async clearTrafficStats(groupId: string): Promise<number> {
    const ids: Set<string> = new Set<string>();
    for (const p of this.inScope(groupId)) {
      if (p.rx !== 0 || p.tx !== 0) {
        ids.add(p.id);
      }
    }
    if (ids.size === 0) {
      return 0;
    }
    const updated: Array<Profile> = await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      for (const p of list) {
        if (ids.has(p.id)) {
          p.rx = 0;
          p.tx = 0;
        }
      }
      return list;
    });
    this.profiles = updated;
    this.bump();
    return ids.size;
  }

  /** 清除测速结果（latencyMs=0 表示未测速）；同样走读改写，避免整表覆盖 */
  async clearTestResults(groupId: string): Promise<number> {
    const ids: Set<string> = new Set<string>();
    for (const p of this.inScope(groupId)) {
      if (p.latencyMs !== 0 || p.latencyTestedAt !== 0) {
        ids.add(p.id);
      }
    }
    if (ids.size === 0) {
      return 0;
    }
    // 正在跑的那轮测速还有没落库的结果：一起丢掉，否则刚清完又被下一批 flush 写回来
    this.pendingLatency.clear();
    const updated: Array<Profile> = await mutateProfiles((list: Array<Profile>): Array<Profile> => {
      for (const p of list) {
        if (ids.has(p.id)) {
          p.latencyMs = 0;
          p.latencyTestedAt = 0;
        }
      }
      return list;
    });
    this.profiles = updated;
    this.bump();
    return ids.size;
  }

  /** 移除重复节点（判据 = 类型 + 服务器 + 端口 + UUID/密码），保留第一条 */
  async removeDuplicates(groupId: string): Promise<number> {
    const seen: Record<string, boolean> = {};
    const keep: Array<Profile> = [];
    let removed: number = 0;
    const inScopeIds: Array<string> = [];
    const doomed: Array<string> = [];
    for (const p of this.profiles) {
      if (groupId.length === 0 || p.groupId === groupId) {
        inScopeIds.push(p.id);
      }
    }
    for (const p of this.profiles) {
      const scoped: boolean = inScopeIds.indexOf(p.id) >= 0;
      const key: string = `${p.type}|${p.server}|${p.serverPort}|${p.uuid.length > 0 ? p.uuid : p.password}`;
      if (scoped && seen[key] === true) {
        removed++;
        doomed.push(p.id);
        continue;
      }
      if (scoped) {
        seen[key] = true;
      }
      keep.push(p);
    }
    if (removed > 0) {
      await this.disconnectIfRunningRemoved(doomed);
      await saveProfiles(keep);
      await this.reloadProfiles();
    }
    return removed;
  }

  /** 删除不可用节点（latencyMs < 0 = 测试超时/失败） */
  async deleteUnavailable(groupId: string): Promise<number> {
    const keep: Array<Profile> = [];
    const doomed: Array<string> = [];
    let removed: number = 0;
    for (const p of this.profiles) {
      const scoped: boolean = groupId.length === 0 || p.groupId === groupId;
      if (scoped && p.latencyMs < 0) {
        removed++;
        doomed.push(p.id);
        continue;
      }
      keep.push(p);
    }
    if (removed > 0) {
      await this.disconnectIfRunningRemoved(doomed);
      await saveProfiles(keep);
      await this.reloadProfiles();
    }
    return removed;
  }

  /**
   * 更新"当前分组"的订阅：
   *   · 订阅分组 → 走分组自己的订阅地址；
   *   · 基础分组 → 如果这个分组名上挂过订阅（首页导入订阅链接时 `SubInfo.group` = 组名），也让它能更新。
   */
  async updateCurrentSubscription(groupId: string): Promise<string> {
    for (const g of this.groups) {
      if (g.id === groupId) {
        if (g.type === 'subscription') {
          return await this.refreshGroup(g);
        }
        const attached: SubInfo | undefined = this.subForGroupName(g.name);
        if (attached !== undefined) {
          return await this.refreshSubscription(attached.url);
        }
        return '该分组没有订阅';
      }
    }
    return '该分组没有订阅';
  }

  private subForGroupName(name: string): SubInfo | undefined {
    for (const s of this.subs) {
      if (s.group === name) {
        return s;
      }
    }
    return undefined;
  }

  // ------------------------------------------------------------------ 状态回写（供 :vpn 进程事件订阅）

  /** Single event path: VpnRuntime emits once; its AppState listener mirrors @Trace values and notifies pages. */
  applyVpnStatus(status: string, running: boolean, profileId: string): void {
    this.runtime.setStatus(status, running, profileId);
  }

  /**
   * 流量回写。
   * `running/profileId` 来自扩展进程的流量事件:UI 进程被回收后重开时,它以为"未连接",
   * 而隧道一直在跑 —— 只靠状态事件的话要等到下一次连接/切换才纠正(表现:"进软件看到未连接、速度 0")。
   * 这里用每秒一次的流量事件把会话状态补回来;会话结束的那条事件带 running=false,不会误判。
   */
  applyTraffic(up: number, down: number, totalUp: number, totalDown: number,
    running: boolean = true, profileId: string = ''): void {
    if (running && !this.runtime.vpnRunning) {
      this.runtime.setStatus('connected:running', true, profileId);
    }
    this.runtime.setTraffic(up, down, totalUp, totalDown);
  }

  statusText(): string {
    if (this.vpnStatus === 'disconnecting') {
      return '正在断开…';
    }
    if (this.vpnStatus === 'connecting' || this.vpnStatus === 'awaiting_auth') {
      return this.vpnStatus === 'awaiting_auth' ? '等待 VPN 授权…' : '正在建立 VPN…';
    }
    if (this.vpnStatus === 'switching') {
      return '正在切换节点…';
    }
    if (this.vpnRunning) {
      return '已连接';
    }
    if (this.vpnStatus.startsWith('start_failed:') || this.vpnStatus.startsWith('connect_failed:')) {
      return '连接失败';
    }
    return '未连接';
  }

  /** 供 UI 取一次点击反馈文本（不弹系统 Toast，避免与 HDS 材质抢焦点） */
  nextToastSeq(): number {
    this.toastSeq++;
    return this.toastSeq;
  }

  async clearAllData(): Promise<void> {
    await mutateProfiles((): Array<Profile> => []);
    await saveGroups([]);
    await this.reloadData();
  }
}
