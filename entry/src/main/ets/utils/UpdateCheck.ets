import http from '@ohos.net.http';

/**
 * 检查更新：从 GitHub Releases 取版本清单。
 *
 * 为什么用 Releases 而不是自建版本文件：
 *   · 源码已经在 `RzdPai/ReedBox` 上，发版时打一个 tag、传 HAP 即可，不用再维护第二份清单；
 *   · 「正式版 / 预览版」正好对应 release 的 `prerelease` 标记，两条入口一套代码。
 *
 * ⚠️ 网络现实：`api.github.com` 在国内可能被解析到坏 IP（本机实测过 DNS 池里有不通的地址），
 * 失败时不要含糊报"检查失败"，要把 HTTP 状态码/异常文本原样带出去，用户才知道是网络问题还是没发版。
 */

const OWNER: string = 'RzdPai';
const REPO: string = 'ReedBox';
const RELEASES_API: string = `https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=20`;
const TIMEOUT_MS: number = 8000;

/** 一个发布版本（只留应用要用的字段） */
export class UpdateRelease {
  versionName: string = '';
  tag: string = '';
  notes: string = '';
  pageUrl: string = '';
  /** 优先取 .hap 资产；没有就回落发布页 */
  assetUrl: string = '';
  prerelease: boolean = false;
}

/** 一次检查的结果 */
export class UpdateCheckResult {
  /** 请求本身是否成功（成功 ≠ 有新版本） */
  ok: boolean = false;
  hasUpdate: boolean = false;
  /** 最新版本（ok=true 且至少有一个 release 时非空） */
  latest: UpdateRelease | null = null;
  /** ok=false 时给用户看的一句话 */
  error: string = '';
}

/** `v0.5.60` / `0.5.60` → [0,5,60]；非数字段按 0 处理 */
export function parseVersionName(raw: string): Array<number> {
  const text: string = raw.trim().replace(/^[vV]/, '');
  const parts: Array<number> = [];
  const list: Array<string> = text.split('.');
  for (const item of list) {
    const value: number = parseInt(item, 10);
    parts.push(isNaN(value) ? 0 : value);
  }
  return parts;
}

/**
 * 比版本号：`a` 比 `b` 新返回 >0，相同返回 0，旧返回 <0。
 * 逐段比数字，缺的段按 0 补（`0.5` == `0.5.0`）。
 */
export function compareVersions(a: string, b: string): number {
  const left: Array<number> = parseVersionName(a);
  const right: Array<number> = parseVersionName(b);
  const count: number = left.length > right.length ? left.length : right.length;
  for (let i = 0; i < count; i++) {
    const l: number = i < left.length ? left[i] : 0;
    const r: number = i < right.length ? right[i] : 0;
    if (l !== r) {
      return l - r;
    }
  }
  return 0;
}

/**
 * GitHub Releases 的 JSON → `UpdateRelease[]`。
 * 服务端返回错误对象（限流 `{"message": "API rate limit exceeded..."}`）时返回空数组 —
 * 调用方靠"空数组"给出"还没有发布版本"，比抛异常好定位。
 */
export function parseReleases(raw: string): Array<UpdateRelease> {
  const out: Array<UpdateRelease> = [];
  let parsed: Object = '';
  try {
    parsed = JSON.parse(raw) as Object;
  } catch (e) {
    return out;
  }
  if (!Array.isArray(parsed)) {
    return out;
  }
  const list: Array<Object> = parsed as Array<Object>;
  for (const item of list) {
    if (item === null || item === undefined) {
      continue;
    }
    const rec: Record<string, Object> = item as Record<string, Object>;
    if (`${rec['draft']}` === 'true') {
      continue;
    }
    const release: UpdateRelease = new UpdateRelease();
    release.tag = rec['tag_name'] === undefined ? '' : `${rec['tag_name']}`;
    release.versionName = release.tag.replace(/^[vV]/, '');
    release.notes = rec['body'] === undefined ? '' : `${rec['body']}`;
    release.pageUrl = rec['html_url'] === undefined ? '' : `${rec['html_url']}`;
    release.prerelease = `${rec['prerelease']}` === 'true';
    const assets: Object | undefined = rec['assets'];
    if (assets !== undefined && Array.isArray(assets)) {
      const assetList: Array<Object> = assets as Array<Object>;
      for (const asset of assetList) {
        const assetRec: Record<string, Object> = asset as Record<string, Object>;
        const name: string = assetRec['name'] === undefined ? '' : `${assetRec['name']}`;
        const url: string = assetRec['browser_download_url'] === undefined
          ? '' : `${assetRec['browser_download_url']}`;
        if (url.length === 0) {
          continue;
        }
        if (name.toLowerCase().endsWith('.hap')) {
          release.assetUrl = url;
          break;
        }
        if (release.assetUrl.length === 0) {
          release.assetUrl = url;
        }
      }
    }
    if (release.versionName.length === 0) {
      continue;
    }
    out.push(release);
  }
  return out;
}

/**
 * 从列表里挑"这个渠道的最新版"。
 * Releases API 按发布时间倒序返回，所以取第一个匹配的即可。
 *   stable  = 非 prerelease（正式版）
 *   preview = 包含 prerelease（预览版优先给最新）
 */
export function pickRelease(releases: Array<UpdateRelease>, channel: string): UpdateRelease | null {
  for (const release of releases) {
    if (channel === 'stable' && release.prerelease) {
      continue;
    }
    return release;
  }
  return null;
}

/** 组装结果：只在远端版本确实比当前新时 hasUpdate=true（同版本/回退版本都算"已是最新"） */
export function resolveCheckResult(releases: Array<UpdateRelease>, channel: string,
  currentVersionName: string): UpdateCheckResult {
  const result: UpdateCheckResult = new UpdateCheckResult();
  result.ok = true;
  const latest: UpdateRelease | null = pickRelease(releases, channel);
  if (latest === null) {
    return result;
  }
  result.latest = latest;
  result.hasUpdate = compareVersions(latest.versionName, currentVersionName) > 0;
  return result;
}

/** 拉一次 Releases 并判断有没有新版本。网络/服务异常都写进 `result.error`。 */
export async function checkForUpdate(channel: string, currentVersionName: string): Promise<UpdateCheckResult> {
  const client = http.createHttp();
  try {
    const resp = await client.request(RELEASES_API, {
      method: http.RequestMethod.GET,
      header: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'ReedBox'
      },
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    });
    const body: string = `${resp.result}`;
    if (resp.responseCode === 403) {
      const failed: UpdateCheckResult = new UpdateCheckResult();
      failed.error = 'GitHub 拒绝了请求（403，多是接口限流），过一会儿再试';
      return failed;
    }
    if (resp.responseCode !== 200) {
      const failed: UpdateCheckResult = new UpdateCheckResult();
      failed.error = `GitHub 返回 HTTP ${resp.responseCode}`;
      return failed;
    }
    return resolveCheckResult(parseReleases(body), channel, currentVersionName);
  } catch (e) {
    const failed: UpdateCheckResult = new UpdateCheckResult();
    failed.error = `连不上 GitHub：${(e as Error).message}`;
    return failed;
  } finally {
    client.destroy();
  }
}
