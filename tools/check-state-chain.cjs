const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TS_LIB || '/root/command-line-tools/arktsdoc/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '..');
const ets = path.join(root, 'entry', 'src', 'main', 'ets');
const logs = [];
const checks = [];
function checked(name, fn) { fn(); checks.push(name); }
function source(rel) { return fs.readFileSync(path.join(ets, rel), 'utf8'); }
function load(rel, imports, globals) {
  const input = source(rel).replace(/^\s*@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(input, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(output, {
    module, exports: module.exports,
    require(name) {
      if (!(name in imports)) throw new Error(`Unexpected import ${rel}: ${name}`);
      const dependency = imports[name];
      return dependency && typeof dependency === 'object' ? { default: dependency, ...dependency } : dependency;
    },
    console, setTimeout: () => 1, clearTimeout: () => {},
    // 允许单个用例注入可控的定时器 / 系统能力桩（智感握姿的延迟订阅要靠它驱动）
    ...(globals || {})
  }, { filename: rel });
  return module.exports;
}
const LogStore = {
  addLog(line) { logs.push(line); if (this.publisher) this.publisher(line); },
  appendRemote(line) { logs.push(line); },
  getLines() { return logs; }
};
const accentModule = load('ui/Accent.ets', {});
const models = load('model/Profile.ets', {});
const runtimeModule = load('core/VpnRuntime.ets', { '../model/Store': { LogStore } });
const runtime = runtimeModule.VpnRuntime.get();
let stateUpdates = 0;
runtime.subscribe(() => stateUpdates++);
checked('Runtime starts disconnected, transitions to connecting synchronously', () => {
  assert.equal(runtime.vpnRunning, false);
  runtime.beginStart('node-A', false);
  assert.equal(runtime.vpnStatus, 'connecting');
  assert.equal(runtime.isBusy(), true);
  assert.equal(stateUpdates, 1);
});
runtime.setStatus('awaiting_auth', false);
checked('Awaiting authorization is a busy state, not disconnected', () => {
  assert.equal(runtime.isBusy(), true);
  assert.equal(runtime.statusText(), '等待 VPN 授权…');
});
const subscribers = [];
const publications = [];
let dropDeliveries = false;
const commonEventManager = {
  createSubscriber(info) { return Promise.resolve({ info }); },
  subscribe(subscriber, cb) { subscribers.push({ subscriber, cb, bundle: 'com.rzdpai.nekobox' }); },
  unsubscribe() {},
  publish(event, options, cb) {
    publications.push({ event, options });
    if (!dropDeliveries) {
      for (const sub of subscribers) {
        if (sub.subscriber.info.events.includes(event)
          && (!options.bundleName || sub.bundle === options.bundleName)) {
          sub.cb(undefined, { event, data: options.data });
        }
      }
    }
    cb(undefined);
  }
};
const ipc = load('core/VpnIpc.ets', {
  '@ohos.commonEventManager': commonEventManager,
  '@ohos.base': {},
  BuildProfile: { BUNDLE_NAME: 'com.rzdpai.nekobox' },
  './VpnRuntime': runtimeModule
});
async function main() {
  ipc.subscribeVpnEvents(line => LogStore.appendRemote(line),
    (status, running, id) => runtime.setStatus(status, running, id),
    (up, down, totalUp, totalDown) => runtime.setTraffic(up, down, totalUp, totalDown));
  await Promise.resolve();
  ipc.publishVpnStatus('connected:Node A', true, 'node-A');
  checked('CommonEvent routes connected to the current bundle and updates runtime', () => {
    assert.equal(publications.at(-1).options.bundleName, 'com.rzdpai.nekobox');
    assert.equal(runtime.vpnRunning, true);
    assert.equal(runtime.runningProfileId, 'node-A');
    assert.equal(runtime.statusText(), '已连接');
    assert.equal(runtime.isBusy(), false);
  });
  ipc.publishVpnTraffic(12, 34, 56, 78);
  checked('Traffic event reaches the same runtime instance', () => {
    assert.equal(runtime.upSpeed, 12);
    assert.equal(runtime.downSpeed, 34);
    assert.equal(runtime.totalDown, 78);
  });
  let forwards = 0;
  LogStore.publisher = line => { forwards++; ipc.publishVpnLog(line); };
  LogStore.addLog('[vpn] one extension log');
  checked('Extension log forwarding does not call LogStore recursively', () => {
    assert.equal(forwards, 1);
  });
  LogStore.publisher = undefined;
  ipc.publishVpnStatus('disconnected', false);
  checked('Disconnect clears runtime ID and speeds', () => {
    assert.equal(runtime.vpnRunning, false);
    assert.equal(runtime.runningProfileId, '');
    assert.equal(runtime.upSpeed, 0);
  });
  dropDeliveries = true;
  ipc.publishVpnStatus('connected:Offline Node', true, 'node-C');
  ipc.publishVpnTraffic(5, 6, 7, 8);
  checked('Direct mirror keeps the UI runtime correct even when the event is not delivered', () => {
    assert.equal(runtime.vpnStatus, 'connected:Offline Node');
    assert.equal(runtime.vpnRunning, true);
    assert.equal(runtime.runningProfileId, 'node-C');
    assert.equal(runtime.downSpeed, 6);
    assert.equal(publications.at(-1).event, ipc.VPN_EVENT_TRAFFIC);
  });
  dropDeliveries = false;
  ipc.publishVpnStatus('disconnected', false);
  runtime.beginStart('node-B', false);
  ipc.publishVpnTraffic(1, 0, 1, 0);
  checked('Live traffic recovery uses the requested profile ID', () => {
    assert.equal(runtime.vpnRunning, true);
    assert.equal(runtime.runningProfileId, 'node-B');
  });
  runtime.setStatus('disconnected', false);

  let releases;
  const gate = new Promise(resolve => { releases = resolve; });
  let startCalls = 0;
  let stopCalls = 0;
  let lastWant;
  let useGate = true;
  const serviceModule = load('core/VpnService.ets', {
    '@ohos.net.vpnExtension': {
      async startVpnExtensionAbility(want) { startCalls++; lastWant = want; },
      async stopVpnExtensionAbility() { stopCalls++; }
    },
    '@ohos.app.ability.Want': {}, '@ohos.app.ability.common': {},
    '../model/Store': {
      LogStore,
      async setPendingProfileId() { if (useGate) await gate; },
      async clearPendingProfileId() {}
    },
    './VpnRuntime': runtimeModule
  });
  const ctx = { abilityInfo: { bundleName: 'com.rzdpai.nekobox' } };
  const service = serviceModule.VpnService;
  const first = service.connect(ctx, 'node-A');
  const second = service.connect(ctx, 'node-A');
  assert.equal(runtime.isBusy(), true);
  releases();
  await Promise.all([first, second]);
  checked('Two rapid start taps issue exactly one extension request', () => {
    assert.equal(startCalls, 1);
    assert.equal(lastWant.bundleName, 'com.rzdpai.nekobox');
    assert.equal(lastWant.parameters.profileId, 'node-A');
  });
  useGate = false;
  runtime.setStatus('connected:Node A', true, 'node-A');
  await service.switchTo(ctx, 'node-B');
  checked('Switch preserves original Want profileId and forceRestart contract', () => {
    assert.equal(lastWant.parameters.profileId, 'node-B');
    assert.equal(lastWant.parameters.forceRestart, true);
    assert.equal(runtime.vpnStatus, 'switching');
  });
  await service.disconnect(ctx);
  checked('Stop uses extension stop and reaches disconnected', () => {
    assert.equal(stopCalls, 1);
    assert.equal(runtime.vpnRunning, false);
  });

  const a = new models.Profile(); a.id = 'node-A'; a.name = 'A';
  const b = new models.Profile(); b.id = 'node-B'; b.name = 'B';
  const g = new models.ProfileGroup(); g.id = 'group-A'; g.name = 'Airport';
  const store = {
    LogStore,
    async loadProfiles() { await Promise.resolve(); return [a, b]; },
    async loadGroups() { await Promise.resolve(); return [g]; },
    async writePrefString() {},
    async saveSettings() {},
    async initStore() {}, async readPrefString() { return ''; }
  };
  const appModule = load('core/AppState.ets', {
    '@ohos.app.ability.common': {},
    '../model/Profile': models,
    '../model/Store': store,
    '../model/RouteRule': { async loadRouteRules() { return []; }, async loadRemoteRuleSets() { return []; } },
    './Subscriptions': { async listSubs() { return [{ url: 'https://example.test/sub' }]; } },
    './VpnService': serviceModule,
    './VpnRuntime': runtimeModule,
    '../utils/LinkParser': {}, '../utils/Subscription': {}, '../utils/LatencyTester': {}, '../utils/GeoAssets': {},
    '../ui/Accent': accentModule,
    './Handedness': { Handedness: { get() { return { side: 'right', start() {}, setEnabled() {} }; } } }
  });
  const app = appModule.AppState.get();
  app.attachContext(ctx);
  const observations = [];
  app.subscribe(() => observations.push({ profiles: app.profiles.length, groups: app.groups.length, selected: app.selectedId, mtu: app.settings.mtu, vpnRunning: app.vpnRunning }));
  await app.reloadData();
  checked('Data callback runs after profiles, groups and subscriptions finish loading', () => {
    assert.equal(observations.length, 1);
    assert.equal(observations[0].profiles, 2);
    assert.equal(observations[0].groups, 1);
  });
  await app.pickProfile(b);
  checked('Selecting another node notifies without navigation or timers', () => {
    assert.equal(observations.at(-1).selected, 'node-B');
  });
  const beforeStatus = observations.length;
  app.applyVpnStatus('connecting', true, 'node-B');
  app.applyVpnStatus('awaiting_auth', true, 'node-B');
  app.applyVpnStatus('connected:Node B', true, 'node-B');
  checked('Runtime status reaches AppState mirror fields and page listeners', () => {
    assert.equal(app.vpnRunning, true);
    assert.equal(app.vpnStatus, 'connected:Node B');
    assert.equal(app.runningProfileId, 'node-B');
    assert.equal(runtime.vpnRunning, true);
    assert.equal(observations.length - beforeStatus, 3);
    assert.equal(observations.at(-1).vpnRunning, true);
    assert.equal(app.statusText(), '已连接');
  });
  app.applyTraffic(12, 34, 1200, 3400);
  checked('Traffic samples mirror into the @Trace fields users read', () => {
    assert.equal(app.upSpeed, 12);
    assert.equal(app.downSpeed, 34);
    assert.equal(app.totalUp, 1200);
    assert.equal(app.totalDown, 3400);
  });
  app.applyVpnStatus('disconnected', false, '');
  checked('Disconnect clears the mirror so the home page shows 未连接', () => {
    assert.equal(app.vpnRunning, false);
    assert.equal(app.vpnStatus, 'disconnected');
    assert.equal(app.runningProfileId, '');
    assert.equal(observations.at(-1).vpnRunning, false);
    assert.equal(app.statusText(), '未连接');
  });
  // 会话结束的流量事件不能把"未连接"改成"已连接"；仍在跑的那条要把状态补回来
  app.applyTraffic(0, 0, 5000, 6000, false, '');
  checked('A session-end traffic event never revives a stopped tunnel', () => {
    assert.equal(app.vpnRunning, false);
  });
  app.applyTraffic(9, 8, 9000, 8000, true, 'node-B');
  checked('Traffic events revive a restarted UI process while the tunnel keeps running', () => {
    assert.equal(app.vpnRunning, true);
    assert.equal(app.runningProfileId, 'node-B');
    assert.equal(app.downSpeed, 8);
  });
  app.applyVpnStatus('disconnected', false, '');

  await app.patchSettings(s => { s.mtu = 1280; });
  checked('Settings callback sees the committed new value', () => {
    assert.equal(observations.at(-1).mtu, 1280);
  });

  // ---- 冷启动恢复选中 + 导入落到当前分组 ----
  let storeProfiles = [a, b];
  const prefWrites = {};
  const upsertCalls = [];
  const subCalls = [];
  let savedGroups = [];
  const store2 = {
    LogStore,
    async loadProfiles() { return storeProfiles; },
    async loadGroups() { return [g]; },
    async loadSettings() { return new models.AppSettings(); },
    async initStore() {},
    async getRunningProfileId() { return ''; },
    async readPrefString(key, def) { return key === 'selected_profile_id' ? 'node-B' : (def === undefined ? '' : def); },
    async writePrefString(key, value) { prefWrites[key] = value; },
    async saveGroups(list) { savedGroups = list; },
    async saveProfiles(list) { storeProfiles = list; },
    async mutateProfiles(fn) { storeProfiles = fn(storeProfiles.slice()); },
    async ensureGroupByName() { return g.id; }
  };
  let nextUpdate = { added: 1, removed: 0, total: 1, skipped: 0, note: '', notModified: false };
  const appDeps = (store) => ({
    '@ohos.app.ability.common': {},
    '../model/Profile': models,
    '../model/Store': store,
    '../model/RouteRule': { async loadRouteRules() { return []; }, async loadRemoteRuleSets() { return []; } },
    './Subscriptions': {
      async listSubs() { return []; },
      upsertSub(url, userinfo, name) { upsertCalls.push({ url, name }); },
      async updateSubscription() { return nextUpdate; },
      setAppContext() {},
      async saveSubSettings(url, changes) { subCalls.push({ url, changes }); return null; },
      async removeSub() {}
    },
    './VpnService': serviceModule,
    './VpnRuntime': runtimeModule,
    '../utils/LinkParser': {
      parseShareText(text) {
        const p = new models.Profile();
        p.name = text; p.type = 'vless'; p.server = 'example.test'; p.serverPort = 443;
        return [p];
      }
    },
    '../utils/Subscription': { subErrorText: e => `${e}` },
    '../utils/LatencyTester': { async testProfiles() { return []; }, async urlTestProfiles() { return []; } },
    '../utils/GeoAssets': { async downloadGeoAsset() { return ''; } },
    '../ui/Accent': accentModule,
    './Handedness': { Handedness: { get() { return { side: 'right', start() {}, setEnabled() {} }; } } }
  });
  const appModule2 = load('core/AppState.ets', appDeps(store2));
  const app2 = appModule2.AppState.get();
  app2.attachContext(ctx);
  await app2.ensureInit();
  checked('Cold start restores the persisted selection instead of the first row', () => {
    assert.equal(app2.selectedId, 'node-B');
    assert.equal(prefWrites['selected_profile_id'], 'node-B');
  });
  const importMessage = await app2.importText('vless://one', g.id);
  checked('Importing while a group is selected files the nodes into that group', () => {
    const added = storeProfiles[storeProfiles.length - 1];
    assert.equal(added.groupId, g.id);
    assert.match(importMessage, /Airport/);
  });
  await app2.importText('https://airport.test/sub', g.id);
  checked('Importing a subscription URL never silently promotes a basic group', () => {
    assert.equal(upsertCalls.at(-1).name, 'Airport');
    assert.equal(g.type, 'basic');
    assert.equal(g.url, '');
    assert.equal(savedGroups.length, 0);
  });

  // ---- 没有任何分组时：导入自动建「未命名」分组；孤儿节点开机兜底收进去 ----
  let groups3 = [];
  const store3 = {
    LogStore,
    async loadProfiles() { return storeProfiles; },
    async loadGroups() { return groups3; },
    async loadSettings() { return new models.AppSettings(); },
    async initStore() {},
    async getRunningProfileId() { return ''; },
    async readPrefString(key, def) { return key === 'selected_profile_id' ? 'node-B' : (def === undefined ? '' : def); },
    async writePrefString() {},
    async saveGroups(list) { groups3 = list; },
    async saveProfiles(list) { storeProfiles = list; },
    async mutateProfiles(fn) { storeProfiles = fn(storeProfiles.slice()); },
    async ensureGroupByName(name) {
      for (const item of groups3) {
        if (item.name === name) {
          return item.id;
        }
      }
      const created = new models.ProfileGroup();
      created.id = `g_made_${groups3.length}`;
      created.name = name;
      groups3 = groups3.concat([created]);
      return created.id;
    }
  };
  const app3 = load('core/AppState.ets', appDeps(store3)).AppState.get();
  app3.attachContext(ctx);
  await app3.ensureInit();
  checked('Orphan nodes are adopted into an unnamed group on cold start', () => {
    assert.equal(groups3.length, 1);
    assert.equal(groups3[0].name, '未命名');
    assert.equal(storeProfiles.filter(p => p.groupId !== groups3[0].id).length, 0);
  });
  storeProfiles = [];
  groups3 = [];
  const freshMessage = await app3.importText('vless://fresh', '');
  checked('Importing with no group creates the unnamed group and files the node there', () => {
    assert.equal(groups3.length, 1);
    assert.equal(groups3[0].name, '未命名');
    assert.equal(storeProfiles.length, 1);
    assert.equal(storeProfiles[0].groupId, groups3[0].id);
    assert.equal(app3.pendingGroupId, groups3[0].id);
    assert.match(freshMessage, /未命名/);
  });
  const subGroup = new models.ProfileGroup();
  subGroup.id = 'g_sub';
  subGroup.name = 'airport';
  subGroup.type = 'subscription';
  subGroup.url = 'https://a.test/s';
  groups3 = groups3.concat([subGroup]);
  const subNode = new models.Profile();
  subNode.id = 'p_sub';
  subNode.name = 'sub node';
  subNode.groupId = 'g_sub';
  subNode.subUrl = 'https://a.test/s';
  storeProfiles = storeProfiles.concat([subNode]);
  await app3.reloadData();
  const keptCount = await app3.demoteGroupToBasic(subGroup);
  checked('Demoting a subscription group keeps the nodes and drops the subscription', () => {
    assert.equal(keptCount, 1);
    const after = groups3.find(x => x.id === 'g_sub');
    assert.equal(after.type, 'basic');
    assert.equal(after.url, '');
    const node = storeProfiles.find(p => p.id === 'p_sub');
    assert.equal(node.subUrl, '');
    assert.equal(node.groupId, 'g_sub');
  });
  // 重命名订阅分组：SubInfo.group 必须跟着改，否则下次更新会把节点落到同名新组
  const airGroup = new models.ProfileGroup();
  airGroup.id = 'g_air';
  airGroup.name = 'air';
  airGroup.type = 'subscription';
  airGroup.url = 'https://air.test/s';
  groups3 = groups3.concat([airGroup]);
  await app3.reloadData();
  await app3.renameGroup(airGroup, 'air-new');
  checked('Renaming a subscription group retargets its SubInfo group name', () => {
    assert.equal(groups3.find(x => x.id === 'g_air').name, 'air-new');
    const call = subCalls.at(-1);
    assert.equal(call.url, 'https://air.test/s');
    assert.equal(call.changes.group, 'air-new');
  });
  const duplicateMessage = await app3.addGroup('air-new', 'basic', '', true);
  checked('Creating a group with an existing name is rejected instead of mutating it', () => {
    assert.match(duplicateMessage, /已存在同名分组/);
    assert.equal(groups3.filter(x => x.name === 'air-new').length, 1);
  });
  // 一条订阅地址只能属于一个分组：重复建订阅分组要被拒，且不能留下空分组
  const groupsBefore = groups3.length;
  const sameUrlMessage = await app3.addGroup('另一个机场', 'subscription', 'https://air.test/s', true);
  checked('A second subscription group cannot reuse the same URL', () => {
    assert.match(sameUrlMessage, /已经属于分组/);
    assert.equal(groups3.length, groupsBefore);
    assert.equal(groups3.filter(x => x.url === 'https://air.test/s').length, 1);
  });
  nextUpdate = { added: 2, removed: 1, total: 5, skipped: 0, note: '', notModified: false };
  const diffMessage = await app3.refreshSubscription('https://a.test/s');
  checked('Subscription update reports the real diff instead of equal add/remove counts', () => {
    assert.match(diffMessage, /新增 2/);
    assert.match(diffMessage, /移除 1/);
    assert.match(diffMessage, /共 5 个/);
  });
  nextUpdate = { added: 0, removed: 0, total: 5, skipped: 0, note: '', notModified: false };
  const sameMessage = await app3.refreshSubscription('https://a.test/s');
  checked('An unchanged subscription says so instead of echoing equal counts', () => {
    assert.match(sameMessage, /内容未变/);
    assert.doesNotMatch(sameMessage, /新增 0/);
  });
  const rowModule = load('ui/neko/ProfileRowSource.ets', { '../../model/Profile': models });
  const rows = new rowModule.ProfileRowSource();
  let reloads = 0;
  rows.registerDataChangeListener({ onDataReloaded() { reloads++; } });
  rows.reset([a, b], 'node-A', '', false, true);
  const retainedRow = rows.getData(0);
  rows.updateStates('node-B', 'node-B', true, true);
  rows.reset([a, b], 'node-B', 'node-B', true, true);
  checked('Selection moves between stable lazy rows without rebuilding the source', () => {
    assert.equal(reloads, 1);
    assert.equal(rows.getData(0), retainedRow);
    assert.equal(rows.getData(0).selected, false);
    assert.equal(rows.getData(1).selected, true);
    assert.equal(rows.getData(1).running, true);
  });
  b.name = 'Updated B';
  rows.reset([a, b], 'node-B', 'node-B', true, true);
  checked('Editing a plain Profile replaces its traced row snapshot', () => {
    assert.equal(rows.getData(1).profile.name, 'Updated B');
  });

  const appSource = source('core/AppState.ets');
  const homeSource = source('ui/neko/ProfilesPage.ets');
  const groupSource = source('ui/neko/GroupsPage.ets');
  const routeSource = source('ui/neko/RouteTab.ets');
  const ext = source('vpnext/VpnExtAbility.ets');
  checked('Status experiment code and UI polling are absent', () => {
    assert.doesNotMatch(appSource, /inferFromCoreLog|pullStatusFile|vpn_status\.json/);
    assert.doesNotMatch(homeSource + groupSource, /pollTimer|syncSnapshot|setInterval/);
    // 列表改用 ForEach + onMove（拖动排序照 RzdMusic 音源管理）；仍要求稳定 key
    assert.match(homeSource, /ForEach\(this\.groupRowsFor\(/);
    assert.match(homeSource, /row\.profileId\)/);
    assert.match(homeSource, /\.onMove\(\(from: number, to: number\) =>/);
    const bar = homeSource.slice(homeSource.indexOf('private connectFab()'), homeSource.indexOf('private runtimeCard()'));
    assert.doesNotMatch(bar, /this\.app\.vpnRunning|this\.snap/);
    assert.match(bar, /\.enabled\(!this\.runtimeView\.busy\)/);
    assert.match(ext, /bundleName: BUNDLE_NAME/);
    assert.doesNotMatch(ext, /setPendingProfileId\(this\.latestRequestedProfileId\)/);
    assert.ok(ext.indexOf('publishVpnStatus(`connected:${node.name}`') < ext.indexOf('void this.showConnectedNotification(node.name, -1)'));
  });
  checked('Group tabs are groups only and the subscription card needs a real subscription', () => {
    assert.doesNotMatch(homeSource, /new Array<string>\(\) = \['全部'\]|groupItems[^\n]*\['全部'\]/);
    assert.doesNotMatch(homeSource, /未分组页签|isUngroupedChip/);
    assert.match(homeSource, /group\.type === 'subscription' && group\.url\.length > 0/);
    assert.doesNotMatch(groupSource, /未分组/);
    assert.doesNotMatch(appSource, /markGroupAsSubscription/);
    assert.match(appSource, /const UNNAMED_GROUP: string = '未命名'/);
    // 一条订阅只能挂一个分组 + 历史脏数据修复
    assert.match(appSource, /private subscriptionOwnerName\(url: string\): string/);
    assert.match(appSource, /private async repairDuplicateSubGroups\(\)/);
    const addBody = appSource.slice(appSource.indexOf('async addGroup('), appSource.indexOf('private subGroupForUrl'));
    assert.ok(addBody.indexOf('subscriptionOwnerName(subUrl)') < addBody.indexOf('ensureGroupByName(trimmed)'),
      'addGroup must validate the subscription URL before creating the group');
  });
  checked('Every bindSheet uses two-way binding so it can reopen after a tap-outside close', () => {
    const sheets = ['ui/neko/ProfilesPage.ets', 'ui/neko/GroupsPage.ets', 'ui/neko/RouteTab.ets',
      'ui/neko/SettingsTab.ets', 'ui/neko/ProfileEditPage.ets'];
    for (const rel of sheets) {
      const text = source(rel);
      assert.doesNotMatch(text, /bindSheet\(!!/, rel);
      assert.match(text, /bindSheet\(this\.\w+!!/, rel);
      assert.match(text, /onDisappear: \(\) => \{\s*this\.\w+ = false;/, rel);
    }
  });
  checked('Destructive actions ask for confirmation first', () => {
    assert.match(groupSource, /confirmDestructive\(this\.getUIContext\(\), '删除分组'/);
    assert.match(groupSource, /confirmDestructive\(this\.getUIContext\(\), '清空分组'/);
    assert.match(homeSource, /confirmDestructive\(this\.getUIContext\(\), '删除节点'/);
    assert.match(routeSource, /confirmDestructive\(this\.getUIContext\(\), '清空全部规则'/);
    assert.match(appSource, /disconnectIfRunningRemoved/);
  });
  checked('Group settings panel follows the group type', () => {
    assert.match(groupSource, /const isSub: boolean = g\.type === 'subscription' && g\.url\.length > 0;/);
    assert.match(groupSource, /this\.editKind = isSub \? 'subscription' : 'basic';/);
    assert.match(groupSource, /if \(this\.editKind === 'subscription'\) \{[\s\S]{0,80}ToggleRow/);
    assert.match(appSource, /async renameGroup\(g: ProfileGroup, newName: string\)/);
  });
  checked('Updating a subscription never invents a domain-named group', () => {
    const subSource = source('core/Subscriptions.ets');
    assert.doesNotMatch(subSource, /let groupName = subNameOf\(url\)/);
    assert.doesNotMatch(subSource, /groupName = subForGroup\.name\.trim\(\);/);
    assert.match(subSource, /if \(groupName\.length === 0\) \{\s*groupName = '未命名';/);
    assert.match(subSource, /g\.type === 'subscription' && g\.url === url/);
    // 计数必须是真实差异；total 是本订阅的节点数
    assert.match(subSource, /const beforeKeys: Record<string, boolean>/);
    assert.match(subSource, /added: addedReal, removed: removedReal, total: subTotal/);
    assert.doesNotMatch(appSource, /新增 \$\{result\.added\}，移除 \$\{result\.removed\}，共/);
    // 正在连接的节点不能在更新后变成重复条目
    assert.match(subSource, /runningIdentity/);
  });
  checked('Deleting a group deletes its nodes instead of re-homing them', () => {
    const deleteStart = appSource.indexOf('async deleteGroup(g: ProfileGroup)');
    const deleteBody = appSource.slice(deleteStart, deleteStart + 2200);
    assert.doesNotMatch(deleteBody, /ensureUnnamedGroup|unnamedId/);
    assert.match(deleteBody, /p\.groupId === g\.id \|\| \(isSub && p\.subUrl === g\.url\)/);
    assert.match(deleteBody, /disconnectIfRunningRemoved/);
    assert.match(groupSource, /无法恢复/);
  });
  checked('Breakpoints are compared in vp and the side panel needs a tablet-sized window', () => {
    const entrySource = source('entryability/EntryAbility.ets');
    // 官方断点：SM <600vp ≤ MD <840vp ≤ LG（windowSizeChange / windowRect 都是 px）
    assert.match(entrySource, /const BREAKPOINT_MEDIUM: number = 600;/);
    assert.match(entrySource, /const BREAKPOINT_LARGE: number = 840;/);
    assert.match(entrySource, /private pxToVp\(px: number\): number/);
    assert.match(entrySource, /this\.publishBreakpoint\(rect\.width, rect\.height\)/);
    assert.match(entrySource, /this\.publishBreakpoint\(size\.width, size\.height\)/);
    assert.match(entrySource, /state\.shortSide = Math\.min\(widthVp, heightVp\);/);
    const shellSource2 = source('pages/Bootstrap.ets');
    assert.match(shellSource2, /return this\.app\.shortSide >= 600;/);
    assert.doesNotMatch(shellSource2, /this\.app\.breakpoint !== 'compact'/);
    assert.match(appSource, /@Trace shortSide: number = 360;/);
  });
  checked('Shell: narrow drawer, in-shell sections, permanent left panel on tablets', () => {
    const shellSource = source('pages/Bootstrap.ets');
    assert.doesNotMatch(shellSource, /\.width\('82%'\)/);
    assert.match(shellSource, /private drawerWidth\(\): number/);
    assert.match(shellSource, /private contentMaxWidth\(\): Length/);
    assert.match(shellSource, /private isWide\(\): boolean/);
    // 六个分区全部壳内切换：不再 push 二级页，只有节点编辑走 navDestination
    assert.doesNotMatch(shellSource, /pushPathByName\(/);
    assert.match(shellSource, /if \(this\.isWide\(\)\) \{[\s\S]{0,120}this\.drawerPanel\(\)/);
    const sectionBody = shellSource.slice(shellSource.indexOf('private sectionContent()'),
      shellSource.indexOf('private drawerPanel()'));
    for (const page of ['GroupsPage', 'RouteTab', 'SettingsTab', 'LogsPage', 'AboutPage', 'ProfilesPage']) {
      assert.match(sectionBody, new RegExp(page), page);
    }
  });
  checked('Shell pages are in-shell components without HDS title bars', () => {
    for (const rel of ['ui/neko/RouteTab.ets', 'ui/neko/SettingsTab.ets', 'ui/neko/LogsPage.ets', 'ui/neko/AboutPage.ets']) {
      const text = source(rel);
      assert.doesNotMatch(text, /HdsNavDestination\(/, rel);
      assert.doesNotMatch(text, /hdsPageBar\(/, rel);
      assert.match(text, /PageHeader\(\{/, rel);
      assert.match(text, /onDrawer: \(\) => \{/, rel);
    }
  });
  checked('Handedness: operating hand wins, no centre docking, right by default', () => {
    const handSource = source('core/Handedness.ets');
    assert.match(handSource, /BOTH_HANDS_HELD/);
    // 甲方：启动按钮只保留左右手 ⇒ 双手握持不再映射 center
    assert.doesNotMatch(handSource, /next = HAND_CENTER;/);
    assert.match(handSource, /SystemCapability\.MultimodalAwareness\.Motion/);
    assert.match(handSource, /setTimeout\(\(\) => \{/);
    assert.match(handSource, /@ObservedV2/);
    assert.doesNotMatch(handSource, /AppStorage/);
  });
  checked('Home page floats the connect button and hides the status card until connected', () => {
    assert.doesNotMatch(homeSource, /private statusBar\(\)/);
    assert.match(homeSource, /private connectFab\(\)/);
    assert.match(homeSource, /private runtimeCard\(\)/);
    assert.match(homeSource, /return this\.runtimeView\.running \|\| this\.runtimeView\.busy;/);
    assert.match(homeSource, /private fabOffset\(\): number/);
    assert.match(homeSource, /\.translate\(\{ x: this\.fabOffset\(\) \}\)/);
    assert.match(homeSource, /\.animation\(\{ duration: \d+, curve: Curve\.FastOutSlowIn \}\)/);
    assert.match(homeSource, /hitTestBehavior\(HitTestMode\.Transparent\)/);
  });
  checked('Settings value pickers use the system Select with immersive material', () => {
    const settingsSource = source('ui/neko/SettingsTab.ets');
    assert.match(settingsSource, /SelectRow\(\{/);
    assert.doesNotMatch(settingsSource, /this\.openPick\(/);
    assert.doesNotMatch(settingsSource, /PickSheetPanel/);
    const commonSource = source('ui/CommonUi.ets');
    const rowBody = commonSource.slice(commonSource.indexOf('export struct SelectRow'),
      commonSource.indexOf('export struct SelectRow') + 2600);
    assert.match(rowBody, /Select\(this\.selectOptions\(\)\)/);
    assert.match(rowBody, /attributeModifier\(new HdsSelectMenuMaterial/);
    const material = source('ui/SelectMaterial.ets');
    assert.match(material, /menuSystemMaterial\(immersiveMedium\(\)\)/);
    assert.match(material, /isImmersiveMaterialSupported\(\)/);
    assert.match(material, /menuBackgroundBlurStyle\(BlurStyle\.COMPONENT_THICK\)/);
  });
  checked('Page header is two stacked layers (title slides, icons fly out and back)', () => {
    const common = source('ui/CommonUi.ets');
    const header = common.slice(common.indexOf('export struct PageHeader'),
      common.indexOf('export struct GroupTabs'));
    // 标题层 / 图标层各自 width('100%') 铺在同一个 Stack 上 ⇒ 不可能互相压字
    assert.match(header, /Stack\(\{ alignContent: Alignment\.Start \}\)/);
    assert.match(header, /\.translate\(\{ x: this\.titleShift \}\)/);
    // 图标层里 ☰ 与动作组分居两端（中间 Blank 撑开），换手时顺序互换
    assert.match(header, /if \(this\.mirrored\) \{\s*Column\(\) \{\s*this\.actionGroup\(\)/);
    assert.match(header, /Blank\(\)/);
    // 换手：各自往自己那一侧飞出去（translate + 同步淡出），换边后再飞回来
    assert.match(header, /\.translate\(\{ x: this\.flyX\(true\) \}\)/);
    assert.match(header, /\.translate\(\{ x: this\.flyX\(false\) \}\)/);
    assert.match(header, /\.opacity\(this\.iconFade\(\)\)/);
    assert.match(header, /return \(onLeft \? -HDR_FLY : HDR_FLY\) \* this\.iconFly;/);
    assert.doesNotMatch(header, /headerAlpha|iconAlpha/);
    // monitor：先飞出 → 再翻 mirrored（此刻不可见）→ 标题滑动 + 图标飞回
    const monitorBody = header.slice(header.indexOf("@Monitor('handedness.side'"),
      header.indexOf('@Event onDrawer'));
    assert.match(monitorBody, /ui\.animateTo\(\{ duration: \d+, curve: Curve\.EaseIn \}[\s\S]{0,80}this\.iconFly = 1;/);
    assert.match(monitorBody, /this\.mirrored = target;/);
    assert.match(monitorBody, /this\.titleShift = this\.shiftFor\(target\);/);
    assert.match(monitorBody, /this\.iconFly = 0;/);
    // 老写法（整条 Row 用 justifyContent 换边 ⇒ 不可动画 ⇒ 瞬切）不许回来
    assert.doesNotMatch(header, /justifyContent\(this\.mirrored \? FlexAlign\.End : FlexAlign\.Start\)/);
  });
  checked('Content reaches the physical screen bottom (full-screen + root ignore)', () => {
    // ★ 甲方 2026-11-01 第五次反馈："Neko4 / RzdCard / RzdMusic 都是到最底部的"。
    //   做法照 RzdMusic 的"状态栏三件套"：窗口全屏布局 + 页面根 ignore TOP/BOTTOM + 内容列 padding-top=状态栏高，
    //   底部**不加任何留白**（谁再加 navBottom 到列表上，就等于凭空多一块空白）。
    assert.match(source('entryability/EntryAbility.ets'), /setWindowLayoutFullScreen\(true\)/);
    const shell = source('pages/Bootstrap.ets');
    assert.match(shell, /private topInset\(\): number/);
    assert.match(shell, /\.padding\(\{ top: this\.topInset\(\) \}\)/);
    assert.match(shell,
      /\.ignoreLayoutSafeArea\(\[LayoutSafeAreaType\.SYSTEM\], \[LayoutSafeAreaEdge\.TOP, LayoutSafeAreaEdge\.BOTTOM\]\)/);
    // 列表/滚动容器不许再叠底部留白；只有悬浮层（FAB/状态卡）可以让 navBottom，避免被手势条压住
    for (const rel of ['ui/neko/ProfilesPage.ets', 'ui/neko/GroupsPage.ets', 'ui/neko/RouteTab.ets',
      'ui/neko/SettingsTab.ets', 'ui/neko/LogsPage.ets', 'ui/neko/AboutPage.ets']) {
      const text = source(rel);
      const listPads = text.match(/\.padding\(\{[^}]*bottom: Metrics\.get\(\)\.navBottom[^}]*\}\)/g) ?? [];
      assert.ok(listPads.length <= 1, rel);   // 只允许悬浮层那一处
      assert.match(text, /bottom: 8 \}\)|bottom: Metrics\.get\(\)\.navBottom \+ 12 \}\)/, rel);
    }
  });
  checked('App icon is a single flat 1024 tile (no layered white-card foreground)', () => {
    const appJson = fs.readFileSync(path.join(root, 'AppScope', 'app.json5'), 'utf8');
    assert.match(appJson, /"icon": "\$media:app_icon"/);
    const moduleJson = fs.readFileSync(path.join(root, 'entry', 'src', 'main', 'module.json5'), 'utf8');
    assert.match(moduleJson, /"icon": "\$media:icon"/);
    // PNG IHDR：宽高各 4 字节大端（偏移 16 / 20）
    for (const rel of ['AppScope/resources/base/media/app_icon.png',
      'entry/src/main/resources/base/media/icon.png']) {
      const png = fs.readFileSync(path.join(root, rel));
      assert.equal(png.readUInt32BE(16), 1024, rel);
      assert.equal(png.readUInt32BE(20), 1024, rel);
    }
  });
  checked('Group switch rebuilds the list, and selectors animate', () => {
    const home = source('ui/neko/ProfilesPage.ets');
    // ★ V2 是细粒度刷新：ForEach 读普通对象的内部数组时，切分组不会重刷（甲方 2026-11-01 报的"永远第一个分组"）
    assert.match(home, /@Local visibleRows: Array<ProfileRowModel> = \[\];/);
    assert.match(home, /this\.visibleRows = this\.groupRowsFor\(/);
    assert.match(home, /ForEach\(this\.groupRowsFor\(/);
    assert.doesNotMatch(home, /ForEach\(this\.profileSource\.models\(\)/);
    const common = source('ui/CommonUi.ets');
    // 分组页签：指示器是一根会滑的横条（measured → animateTo translate）
    const tabs = common.slice(common.indexOf('export struct GroupTabs'), common.indexOf('// ------------------------------------------------------------------ 光感'));
    assert.match(tabs, /@Monitor\('selected'\)/);
    assert.match(tabs, /this\.getUIContext\(\)\.animateTo\(\{ duration: \d+, curve: Curve\.FastOutSlowIn \}/);
    assert.match(tabs, /\.translate\(\{ x: this\.barX \}\)/);
    assert.match(tabs, /Number\(newArea\.globalPosition\.x\) - this\.originX/);
    // 横向滑到头要有系统回弹（内容不够一屏也给：alwaysEnabled）
    assert.match(tabs, /\.edgeEffect\(EdgeEffect\.Spring, \{ alwaysEnabled: true \}\)/);
    // 分段条改成**官方高级组件** CapsuleSegmentButtonV2（自绘版已删）
    const seg = common.slice(common.indexOf('export struct SegmentedRow'), common.indexOf('export struct FormRow'));
    assert.match(seg, /CapsuleSegmentButtonV2\(\{/);
    assert.match(seg, /@Local items: SegmentButtonV2Items = new SegmentButtonV2Items\(\[\]\);/);
    assert.doesNotMatch(seg, /this\.segWidth\(\)/);
    // 切分组：**系统 Tabs** 负责切换动画（不再自绘 translate/animateTo）
    const home2 = source('ui/neko/ProfilesPage.ets');
    assert.match(home2, /private tabsController: TabsController = new TabsController\(\);/);
    // 只给 controller（带 index 会吃掉切页动画）；首帧对齐靠延后一帧的一次性 realign
    assert.match(home2, /Tabs\(\{ barPosition: BarPosition\.Start, controller: this\.tabsController \}\)/);
    assert.match(home2, /private realignTabsToSelectedGroup\(\): void \{/);
    assert.match(home2, /this\.realignTimer = setTimeout\(\(\): void => \{/);
    assert.match(home2, /this\.realignTimer = -1;/);
    assert.match(home2, /\.animationDuration\(\d+\)/);
    assert.match(home2, /this\.tabsController\.changeIndex\(index\);/);
    // 系统回调不能把页签写回真源（首帧会先落到 0，写了就把恢复的分组覆盖掉）
    assert.doesNotMatch(home2.slice(home2.indexOf('.onChange((index: number)'), home2.indexOf('.onChange((index: number)') + 1200), /selectGroupById/);
    assert.match(home2, /ForEach\(this\.groupRowsFor\(/);
    assert.doesNotMatch(home2, /listShift|listAlpha|groupSwitchGen/);
    // ★ ForEach 同 key 不会重跑 itemGenerator ⇒ 行模型必须按 id 复用（否则切节点 UI 不刷新）
    assert.match(home2, /private rowsById: Map<string, ProfileRowModel> = new Map<string, ProfileRowModel>\(\);/);
    assert.match(home2, /private rowFor\(p: Profile\): ProfileRowModel \{/);
    assert.match(home2, /rows\.push\(this\.rowFor\(p\)\);/);
    // 切模式不再弹提示
    assert.doesNotMatch(source('ui/neko/RouteTab.ets'), /已切换为/);
  });
  checked('Theme colour, splash icon, app icon reuse and secondary-page title', () => {
    // 主题色：BRAND 变成运行期可取的 getter，设置页有一排色点，'界面' 那行删掉
    const theme = source('ui/Theme.ets');
    assert.match(theme, /static get BRAND\(\): ResourceColor \{\s*return Accent\.get\(\)\.color;/);
    assert.match(theme, /from '\.\/Accent'/);
    assert.match(source('ui/Accent.ets'), /@ObservedV2/);
    assert.match(source('ui/Accent.ets'), /@Trace color: string/);
    assert.match(source('model/Profile.ets'), /themeColor: string = '';/);
    assert.match(source('core/AppState.ets'), /Accent\.get\(\)\.apply\(this\.settings\.themeColor/);
    assert.match(source('core/AppState.ets'), /async setThemeColor\(color: string\): Promise<void>/);
    const settings = source('ui/neko/SettingsTab.ets');
    assert.match(settings, /this\.themeColorRow\(\)/);
    assert.match(settings, /ForEach\(Accent\.PRESETS/);
    assert.doesNotMatch(settings, /label: '界面'/);
    const about = source('ui/neko/AboutPage.ets');
    assert.doesNotMatch(about, /'界面'/);
    // 关于页 / 侧栏头部用应用图标（不是 symbol）
    assert.match(about, /\$r\('app\.media\.icon'\)/);
    assert.match(source('pages/Bootstrap.ets'), /\$r\('app\.media\.icon'\)/);
    // 开屏图换成透明底 artwork，否则夜间模式是一块白板
    const moduleJson = fs.readFileSync(path.join(root, 'entry', 'src', 'main', 'module.json5'), 'utf8');
    assert.match(moduleJson, /"startWindowIcon": "\$media:start_icon"/);
    const startIcon = fs.readFileSync(path.join(root, 'entry/src/main/resources/base/media/start_icon.png'));
    assert.equal(startIcon.readUInt8(25), 6, 'start_icon 必须是带 alpha 的 PNG(RGBA)');
    // 二级页（编辑节点）标题栏：窗口全屏 + destination ignore TOP ⇒ 标题栏必须自己让状态栏
    // 智感握姿开关：设置项 + 立即生效的 action + 设置页开关行（关掉要退订系统服务）
    assert.match(source('model/Profile.ets'), /handAwareness: boolean = false;/);
    assert.match(source('core/Handedness.ets'), /get fabSide\(\): string/);
    assert.match(source('core/Handedness.ets'), /get uiSide\(\): string/);
    assert.match(source('ui/neko/ProfilesPage.ets'), /this\.handedness\.fabSide === HAND_LEFT/);
    assert.match(source('pages/Bootstrap.ets'), /this\.handedness\.uiSide === HAND_RIGHT/);
    assert.match(source('core/Handedness.ets'), /setEnabled\(enabled: boolean\): void/);
    assert.match(source('core/Handedness.ets'), /if \(this\.started \|\| !this\.enabled\)/);
    assert.match(source('core/AppState.ets'), /async setHandAwareness\(enabled: boolean\): Promise<void>/);
    assert.match(source('core/AppState.ets'), /Handedness\.get\(\)\.setEnabled\(this\.settings\.handAwareness\)/);
    assert.match(source('ui/neko/SettingsTab.ets'), /label: '智感握姿'/);
    const edit = source('ui/neko/ProfileEditPage.ets');
    assert.match(edit, /hdsPageBar\([\s\S]{0,200}this\.pathStack, true,\s*\/\/[\s\S]{0,200}true\)\)/);
  });
  checked('No hand-holding copy in the UI (power users only)', () => {
    // 甲方 2026-11-01：这软件不是给小白用的 —— 删掉"点右上角…""换个关键字…""已切换为…模式"这类科普/教程文案
    const uiText = ['ui/neko/ProfilesPage.ets', 'ui/neko/GroupsPage.ets', 'ui/neko/RouteTab.ets',
      'ui/neko/SettingsTab.ets', 'ui/neko/AboutPage.ets', 'ui/neko/ProfileEditPage.ets']
      .map(source).join('\n');
    assert.doesNotMatch(uiText, /点右上角|换个关键字|会自动建|规则的先后就是优先级|原版 [a-z_]+ 分组/);
    // 模式切换不再有说明文字（'所有流量走代理' 那三句）
    assert.doesNotMatch(source('ui/neko/RouteTab.ets'), /所有流量走代理|所有流量直连/);
  });
  // ---------------------------------------------------------------- 智感握姿：订阅生命周期（行为级）
  // 这些用例真的会跑 Handedness 的代码：用可控定时器驱动 start() 的延后订阅，
  // 用桩记录 motion.on/off 的调用，验证"关闭后绝不重新订阅"和"关闭态不跟手"。
  const makeHandHarness = () => {
    const calls = { on: [], off: [] };
    const timers = [];
    const motionModule = {
      motion: {
        OperatingHandStatus: { NONE: 0, LEFT_HAND_OPERATED: 1, RIGHT_HAND_OPERATED: 2 },
        HoldingHandStatus: { NONE: 0, LEFT_HAND_HELD: 1, RIGHT_HAND_HELD: 2, BOTH_HANDS_HELD: 3 },
        getRecentOperatingHandStatus() { return 0; },
        on(type) { calls.on.push(type); },
        off(type) { calls.off.push(type); }
      }
    };
    const mod = load('core/Handedness.ets', {
      '@kit.MultimodalAwarenessKit': motionModule,
      '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } }
    }, {
      setTimeout(fn) { timers.push(fn); return timers.length; },
      clearTimeout() {},
      canIUse() { return true; }
    });
    return {
      motion: motionModule.motion,
      calls,
      inst: mod.Handedness.get(),
      drain() { const q = timers.splice(0); for (const fn of q) { fn(); } }
    };
  };

  checked('Handedness: enable then disable before the deferred task runs never subscribes', () => {
    const h = makeHandHarness();
    h.inst.setEnabled(true);    // 排队 subscribe
    h.inst.setEnabled(false);   // stop() 必须让排队任务作废
    h.drain();                  // 把队列跑掉
    assert.deepEqual(h.calls.on, [], '关闭后不应发生任何 motion.on');
    assert.equal(h.inst.enabled, false);
    assert.equal(h.inst.fabSide, 'right', '关闭态：启动按钮固定右侧');
    assert.equal(h.inst.uiSide, 'left', '关闭态：页头/抽屉固定左侧');
  });

  checked('Handedness: disabled state ignores stray events; enabled state follows them', () => {
    const h = makeHandHarness();
    // 1) 关闭态：直接塞事件（模拟"off 没退干净"）也不能改布局
    h.inst.onOperating(h.motion.OperatingHandStatus.LEFT_HAND_OPERATED);
    h.inst.onHolding(h.motion.HoldingHandStatus.LEFT_HAND_HELD);
    assert.equal(h.inst.side, 'right');
    assert.equal(h.inst.uiSide, 'left');
    // 2) 开启并让订阅任务跑掉之后，事件才生效
    h.inst.setEnabled(true);
    h.drain();
    assert.deepEqual(h.calls.on, ['operatingHandChanged', 'holdingHandChanged']);
    h.inst.onOperating(h.motion.OperatingHandStatus.LEFT_HAND_OPERATED);
    assert.equal(h.inst.side, 'left');
    assert.equal(h.inst.uiSide, 'left');
    assert.equal(h.inst.fabSide, 'left');
  });

  checked('Handedness: repeated toggling never double-subscribes', () => {
    const h = makeHandHarness();
    h.inst.setEnabled(true);
    h.drain();
    h.inst.setEnabled(false);
    h.inst.setEnabled(true);
    h.inst.setEnabled(false);
    h.inst.setEnabled(true);
    h.drain();
    const operatings = h.calls.on.filter((t) => t === 'operatingHandChanged');
    assert.equal(operatings.length, 2, '每次开启只订阅一次（共两次），不能叠加');
    // 第二次关闭发生在"排队但还没真正订阅"时 ⇒ 不该对未订阅的事件调 off（只应有第一次关闭的那 1 次退订）
    const offs = h.calls.off.filter((t) => t === 'operatingHandChanged');
    assert.equal(offs.length, 1, '只对真正订阅过的事件退订');
    // 最后一次是"开" ⇒ 应当处于已订阅状态
    assert.equal(h.inst.enabled, true);
  });

  // ---------------------------------------------------------------- 行模型：稳定身份 + 状态回写
  checked('Row model keeps identity while selected state flips (list refresh contract)', () => {
    const rowMod = load('ui/neko/ProfileRowSource.ets', { '../../model/Profile': models });
    const a = new rowMod.ProfileRowModel(storeProfiles[0]);
    const b = new rowMod.ProfileRowModel(storeProfiles[1]);
    a.updateState(storeProfiles[1].id, '', false, true);   // 选中 B
    assert.equal(a.selected, false, 'A 必须取消选中');
    assert.equal(b.selected, false);
    b.updateState(storeProfiles[1].id, '', false, true);
    assert.equal(b.selected, true, 'B 选中');
    // 再切回 A：同一对象复用，字段能来回翻
    a.updateState(storeProfiles[0].id, '', false, true);
    b.updateState(storeProfiles[0].id, '', false, true);
    assert.equal(a.selected, true);
    assert.equal(b.selected, false);
  });

  // ---------------------------------------------------------------- 智感握姿"默认关"迁移：只跑一次
  checked('Hand-awareness default-off migration runs exactly once', async () => {
    const migrationStore = (settings, prefs) => ({
      LogStore,
      async loadProfiles() { return []; },
      async loadGroups() { return []; },
      async loadSettings() { return settings; },
      async initStore() {},
      async getRunningProfileId() { return ''; },
      async readPrefString(key, def) { return key in prefs ? prefs[key] : (def === undefined ? '' : def); },
      async writePrefString(key, value) { prefs[key] = value; },
      async saveGroups() {},
      async saveProfiles() {},
      async mutateProfiles() {},
      async ensureGroupByName() { return ''; },
      async saveSettings(s) { this.saved = s; return s; }
    });
    const MIGRATION_KEY = 'migration_hand_awareness_default_off';

    // 第一次启动：老用户存的是"开"，且还没有迁移标记 ⇒ 强制关 + 写标记
    const prefs1 = {};
    const oldSettings = new models.AppSettings();
    oldSettings.handAwareness = true;
    const store1 = migrationStore(oldSettings, prefs1);
    const s1 = load('core/AppState.ets', appDeps(store1)).AppState.get();
    s1.attachContext(ctx);
    await s1.ensureInit();
    assert.equal(s1.settings.handAwareness, false, '旧存量必须被强制关一次');
    assert.equal(prefs1[MIGRATION_KEY], '1', '迁移标记要落盘');

    // 第二次启动：用户手动打开了开关，但标记已在 ⇒ 不许再被强制关
    const prefs2 = { [MIGRATION_KEY]: '1' };
    const userSettings = new models.AppSettings();
    userSettings.handAwareness = true;
    const store2b = migrationStore(userSettings, prefs2);
    const s2 = load('core/AppState.ets', appDeps(store2b)).AppState.get();
    s2.attachContext(ctx);
    await s2.ensureInit();
    assert.equal(s2.settings.handAwareness, true, '迁移只跑一次，之后尊重用户选择');
  });

  checked('PageHeader cancels stale hand-change animations (source-level guard)', () => {
    // 组件内部时序无法在 Node 里跑，这里只锁住"必须存在的守卫"，运行时仍需真机确认
    const header = source('ui/CommonUi.ets').slice(source('ui/CommonUi.ets').indexOf('export struct PageHeader'));
    assert.match(header, /private animGeneration: number = 0;/);
    assert.match(header, /const generation: number = \+\+this\.animGeneration;/);
    assert.match(header, /if \(generation !== this\.animGeneration\) \{/);
    assert.match(header, /const latest: boolean = this\.handRight\(\);/);
    assert.match(header, /aboutToDisappear\(\): void \{[\s\S]{0,160}this\.animGeneration\+\+;/);
  });

  // ---- 测速：并发请求必须如实回报（甲方 2026-11-15：TCPing 没跑完点 URL Test 直接提示已完成）----
  class StubLatencyOutcome {
    constructor() {
      this.ran = false; this.busy = false; this.urlMode = false; this.ok = 0; this.total = 0;
      this.degraded = false; this.degradeReason = ''; this.bindFallback = false; this.reason = '';
    }
  }
  class StubLatencyPassCount {
    constructor() { this.ok = 0; this.total = 0; }
  }
  let releaseUrlTest = () => {};
  let urlTestRuns = 0;
  const stubLatency = {
    LatencyTestOutcome: StubLatencyOutcome,
    LatencyPassCount: StubLatencyPassCount,
    async testProfiles(targets, onResult) {
      for (const target of targets) { onResult(target.id, 11); }
      const count = new StubLatencyPassCount();
      count.ok = targets.length; count.total = targets.length;
      return count;
    },
    async urlTestProfiles(targets, all, settings, context, onResult) {
      urlTestRuns++;
      await new Promise(resolve => { releaseUrlTest = resolve; });
      onResult(targets[0].id, 42);
      return { degraded: false, degradeReason: '', bindFallback: false, ok: 1, total: targets.length };
    }
  };
  let latencyProfiles = [a, b];
  const storeLatency = {
    LogStore,
    async loadProfiles() { return latencyProfiles; },
    async loadGroups() { return [g]; },
    async loadSettings() { return new models.AppSettings(); },
    async saveSettings() {},
    async initStore() {},
    async getRunningProfileId() { return ''; },
    async readPrefString(key, def) { return def === undefined ? '' : def; },
    async writePrefString() {},
    async saveGroups() {},
    async saveProfiles(list) { latencyProfiles = list; },
    async mutateProfiles(fn) { latencyProfiles = fn(latencyProfiles.slice()); return latencyProfiles; },
    async ensureGroupByName() { return g.id; }
  };
  const appModule4 = load('core/AppState.ets', {
    '@ohos.app.ability.common': {},
    '../model/Profile': models,
    '../model/Store': storeLatency,
    '../model/RouteRule': { async loadRouteRules() { return []; }, async loadRemoteRuleSets() { return []; } },
    './Subscriptions': { async listSubs() { return []; }, setAppContext() {} },
    './VpnService': serviceModule,
    './VpnRuntime': runtimeModule,
    '../utils/LinkParser': {},
    '../utils/Subscription': { subErrorText: e => `${e}` },
    '../utils/LatencyTester': stubLatency,
    '../utils/GeoAssets': { async downloadGeoAsset() { return ''; } },
    '../ui/Accent': accentModule,
    './Handedness': { Handedness: { get() { return { side: 'right', start() {}, setEnabled() {} }; } } }
  });
  const app4 = appModule4.AppState.get();
  app4.attachContext(ctx);
  const running = app4.testLatency([a, b], 'url');
  const rejected = await app4.testLatency([a, b], 'tcp');
  checked('A second latency run is refused with a reason instead of being reported as complete', () => {
    assert.equal(urlTestRuns, 1);
    assert.equal(rejected.ran, false);
    assert.equal(rejected.busy, true);
    assert.match(rejected.reason, /正在/);
    assert.equal(app4.testing, true);
    assert.equal(app4.testLabel, 'URL Test');
  });
  releaseUrlTest();
  const finished = await running;
  checked('The finished run reports how many nodes actually answered', () => {
    assert.equal(finished.ran, true);
    assert.equal(finished.ok, 1);
    assert.equal(finished.total, 2);
    assert.equal(app4.testing, false);
    assert.equal(app4.testDone, 0);
    assert.equal(app4.testLabel, '');
    assert.equal(a.latencyMs, 42);
  });
  const tcpOutcome = await app4.testLatency([a, b], 'tcp');
  checked('TCPing runs report their own pass count without touching the URL Test path', () => {
    assert.equal(tcpOutcome.ran, true);
    assert.equal(tcpOutcome.urlMode, false);
    assert.equal(tcpOutcome.ok, 2);
    assert.equal(urlTestRuns, 1);
  });

  // 双击同一个入口：第一轮在 await 落盘"测速方式"时，第二轮必须已经被挡住
  await app4.patchSettings(s => { s.latencyTestMode = 'url'; });
  const firstTap = app4.testLatency([a, b], 'tcp');
  const secondTap = await app4.testLatency([a], 'tcp');
  checked('Double-tapping a test entry cannot start two runs while the mode is being saved', () => {
    assert.equal(secondTap.ran, false);
    assert.equal(secondTap.busy, true);
    assert.equal(app4.testing, true);
  });
  const firstTapOutcome = await firstTap;
  checked('The first tap still completes and records the chosen mode', () => {
    assert.equal(firstTapOutcome.ran, true);
    assert.equal(firstTapOutcome.ok, 2);
    assert.equal(app4.settings.latencyTestMode, 'tcp');
  });

  // ---- 分组页签：真源在 AppState 且按 id 落盘（重进软件/组件重建都不该回到第 1 个）----
  const other = new models.ProfileGroup();
  other.id = 'group-B'; other.name = 'Manual';
  a.groupId = g.id; b.groupId = g.id;
  let tabPrefs = { selected_group_id: other.id, selected_profile_id: 'node-B' };
  const tabStore = {
    LogStore,
    async loadProfiles() { return [a, b]; },
    async loadGroups() { return [g, other]; },
    async loadSettings() { return new models.AppSettings(); },
    async saveSettings() {},
    async initStore() {},
    async getRunningProfileId() { return ''; },
    async readPrefString(key, def) {
      const saved = tabPrefs[key];
      return saved === undefined ? (def === undefined ? '' : def) : saved;
    },
    async writePrefString(key, value) { tabPrefs[key] = value; },
    async saveGroups() {},
    async saveProfiles() {},
    async mutateProfiles(fn) { return fn([a, b]); },
    async ensureGroupByName() { return g.id; }
  };
  const appModule5 = load('core/AppState.ets', {
    '@ohos.app.ability.common': {},
    '../model/Profile': models,
    '../model/Store': tabStore,
    '../model/RouteRule': { async loadRouteRules() { return []; }, async loadRemoteRuleSets() { return []; } },
    './Subscriptions': { async listSubs() { return []; }, setAppContext() {} },
    './VpnService': serviceModule,
    './VpnRuntime': runtimeModule,
    '../utils/LinkParser': {},
    '../utils/Subscription': { subErrorText: e => `${e}` },
    '../utils/LatencyTester': stubLatency,
    '../utils/GeoAssets': { async downloadGeoAsset() { return ''; } },
    '../ui/Accent': accentModule,
    './Handedness': { Handedness: { get() { return { side: 'right', start() {}, setEnabled() {} }; } } }
  });
  const app5 = appModule5.AppState.get();
  app5.attachContext(ctx);
  await app5.ensureInit();
  checked('Cold start restores the group tab the user was on, not the first group', () => {
    assert.equal(app5.selectedGroupId, other.id);
  });
  app5.selectGroupById(g.id);
  checked('Switching group tabs persists the group id for the next launch', () => {
    assert.equal(app5.selectedGroupId, g.id);
    assert.equal(tabPrefs['selected_group_id'], g.id);
  });
  app5.selectGroupById('group-deleted');
  checked('A tab pointing at a deleted group is ignored instead of blanking the list', () => {
    assert.equal(app5.selectedGroupId, g.id);
  });

  // ---- 数据保全：订阅更新/测速写盘不能把延迟与流量抹掉（甲方 2026-11-15）----
  checked('A subscription refresh carries latency and traffic onto the rebuilt nodes', () => {
    const text = source('core/Subscriptions.ets');
    assert.match(text, /function carryRuntimeData\(target: Profile, previous: Profile\): void \{/);
    assert.match(text, /target\.latencyMs = previous\.latencyMs;/);
    assert.match(text, /target\.rx = previous\.rx;/);
    assert.match(text, /carryRuntimeData\(p, fuzzy\);/);
    // 落库前用磁盘上最新一份再刷一遍：fetch 期间的测速结果不能被 fetch 开始时的快照覆盖
    assert.match(text, /const latest: Array<Profile> = await loadProfiles\(\);/);
  });
  checked('Latency tests persist field-by-field instead of replacing the whole profile table', () => {
    // 注释里会提到旧写法，检查前先剥掉注释
    const text = source('core/AppState.ets').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\r\n]*/g, '');
    assert.match(text, /private async applyLatencyBatch\(batch: Map<string, number>\)/);
    assert.match(text, /private async flushLatency\(\): Promise<void> \{/);
    assert.doesNotMatch(text, /saveProfiles\(this\.profiles\)/);
  });
  checked('Editing a node keeps the runtime columns already on disk', () => {
    const text = source('core/AppState.ets');
    assert.match(text, /p\.latencyMs = item\.latencyMs;/);
    assert.match(text, /p\.rx = item\.rx;/);
  });

  // ---- 检查更新：版本比较与 release 挑选（纯函数，真在 GitHub 上的行为另说）----
  const updateModule = load('utils/UpdateCheck.ets', {
    '@ohos.net.http': { createHttp() { throw new Error('network not available in host checks'); } }
  });
  checked('Version comparison treats dotted numbers numerically and pads missing parts', () => {
    assert.ok(updateModule.compareVersions('0.5.60', '0.5.59') > 0);
    assert.ok(updateModule.compareVersions('v0.10.0', '0.9.9') > 0);
    assert.equal(updateModule.compareVersions('0.5.59', 'v0.5.59'), 0);
    assert.equal(updateModule.compareVersions('0.5', '0.5.0'), 0);
    assert.ok(updateModule.compareVersions('0.5.58', '0.5.59') < 0);
    // vm 里造出来的数组原型和宿主机不同，用 JSON 比内容而不是 deepStrictEqual
    assert.equal(JSON.stringify(updateModule.parseVersionName('v0.5.60')), '[0,5,60]');
  });
  const releaseJson = JSON.stringify([
    { tag_name: 'v0.6.0-beta1', name: 'beta', body: 'pre', prerelease: true, draft: false, html_url: 'https://x/pre',
      assets: [{ name: 'ReedBox-unsigned.hap', browser_download_url: 'https://x/pre.hap' }] },
    { tag_name: 'v0.5.60', name: 'stable', body: 'notes', prerelease: false, draft: false, html_url: 'https://x/rel',
      assets: [{ name: 'checksums.txt', browser_download_url: 'https://x/sums.txt' },
               { name: 'ReedBox-unsigned.hap', browser_download_url: 'https://x/rel.hap' }] },
    { tag_name: 'v0.5.50', name: 'old', prerelease: false, draft: false,
      assets: [] }
  ]);
  checked('Releases parse into version, notes and the .hap download link', () => {
    const releases = updateModule.parseReleases(releaseJson);
    assert.equal(releases.length, 3);
    assert.equal(releases[0].versionName, '0.6.0-beta1');
    assert.equal(releases[0].prerelease, true);
    assert.equal(releases[1].versionName, '0.5.60');
    assert.equal(releases[1].assetUrl, 'https://x/rel.hap');
    assert.equal(releases[1].notes, 'notes');
  });
  checked('Stable checks ignore prereleases, preview checks see them', () => {
    const releases = updateModule.parseReleases(releaseJson);
    assert.equal(updateModule.pickRelease(releases, 'stable').versionName, '0.5.60');
    assert.equal(updateModule.pickRelease(releases, 'preview').versionName, '0.6.0-beta1');
  });
  checked('Only a strictly newer release counts as an update', () => {
    const releases = updateModule.parseReleases(releaseJson);
    const newer = updateModule.resolveCheckResult(releases, 'stable', '0.5.59');
    assert.equal(newer.ok, true);
    assert.equal(newer.hasUpdate, true);
    const same = updateModule.resolveCheckResult(releases, 'stable', '0.5.60');
    assert.equal(same.hasUpdate, false);
    const ahead = updateModule.resolveCheckResult(releases, 'stable', '0.5.61');
    assert.equal(ahead.hasUpdate, false);
  });
  checked('A rate-limit or error payload is not mistaken for a release list', () => {
    const releases = updateModule.parseReleases('{"message":"API rate limit exceeded"}');
    assert.equal(releases.length, 0);
    const broken = updateModule.parseReleases('<html>502</html>');
    assert.equal(broken.length, 0);
    const empty = updateModule.resolveCheckResult([], 'stable', '0.5.59');
    assert.equal(empty.ok, true);
    assert.equal(empty.hasUpdate, false);
    assert.equal(empty.latest, null);
  });
  checked('The about page actually calls the checker for both channels', () => {
    const about = source('ui/neko/AboutPage.ets');
    assert.match(about, /this\.runUpdateCheck\('stable'\)/);
    assert.match(about, /this\.runUpdateCheck\('preview'\)/);
    assert.match(about, /checkForUpdate\(channel, this\.versionName\)/);
    assert.doesNotMatch(about, /暂未接入更新检查/);
  });

  // A filename match is not evidence of success: inspect every ETS file recursively.
  function files(dir) { return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory() ? files(path.join(dir, e.name)) : [path.join(dir, e.name)]); }
  checked('All ETS sources meet the V2 and Navigation constraints', () => {
    for (const file of files(ets).filter(f => f.endsWith('.ets'))) {
      const text = fs.readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\r\n]*/g, '');
      assert.doesNotMatch(text, /@(State|Prop|Link|ObjectLink|StorageLink|StorageProp|Watch|Observed|Component)\b|@ohos\.router|\$\$this\./, file);
    }
  });
  const report = ['# State-chain regression checks', '', 'Validation: source/host logic only. ArkUI decorators are stripped for the mock harness; device IPC and rendering remain unverified.', '', ...checks.map(n => `- PASS: ${n}`), ''].join('\n');
  fs.writeFileSync(path.join(root, 'docs', 'state-chain-checks.md'), report);
  for (const name of checks) console.log(`PASS ${name}`);
  console.log(`CHECKS=${checks.length}`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
