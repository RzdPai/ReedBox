import { ProfileType, Profile, profileTypeLabel } from '../model/Profile';

/** 速率/流量格式化（与通知栏同一口径，避免两处数字跳动不一致） */
export function speedText(bytesPerSec: number): string {
  if (!(bytesPerSec > 0)) {
    return '0 B/s';
  }
  const units: Array<string> = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  let value: number = bytesPerSec;
  let index: number = 0;
  while (value >= 1024 && index < units.length - 1) {
    value = value / 1024;
    index++;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[index]}`;
}

export function bytesText(bytes: number): string {
  if (!(bytes > 0)) {
    return '0 B';
  }
  const units: Array<string> = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value: number = bytes;
  let index: number = 0;
  while (value >= 1024 && index < units.length - 1) {
    value = value / 1024;
    index++;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[index]}`;
}

/** 连接时长 mm:ss / h:mm:ss */
export function durationText(ms: number): string {
  if (!(ms > 0)) {
    return '--:--';
  }
  const total: number = Math.floor(ms / 1000);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const two = (v: number): string => v < 10 ? `0${v}` : `${v}`;
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${two(m)}:${two(s)}`;
}

/** 延迟颜色分档：<200 绿 / <500 橙 / 其它红；未测灰 */
export function latencyColor(ms: number): ResourceColor {
  if (ms <= 0) {
    return $r('app.color.text_3');
  }
  if (ms < 200) {
    return $r('app.color.dot_live');
  }
  if (ms < 500) {
    return $r('app.color.warning');
  }
  return $r('app.color.error');
}

export function latencyText(ms: number): string {
  if (ms < 0) {
    return '超时';
  }
  if (ms === 0) {
    return '未测';
  }
  return `${ms} ms`;
}

/** 协议短名（节点卡左侧徽标用，2~4 个字符） */
export function protocolShort(type: string): string {
  switch (type) {
    case ProfileType.SHADOWSOCKS:
      return 'SS';
    case ProfileType.VMESS:
      return 'VM';
    case ProfileType.VLESS:
      return 'VL';
    case ProfileType.TROJAN:
      return 'TJ';
    case ProfileType.HYSTERIA:
      return 'HY';
    case ProfileType.HYSTERIA2:
      return 'H2';
    case ProfileType.TUIC:
      return 'TU';
    case ProfileType.WIREGUARD:
      return 'WG';
    case ProfileType.HTTP:
      return 'HT';
    case ProfileType.SOCKS:
      return 'SO';
    case ProfileType.SSH:
      return 'SH';
    case ProfileType.SHADOWTLS:
      return 'ST';
    case ProfileType.ANYTLS:
      return 'AT';
    case ProfileType.SNELL:
      return 'SN';
    case ProfileType.CUSTOM:
      return 'CU';
    case ProfileType.CHAIN:
      return 'CH';
    default:
      return '?';
  }
}

export function protocolName(type: string): string {
  return profileTypeLabel(type);
}

/** 协议徽标底色（同协议同色，扫一眼能分出机场里的节点类型分布） */
export function protocolTint(type: string): ResourceColor {
  switch (type) {
    case ProfileType.VMESS:
      return $r('app.color.protocol_vmess');
    case ProfileType.VLESS:
      return $r('app.color.protocol_vless');
    case ProfileType.TROJAN:
      return $r('app.color.protocol_trojan');
    case ProfileType.SHADOWSOCKS:
      return $r('app.color.protocol_shadowsocks');
    case ProfileType.HYSTERIA2:
    case ProfileType.HYSTERIA:
      return $r('app.color.protocol_hysteria2');
    case ProfileType.TUIC:
      return $r('app.color.protocol_tuic');
    default:
      return $r('app.color.text_2');
  }
}

/** 节点副标题：server:port（设置里可关） */
export function endpointText(p: Profile, alwaysShow: boolean): string {
  if (p.type === ProfileType.CUSTOM) {
    return '自定义出站';
  }
  if (p.type === ProfileType.CHAIN) {
    return '链式代理';
  }
  if (!alwaysShow && p.name.length > 0 && p.host.length > 0) {
    return p.host;
  }
  return `${p.server}:${p.serverPort}`;
}

export function dateText(ts: number): string {
  if (!(ts > 0)) {
    return '从未';
  }
  const d: Date = new Date(ts);
  const two = (v: number): string => v < 10 ? `0${v}` : `${v}`;
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
}
