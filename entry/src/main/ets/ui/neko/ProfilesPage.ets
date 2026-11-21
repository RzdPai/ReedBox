import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { AppSettings, Profile, ProfileGroup, ProfileType } from '../../model/Profile';
import { UIContext } from '@kit.ArkUI';
import { AppState } from '../../core/AppState';
import { VpnRuntime } from '../../core/VpnRuntime';
import { ProfileCard } from './ProfileCard';
import { ProfileRowModel } from './ProfileRowSource';
import { SubInfo } from '../../core/Subscriptions';
import { exportProfileLink } from '../../utils/LinkExporter';
import { LatencyTestOutcome } from '../../utils/LatencyTester';
import { buildOutboundJson } from '../../core/ConfigBuilder';
import { getClipboardText, setClipboardText } from '../../utils/ClipboardHelper';
import {
  confirmDestructive,
  GlowButton,
  GroupTabs,
  HdsMenu,
  MenuItemData,
  PageHeader,
  PickOption,
  PickSheetPanel,
  PickSheetParam,
  pressLightEffect
} from '../CommonUi';
import { bytesText, dateText, speedText } from '../Format';
import { Metrics } from '../Metrics';
import { Space, Theme } from '../Theme';
import { gotoProfileEdit } from '../Routes';
import { HAND_LEFT, Handedness } from '../../core/Handedness';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Profiles';

const TYPE_MENU: Array<string> = [ProfileType.VMESS, ProfileType.VLESS, ProfileType.SHADOWSOCKS, ProfileType.SOCKS,
  ProfileType.HTTP, ProfileType.TROJAN, ProfileType.WIREGUARD, ProfileType.HYSTERIA2, ProfileType.TUIC,
  ProfileType.ANYTLS, ProfileType.SNELL];

/* 行内 ⋯ 菜单 */
const R_TEST: number = 0;
const R_PIN: number = 1;
const R_EDIT: number = 2;
const R_MOVE: number = 3;
const R_COPY: number = 4;
const R_DELETE: number = 5;


/** One immutable value supplies every runtime label, tint and control state in the bottom bar. */
class ProfilesRuntimeView {
  running: boolean = false;
  status: string = 'disconnected';
  runningId: string = '';
  up: number = 0;
  down: number = 0;
  nodeName: string = '未选择节点';
  busy: boolean = false;
  text: string = '未连接';
  hint: string = '点击右下开关连接';
  tint: ResourceColor = Theme.TEXT_3;
  buttonColor: ResourceColor = Theme.BRAND;
}

@ComponentV2
export struct ProfilesPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Event onDrawer: () => void = (): void => {
  };
  @Local app: AppState = AppState.get();
  @Local query: string = '';
  @Local searchOpen: boolean = false;
  @Local groupIndex: number = 0;
  @Local litPower: boolean = false;
  @Local runtimeView: ProfilesRuntimeView = new ProfilesRuntimeView();
  @Local profileCount: number = 0;
  @Local groupCount: number = 0;
  @Local visibleCount: number = 0;
  @Local groupItems: Array<string> = [];
  @Local visibleRows: Array<ProfileRowModel> = [];
  @Local subscriptionBusy: boolean = false;
  @Local handedness: Handedness = Handedness.get();
  @Local fabAreaWidth: number = 0;
  private runtime: VpnRuntime = VpnRuntime.get();
  private commandPending: boolean = false;
  private pendingAction: string = '';
  private stateSubscribed: boolean = false;
  private lastSelectedId: string = '';
  private lastRunningId: string = '';
  private lastCanSelect: boolean = true;
  private lastShowAddress: boolean = false;
  @Local busy: boolean = false;
  @Local sheetOpen: boolean = false;
  @Local sheetKind: string = '';
  @Local importText: string = '';
  @Local moveTargetId: string = '';
  private menu: HdsMenu = new HdsMenu();


  private groupLabels(): Array<string> {
    const labels: Array<string> = [];
    for (const g of this.app.groups) {
      labels.push(`${g.name}(${this.app.groupNodeCount(g.id)})`);
    }
    return labels;
  }

  private selectedGroup(): ProfileGroup | undefined {
    if (this.app.groups.length === 0) {
      return undefined;
    }
    return this.app.groups[this.effectiveGroupIndex()];
  }

  private effectiveGroupIndex(): number {
    if (this.groupIndex < 0) {
      return 0;
    }
    if (this.groupIndex >= this.app.groups.length) {
      return this.app.groups.length === 0 ? 0 : this.app.groups.length - 1;
    }
    return this.groupIndex;
  }

  private sortProfiles(list: Array<Profile>): void {
    const mode: string = this.app.settings.profileSortMode;
    list.sort((a: Profile, b: Profile): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (mode === 'name') {
        return a.name.localeCompare(b.name);
      }
      if (mode === 'latency') {
        const la: number = a.latencyMs > 0 ? a.latencyMs : 999999;
        const lb: number = b.latencyMs > 0 ? b.latencyMs : 999999;
        if (la !== lb) {
          return la - lb;
        }
      }
      return a.sortOrder - b.sortOrder;
    });
  }

  private groupProfiles(groupId: string, showAll: boolean): Array<Profile> {
    const keyword: string = this.query.trim().toLowerCase();
    const out: Array<Profile> = [];
    for (const p of this.app.profiles) {
      if (!showAll && p.groupId !== groupId) {
        continue;
      }
      if (keyword.length > 0) {
        const hay: string = `${p.name} ${p.server} ${p.type}`.toLowerCase();
        if (hay.indexOf(keyword) < 0) {
          continue;
        }
      }
      out.push(p);
    }
    this.sortProfiles(out);
    return out;
  }

  private rowsById: Map<string, ProfileRowModel> = new Map<string, ProfileRowModel>();

  private rowFor(p: Profile): ProfileRowModel {
    let row: ProfileRowModel | undefined = this.rowsById.get(p.id);
    if (row === undefined) {
      // 首次建行：这一次要带上选中/运行态，否则首帧高亮是空的
      row = new ProfileRowModel(p);
      row.updateState(this.app.selectedId, this.runtimeView.runningId,
        this.app.settings.alwaysShowAddress, !this.runtimeView.busy);
      this.rowsById.set(p.id, row);
      return row;
    }
    // 复用老行：**只刷业务字段**，不在这里写 selected/running（构建期不写 @Trace，
    // 状态统一由 syncAllRowStates 在业务/运行态回调里推送）
    row.updateProfile(p);
    return row;
  }

  /** 把选中/运行/显示地址/可选态推给所有已缓存的行（只在回调里调用，不在 build 里） */
  private syncAllRowStates(): void {
    const selectedId: string = this.app.selectedId;
    const runningId: string = this.runtimeView.runningId;
    const showAddress: boolean = this.app.settings.alwaysShowAddress;
    const canSelect: boolean = !this.runtimeView.busy;
    this.rowsById.forEach((row: ProfileRowModel) => {
      row.updateState(selectedId, runningId, showAddress, canSelect);
    });
  }

  private groupRowsFor(groupId: string, showAll: boolean): Array<ProfileRowModel> {
    const rows: Array<ProfileRowModel> = [];
    for (const p of this.groupProfiles(groupId, showAll)) {
      rows.push(this.rowFor(p));
    }
    return rows;
  }

  /** 节点被删后清掉缓存：按 id 差集清理（不能用"数量比较"，删一个加一个数量不变会漏清） */
  private pruneRows(): void {
    if (this.rowsById.size === 0) {
      return;
    }
    const alive: Set<string> = new Set<string>();
    for (const p of this.app.profiles) {
      alive.add(p.id);
    }
    const stale: Array<string> = [];
    this.rowsById.forEach((row: ProfileRowModel, id: string) => {
      if (!alive.has(id)) {
        stale.push(id);
      }
    });
    for (const id of stale) {
      this.rowsById.delete(id);
    }
  }

  private filtered(): Array<Profile> {
    const group: ProfileGroup | undefined = this.selectedGroup();
    if (group === undefined) {
      return this.groupProfiles('', true);
    }
    return this.groupProfiles(group.id, false);
  }

  /** Business callbacks run after AppState commits its data; assign actual rendered values. */
  private syncBusinessView(): void {
    this.profileCount = this.app.profiles.length;
    this.groupCount = this.app.groups.length;
    this.groupItems = this.groupLabels();
    this.consumePendingGroup();
    // ★ 内容页由 Swiper 的 `index` 直接绑 groupIndex 决定（见 build()）：这里只要把下标算对，
    //   页签条与列表内容就永远是同一页，不需要任何"延后对齐/重试"。
    this.alignGroupIndex();
    this.syncRuntimeView();
    this.syncVisibleRows();
  }

  private consumePendingGroup(): void {
    const pending: string = this.app.pendingGroupId;
    if (pending.length === 0) {
      return;
    }
    for (let i = 0; i < this.app.groups.length; i++) {
      if (this.app.groups[i].id === pending) {
        this.groupIndex = i;
        this.app.pendingGroupId = '';
        // 导入/订阅落地要切过去的那一组，也是用户"当前所在分组"⇒ 一起写进真源并落盘
        this.app.selectGroupById(pending);
        return;
      }
    }
  }

  /** 分组 id → 页签下标；找不到返回 -1（分组被删/还没加载） */
  private indexForGroup(groupId: string): number {
    if (groupId.length === 0) {
      return -1;
    }
    for (let i = 0; i < this.app.groups.length; i++) {
      if (this.app.groups[i].id === groupId) {
        return i;
      }
    }
    return -1;
  }


  /**
   * 页签下标跟着 `AppState.selectedGroupId` 走。
   * ⚠️ 以前下标只活在 `@Local groupIndex` 里：切到「设置」再切回来（组件重建）或重启软件，
   *   一律回到第 1 个分组（甲方 2026-11-15：在 A 分组、选中节点也在 A，重进却跳到第 1 个）。
   *   真源现在在 AppState（按 **id** 保存），页面只负责映射成下标。
   */
  private alignGroupIndex(): void {
    const targetId: string = this.app.selectedGroupId;
    if (targetId.length > 0) {
      for (let i = 0; i < this.app.groups.length; i++) {
        if (this.app.groups[i].id === targetId) {
          this.groupIndex = i;
          return;
        }
      }
      this.groupIndex = 0;
      return;
    }
    this.groupIndex = this.effectiveGroupIndex();
  }

  private syncVisibleRows(): void {
    const profiles: Array<Profile> = this.filtered();
    this.pruneRows();
    // 状态先统一推到所有缓存行，再取当前分组的行给 ForEach
    this.syncAllRowStates();
    this.visibleRows = this.groupRowsFor(this.selectedGroupId(), this.app.groups.length === 0);
    this.visibleCount = profiles.length;
    hilog.info(DOMAIN, TAG, '[profiles-data] rows count=%{public}d group=%{public}d selected=%{public}s',
      this.visibleCount, this.groupIndex, this.app.selectedId);
  }

  private selectedGroupId(): string {
    const group: ProfileGroup | undefined = this.selectedGroup();
    return group === undefined ? '' : group.id;
  }


  private syncRuntimeView(): void {
    const next: ProfilesRuntimeView = new ProfilesRuntimeView();
    next.running = this.runtime.vpnRunning;
    next.status = this.runtime.vpnStatus;
    next.runningId = next.running ? this.runtime.runningProfileId : '';
    next.up = this.runtime.upSpeed;
    next.down = this.runtime.downSpeed;
    next.busy = this.commandPending || this.runtime.isBusy();
    next.text = this.runtime.statusText();
    if (this.commandPending && !this.runtime.isBusy()) {
      next.status = this.pendingAction;
      if (this.pendingAction === 'disconnecting') {
        next.text = '正在断开…';
      } else if (this.pendingAction === 'switching') {
        next.text = '正在切换节点…';
      } else if (this.pendingAction === 'connecting') {
        next.text = '正在建立 VPN…';
      } else if (this.pendingAction === 'reloading') {
        next.text = '正在载入配置…';
      } else {
        next.text = '正在保存选择…';
      }
    }
    const targetId: string = next.busy && this.runtime.requestedProfileId.length > 0
      ? this.runtime.requestedProfileId : (next.runningId.length > 0 ? next.runningId : this.app.selectedId);
    let current: Profile | undefined = undefined;
    for (const profile of this.app.profiles) {
      if (profile.id === targetId) {
        current = profile;
        break;
      }
    }
    if (current === undefined) {
      current = this.app.selectedProfile();
    }
    next.nodeName = current === undefined ? '未选择节点' : current.name;
    next.hint = next.busy ? next.text : (next.running ? `${next.text} · 点击可断开` : '点击右下开关连接');
    next.tint = next.busy ? Theme.BRAND : (next.running ? Theme.OK : Theme.TEXT_3);
    next.buttonColor = next.running && !next.busy ? Theme.OK : Theme.BRAND;
    const stateChanged: boolean = this.runtimeView.status !== next.status || this.runtimeView.running !== next.running;
    this.runtimeView = next;
    const canSelect: boolean = !next.busy;
    const showAddress: boolean = this.app.settings.alwaysShowAddress;
    if (this.lastSelectedId !== this.app.selectedId || this.lastRunningId !== next.runningId
      || this.lastCanSelect !== canSelect || this.lastShowAddress !== showAddress) {
      // 更新**所有已缓存的行**（每个 Tab 一份），否则隐藏页签的卡片会停在旧状态
      this.syncAllRowStates();
      this.lastSelectedId = this.app.selectedId;
      this.lastRunningId = next.runningId;
      this.lastCanSelect = canSelect;
      this.lastShowAddress = showAddress;
    }
    if (stateChanged) {
      hilog.info(DOMAIN, TAG, '[profiles-runtime] status=%{public}s running=%{public}s busy=%{public}s',
        next.status, `${next.running}`, `${next.busy}`);
    }
  }

  private switchGroup(index: number): void {
    if (index < 0 || index >= this.app.groups.length || index === this.groupIndex) {
      return;
    }
    hilog.info(DOMAIN, TAG, '[profiles-tab] switch to=%{public}d', index);
    this.selectGroup(index);
  }

  /**
   * 点分组页签：① 写 AppState（按 id 落盘，重进软件/重建组件都能回到这一组）；
   * ② `groupIndex` 一变 Swiper 就带着动画切过去；③ 该分组自己的 Scroll 回到顶部。
   */
  private selectGroup(index: number): void {
    const group: ProfileGroup | undefined = this.app.groups[index];
    if (group === undefined) {
      return;
    }
    hilog.info(DOMAIN, TAG, '[profiles-tab] select index=%{public}d group=%{public}s nodes=%{public}d',
      index, group.id, this.app.groupNodeCount(group.id));
    // 改 groupIndex 就等于切页（Swiper 的 index 绑着它），内容与页签条不会各走各的
    this.groupIndex = index;
    this.app.selectGroupById(group.id);
    this.syncVisibleRows();
    // 该分组自己的 Scroll 回到顶部（每页一个 Scroller）
    try {
      this.scrollerFor(group.id).scrollEdge(Edge.Top);
    } catch (e) {
      // 列表还没挂上 scroller 时忽略
    }
  }


  private pageScrollers: Map<string, Scroller> = new Map<string, Scroller>();

  private scrollerFor(key: string): Scroller {
    let scroller: Scroller | undefined = this.pageScrollers.get(key);
    if (scroller === undefined) {
      scroller = new Scroller();
      this.pageScrollers.set(key, scroller);
    }
    return scroller;
  }

  private setQuery(query: string): void {
    this.query = query;
    this.syncVisibleRows();
  }

  private beginCommand(action: string): boolean {
    if (this.commandPending || this.runtime.isBusy()) {
      hilog.info(DOMAIN, TAG, '[profiles-runtime] ignored command=%{public}s status=%{public}s',
        action, this.runtime.vpnStatus);
      return false;
    }
    this.commandPending = true;
    this.pendingAction = action;
    this.syncRuntimeView();
    return true;
  }

  private endCommand(): void {
    this.commandPending = false;
    this.pendingAction = '';
    this.syncRuntimeView();
  }

  private async selectProfile(profile: Profile): Promise<void> {
    if (!this.beginCommand(this.runtime.vpnRunning ? 'switching' : 'selecting')) {
      return;
    }
    try {
      await this.app.pickProfile(profile);
    } catch (e) {
      this.toast(`切换失败：${(e as Error).message}`);
    } finally {
      this.endCommand();
    }
  }

  private async toggleVpn(): Promise<void> {
    if (!this.runtime.vpnRunning && this.app.selectedProfile() === undefined) {
      this.toast('先导入或新建一个节点');
      return;
    }
    if (!this.beginCommand(this.runtime.vpnRunning ? 'disconnecting' : 'connecting')) {
      return;
    }
    try {
      await this.app.toggleConnection();
    } catch (e) {
      this.toast(`操作失败：${(e as Error).message}`);
    } finally {
      this.endCommand();
    }
  }

  private removeProfile(profile: Profile): void {
    confirmDestructive(this.getUIContext(), '删除节点',
      `「${profile.name.length > 0 ? profile.name : profile.server}」将从列表里移除。`, '删除', (): void => {
        this.app.deleteProfile(profile.id).then((): void => {
          this.toast(`已删除 ${profile.name}`);
        }).catch((e: Error): void => {
          this.toast(`删除失败：${e.message}`);
        });
      });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }


  private openCreateMenu(): void {
    const items: Array<MenuItemData> = [
      new MenuItemData('扫描二维码', false, $r('sys.symbol.scope')),
      new MenuItemData('粘贴文本', false, $r('sys.symbol.doc_plaintext')),
      new MenuItemData('从文件导入', false, $r('sys.symbol.doc_text')),
      new MenuItemData('手动设置 ▸', false, $r('sys.symbol.square_and_pencil'))
    ];
    this.menu.open(this.getUIContext(), 'hdr_add', items, (index: number) => {
      if (index === 0) {
        this.scanQr();
      } else if (index === 1) {
        // 不再直接读剪贴板(那需要受限权限)：打开面板，用面板里的粘贴控件取内容
        this.importText = '';
        this.sheetKind = 'import';
        this.sheetOpen = true;
      } else if (index === 2) {
        this.importFromFile();
      } else if (index === 3) {
        this.openManualMenu();
      }
    }, this.app.settings.lightLevel);
  }

  private openManualMenu(): void {
    const items: Array<MenuItemData> = [];
    for (const t of TYPE_MENU) {
      items.push(new MenuItemData(typeLabel(t), false, undefined));
    }
    const idxCustom: number = items.length;
    items.push(new MenuItemData('自定义配置', false, $r('sys.symbol.doc_text')));
    const idxChain: number = items.length;
    items.push(new MenuItemData('链式代理', false, $r('sys.symbol.link')));
    this.menu.open(this.getUIContext(), 'hdr_add', items, (index: number) => {
      this.app.editingGroupId = this.currentGroupId();
      if (index === idxCustom) {
        gotoProfileEdit(this.pathStack, '', ProfileType.CUSTOM);
        return;
      }
      if (index === idxChain) {
        gotoProfileEdit(this.pathStack, '', ProfileType.CHAIN);
        return;
      }
      if (index >= 0 && index < TYPE_MENU.length) {
        gotoProfileEdit(this.pathStack, '', TYPE_MENU[index]);
      }
    }, this.app.settings.lightLevel);
  }

  private openMiscMenu(): void {
    const items: Array<MenuItemData> = [
      new MenuItemData('更新当前订阅', false, $r('sys.symbol.arrow_clockwise')),
      new MenuItemData('清除流量统计', false, $r('sys.symbol.trash')),
      new MenuItemData('移除重复节点', false, $r('sys.symbol.doc_plaintext')),
      new MenuItemData('TCPing 测试', false, $r('sys.symbol.bolt')),
      new MenuItemData('URL Test', false, $r('sys.symbol.bolt')),
      new MenuItemData('清除测试结果', false, $r('sys.symbol.xmark')),
      new MenuItemData('删除不可用节点', false, $r('sys.symbol.trash')),
      new MenuItemData('排序 ▸', false, $r('sys.symbol.list_bullet'))
    ];
    this.menu.open(this.getUIContext(), 'profiles_more_anchor', items, (index: number) => {
      const groupId: string = this.currentGroupId();
      if (index === 0) {
        this.app.updateCurrentSubscription(groupId).then((message: string) => {
          this.toast(message);
        }).catch((e: Error) => {
          this.toast(`更新失败：${e.message}`);
        });
      } else if (index === 1) {
        this.app.clearTrafficStats(groupId).then((n: number) => {
          this.toast(n > 0 ? `已清除 ${n} 个节点的流量统计` : '没有需要清除的流量统计');
        });
      } else if (index === 2) {
        this.app.removeDuplicates(groupId).then((n: number) => {
          this.toast(n > 0 ? `已移除 ${n} 个重复节点` : '没有发现重复节点');
        });
      } else if (index === 3) {
        this.testTcp();
      } else if (index === 4) {
        this.testUrl();
      } else if (index === 5) {
        this.app.clearTestResults(groupId).then((n: number) => {
          this.toast(n > 0 ? `已清除 ${n} 个测试结果` : '没有测试结果');
        });
      } else if (index === 6) {
        this.app.deleteUnavailable(groupId).then((n: number) => {
          this.toast(n > 0 ? `已删除 ${n} 个不可用节点` : '没有不可用节点');
        });
      } else if (index === 7) {
        this.openSortMenu();
      }
    }, this.app.settings.lightLevel);
  }

  private openSortMenu(): void {
    const current: string = this.app.settings.profileSortMode;
    const items: Array<MenuItemData> = [
      new MenuItemData('原始顺序', current === 'manual', undefined),
      new MenuItemData('按名称', current === 'name', undefined),
      new MenuItemData('按延迟', current === 'latency', undefined)
    ];
    const values: Array<string> = ['manual', 'name', 'latency'];
    this.menu.open(this.getUIContext(), 'profiles_more_anchor', items, (index: number) => {
      this.app.patchSettings((s) => {
        s.profileSortMode = values[index];
      }).then(() => {
        // 设置项变化后要重建可见行（排序口径变了）
        this.app.requestRefresh();
        this.toast(`已切换为${items[index].label}`);
      });
    }, this.app.settings.lightLevel);
  }

  private currentGroupId(): string {
    const group: ProfileGroup | undefined = this.selectedGroup();
    return group === undefined ? '' : group.id;
  }

  private testTcp(): void {
    this.runTest('tcp');
  }

  private testUrl(): void {
    this.runTest('url');
  }

  /**
   * 统一的测速入口：**模式作为参数往下传**，不再"先去改全局设置再跑"。
   * 原来的写法有两个后果：改设置的那次 await 之后正在跑的那轮已经起来，
   * 第二次点击又被 AppState 的 `testing` 静默吞掉，调用方照旧弹「完成」
   * —— 甲方 2026-11-15 报的"TCPing 还没完就点 URL Test，直接提示已完成"。
   */
  private runTest(mode: string): void {
    const list: Array<Profile> = this.filtered();
    if (list.length === 0) {
      this.toast('没有可测速的节点');
      return;
    }
    this.app.testLatency(list, mode).then((outcome: LatencyTestOutcome) => {
      this.toastOutcome(outcome);
    }).catch((e: Error) => {
      this.toast(`测速失败：${e.message}`);
    });
  }

  /** 结果怎么提示：没跑要说清为什么，跑了要说清通过几个 */
  private toastOutcome(outcome: LatencyTestOutcome): void {
    if (!outcome.ran) {
      this.toast(outcome.reason.length > 0 ? outcome.reason : '测速未执行');
      return;
    }
    const label: string = outcome.urlMode ? 'URL Test' : 'TCPing';
    const summary: string = `${label} 完成：可用 ${outcome.ok}/${outcome.total}`;
    if (outcome.bindFallback) {
      this.toast(`${summary}（绑定网卡失败已去掉绑定重测，结果仅供参考）`);
    } else if (outcome.degraded) {
      this.toast(`${summary}（已降级为握手测试：${outcome.degradeReason}）`);
    } else {
      this.toast(summary);
    }
  }

  private async scanQr(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.app.uicontext();
    if (ctx === undefined) {
      return;
    }
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: false,
        enableAlbum: true
      };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(ctx, options);
      const message: string = await this.app.importText(result.originalValue, this.currentGroupId());
      this.toast(message);
    } catch (e) {
      this.toast(`扫码未完成：${(e as Error).message}`);
    }
  }

  private async importFromFile(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.app.uicontext();
    if (ctx === undefined) {
      return;
    }
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: Array<string> = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const text: string = fs.readTextSync(uris[0]);
      const message: string = await this.app.importText(text, this.currentGroupId());
      this.toast(message);
    } catch (e) {
      this.toast(`读取文件失败：${(e as Error).message}`);
    }
  }


  private openRowMenu(p: Profile): void {
    const items: Array<MenuItemData> = [
      new MenuItemData('测速', false, $r('sys.symbol.bolt')),
      new MenuItemData(p.pinned ? '取消置顶' : '置顶', false, $r('sys.symbol.pin')),
      new MenuItemData('编辑', false, $r('sys.symbol.square_and_pencil')),
      new MenuItemData('移动到分组', false, $r('sys.symbol.list_square')),
      new MenuItemData('复制分享链接', false, $r('sys.symbol.doc_plaintext')),
      new MenuItemData('删除', false, $r('sys.symbol.trash'))
    ];
    this.menu.open(this.getUIContext(), `profile_more_${p.id}`, items, (index: number) => {
      if (index === R_TEST) {
        this.app.testLatency([p]).then((outcome: LatencyTestOutcome) => {
          // 单节点测速的成功结果直接看卡片上的毫秒数；只有被并发请求挡下来才需要提示
          if (!outcome.ran && outcome.reason.length > 0) {
            this.toast(outcome.reason);
          }
        }).catch((e: Error) => {
          this.toast(`测速失败：${e.message}`);
        });
      } else if (index === R_PIN) {
        this.app.togglePin(p).catch((e: Error) => {
          this.toast(`操作失败：${e.message}`);
        });
      } else if (index === R_EDIT) {
        gotoProfileEdit(this.pathStack, p.id);
      } else if (index === R_MOVE) {
        this.moveTargetId = p.id;
        this.sheetKind = 'move';
        this.sheetOpen = true;
      } else if (index === R_COPY) {
        const link: string = exportProfileLink(p);
        if (link.length === 0) {
          this.toast('该协议暂不支持导出链接');
          return;
        }
        setClipboardText(link).then(() => {
          this.toast('节点链接已复制');
        }).catch((e: Error) => {
          this.toast(`复制失败：${e.message}`);
        });
      } else if (index === R_DELETE) {
        this.app.deleteProfile(p.id).then(() => {
          this.toast('已删除');
        }).catch((e: Error) => {
          this.toast(`删除失败：${e.message}`);
        });
      }
    }, this.app.settings.lightLevel);
  }


  private openShareMenu(p: Profile): void {
    const items: Array<MenuItemData> = [
      new MenuItemData('复制分享链接', false, $r('sys.symbol.doc_plaintext')),
      new MenuItemData('复制出站配置 JSON', false, $r('sys.symbol.doc_text'))
    ];
    this.menu.open(this.getUIContext(), `profile_share_${p.id}`, items, (index: number) => {
      if (index === 0) {
        const link: string = exportProfileLink(p);
        if (link.length === 0) {
          this.toast('该协议暂不支持导出链接');
          return;
        }
        setClipboardText(link).then(() => {
          this.toast('节点链接已复制');
        }).catch((e: Error) => {
          this.toast(`复制失败：${e.message}`);
        });
        return;
      }
      try {
        const json: string = buildOutboundJson(p, this.app.settings);
        setClipboardText(json).then(() => {
          this.toast('出站配置已复制');
        }).catch((e: Error) => {
          this.toast(`复制失败：${e.message}`);
        });
      } catch (e) {
        this.toast(`生成配置失败：${(e as Error).message}`);
      }
    }, this.app.settings.lightLevel);
  }

  @Builder
  private dragFloatingCard(index: number) {
    Row() {
      Text(this.visibleRows.length > index ? this.visibleRows[index].currentProfile().name : '')
        .fontSize(14)
        .fontColor(Theme.TEXT_1)
        .maxLines(1)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    }
    .borderRadius(14)
    .backgroundColor(Theme.SURFACE_2)
  }

  private reorderProfiles(from: number, insert: number): void {
    const list: Array<Profile> = this.filtered();
    if (from < 0 || from >= list.length) {
      return;
    }
    const moved: Profile = list.splice(from, 1)[0];
    const target: number = Math.max(0, Math.min(insert, list.length));
    list.splice(target, 0, moved);
    const ids: Array<string> = [];
    for (const p of list) {
      ids.push(p.id);
    }
    this.app.applyManualOrder(ids).then(() => {
      this.toast('已保存排序');
    }).catch((e: Error) => {
      this.toast(`排序失败：${e.message}`);
    });
  }

  @Builder
  private swipeActions(p: Profile) {
    Row({ space: 8 }) {
      this.swipeButton($r('sys.symbol.square_and_pencil'), '编辑', Theme.SURFACE_2, Theme.TEXT_1, () => {
        gotoProfileEdit(this.pathStack, p.id);
      })
      this.swipeButton($r('sys.symbol.share'), '分享', Theme.SURFACE_2, Theme.TEXT_1, () => {
        this.openShareMenu(p);
      })
      this.swipeButton($r('sys.symbol.trash'), '删除', Theme.DANGER, Color.White, () => {
        this.removeProfile(p);
      })
    }
    .height(80)
    .padding({ left: 6 })
  }

  @Builder
  private swipeButton(symbol: Resource, label: string, bg: ResourceColor, fg: ResourceColor, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(symbol)
        .fontSize(19)
        .fontColor([fg])
      Text(label)
        .fontSize(11)
        .fontColor(fg)
    }
    .width(64)
    .height(64)
    .borderRadius(18)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(bg)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  private subscriptionCard(group: ProfileGroup) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(17)
          .fontColor([Theme.BRAND])
          .onClick(() => {
            this.refreshSubscription(group);
          })
        Text(group.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick(() => {
            this.refreshSubscription(group);
          })
        Text(this.expireTextOf(group))
          .fontSize(12)
          .fontColor(Theme.TEXT_3)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.trafficTextOf(group))
        .fontSize(13)
        .fontColor(Theme.TEXT_2)
        .width('100%')

      Row() {
        Text(`${this.app.groupNodeCount(group.id)} 个节点`)
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
        Blank()
        Text(this.updatedTextOf(group))
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
      }
      .width('100%')

      if (group.lastError.length > 0) {
        Text(`上次更新失败：${group.lastError}`)
          .fontSize(11)
          .fontColor(Theme.DANGER)
          .maxLines(2)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(18)
    .backgroundColor(Theme.SURFACE)
    .alignItems(HorizontalAlign.Start)
  }

  private refreshSubscription(group: ProfileGroup): void {
    if (this.subscriptionBusy) {
      return;
    }
    this.subscriptionBusy = true;
    this.app.updateCurrentSubscription(group.id).then((message: string) => {
      this.subscriptionBusy = false;
      this.toast(message);
    }).catch((e: Error) => {
      this.subscriptionBusy = false;
      this.toast(`更新失败：${e.message}`);
    });
  }

  private expireTextOf(g: ProfileGroup): string {
    const info: SubInfo | undefined = this.app.groupSub(g);
    if (info === undefined || info.expire <= 0) {
      return '长期有效';
    }
    const days: number = Math.ceil((info.expire * 1000 - Date.now()) / 86400000);
    return days > 0 ? `剩余 ${days} 天` : '已过期';
  }

  private trafficTextOf(g: ProfileGroup): string {
    const info: SubInfo | undefined = this.app.groupSub(g);
    if (info === undefined) {
      return '流量未知';
    }
    if (info.total <= 0) {
      return '可用流量：无限';
    }
    return `已用 ${bytesText(info.download + info.upload)} / 共 ${bytesText(info.total)}`;
  }

  private updatedTextOf(g: ProfileGroup): string {
    const info: SubInfo | undefined = this.app.groupSub(g);
    if (info === undefined || info.lastUpdate <= 0) {
      return '从未更新';
    }
    return `更新于 ${dateText(info.lastUpdate)}`;
  }

  private fabOffset(): number {
    const available: number = this.fabAreaWidth - 58;
    if (available <= 0) {
      return 0;
    }
    // 智感握姿：关掉时 fabSide 固定右侧（与页头/抽屉的左侧互不干扰）
    return this.handedness.fabSide === HAND_LEFT ? 0 : available;
  }

  private showRuntimeCard(): boolean {
    return this.runtimeView.running || this.runtimeView.busy;
  }

  private tailSpacer(): number {
    return 96;
  }

  @Builder
  private connectFab() {
    Row() {
      SymbolGlyph($r('sys.symbol.paperplane'))
        .fontSize(24)
        .fontColor([Theme.ON_BRAND])
    }
    .width(58)
    .height(58)
    .borderRadius(29)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.runtimeView.buttonColor)
    .enabled(!this.runtimeView.busy)
    .shadow({ radius: 18, color: '#40101820', offsetY: 6 })
    .visualEffect(pressLightEffect(this.litPower, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litPower = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litPower = false;
      }
    })
    .onClick(() => {
      this.toggleVpn();
    })
  }

  @Builder
  private runtimeCard() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(10)
            .fontColor([Theme.SPEED_UP])
          Text(speedText(this.runtimeView.up))
            .fontSize(12)
            .fontColor(Theme.TEXT_2)
        }
        .alignItems(VerticalAlign.Center)

        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_down'))
            .fontSize(10)
            .fontColor([Theme.SPEED_DOWN])
          Text(speedText(this.runtimeView.down))
            .fontSize(12)
            .fontColor(Theme.TEXT_2)
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .width(80)

      Column({ space: 2 }) {
        Text(this.runtimeView.nodeName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.runtimeView.text)
          .fontSize(11)
          .fontColor(this.runtimeView.tint)
          .maxLines(1)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row() {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(18)
          .fontColor([Theme.TEXT_2])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Theme.SURFACE_2)
      .onClick(() => {
        this.refreshFromBar();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 10, top: 12, bottom: 12 })
    .borderRadius(24)
    .backgroundColor(Theme.SURFACE)
    .shadow({ radius: 18, color: '#33101820', offsetY: 6 })
    .alignItems(VerticalAlign.Center)
  }

  private async refreshFromBar(): Promise<void> {
    if (!this.beginCommand(this.runtime.vpnRunning ? 'switching' : 'reloading')) {
      return;
    }
    try {
      if (this.runtime.vpnRunning) {
        await this.app.reconnect();
      } else {
        await this.app.reloadData();
        this.toast('已刷新');
      }
    } catch (e) {
      this.toast(`操作失败：${(e as Error).message}`);
    } finally {
      this.endCommand();
    }
  }

  @Builder
  private sheetBody() {
    if (this.sheetKind === 'import') {
      Column({ space: 10 }) {
        Text('从文本导入')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
          .width('100%')
        Text('支持订阅地址与节点链接（vmess:// vless:// ss:// …）、'
          + 'base64 整段订阅、Clash YAML、sing-box JSON。多条链接按行分隔。')
          .fontSize(11)
          .fontColor(Theme.TEXT_3)
          .width('100%')
        TextArea({ text: this.importText, placeholder: '粘贴链接或订阅地址' })
          .height(140)
          .fontSize(13)
          .backgroundColor(Theme.SURFACE_2)
          .borderRadius(12)
          .onChange((v: string) => {
            this.importText = v;
          })
        Row({ space: 10 }) {
          // 读剪贴板用官方**安全控件**：用户点这一下就临时授权，应用不需要声明任何权限
          // （ohos.permission.READ_PASTEBOARD 是受限权限，要 AGC 申请 ACL + 每次弹窗）。
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .fontSize(14)
            .constraintSize({ minWidth: 96, maxWidth: 132, minHeight: 40, maxHeight: 44 })
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.fillFromClipboard();
              } else {
                this.toast('没拿到剪贴板授权');
              }
            })
          GlowButton({
            label: this.busy ? '导入中…' : '导入',
            grow: true,
            onTap: () => {
              this.doImport();
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: Space.PAGE, right: Space.PAGE, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    } else {
      Column() {
        PickSheetPanel({
          param: this.moveParam(),
          onClose: () => {
            this.sheetOpen = false;
          }
        })
      }
      .width('100%')
      .padding({ top: 8 })
    }
  }

  private moveParam(): PickSheetParam {
    const param: PickSheetParam = new PickSheetParam();
    param.title = '移动到分组';
    const options: Array<PickOption> = [];
    // 列出所有分组（标注"订阅/基础"），当前节点所在分组会被选中
    for (const g of this.app.groups) {
      options.push(new PickOption(g.name, g.id, g.type === 'subscription' ? '订阅' : '基础'));
    }
    param.options = options;
    let current: string = '';
    for (const p of this.app.profiles) {
      if (p.id === this.moveTargetId) {
        current = p.groupId;
      }
    }
    param.current = current;
    param.onPick = (groupId: string): void => {
      for (const p of this.app.profiles) {
        if (p.id === this.moveTargetId) {
          this.app.moveToGroup(p, groupId).then(() => {
            this.toast('已移动');
          }).catch((e: Error) => {
            this.toast(`移动失败：${e.message}`);
          });
        }
      }
    };
    return param;
  }

  /** PasteButton 授权成功后才读得到剪贴板；空内容也在这里提示 */
  private fillFromClipboard(): void {
    getClipboardText().then((text: string) => {
      if (text.trim().length === 0) {
        this.toast('剪贴板为空');
        return;
      }
      this.importText = text;
      this.toast('已粘贴');
    }).catch((e: Error) => {
      this.toast(`读取剪贴板失败：${e.message}`);
    });
  }

  private async doImport(): Promise<void> {
    if (this.importText.trim().length === 0) {
      this.toast('内容为空');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const message: string = await this.app.importText(this.importText, this.currentGroupId());
      this.toast(message);
      this.sheetOpen = false;
      this.importText = '';
    } finally {
      this.busy = false;
    }
  }

  aboutToAppear(): void {
    if (!this.stateSubscribed) {
      this.app.subscribe(this.onBusinessChanged);
      this.runtime.subscribe(this.onRuntimeChanged);
      this.stateSubscribed = true;
    }
    this.syncBusinessView();
  }

  aboutToDisappear(): void {
    this.app.unsubscribe(this.onBusinessChanged);
    this.runtime.unsubscribe(this.onRuntimeChanged);
    this.stateSubscribed = false;
  }

  private onBusinessChanged = (): void => {
    this.syncBusinessView();
  };

  private onRuntimeChanged = (): void => {
    this.syncRuntimeView();
  };

  /** 一个分组都没有时的占位（这时不渲染 Swiper：它要至少一页才有意义） */
  @Builder
  private emptyGroupsHint() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(38)
        .fontColor([Theme.TEXT_3])
      Text('还没有分组')
        .fontSize(15)
        .fontColor(Theme.TEXT_1)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private groupPage(group: ProfileGroup | undefined, showAll: boolean) {
    List({ space: 10, scroller: this.scrollerFor(showAll ? '__all__' : (group === undefined ? '' : group.id)) }) {
      if (!showAll && group !== undefined && group.type === 'subscription' && group.url.length > 0) {
        ListItem() {
          this.subscriptionCard(group)
        }
      }
      if (this.groupRowsFor(group === undefined ? '' : group.id, showAll).length === 0) {
        ListItem() {
          // 只留一句状态（不要导入教程类文案）
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(38)
              .fontColor([Theme.TEXT_3])
            Text(this.profileCount === 0
              ? (this.groupCount === 0 ? '还没有分组' : '这个分组还没有节点')
              : '没有匹配的节点')
              .fontSize(15)
              .fontColor(Theme.TEXT_1)
          }
          .width('100%')
          .padding({ top: 70, bottom: 40 })
          .alignItems(HorizontalAlign.Center)
        }
      } else {
        ForEach(this.groupRowsFor(group === undefined ? '' : group.id, showAll), (row: ProfileRowModel) => {
          ListItem() {
            ProfileCard({
              row: row,
              onSelect: (profile: Profile): void => { this.selectProfile(profile); },
              onEdit: (profile: Profile): void => { gotoProfileEdit(this.pathStack, profile.id); },
              onShare: (profile: Profile): void => { this.openShareMenu(profile); },
              onRemove: (profile: Profile): void => { this.removeProfile(profile); },
              onMore: (profile: Profile): void => { this.openRowMenu(profile); }
            })
          }
          .swipeAction({ end: this.swipeActions(row.currentProfile()), edgeEffect: SwipeEdgeEffect.Spring })
        }, (row: ProfileRowModel): string => row.profileId)
          .onMove((from: number, to: number) => {
            this.reorderProfiles(from, to);
          }, {
            onLongPress: (index: number): void => {
              hilog.info(DOMAIN, TAG, '[profiles-drag] press=%{public}d', index);
            }
          })
      }
      if (this.showRuntimeCard()) {
        ListItem() {
          Row()
            .width('100%')
            .height(this.tailSpacer())
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, bottom: 8 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    // Stack 底对齐：内容列铺满，悬浮层（状态卡 + 启动按钮）浮在上面，不占列表高度、不挡滚动
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        PageHeader({
          title: 'ReedBox',
          subtitle: this.app.testing
            ? `${this.app.testLabel} 测速中 ${this.app.testDone}/${this.app.testTotal}`
            : (this.profileCount === 0 ? '还没有配置' : `${this.profileCount} 个配置 · ${this.groupCount} 个分组`),

          showSearch: true,
          showAdd: true,
          addSymbol: $r('sys.symbol.doc_text'),
          showMenu: true,
          menuSymbol: $r('sys.symbol.dot_grid_1x2'),
          menuAnchorId: 'profiles_more_anchor',
          onDrawer: () => {
            this.onDrawer();
          },
          onSearch: () => {
            this.searchOpen = !this.searchOpen;
            if (!this.searchOpen) {
              this.setQuery('');
            }
          },
          onAdd: () => {
            this.openCreateMenu();
          },
          onMenu: () => {
            this.openMiscMenu();
          }
        })

      if (this.groupCount > 0) {
        GroupTabs({
          items: this.groupItems,
          selected: this.groupIndex,
          onSelect: (index: number) => {
            this.switchGroup(index);
          }
        })
      }

      if (this.searchOpen) {
        Row() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(15)
              .fontColor([Theme.TEXT_3])
            TextInput({ text: this.query, placeholder: '搜索名称 / 服务器 / 协议' })
              .layoutWeight(1)
              .height(36)
              .padding(0)
              .fontSize(13)
              .backgroundColor(Color.Transparent)
              .onChange((v: string) => {
                this.setQuery(v);
              })
            if (this.query.length > 0) {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(16)
                .fontColor([Theme.TEXT_3])
                .onClick(() => {
                  this.setQuery('');
                })
            }
          }
          .width('100%')
          .height(38)
          .padding({ left: 12, right: 12 })
          .borderRadius(19)
          .backgroundColor(Theme.SURFACE_2)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: Space.PAGE, right: Space.PAGE })
      }

      /**
       * 每个分组 = Swiper 的一页。
       *
       * ★ 为什么从 Tabs 换成 Swiper（2026-11-20 甲方："分组的改法不好，换个方案"）：
       *   Tabs 的"当前页"是**内部状态**，只能靠 `changeIndex()` 去推；分组列表从 0 变成 n 的那一帧
       *   子节点还没建好，`changeIndex(A)` 会被当成越界忽略 ⇒ 页签条（我自己画的）显示 A、
       *   内容却是第 1 组。之前用"延后一帧/多次重试"去补，本质是在和框架的时序赌博。
       *   Swiper 的 `index` 是**受控属性**：页面由 `groupIndex` 唯一决定，重建多少次都落在同一页，
       *   不需要控制器、不需要定时器；切换时 Swiper 自己带平移动画（duration 240ms）。
       *   `disableSwipe(true)` 保持"只能用上方页签条切组"（与原来 Tabs.scrollable(false) 一致）。
       */
      if (this.groupCount === 0) {
        this.emptyGroupsHint()
      } else {
        Swiper() {
          ForEach(this.app.groups, (group: ProfileGroup) => {
            Column() {
              this.groupPage(group, false)
            }
            .width('100%')
            .height('100%')
          }, (group: ProfileGroup) => `group_page_${group.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .index(this.groupIndex)
        .indicator(false)
        .loop(false)
        .disableSwipe(true)
        .duration(240)
        .curve(Curve.FastOutSlowIn)
        .onChange((index: number) => {
          // 只在"页面确实换了"时同步下标（切页由 groupIndex 驱动，这里正常不会改到别的值）
          if (index !== this.groupIndex) {
            this.groupIndex = index;
            this.syncVisibleRows();
          }
        })
      }

      }
      /**
       * ★ 内容列必须**明确占满整屏**：以前这里没有宽高，Column 是"包住内容"的高度，
       *   里面的 `layoutWeight(1)`（Tabs/Swiper）拿到的高度就成了不确定值，
       *   列表到不了屏幕物理底，最下面留出一条背景色空档（甲方 2026-11-21 截图："下面有一点点空白"）。
       *   页根已经开了全屏布局 + expandSafeArea/ignoreLayoutSafeArea，所以 100% 就是屏幕物理高。
       */
      .width('100%')
      .height('100%')

      Column({ space: 10 }) {
        Row() {
          this.connectFab()
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.fabAreaWidth = Number(newValue.width);
        })
        .translate({ x: this.fabOffset() })
        .animation({ duration: 280, curve: Curve.FastOutSlowIn })
        if (this.showRuntimeCard()) {
          this.runtimeCard()
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 620 })
      .padding({ left: Space.PAGE, right: Space.PAGE, bottom: Metrics.get().navBottom + 12 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
    .bindSheet(this.sheetOpen!!, this.sheetBody(), {
      height: this.sheetKind === 'import' ? 420 : 400,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.BG,
      preferType: SheetType.BOTTOM,
      onDisappear: () => {
        this.sheetOpen = false;
      }
    })
  }
}

function typeLabel(type: string): string {
  if (type === ProfileType.CHAIN) {
    return '链式代理';
  }
  if (type === ProfileType.SHADOWSOCKS) {
    return 'Shadowsocks';
  }
  if (type === ProfileType.VMESS) {
    return 'VMess';
  }
  if (type === ProfileType.VLESS) {
    return 'VLESS';
  }
  if (type === ProfileType.TROJAN) {
    return 'Trojan';
  }
  if (type === ProfileType.HYSTERIA2) {
    return 'Hysteria2';
  }
  if (type === ProfileType.TUIC) {
    return 'TUIC';
  }
  if (type === ProfileType.WIREGUARD) {
    return 'Wireguard';
  }
  if (type === ProfileType.SOCKS) {
    return 'SOCKS';
  }
  if (type === ProfileType.HTTP) {
    return 'HTTP';
  }
  if (type === ProfileType.ANYTLS) {
    return 'AnyTLS';
  }
  if (type === ProfileType.SNELL) {
    return 'Snell';
  }
  return type;
}
