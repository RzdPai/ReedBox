import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettings, Profile, ProfileType } from '../../model/Profile';
import { AppState } from '../../core/AppState';
import { parseSingleLink } from '../../utils/LinkParser';
import { getClipboardText } from '../../utils/ClipboardHelper';
import {
  FormRow,
  GlowButton,
  OutlineButton,
  PickOption,
  PickSheetParam,
  PickSheetPanel,
  SectionHeader,
  ToggleRow,
  hdsPageBar
} from '../CommonUi';
import { Metrics } from '../Metrics';
import { Space, Theme } from '../Theme';
import { ProfileEditParam } from '../Routes';
import { immersiveMedium } from '../../ui/SelectMaterial';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-ProfileEdit';

const TYPE_LABELS: Array<string> = ['Shadowsocks', 'VMess', 'VLESS', 'Trojan', 'Hysteria2', 'TUIC', 'WireGuard',
  'Socks', 'HTTP', 'SSH', 'ShadowTLS', 'AnyTLS', 'Snell', '链式代理'];
const TYPE_VALUES: Array<string> = [ProfileType.SHADOWSOCKS, ProfileType.VMESS, ProfileType.VLESS, ProfileType.TROJAN,
  ProfileType.HYSTERIA2, ProfileType.TUIC, ProfileType.WIREGUARD, ProfileType.SOCKS, ProfileType.HTTP, ProfileType.SSH,
  ProfileType.SHADOWTLS, ProfileType.ANYTLS, ProfileType.SNELL, ProfileType.CHAIN];
const TRANSPORT_LABELS: Array<string> = ['无', 'HTTP', 'WS', 'gRPC', 'HTTPUpgrade', 'QUIC'];
const TRANSPORT_VALUES: Array<string> = ['', 'http', 'ws', 'grpc', 'httpupgrade', 'quic'];
const SS_METHODS: Array<string> = ['2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', 'aes-128-gcm', 'aes-256-gcm',
  'chacha20-ietf-poly1305', 'xchacha20-ietf-poly1305', 'none'];
const SECURITY: Array<string> = ['auto', 'none', 'zero', 'aes-128-gcm', 'chacha20-poly1305'];

/** 新建 / 编辑一个节点（这是唯一"手填协议字段"的地方，字段按协议显隐） */
@ComponentV2
export struct ProfileEditPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local app: AppState = AppState.get();
  @Local name: string = '';
  @Local type: string = ProfileType.VLESS;
  @Local server: string = '';
  @Local port: string = '443';
  @Local uuid: string = '';
  @Local password: string = '';
  @Local method: string = 'aes-128-gcm';
  @Local security: string = 'auto';
  @Local flow: string = '';
  @Local transport: string = '';
  @Local host: string = '';
  @Local path: string = '';
  @Local serviceName: string = '';
  @Local tls: boolean = true;
  @Local sni: string = '';
  @Local allowInsecure: boolean = false;
  @Local alpn: string = '';
  @Local fingerprint: string = '';
  @Local realityPublicKey: string = '';
  @Local realityShortId: string = '';
  @Local obfs: string = '';
  @Local upMbps: string = '100';
  @Local downMbps: string = '100';
  @Local extra: string = '';
  /** 链式代理：**有序的 N 跳**（原版 ChainBean.proxies 就是列表，支持拖动排序/左滑删除，不止两跳） */
  @Local chainHops: Array<string> = [];
  // 以下字段按 standard_v2ray_preferences.xml 的分类补齐（原版是分组 Preference）
  @Local username: string = '';
  @Local alterId: string = '0';
  @Local wsEarlyData: string = '0';
  @Local wsEarlyDataHeader: string = '';
  @Local mux: boolean = false;
  @Local muxProtocol: string = 'h2mux';
  @Local muxMaxStreams: string = '8';
  @Local muxPadding: boolean = true;
  @Local ech: boolean = false;
  @Local echConfig: string = '';
  @Local packetEncoding: string = '';
  // WireGuard / SSH 字段（原版 wireguard_preferences / ssh_preferences）
  @Local localAddress: string = '172.16.0.2/32';
  @Local privateKey: string = '';
  @Local peerPublicKey: string = '';
  @Local preSharedKey: string = '';
  @Local wgMtu: string = '1420';
  @Local reserved: string = '';
  @Local sshAuthType: string = 'password';
  @Local hostKey: string = '';
  @Local pickOpen: boolean = false;
  @Local pickTitle: string = '';
  @Local pickCurrent: string = '';
  @Local pickOptions: Array<PickOption> = [];
  @Local pasteOpen: boolean = false;
  @Local pasteText: string = '';
  private originId: string = '';
  /**
   * 编辑中节点的原始对象。`buildProfile()` 只重建"可编辑字段"，
   * 分组/置顶/排序/订阅来源/延迟/流量这些**非编辑字段必须从原件带过来**，
   * 否则保存一次节点就掉出原分组（甲方 2026-11-01 反馈的"节点跑进未分组"就是这条链路）。
   */
  private origin: Profile | undefined = undefined;
  private scroller: Scroller = new Scroller();
  private pickAction: (value: string) => void = (value: string): void => {
  };

  aboutToAppear(): void {
    const targetId: string = this.app.editingProfileId;
    if (targetId.length === 0) {
      this.applyDefaults();
      return;
    }
    for (const p of this.app.profiles) {
      if (p.id === targetId) {
        this.fill(p);
        return;
      }
    }
    this.applyDefaults();
  }

  private applyDefaults(): void {
    this.originId = '';
    this.origin = undefined;
    // "添加 [VMess]" 这类入口会把协议预设写进 editingProfileType；没有就用 VLESS
    const preset: string = this.app.editingProfileType;
    this.type = preset.length > 0 ? preset : ProfileType.VLESS;
    this.port = '443';
    this.tls = true;
    this.security = 'auto';
  }

  private fill(p: Profile): void {
    this.originId = p.id;
    this.origin = p;
    this.name = p.name;
    this.type = p.type;
    this.server = p.server;
    this.port = `${p.serverPort}`;
    this.uuid = p.uuid;
    this.password = p.password;
    this.method = p.method;
    this.security = p.security;
    this.flow = p.flow;
    this.transport = p.transport;
    this.host = p.host;
    this.path = p.path;
    this.serviceName = p.serviceName;
    this.tls = p.tls;
    this.sni = p.sni;
    this.allowInsecure = p.allowInsecure;
    this.alpn = p.alpn;
    this.fingerprint = p.fingerprint;
    this.realityPublicKey = p.realityPublicKey;
    this.realityShortId = p.realityShortId;
    this.obfs = p.obfs;
    this.upMbps = `${p.upMbps}`;
    this.downMbps = `${p.downMbps}`;
    this.extra = p.extra;
    this.username = p.username;
    this.packetEncoding = p.packetEncoding;
    this.localAddress = p.localAddress;
    this.privateKey = p.privateKey;
    this.peerPublicKey = p.peerPublicKey;
    this.preSharedKey = p.preSharedKey;
    this.wgMtu = `${p.wgMtu}`;
    this.reserved = p.reserved;
    this.sshAuthType = p.sshAuthType;
    this.hostKey = p.hostKey;
    this.alterId = `${p.alterId}`;
    this.wsEarlyData = `${p.wsEarlyData}`;
    this.wsEarlyDataHeader = p.wsEarlyDataHeaderName;
    this.mux = p.mux;
    this.muxProtocol = p.muxProtocol;
    this.muxMaxStreams = `${p.muxMaxStreams}`;
    this.muxPadding = p.muxPadding;
    this.ech = p.ech;
    this.echConfig = p.echConfig;
    // 链式代理：chainIds 是「第 1 跳 → 第 2 跳 → …」的顺序 id 列表
    const hops: Array<string> = [];
    for (const id of p.chainIds.split(',')) {
      if (id.trim().length > 0) {
        hops.push(id.trim());
      }
    }
    this.chainHops = hops;
  }

  private profileNameOf(id: string): string {
    for (const p of this.app.profiles) {
      if (p.id === id) {
        return p.name.length > 0 ? p.name : `${p.server}:${p.serverPort}`;
      }
    }
    return '';
  }

  /**
   * 选一跳节点（原版 `AddHolder` / `ProfileHolder.edit` → `ProfileSelectActivity`）。
   * `replaceIndex >= 0` 表示替换该跳，-1 表示追加到链尾。
   * 原版有**循环引用校验**（`testProfileAllowed`）：不能选自己、不能选已经在链里的同一节点。
   */
  private openChainPick(replaceIndex: number): void {
    const labels: Array<string> = [];
    const values: Array<string> = [];
    for (const p of this.app.profiles) {
      if (replaceIndex < 0 && this.chainHops.indexOf(p.id) >= 0) {
        continue;
      }
      if (!this.chainHopAllowed(p.id)) {
        continue;
      }
      labels.push(p.name.length > 0 ? p.name : `${p.server}:${p.serverPort}`);
      values.push(p.id);
    }
    if (values.length === 0) {
      this.toast('先添加至少一个普通节点，才能做链式代理');
      return;
    }
    const current: string = replaceIndex >= 0 && replaceIndex < this.chainHops.length
      ? this.chainHops[replaceIndex] : '';
    this.openPick(replaceIndex < 0 ? '把节点加到链尾' : '替换这一跳', labels, values, current,
      (value: string) => {
        const next: Array<string> = this.chainHops.slice();
        if (replaceIndex < 0) {
          next.push(value);
        } else {
          next[replaceIndex] = value;
        }
        this.chainHops = next;
      });
  }

  /**
   * 这条链（含嵌套链）是否直接或间接引用了 `targetId` —— 对齐原版 `testProfileContains`。
   * `visited` 防自己成环时无限递归（脏数据兜底）。
   */
  private chainContains(chainId: string, targetId: string, visited: Array<string>): boolean {
    if (chainId === targetId) {
      return true;
    }
    if (visited.indexOf(chainId) >= 0) {
      return false;
    }
    visited.push(chainId);
    let chain: Profile | undefined = undefined;
    for (const prof of this.app.profiles) {
      if (prof.id === chainId) {
        chain = prof;
        break;
      }
    }
    if (chain === undefined || chain.type !== ProfileType.CHAIN) {
      return false;
    }
    for (const hop of chain.chainIds.split(',')) {
      const id: string = hop.trim();
      if (id.length === 0) {
        continue;
      }
      if (this.chainContains(id, targetId, visited)) {
        return true;
      }
    }
    return false;
  }

  /** 能否把 `candidateId` 加进当前链（对齐 `testProfileAllowed`：不能选自己、不能形成环） */
  private chainHopAllowed(candidateId: string): boolean {
    if (candidateId === this.originId) {
      return false;
    }
    for (const hop of this.chainHops) {
      if (this.chainContains(hop, candidateId, [])) {
        return false;
      }
    }
    return true;
  }

  /** 链列表里的一个小图标按钮（上移/下移/替换/删除） */
  @Builder
  private chainIcon(symbol: Resource, enabled: boolean, action: () => void) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(15)
        .fontColor([enabled ? Theme.TEXT_3 : Theme.HAIRLINE])
    }
    .width(28)
    .height(28)
    .borderRadius(14)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .enabled(enabled)
    .onClick(() => {
      if (enabled) {
        action();
      }
    })
  }

  private moveChainHop(index: number, delta: number): void {
    const target: number = index + delta;
    if (index < 0 || target < 0 || index >= this.chainHops.length || target >= this.chainHops.length) {
      return;
    }
    const next: Array<string> = this.chainHops.slice();
    const temp: string = next[index];
    next[index] = next[target];
    next[target] = temp;
    this.chainHops = next;
  }

  private removeChainHop(index: number): void {
    if (index < 0 || index >= this.chainHops.length) {
      return;
    }
    const next: Array<string> = this.chainHops.slice();
    next.splice(index, 1);
    this.chainHops = next;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }

  private labelOf(labels: Array<string>, values: Array<string>, current: string): string {
    const index: number = values.indexOf(current);
    return index < 0 ? current : labels[index];
  }

  private openPick(title: string, labels: Array<string>, values: Array<string>, current: string,
    action: (value: string) => void): void {
    const options: Array<PickOption> = [];
    for (let i = 0; i < labels.length; i++) {
      options.push(new PickOption(labels[i], values[i]));
    }
    this.pickTitle = title;
    this.pickCurrent = current;
    this.pickOptions = options;
    this.pickAction = action;
    this.pickOpen = true;
  }

  private pickParam(): PickSheetParam {
    const param: PickSheetParam = new PickSheetParam();
    param.title = this.pickTitle;
    param.options = this.pickOptions;
    param.current = this.pickCurrent;
    param.onPick = (value: string): void => {
      this.pickAction(value);
    };
    return param;
  }

  private isSs(): boolean {
    return this.type === ProfileType.SHADOWSOCKS;
  }

  private needsUuid(): boolean {
    return this.type === ProfileType.VMESS || this.type === ProfileType.VLESS || this.type === ProfileType.TUIC;
  }

  private needsPassword(): boolean {
    return this.type === ProfileType.TROJAN || this.type === ProfileType.HYSTERIA
      || this.type === ProfileType.HYSTERIA2 || this.type === ProfileType.TUIC
      || this.type === ProfileType.ANYTLS || this.type === ProfileType.SNELL
      || this.type === ProfileType.SOCKS || this.type === ProfileType.HTTP;
  }

  private supportsTls(): boolean {
    if (this.type === ProfileType.CHAIN) {
      // 链式代理只是一层包装，TLS 由各跳自己决定
      return false;
    }
    return this.type !== ProfileType.SOCKS && this.type !== ProfileType.HTTP && this.type !== ProfileType.WIREGUARD
      && this.type !== ProfileType.SNELL && this.type !== ProfileType.SHADOWSOCKS;
  }

  private supportsReality(): boolean {
    return this.type === ProfileType.VLESS || this.type === ProfileType.TROJAN;
  }

  private supportsTransport(): boolean {
    return this.type === ProfileType.VMESS || this.type === ProfileType.VLESS || this.type === ProfileType.TROJAN;
  }

  private async pasteAndParse(): Promise<void> {
    try {
      const text: string = await getClipboardText();
      if (text.trim().length === 0) {
        this.toast('剪贴板为空');
        return;
      }
      const parsed: Profile | null = parseSingleLink(text.trim());
      if (parsed === null) {
        this.toast('无法识别该链接');
        return;
      }
      this.fill(parsed);
      this.originId = parsed.id;
      this.pasteOpen = false;
      this.toast('已解析，请核对后保存');
    } catch (e) {
      this.toast(`解析失败：${(e as Error).message}`);
    }
  }

  private buildProfile(): Profile {
    const p: Profile = new Profile();
    p.id = this.originId;
    p.name = this.name.trim().length > 0 ? this.name.trim() : `${this.server}:${this.port}`;
    p.type = this.type;
    p.server = this.server.trim();
    p.serverPort = Number(this.port);
    p.uuid = this.uuid.trim();
    p.password = this.password;
    p.method = this.method;
    p.security = this.security;
    p.flow = this.flow.trim();
    p.transport = this.transport;
    p.host = this.host.trim();
    p.path = this.path.trim();
    p.serviceName = this.serviceName.trim();
    p.tls = this.tls;
    p.sni = this.sni.trim();
    p.allowInsecure = this.allowInsecure;
    p.alpn = this.alpn.trim();
    p.fingerprint = this.fingerprint.trim();
    p.realityPublicKey = this.realityPublicKey.trim();
    p.realityShortId = this.realityShortId.trim();
    p.obfs = this.obfs.trim();
    p.upMbps = Number(this.upMbps) > 0 ? Number(this.upMbps) : 100;
    p.downMbps = Number(this.downMbps) > 0 ? Number(this.downMbps) : 100;
    p.username = this.username.trim();
    p.packetEncoding = this.packetEncoding;
    p.localAddress = this.localAddress.trim();
    p.privateKey = this.privateKey.trim();
    p.peerPublicKey = this.peerPublicKey.trim();
    p.preSharedKey = this.preSharedKey.trim();
    p.wgMtu = Number(this.wgMtu) > 0 ? Number(this.wgMtu) : 1420;
    p.reserved = this.reserved.trim();
    p.sshAuthType = this.sshAuthType;
    p.hostKey = this.hostKey.trim();
    p.alterId = Number(this.alterId) > 0 ? Number(this.alterId) : 0;
    p.wsEarlyData = Number(this.wsEarlyData) > 0 ? Number(this.wsEarlyData) : 0;
    p.wsEarlyDataHeaderName = this.wsEarlyDataHeader.trim();
    p.mux = this.mux;
    p.muxProtocol = this.muxProtocol;
    p.muxMaxStreams = Number(this.muxMaxStreams) > 0 ? Number(this.muxMaxStreams) : 8;
    p.muxPadding = this.muxPadding;
    p.ech = this.ech;
    p.echConfig = this.echConfig.trim();
    p.extra = this.extra.trim();
    if (p.type === ProfileType.CHAIN) {
      // 链式代理没有自己的服务器：只是把两跳按顺序串起来（ConfigBuilder 的 expandChain 消费它）
      p.chainIds = this.chainHops.join(',');
      p.server = '';
    }
    return p;
  }

  private validate(p: Profile): string {
    if (p.type === ProfileType.CHAIN) {
      if (this.chainHops.length === 0) {
        return '链式代理至少要加入 1 个节点';
      }
      const seen: Record<string, boolean> = {};
      for (const id of this.chainHops) {
        if (seen[id] === true) {
          return '同一节点不能在一条链里出现两次';
        }
        seen[id] = true;
      }
      return '';
    }
    // REALITY 公钥必须是 43 字符 base64url；shortId 必须是 2~16 位十六进制（对齐原版 reality 校验）
    if (p.realityPublicKey.length > 0) {
      const keyLen: number = p.realityPublicKey.length;
      if (keyLen !== 43) {
        return 'REALITY 公钥必须是 43 个字符的 base64url';
      }
    }
    if (p.realityShortId.length > 0) {
      if (!/^[0-9a-fA-F]{2,16}$/.test(p.realityShortId)) {
        return 'REALITY shortId 必须是 2~16 位十六进制字符';
      }
    }
    // WireGuard reserved 必须是 3 个 0~255 的整数（逗号分隔）
    if (p.type === ProfileType.WIREGUARD && p.reserved.length > 0) {
      const parts: Array<string> = p.reserved.split(',');
      if (parts.length !== 3) {
        return 'WireGuard reserved 需要 3 个数字';
      }
      for (const part of parts) {
        const value: number = Number(part.trim());
        if (!(value >= 0 && value <= 255)) {
          return 'WireGuard reserved 每个值必须在 0~255';
        }
      }
    }
    if (p.type !== ProfileType.CUSTOM && p.server.length === 0) {
      return '服务器地址不能为空';
    }
    if (!(p.serverPort >= 1 && p.serverPort <= 65535)) {
      return '端口必须是 1~65535 之间的整数';
    }
    return '';
  }

  private save(): void {
    const p: Profile = this.buildProfile();
    const error: string = this.validate(p);
    if (error.length > 0) {
      this.toast(error);
      return;
    }
    const origin: Profile | undefined = this.origin;
    if (origin !== undefined) {
      // 非编辑字段原样继承：分组 / 置顶 / 组内顺序 / 订阅来源 / 延迟与流量统计
      p.groupId = origin.groupId;
      p.pinned = origin.pinned;
      p.sortOrder = origin.sortOrder;
      p.subUrl = origin.subUrl;
      p.latencyMs = origin.latencyMs;
      p.latencyTestedAt = origin.latencyTestedAt;
      p.rx = origin.rx;
      p.tx = origin.tx;
    }
    this.app.saveProfile(p).then(() => {
      this.toast('已保存');
      this.pathStack.pop();
    }).catch((e: Error) => {
      this.toast(`保存失败：${e.message}`);
    });
  }

  @Builder
  private field(label: string, value: string, placeholder: string, onChange: (v: string) => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(Theme.TEXT_1)
        .width(96)
      TextInput({ text: value, placeholder: placeholder })
        .layoutWeight(1)
        .height(38)
        .fontSize(14)
        .backgroundColor(Theme.SURFACE_2)
        .borderRadius(10)
        .onChange((v: string) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private pageRoot() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            // 安全控件：点一下临时授权读剪贴板（不再申请 READ_PASTEBOARD）
            PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
              .fontSize(14)
              .constraintSize({ minWidth: 96, maxWidth: 132, minHeight: 40, maxHeight: 44 })
              .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                if (result === PasteButtonOnClickResult.SUCCESS) {
                  this.pasteAndParse();
                } else {
                  this.toast('没拿到剪贴板授权');
                }
              })
            GlowButton({
              label: '保存',
              grow: true,
              onTap: () => {
                this.save();
              }
            })
          }
          .width('100%')

          Column() {
            this.field('名称', this.name, '给这个节点起个名字', (v: string) => {
              this.name = v;
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            FormRow({
              label: '协议',
              value: this.labelOf(TYPE_LABELS, TYPE_VALUES, this.type),
              labelWidth: 96,
              onTap: () => {
                this.openPick('协议类型', TYPE_LABELS, TYPE_VALUES, this.type, (value: string) => {
                  this.type = value;
                });
              }
            })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(Theme.SURFACE)

          if (this.type === ProfileType.CHAIN) {
            // 对齐 ChainSettingsActivity：一个**有序列表**（第 0 项是"添加"），可上移/下移/删除/替换，N 跳
            Column({ space: 0 }) {
              ForEach(this.chainHops, (hopId: string, index: number) => {
                Row({ space: 8 }) {
                  Text(`${index + 1}`)
                    .fontSize(11)
                    .fontColor(Theme.ON_BRAND)
                    .width(20)
                    .height(20)
                    .borderRadius(10)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(Theme.BRAND)
                  Column({ space: 2 }) {
                    Text(this.profileNameOf(hopId))
                      .fontSize(14)
                      .fontColor(Theme.TEXT_1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(index === 0 ? '第一跳（先连这台）' : `第 ${index + 1} 跳`)
                      .fontSize(10)
                      .fontColor(Theme.TEXT_3)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  this.chainIcon($r('sys.symbol.chevron_up'), index > 0, () => {
                    this.moveChainHop(index, -1);
                  })
                  this.chainIcon($r('sys.symbol.chevron_down'), index < this.chainHops.length - 1, () => {
                    this.moveChainHop(index, 1);
                  })
                  this.chainIcon($r('sys.symbol.square_and_pencil'), true, () => {
                    this.openChainPick(index);
                  })
                  this.chainIcon($r('sys.symbol.trash'), true, () => {
                    this.removeChainHop(index);
                  })
                }
                .width('100%')
                .padding({ left: 16, right: 8, top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Center)
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              }, (hopId: string, index: number) => `hop_${index}_${hopId}_${this.chainHops.length}`)

              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(15)
                  .fontColor([Theme.BRAND])
                Text('添加节点')
                  .fontSize(14)
                  .fontColor(Theme.BRAND)
                Blank()
                Text(`${this.chainHops.length} 跳`)
                  .fontSize(11)
                  .fontColor(Theme.TEXT_3)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.openChainPick(-1);
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)

            Text('数据依次经过第 1 跳 → 最后一跳 → 目标（每跳都是「配置项」里已有的普通节点）。'
              + '同一节点不能在一条链里出现两次；删掉被引用的节点，这条链会失效。')
              .fontSize(11)
              .fontColor(Theme.TEXT_3)
              .width('100%')
          }

          if (this.type !== ProfileType.CHAIN) {
          Column() {
            this.field('服务器', this.server, 'example.com 或 IP', (v: string) => {
              this.server = v;
            })
            Divider().color(Theme.HAIRLINE).margin({ left: 16 })
            this.field('端口', this.port, '443', (v: string) => {
              this.port = v;
            })
            if (this.needsUuid()) {
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('UUID', this.uuid, 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', (v: string) => {
                this.uuid = v;
              })
            }
            if (this.isSs()) {
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              FormRow({
                label: '加密方式',
                value: this.method,
                labelWidth: 96,
                onTap: () => {
                  this.openPick('Shadowsocks 加密方式', SS_METHODS, SS_METHODS, this.method, (value: string) => {
                    this.method = value;
                  });
                }
              })
            }
            if (this.type === ProfileType.VMESS) {
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              FormRow({
                label: '加密',
                value: this.security,
                labelWidth: 96,
                onTap: () => {
                  this.openPick('VMess 加密方式', SECURITY, SECURITY, this.security, (value: string) => {
                    this.security = value;
                  });
                }
              })
            }
            if (this.needsPassword()) {
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field(this.type === ProfileType.TUIC ? '密码/UUID' : '密码', this.password, '', (v: string) => {
                this.password = v;
              })
            }
            if (this.type === ProfileType.VLESS) {
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('FLOW', this.flow, '留空 / xtls-rprx-vision', (v: string) => {
                this.flow = v;
              })
            }
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(Theme.SURFACE)
          }

          if (this.supportsTransport()) {
            Column() {
              FormRow({
                label: '传输层',
                value: this.labelOf(TRANSPORT_LABELS, TRANSPORT_VALUES, this.transport),
                labelWidth: 96,
                onTap: () => {
                  this.openPick('传输层', TRANSPORT_LABELS, TRANSPORT_VALUES, this.transport, (value: string) => {
                    this.transport = value;
                  });
                }
              })
              if (this.transport === 'ws' || this.transport === 'http' || this.transport === 'httpupgrade') {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('HOST', this.host, '伪装域名', (v: string) => {
                  this.host = v;
                })
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('PATH', this.path, '/', (v: string) => {
                  this.path = v;
                })
              }
              if (this.transport === 'grpc') {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('SERVICE', this.serviceName, 'gRPC serviceName', (v: string) => {
                  this.serviceName = v;
                })
              }
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          if (this.supportsTls()) {
            Column() {
              ToggleRow({
                label: '启用 TLS',
                summary: '',
                checked: this.tls,
                onToggle: (on: boolean) => {
                  this.tls = on;
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('SNI', this.sni, '留空则用服务器地址', (v: string) => {
                this.sni = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('ALPN', this.alpn, 'h2,http/1.1', (v: string) => {
                this.alpn = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('指纹', this.fingerprint, 'chrome / firefox / safari', (v: string) => {
                this.fingerprint = v;
              })
              if (this.supportsReality()) {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('REALITY', this.realityPublicKey, '公钥 pbk', (v: string) => {
                  this.realityPublicKey = v;
                })
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('SHORT ID', this.realityShortId, '十六进制 2~16 位', (v: string) => {
                  this.realityShortId = v;
                })
              }
              ToggleRow({
                label: '允许不安全 TLS',
                summary: '调试自签证书节点时使用',
                checked: this.allowInsecure,
                onToggle: (on: boolean) => {
                  this.allowInsecure = on;
                }
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          if (this.type === ProfileType.HYSTERIA2 || this.type === ProfileType.HYSTERIA) {
            Column() {
              this.field('上行 Mbps', this.upMbps, '100', (v: string) => {
                this.upMbps = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('下行 Mbps', this.downMbps, '100', (v: string) => {
                this.downMbps = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('OBFS', this.obfs, 'salamander 密码（可空）', (v: string) => {
                this.obfs = v;
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          if (this.needsPassword()) {
            Column() {
              this.field('用户名', this.username, '可选（SOCKS/HTTP/Trojan）', (v: string) => {
                this.username = v;
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          if (this.type === ProfileType.VMESS || this.type === ProfileType.VLESS) {
            Column() {
              this.field('alterId', this.alterId, 'VMess 专用，默认 0', (v: string) => {
                this.alterId = v;
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)

            Text('WS / Mux')
              .fontSize(11)
              .fontColor(Theme.TEXT_3)
              .width('100%')
            Column() {
              this.field('早期数据', this.wsEarlyData, 'ws 最大早期数据字节（0=关）', (v: string) => {
                this.wsEarlyData = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('早数据头', this.wsEarlyDataHeader, '如 Sec-WebSocket-Protocol', (v: string) => {
                this.wsEarlyDataHeader = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              ToggleRow({
                label: '启用 Mux',
                summary: '多路复用（原版 mux_preference）',
                checked: this.mux,
                onToggle: (on: boolean) => {
                  this.mux = on;
                }
              })
              if (this.mux) {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                FormRow({
                  label: 'Mux 类型',
                  value: this.muxProtocol,
                  labelWidth: 96,
                  onTap: () => {
                    this.openPick('Mux 类型', ['h2mux', 'smux', 'yamux'], ['h2mux', 'smux', 'yamux'],
                      this.muxProtocol, (value: string) => {
                        this.muxProtocol = value;
                      });
                  }
                })
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('并发流', this.muxMaxStreams, '默认 8', (v: string) => {
                  this.muxMaxStreams = v;
                })
                ToggleRow({
                  label: 'Mux padding',
                  summary: '对 mux 流量做填充',
                  checked: this.muxPadding,
                  onToggle: (on: boolean) => {
                    this.muxPadding = on;
                  }
                })
              }
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)

            Text('ECH')
              .fontSize(11)
              .fontColor(Theme.TEXT_3)
              .width('100%')
            Column() {
              ToggleRow({
                label: '启用 ECH',
                summary: 'Encrypted Client Hello；需要服务端支持',
                checked: this.ech,
                onToggle: (on: boolean) => {
                  this.ech = on;
                }
              })
              if (this.ech) {
                Divider().color(Theme.HAIRLINE).margin({ left: 16 })
                this.field('ECH 配置', this.echConfig, 'base64 的 ech config', (v: string) => {
                  this.echConfig = v;
                })
              }
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }
          if (this.type === ProfileType.VMESS || this.type === ProfileType.VLESS) {
            Column() {
              FormRow({
                label: 'packet_encoding',
                value: this.packetEncoding.length > 0 ? this.packetEncoding : '自动',
                labelWidth: 128,
                onTap: () => {
                  this.openPick('packet_encoding（VMess 支持 packetaddr/xudp，VLESS 只有 xudp）',
                    ['自动', 'packetaddr', 'xudp'], ['', 'packetaddr', 'xudp'], this.packetEncoding,
                    (value: string) => {
                      if (value === 'packetaddr' && this.type === ProfileType.VLESS) {
                        this.toast('VLESS 不支持 packetaddr');
                        return;
                      }
                      this.packetEncoding = value;
                    });
                }
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          if (this.type === ProfileType.WIREGUARD) {
            Text('WireGuard')
              .fontSize(11)
              .fontColor(Theme.TEXT_3)
              .width('100%')
            Column() {
              this.field('本地地址', this.localAddress, '172.16.0.2/32', (v: string) => {
                this.localAddress = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('本机私钥', this.privateKey, 'private_key', (v: string) => {
                this.privateKey = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('对端公钥', this.peerPublicKey, 'peer public_key', (v: string) => {
                this.peerPublicKey = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('预共享密钥', this.preSharedKey, '可选', (v: string) => {
                this.preSharedKey = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('WG MTU', this.wgMtu, '默认 1420', (v: string) => {
                this.wgMtu = v;
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('reserved', this.reserved, '3 个 0~255 的数字，逗号分隔（WARP 用）', (v: string) => {
                this.reserved = v;
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          if (this.type === ProfileType.SSH) {
            Text('SSH')
              .fontSize(11)
              .fontColor(Theme.TEXT_3)
              .width('100%')
            Column() {
              FormRow({
                label: '认证方式',
                value: this.sshAuthType,
                labelWidth: 96,
                onTap: () => {
                  this.openPick('SSH 认证方式', ['密码', '私钥', '无'], ['password', 'private_key', 'none'],
                    this.sshAuthType, (value: string) => {
                      this.sshAuthType = value;
                    });
                }
              })
              Divider().color(Theme.HAIRLINE).margin({ left: 16 })
              this.field('Host Key', this.hostKey, '服务器公钥 base64，多个用逗号分隔', (v: string) => {
                this.hostKey = v;
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor(Theme.SURFACE)
          }

          Column() {
            this.field('附加 JSON', this.extra, '与出站对象浅合并（高级）', (v: string) => {
              this.extra = v;
            })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(Theme.SURFACE)

          Text('改完记得保存')
            .fontSize(11)
            .fontColor(Theme.TEXT_3)
            .width('100%')

          Row()
            .width('100%')
            .height(Metrics.get().bottomInset)
        }
        .width('100%')
        .padding({ left: Space.PAGE, right: Space.PAGE, top: Metrics.get().detailTopInset })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleBar(hdsPageBar(this.originId.length > 0 ? '编辑节点' : '新建节点',
      this.app.settings.lightLevel, [], this.pathStack, true,
      // ★ 2026-11-01：窗口是全屏布局 + 这个 destination 又 ignore 了 TOP ⇒ 标题栏必须自己让状态栏，
      //   否则标题会顶进状态栏（甲方截图："编辑节点"压在时钟上）。传 true = 材质铺满、标题内容退到状态栏下方。
      true))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .backgroundColor(Theme.BG)
    .bindSheet(this.pickOpen!!, this.pickSheet(), {
      // API 26：面板统一走系统沉浸材质（菜单同一套玻璃），设备不支持时系统自动忽略
      systemMaterial: immersiveMedium(),
      height: 420,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.BG,
      preferType: SheetType.BOTTOM,
      onDisappear: () => {
        this.pickOpen = false;
      }
    })
  }

  @Builder
  private pickSheet() {
    Column() {
      PickSheetPanel({
        param: this.pickParam(),
        onClose: () => {
          this.pickOpen = false;
        }
      })
    }
    .width('100%')
    .padding({ top: 8 })
  }

  build() {
    this.pageRoot()
  }
}
