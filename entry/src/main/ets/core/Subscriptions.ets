import common from '@ohos.app.ability.common';
import connection from '@ohos.net.connection';
import { VpnRuntime } from './VpnRuntime';
import { Profile } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, mutateProfiles, loadSettings, readPrefString, writePrefString, ensureGroupByName, loadGroups, saveGroups, LogStore } from '../model/Store';
import { fetchSubscriptionConditional, fetchTextUrl, parseSubUserInfo, looksLikeClashYaml, looksLikeSingBoxJson, parseSingBoxConfig, ClashParseResult, subFailureText, subFailureBaseText, SUB_UA, SUB_UA_FALLBACKS } from '../utils/Subscription';
import { parseClashProxiesWithProviders, parseClashGroups, ClashGroupDef } from '../utils/ClashProviders';
import { parseShareText, ShareSkipReport } from '../utils/LinkParser';

// 解析失败文案定义在 utils/Subscription.ets(与 note 常量同处,供手动导入路径复用);
// 从这里再导出一次,保持既有 import 点不变。
export { subFailureText, subFailureBaseText };

/** 订阅管理:记录订阅来源、更新节点(按 subUrl 原子替换)。 */

const KEY_SUBS = 'subscriptions';
const AUTO_UPDATE_INTERVAL = 12 * 3600 * 1000; // 12h

export class SubInfo {
  url: string = '';
  name: string = '';
  group: string = '';
  lastUpdate: number = 0;
  upload: number = 0;
  download: number = 0;
  total: number = 0;
  expire: number = 0;
  updateIntervalHours: number = 12;
  nextUpdateAt: number = 0;
  lastAttemptAt: number = 0;
  lastError: string = '';
  // 连续更新失败次数(成功一次即清零);≥3 次跳过自动更新,由手动更新复位
  failCount: number = 0;
  // 订阅级设置(对齐安卓 group_preferences.xml)
  userAgent: string = '';                    // 自定义 User-Agent,空 = 默认
  autoUpdate: boolean = true;                // 本订阅是否参与自动更新
  updateWhenConnectedOnly: boolean = false;  // 仅 VPN 已连接时自动更新
  deduplication: boolean = false;            // 更新时按 类型+服务器+端口+UUID 去重(对齐安卓,默认关闭)
  forceResolve: boolean = false;             // 更新时把节点服务器域名解析为 IP(对齐安卓 subscriptionForceResolve)
  // HTTP 条件请求校验器:下次更新带上,服务端回 304 即跳过正文下载
  etag: string = '';
  lastModified: string = '';
}

export interface SubUpdateResult {
  added: number;
  removed: number;
  total: number;
  // 服务端回 304:节点未变,只推进了更新时刻
  notModified: boolean;
  // 解析成功但被跳过的节点数(内核不支持的类型等)与其中前若干个名称
  skipped: number;
  skippedNames: Array<string>;
  // 整体性说明键(非空表示订阅不可用或需提示),见 Subscription.ets 的 note 取值
  note: string;
}

export async function listSubs(): Promise<Array<SubInfo>> {
  try {
    const raw = await readPrefString(KEY_SUBS, '[]');
    const parsed = JSON.parse(raw) as Array<SubInfo>;
    const result: Array<SubInfo> = [];
    for (const source of parsed) {
      const item = new SubInfo();
      item.url = source.url ?? '';
      item.name = source.name ?? subNameOf(item.url);
      item.group = source.group ?? '';
      item.lastUpdate = Number(source.lastUpdate) || 0;
      item.upload = Number(source.upload) || 0;
      item.download = Number(source.download) || 0;
      item.total = Number(source.total) || 0;
      item.expire = Number(source.expire) || 0;
      const rawHours = Number(source.updateIntervalHours);
      item.updateIntervalHours = !(rawHours > 0) ? 12 : Math.max(1, Math.min(720, Math.floor(rawHours)));
      item.nextUpdateAt = Number(source.nextUpdateAt)
        || item.lastUpdate + item.updateIntervalHours * 3600 * 1000;
      item.lastAttemptAt = Number(source.lastAttemptAt) || 0;
      item.lastError = source.lastError ?? '';
      item.failCount = Number(source.failCount) || 0;
      item.userAgent = source.userAgent ?? '';
      item.autoUpdate = source.autoUpdate !== false;
      item.updateWhenConnectedOnly = source.updateWhenConnectedOnly === true;
      item.deduplication = source.deduplication === true;
      item.forceResolve = source.forceResolve === true;
      item.etag = source.etag ?? '';
      item.lastModified = source.lastModified ?? '';
      result.push(item);
    }
    return result;
  } catch (e) {
    return [];
  }
}

export async function saveSubs(list: Array<SubInfo>): Promise<void> {
  await writePrefString(KEY_SUBS, JSON.stringify(list));
}

export function subNameOf(url: string): string {
  let s = url;
  const scheme = s.indexOf('://');
  if (scheme >= 0) {
    s = s.substring(scheme + 3);
  }
  const path = s.indexOf('/');
  if (path >= 0) {
    s = s.substring(0, path);
  }
  return s;
}

export async function upsertSub(url: string, userinfo: string = '', requestedName: string = ''): Promise<void> {
  const list = await listSubs();
  const target = list.find(x => x.url === url);
  const normalizedName = requestedName.trim();
  if (target === undefined) {
    const info = new SubInfo();
    info.url = url;
    info.name = normalizedName.length > 0 ? normalizedName : subNameOf(url);
    info.group = normalizedName;
    info.lastUpdate = Date.now();
    if (userinfo.length > 0) {
      const parsed = parseSubUserInfo(userinfo);
      if (parsed !== null) {
        info.upload = parsed.upload;
        info.download = parsed.download;
        info.total = parsed.total;
        info.expire = parsed.expire;
      }
    }
    list.push(info);
  } else {
    if (normalizedName.length > 0) {
      target.name = normalizedName;
      target.group = normalizedName;
    }
    // 手动(重新)导入一律清掉校验器。带 ETag/Last-Modified 去请求,若机场侧
    // 对该 URL 回 304,就会走"内容未变更"分支拿到空正文 → 导入 0 个节点。
    // 用户主动点导入的语义是"我要全量重新拉一次"。
    target.etag = '';
    target.lastModified = '';
    if (userinfo.length > 0) {
      const parsed = parseSubUserInfo(userinfo);
      if (parsed !== null) {
        target.upload = parsed.upload;
        target.download = parsed.download;
        target.total = parsed.total;
        target.expire = parsed.expire;
      }
    }
  }
  await saveSubs(list);
}

export async function removeSub(url: string): Promise<void> {
  const list = await listSubs();
  await saveSubs(list.filter(x => x.url !== url));
}

async function touchSub(url: string): Promise<void> {
  const list = await listSubs();
  for (const s of list) {
    if (s.url === url) {
      s.lastUpdate = Date.now();
      s.nextUpdateAt = s.lastUpdate + Math.max(1, s.updateIntervalHours) * 3600 * 1000;
    }
  }
  await saveSubs(list);
}

export async function needAutoUpdate(): Promise<Array<SubInfo>> {
  const subs = await listSubs();
  if (subs.length === 0) {
    return [];
  }
  const now = Date.now();
  // 仅连接时更新:VPN 未运行时跳过(对齐安卓 subscriptionUpdateWhenConnectedOnly)
  const connected: boolean = VpnRuntime.get().vpnRunning;
  // 连续失败 ≥3 次的订阅跳过自动更新(手动更新成功后由 markSubSuccess 清零恢复)
  return subs.filter(s => s.autoUpdate
    && !(s.updateWhenConnectedOnly && !connected)
    && now >= (s.nextUpdateAt || s.lastUpdate + Math.max(1, s.updateIntervalHours) * 3600 * 1000)
    && !(Number(s.failCount) >= 3));
}

/** 保存订阅级设置(对齐安卓 GroupSettingsActivity 的订阅分类) */
export async function saveSubSettings(url: string, changes: Record<string, Object>): Promise<SubInfo | null> {
  const list = await listSubs();
  let target: SubInfo | null = null;
  for (const s of list) {
    if (s.url !== url) {
      continue;
    }
    target = s;
    if (changes['name'] !== undefined) {
      s.name = `${changes['name']}`;
    }
    if (changes['group'] !== undefined) {
      s.group = `${changes['group']}`;
    }
    if (changes['userAgent'] !== undefined) {
      s.userAgent = `${changes['userAgent']}`;
    }
    if (changes['autoUpdate'] !== undefined) {
      s.autoUpdate = changes['autoUpdate'] === true;
    }
    if (changes['updateWhenConnectedOnly'] !== undefined) {
      s.updateWhenConnectedOnly = changes['updateWhenConnectedOnly'] === true;
    }
    if (changes['deduplication'] !== undefined) {
      s.deduplication = changes['deduplication'] === true;
    }
    if (changes['forceResolve'] !== undefined) {
      s.forceResolve = changes['forceResolve'] === true;
    }
    if (changes['updateIntervalHours'] !== undefined) {
      // 非正数/非数字一律视为非法,回落默认 12(与 listSubs 同一规则)
      const raw = Number(changes['updateIntervalHours']);
      const hours = !(raw > 0) ? 12 : Math.min(720, Math.floor(raw));
      s.updateIntervalHours = Math.max(1, hours);
    }
  }
  if (target !== null) {
    await saveSubs(list);
  }
  return target;
}

/** 记录订阅更新成功:失败计数清零,恢复自动更新资格 */
export async function markSubSuccess(url: string): Promise<void> {
  const list = await listSubs();
  let changed = false;
  for (const s of list) {
    if (s.url === url && Number(s.failCount) !== 0) {
      s.failCount = 0;
      changed = true;
    }
  }
  if (changed) {
    await saveSubs(list);
  }
}

/** 记录订阅更新失败:失败计数 +1(由调用方在 catch 中调用) */
export async function markSubFailure(url: string): Promise<void> {
  const list = await listSubs();
  for (const s of list) {
    if (s.url === url) {
      const cur = Number(s.failCount);
      s.failCount = (isNaN(cur) ? 0 : cur) + 1;
    }
  }
  await saveSubs(list);
}

function profileIdentity(p: Profile, url: string): string {
  return [url, p.type, p.server, `${p.serverPort}`, p.uuid, p.name, p.transport,
    p.path, p.host, p.serviceName, p.sni].join('\u001f');
}

/**
 * "同一条线路"的粗判据（比 profileIdentity 宽松）：不含节点名，也不含传输层细节。
 * 用途只有一个 —— 订阅更新时**把上一轮的运行期数据带到新节点上**：
 * 机场经常改名（"香港01"→"HK-01"），改名就会换 id；只按 identity 匹配的话，
 * 一次改名就让测速结果和历史流量全清零。
 */
function runtimeCarryKey(p: Profile): string {
  const auth: string = p.uuid.length > 0 ? p.uuid : `${p.password}\u001f${p.method}`;
  return [p.type, p.server, `${p.serverPort}`, auth].join('\u001f');
}

/** 把旧节点的运行期数据（延迟/流量/置顶/组内顺序）搬到新节点上 */
function carryRuntimeData(target: Profile, previous: Profile): void {
  target.latencyMs = previous.latencyMs;
  target.latencyTestedAt = previous.latencyTestedAt;
  target.rx = previous.rx;
  target.tx = previous.tx;
  target.pinned = previous.pinned;
  target.sortOrder = previous.sortOrder;
}

function stableProfileId(p: Profile, url: string): string {
  const value = profileIdentity(p, url);
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `sub_${(hash >>> 0).toString(16)}`;
}

function isIpAddress(host: string): boolean {
  if (host.length === 0) {
    return true;
  }
  if (host.indexOf(':') >= 0) {
    return true; // IPv6 字面量
  }
  const parts = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) {
      return false;
    }
    const n = parseInt(part, 10);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

/** 解析单个节点服务器域名并改写为 IP(对齐安卓 rewriteAddress);失败保留原域名 */
async function resolveOneProfile(p: Profile): Promise<void> {
  const host = p.server.trim();
  if (isIpAddress(host)) {
    return;
  }
  try {
    const addrs = await connection.getAddressesByName(host);
    let v4 = '';
    let v6 = '';
    for (const a of addrs) {
      const addr = a.address;
      if (addr.indexOf(':') < 0) {
        if (v4.length === 0) {
          v4 = addr;
        }
      } else if (v6.length === 0) {
        v6 = addr;
      }
    }
    const chosen = v4.length > 0 ? v4 : v6;
    if (chosen.length === 0) {
      return;
    }
    if (p.tls && p.sni.trim().length === 0) {
      p.sni = host; // 保留原域名作 TLS SNI
    }
    p.server = chosen;
  } catch (e) {
    LogStore.addLog(`[sub] 强制解析 ${host} 失败,保留域名: ${e}`);
  }
}

/** 批量强制解析(对齐安卓 forceResolve 的 5 并发查询池) */
async function applyForceResolve(list: Array<Profile>): Promise<void> {
  const BATCH = 5;
  for (let i = 0; i < list.length; i += BATCH) {
    const batch = list.slice(i, i + BATCH);
    await Promise.all(batch.map((p: Profile): Promise<void> => resolveOneProfile(p)));
  }
}

/** 更新单个订阅:条件下载 → 解析 → 原子替换该订阅的节点(保留运行中节点);同时记录流量/到期 */
export async function updateSubscription(url: string): Promise<SubUpdateResult> {
  // 必须最先 initStore:listSubs/saveSubs 依赖 preferences,未初始化时
  // listSubs 会吞掉异常并返回空数组,导致 ETag 校验器永远存不下去。
  await initStore(globalContext());
  const settings = await loadSettings();
  const subsForGroup = await listSubs();
  const subForGroup = subsForGroup.find((item: SubInfo) => item.url === url);
  const customUA = subForGroup !== undefined ? subForGroup.userAgent : '';
  // 去重开关(对齐安卓 subscriptionDeduplication,默认关闭:保留订阅返回的全部节点)
  const dedupEnabled = subForGroup !== undefined && subForGroup.deduplication;
  const knownEtag = subForGroup !== undefined ? subForGroup.etag : '';
  const knownLastMod = subForGroup !== undefined ? subForGroup.lastModified : '';
  const existing = await loadProfiles();
  // 本订阅当前已入库的节点数:304 分支的兜底判据。
  const ownedBefore = existing.filter(p => p.subUrl === url).length;
  let fetched = await fetchSubscriptionConditional(url, settings.subAllowInsecure,
    customUA, knownEtag, knownLastMod);
  // 304 兜底:一个节点都没有却收到 304,说明上次落库的校验器对应的是一份
  // 「解析失败但已记下 ETag」的响应(机场错误页/限流/劫持)。此时复用 304 会让
  // 本订阅永远停在 0 节点、且 UI 一直显示「更新成功」。强制脱掉校验器重下一次。
  if (fetched.notModified && ownedBefore === 0 && (knownEtag.length > 0 || knownLastMod.length > 0)) {
    fetched = await fetchSubscriptionConditional(url, settings.subAllowInsecure,
      customUA, '', '');
  }
  // 304:内容未变,保留全部节点,只推进更新时刻
  if (fetched.notModified) {
    await touchSub(url);
    if (fetched.userinfo.length > 0) {
      await applySubUserInfo(url, fetched.userinfo);
    }
    const res304: SubUpdateResult = {
      added: 0, removed: 0, total: existing.length,
      notModified: true, skipped: 0, skippedNames: [], note: ''
    };
    return res304;
  }
  let content = fetched.content;
  // HTML 前置闸:机场/中间层返回错误页时,正文里可能恰好含 "proxies:" 一行,
  // 会被 hasTopLevelKey 误判成 Clash YAML,最后报「没有 proxies 节点列表」——
  // 与真实原因(返回了网页)完全不符。先把这种情况挑明。
  if (/^\s*(<!DOCTYPE\s+html|<html[\s>])/i.test(content)) {
    throw new Error('订阅服务器返回了 HTML 页面而不是节点列表,请检查订阅地址是否正确、或该地址是否需要鉴权');
  }
  let r = await parseSubscriptionBody(content, settings.subAllowInsecure, customUA);
  let parsed = r.profiles;
  let skipped = r.skipped;
  let skippedNames = r.skippedNames;
  let note = r.note;
  let usedUa = customUA.trim().length > 0 ? customUA.trim() : SUB_UA;

  // UA 回退:不少机场按 User-Agent 分流不同格式(只认 clash.meta 的返回 YAML、
  // 只认 v2rayN/sing-box 的返回 base64 或 JSON)。单个 UA 解析不出节点时换几个
  // 常见 UA 再试一轮,避免用户只能去订阅设置里手工试错。
  // 仅在正文「看起来确实是订阅但没解析出节点」时触发(纯文本提示/HTML 已在上游挡掉),
  // 且每轮最多 2 次额外请求,避免把失败路径变成压测。
  if (parsed.length === 0 && note !== 'clash_provider_only') {
    for (const ua of SUB_UA_FALLBACKS) {
      if (ua === usedUa) {
        continue;
      }
      let altContent = '';
      try {
        altContent = await fetchTextUrl(url, settings.subAllowInsecure, ua);
      } catch (e) {
        continue;
      }
      if (altContent.trim().length === 0 || altContent === content) {
        continue;
      }
      const alt = await parseSubscriptionBody(altContent, settings.subAllowInsecure, ua);
      if (alt.profiles.length > 0) {
        LogStore.addLog(`[sub] ${url} 用默认 User-Agent 解析不到节点,改用 ${ua} 后成功`);
        content = altContent;
        fetched.content = altContent;
        r = alt;
        parsed = alt.profiles;
        skipped = alt.skipped;
        skippedNames = alt.skippedNames;
        note = alt.note;
        usedUa = ua;
        break;
      }
    }
  }
  if (parsed.length === 0) {
    // note 优先:只有 proxy-providers / YAML 解析失败这类"格式没认出来"的情况
    // 才给出可操作提示,否则维持通用文案。
    // 关键:此处**不**落盘 ETag/Last-Modified。若在解析前就记下校验器,一次
    // 「正文是错误页」的响应就会把校验器钉死;下次请求带 If-None-Match 拿到 304,
    // 于是永远走「内容未变」分支、永远 0 节点、永远显示更新成功(见上方 304 兜底)。
    const detail = note.length > 0 ? '' : `(已尝试的 User-Agent:${usedUa})`;
    throw new Error(subFailureText(note, content, skipped, skippedNames) + detail);
  }
  // 只在正文确实解析出节点后才记校验器:此时 ETag 对应的是一份可用的订阅内容,
  // 后续 304 复用才是正确的「无变化」语义。服务端不给校验器(空串)时清掉,
  // 下次退化为全量请求。
  await saveSubValidators(url, fetched.etag, fetched.lastModified);
  // Clash 订阅自带的 proxy-groups(仅 Clash YAML 有;分享链接/JSON 无分组概念)
  const clashGroups: Array<ClashGroupDef> = looksLikeClashYaml(content)
    ? parseClashGroups(content) : [];
  // 强制解析(对齐安卓 subscriptionForceResolve):把节点服务器域名解析为 IP,
  // 原域名保留到 sni,避免服务器换 IP 后 TLS/SNI 断裂
  if (subForGroup !== undefined && subForGroup.forceResolve) {
    await applyForceResolve(parsed);
  }
  const profiles = existing;
  /**
   * 节点该落进哪个分组。**绝不能用订阅域名当组名**（甲方 2026-11-01：点更新会凭空多出一个
   * 以域名命名的新分组）。优先级：
   *   ① 订阅分组本身（`ProfileGroup.url === url && type==='subscription'`）——最可靠的真实归属；
   *   ② 该订阅现有节点所在的分组（取第一个有归属的）——历史数据没有 SubInfo.group 时靠这条兜住；
   *   ③ `SubInfo.group`，其次 `SubInfo.name`；
   *   ④ 都没有 ⇒ 「未命名」（导入必须落到某个分组，但不拿域名造组）。
   */
  const groupsNow = await loadGroups();
  let groupName = '';
  for (const g of groupsNow) {
    if (g.type === 'subscription' && g.url === url) {
      groupName = g.name.trim();
      break;
    }
  }
  if (groupName.length === 0) {
    for (const p of profiles) {
      if (p.subUrl !== url || p.groupId.length === 0) {
        continue;
      }
      for (const g of groupsNow) {
        if (g.id === p.groupId) {
          groupName = g.name.trim();
          break;
        }
      }
      if (groupName.length > 0) {
        break;
      }
    }
  }
  if (groupName.length === 0 && subForGroup !== undefined) {
    // ③ 只在"分组确实存在"时复用 SubInfo 里的名字：绝不凭名字新建分组
    //    （历史 SubInfo.group 为空、name=域名 ⇒ 曾经每点一次更新就凭空多一个域名分组）
    const candidates: Array<string> = [subForGroup.group.trim(), subForGroup.name.trim()];
    for (const candidate of candidates) {
      if (candidate.length === 0) {
        continue;
      }
      for (const g of groupsNow) {
        if (g.name.trim() === candidate) {
          groupName = candidate;
          break;
        }
      }
      if (groupName.length > 0) {
        break;
      }
    }
  }
  if (groupName.length === 0) {
    groupName = '未命名';
  }
  const subGroupId = await ensureGroupByName(groupName);
  // 把解析出来的归属回写 SubInfo.group，下次更新就不用再猜（也修掉历史 SubInfo.group 为空的数据）
  if (subForGroup !== undefined && subForGroup.group.trim() !== groupName) {
    const fixGroup: Record<string, Object> = { 'group': groupName };
    await saveSubSettings(url, fixGroup);
  }
  const runningId = VpnRuntime.get().runningProfileId;
  const selectedId = await readPrefString('selected_profile_id', '');
  const selectedProfile = profiles.find((item: Profile) => item.id === selectedId);
  const selectedIdentity = selectedProfile !== undefined && selectedProfile.subUrl === url
    ? profileIdentity(selectedProfile, url) : '';
  let migratedSelectedId = '';

  /**
   * ★ 运行期数据的接力表（甲方 2026-11-15："有时候进入软件时延迟和速度数据会丢失"）。
   * 订阅更新是"删掉本订阅全部节点 → 按最新内容重新落"，新节点是全新的 Profile 对象，
   * `latencyMs / latencyTestedAt / rx / tx / pinned / sortOrder` 全归零 ——
   * 而启动时只要有订阅到期就会自动更新一次，于是"一进软件，昨天测好的延迟和流量就没了"。
   * 这里按 identity（精确）与 runtimeCarryKey（改名也能认）两级把旧值搬过来。
   */
  const carryByIdentity: Record<string, Profile> = {};
  const carryByRuntime: Record<string, Profile> = {};
  for (const p of existing) {
    if (p.subUrl !== url) {
      continue;
    }
    carryByIdentity[profileIdentity(p, url)] = p;
    const key: string = runtimeCarryKey(p);
    if (carryByRuntime[key] === undefined) {
      carryByRuntime[key] = p;
    }
  }
  const kept: Array<Profile> = [];
  let removed = 0;
  let runningIdentity = '';
  for (const p of profiles) {
    if (p.subUrl === url && p.id !== runningId) {
      removed++;
      continue;
    }
    if (p.subUrl === url && p.id === runningId) {
      // 正在连接的节点会保留，下面落新节点时要按身份跳过它，否则每次更新都会多一条重复节点
      runningIdentity = profileIdentity(p, url);
    }
    // 升级迁移:该订阅遗留的未分组节点归入订阅分组(用户手动分过组的不动)
    if (p.subUrl === url && p.groupId.length === 0) {
      p.groupId = subGroupId;
    }
    kept.push(p);
  }
  let added = 0;
  for (const p of parsed) {
    if (runningIdentity.length > 0 && profileIdentity(p, url) === runningIdentity) {
      continue;
    }
    // 开启去重时:类型+服务器+端口+UUID 相同视为重复,跳过(对齐安卓)
    if (dedupEnabled) {
      const dup = kept.find(x => x.type === p.type && x.server === p.server
        && x.serverPort === p.serverPort && x.uuid === p.uuid);
      if (dup !== undefined) {
        continue;
      }
    }
    p.subUrl = url;
    p.groupId = subGroupId;
    p.id = stableProfileId(p, url);
    if (kept.some((item: Profile) => item.id === p.id)) {
      p.id = `${p.id}_${added}`;
    }
    const exact: Profile | undefined = carryByIdentity[profileIdentity(p, url)];
    const fuzzy: Profile | undefined = exact !== undefined
      ? exact : carryByRuntime[runtimeCarryKey(p)];
    if (fuzzy !== undefined) {
      carryRuntimeData(p, fuzzy);
    }
    p.updatedAt = Date.now();
    kept.push(p);
    if (selectedIdentity.length > 0 && profileIdentity(p, url) === selectedIdentity) {
      migratedSelectedId = p.id;
    }
    added++;
  }
  resolveDialerProxies(parsed, kept);
  /**
   * 落库前再用**磁盘上最新的一份**刷新运行期数据：
   * 一次订阅更新要下载 + 解析，可能耗时几秒，期间测速结果/会话流量统计刚写进库，
   * 拿 fetch 开始时的快照整表写回去就会把它们抹掉（"测完延迟一更新订阅就没了"）。
   */
  try {
    const latest: Array<Profile> = await loadProfiles();
    const freshByIdentity: Record<string, Profile> = {};
    const freshByRuntime: Record<string, Profile> = {};
    for (const item of latest) {
      if (item.subUrl !== url) {
        continue;
      }
      freshByIdentity[profileIdentity(item, url)] = item;
      const key: string = runtimeCarryKey(item);
      if (freshByRuntime[key] === undefined) {
        freshByRuntime[key] = item;
      }
    }
    for (const item of kept) {
      if (item.subUrl !== url) {
        continue;
      }
      const fresh: Profile | undefined = freshByIdentity[profileIdentity(item, url)]
        ?? freshByRuntime[runtimeCarryKey(item)];
      if (fresh !== undefined) {
        carryRuntimeData(item, fresh);
      }
    }
  } catch (e) {
    LogStore.addLog(`[sub] 刷新运行期数据失败(按已有结果落库): ${e}`);
  }
  await saveProfiles(kept);
  /**
   * ★★★ 订阅里的 Clash `proxy-groups` **一律不导入**（甲方 2026-11-01 明确：不要 Clash 那套分组，
   *   导入后冒出"节点选择 / 自动选择 / 漏网之鱼"这类组）。
   *   本工程的语义：订阅只贡献 **proxies**（节点），分组只有两种来源 ——
   *   ① 用户自己建的组；② 这个订阅对应的那个组（`SubInfo.group`）。
   *   路由也完全由「路由」页决定，不用 Clash 的 `rules`。
   *   解析仍然保留，只用来记一条可读的 warning（排查订阅内容时有用）。
   */
  if (clashGroups.length > 0) {
    LogStore.addLog(`[sub] 忽略订阅里的 ${clashGroups.length} 个 proxy-groups（本应用不消费 Clash 分组/规则）`);
  }
  if (migratedSelectedId.length > 0 && migratedSelectedId !== selectedId) {
    await writePrefString('selected_profile_id', migratedSelectedId);
  } else if (selectedProfile !== undefined && selectedProfile.subUrl === url
    && !kept.some((item: Profile) => item.id === selectedId)) {
    const replacement = kept.find((item: Profile) => item.subUrl === url);
    await writePrefString('selected_profile_id', replacement === undefined ? '' : replacement.id);
  }
  await touchSub(url);
  // 记录订阅流量/到期信息(响应头 subscription-userinfo)
  if (fetched.userinfo.length > 0) {
    await applySubUserInfo(url, fetched.userinfo);
  }
  /**
   * ★ 计数必须是**真实差异**，不能用"删了多少/加了多少"：这套更新是"先删旧节点再落新节点"，
   *   原始计数在每次更新时都相等（甲方 2026-11-01："创建分组、更新分组都是提示新增 xx，移除 xx，数值一样"）。
   *   `total` 也必须是**本订阅的节点数**（原来是 `kept.length`，把别的分组的节点也算进去了）。
   */
  const beforeKeys: Record<string, boolean> = {};
  for (const p of profiles) {
    if (p.subUrl === url) {
      beforeKeys[profileIdentity(p, url)] = true;
    }
  }
  const afterKeys: Record<string, boolean> = {};
  let subTotal = 0;
  for (const p of kept) {
    if (p.subUrl === url) {
      afterKeys[profileIdentity(p, url)] = true;
      subTotal++;
    }
  }
  let addedReal = 0;
  let removedReal = 0;
  for (const key of Object.keys(afterKeys)) {
    if (beforeKeys[key] !== true) {
      addedReal++;
    }
  }
  for (const key of Object.keys(beforeKeys)) {
    if (afterKeys[key] !== true) {
      removedReal++;
    }
  }
  const result: SubUpdateResult = {
    added: addedReal, removed: removedReal, total: subTotal,
    notModified: false, skipped: skipped, skippedNames: skippedNames, note: note
  };
  return result;
}

/**
 * 把 Clash proxy-groups 落成 ProfileGroup,并把成员节点迁入对应分组。
 *
 * 语义映射(对齐 model/ProfileGroup 的既有字段):
 *   Clash select / selector -> isSelector = true(用户手动选)
 *   Clash url-test          -> autoSelect   = true(内核按 testUrl 自动选)
 *
 * 保守策略:只处理「本订阅节点 + 至少一个成员能按名字匹配上」的组。
 * 成员名匹配不到节点的组(引用了别的订阅或 provider 内部名)直接跳过,
 * 宁可少建组,也不要造出空组或把节点错误地搬走。
 */
async function applyClashGroups(groups: Array<ClashGroupDef>, allProfiles: Array<Profile>): Promise<void> {
  for (const def of groups) {
    const memberNames = def.members;
    // 成员名 -> 本订阅节点 id(只认本次导入范围内的节点)
    const memberIds: Array<string> = [];
    for (const mn of memberNames) {
      const hit = allProfiles.find(p => p.name === mn);
      if (hit !== undefined) {
        memberIds.push(hit.id);
      }
    }
    if (memberIds.length === 0) {
      continue;
    }
    const groupId = await ensureGroupByName(def.name);
    if (groupId.length === 0) {
      continue;
    }
    // 组类型落到 ProfileGroup 的两个互斥开关上
    const isUrlTest = def.type === 'url-test' || def.type === 'urltest';
    const groups1 = await loadGroups();
    const target = groups1.find(g => g.id === groupId);
    if (target === undefined) {
      continue;
    }
    if (target.isSelector !== !isUrlTest || target.autoSelect !== isUrlTest) {
      target.isSelector = !isUrlTest;
      target.autoSelect = isUrlTest;
      target.updatedAt = Date.now();
      await saveGroups(groups1);
    }
    // 成员节点归入该组(节点只属于一个分组,故为迁移而非复制)
    let changed = false;
    for (const p of allProfiles) {
      if (memberIds.indexOf(p.id) >= 0 && p.groupId !== groupId) {
        p.groupId = groupId;
        changed = true;
      }
    }
    if (changed) {
      await saveProfiles(allProfiles);
    }
  }
}

/**
 * 按内容形态分派解析:Clash YAML(跟进 proxy-providers)/ sing-box JSON / 分享链接。
 * 抽成函数是为了让主流程的「首次解析」与「UA 回退重试」走完全相同的判定逻辑。
 */
async function parseSubscriptionBody(content: string, allowInsecure: boolean,
  userAgent: string): Promise<ClashParseResult> {
  if (looksLikeClashYaml(content)) {
    // 跟进 proxy-providers 远程节点集(provider-only 的 Clash 订阅靠这条路径出节点)
    return await parseClashProxiesWithProviders(content, allowInsecure, userAgent);
  }
  if (looksLikeSingBoxJson(content)) {
    return parseSingBoxConfig(content);
  }
  // 分享链接分支:上报跳过项,否则「整份订阅都是 ssr://」这类情况
  // 只会显示笼统的「没有可用节点」,用户无从判断原因。
  const report: ShareSkipReport = { skipped: 0, names: [] };
  const profiles = parseShareText(content, report);
  return { profiles, skipped: report.skipped, skippedNames: report.names, note: '' };
}

/** 把 Clash 的 dialer-proxy / sing-box detour 的"名称引用"解析成节点 id。 */
function resolveDialerProxies(parsed: Array<Profile>, kept: Array<Profile>): void {
  for (const p of parsed) {
    if (p.dialerProxyName.trim().length === 0) {
      continue;
    }
    const target = kept.find(x => x.name === p.dialerProxyName);
    if (target === undefined) {
      // 名称对不上(通常是节点被过滤或改名):不写 id,节点按普通节点使用,
      // 免得配置生成阶段抛错导致整组连不上。
      LogStore.addLog(`[sub] 前置代理 "${p.dialerProxyName}" 未找到,节点 ${p.name} 按无前置处理`);
      p.dialerProxyName = '';
      continue;
    }
    if (target.id === p.id) {
      p.dialerProxyName = '';
      continue;
    }
    p.dialerProxyId = target.id;
  }
}

async function saveSubValidators(url: string, etag: string, lastModified: string): Promise<void> {
  const subs = await listSubs();
  let changed = false;
  for (const s of subs) {
    if (s.url === url && (s.etag !== etag || s.lastModified !== lastModified)) {
      s.etag = etag;
      s.lastModified = lastModified;
      changed = true;
    }
  }
  if (changed) {
    await saveSubs(subs);
  }
}

async function applySubUserInfo(url: string, userinfo: string): Promise<void> {
  const info = parseSubUserInfo(userinfo);
  if (info === null) {
    return;
  }
  const subs = await listSubs();
  let changed = false;
  for (const s of subs) {
    if (s.url === url) {
      s.upload = info.upload;
      s.download = info.download;
      s.total = info.total;
      s.expire = info.expire;
      changed = true;
    }
  }
  if (changed) {
    await saveSubs(subs);
  }
}


// 简单的上下文注入(由 Index 在启动时设置,供 updateSubscription 内部 initStore 使用)
let appContext: common.Context | null = null;

export function setAppContext(ctx: common.Context): void {
  appContext = ctx;
}

function globalContext(): common.Context {
  if (appContext === null) {
    throw new Error('app context not initialized');
  }
  return appContext;
}
