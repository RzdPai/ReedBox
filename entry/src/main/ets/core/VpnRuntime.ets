import { LogStore } from '../model/Store';

type VpnRuntimeListener = () => void;

/**
 * UI process VPN runtime state. Only commands and received extension events write here.
 * No timers, status files, log inspection or UI component imports belong in this module.
 */
@ObservedV2
export class VpnRuntime {
  private static instance: VpnRuntime | undefined = undefined;

  @Trace vpnRunning: boolean = false;
  @Trace vpnStatus: string = 'disconnected';
  @Trace runningProfileId: string = '';
  @Trace requestedProfileId: string = '';
  @Trace upSpeed: number = 0;
  @Trace downSpeed: number = 0;
  @Trace totalUp: number = 0;
  @Trace totalDown: number = 0;
  @Trace connectedAt: number = 0;
  private listeners: Array<VpnRuntimeListener> = [];

  static get(): VpnRuntime {
    if (VpnRuntime.instance === undefined) {
      VpnRuntime.instance = new VpnRuntime();
    }
    return VpnRuntime.instance;
  }

  subscribe(listener: VpnRuntimeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unsubscribe(listener: VpnRuntimeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notify(): void {
    const copy: Array<VpnRuntimeListener> = this.listeners.slice();
    for (const listener of copy) {
      try {
        listener();
      } catch (e) {
        LogStore.addLog(`[vpn-state] subscriber failed: ${(e as Error).message}`);
      }
    }
  }

  beginStart(profileId: string, switching: boolean): void {
    this.requestedProfileId = profileId;
    this.upSpeed = 0;
    this.downSpeed = 0;
    this.totalUp = 0;
    this.totalDown = 0;
    this.setStatus(switching ? 'switching' : 'connecting', this.vpnRunning, this.runningProfileId);
  }

  beginStop(): void {
    this.setStatus('disconnecting', this.vpnRunning, this.runningProfileId);
  }

  setStatus(status: string, running: boolean, profileId: string = ''): void {
    // Status and traffic arrive through two channels (direct mirror + CommonEvent);
    // an identical repeat must not notify listeners twice.
    const sameProfile: boolean = profileId.length === 0 || this.runningProfileId === profileId;
    if (this.vpnStatus === status && this.vpnRunning === running && sameProfile) {
      return;
    }
    this.vpnStatus = status;
    this.vpnRunning = running;
    if (running) {
      if (profileId.length > 0) {
        this.runningProfileId = profileId;
      }
      if (this.connectedAt === 0) {
        this.connectedAt = Date.now();
      }
    } else if (status === 'disconnected' || status.startsWith('start_failed:')
      || status.startsWith('connect_failed:')) {
      this.runningProfileId = '';
      this.requestedProfileId = '';
      this.connectedAt = 0;
      this.upSpeed = 0;
      this.downSpeed = 0;
    }
    LogStore.addLog(`[vpn-state] status=${status} running=${running} profile=${this.runningProfileId}`);
    this.notify();
  }

  setTraffic(up: number, down: number, totalUp: number, totalDown: number): void {
    if (!Number.isFinite(up) || !Number.isFinite(down)
      || !Number.isFinite(totalUp) || !Number.isFinite(totalDown)) {
      return;
    }
    this.upSpeed = up;
    this.downSpeed = down;
    this.totalUp = totalUp;
    this.totalDown = totalDown;
    // Preserve the original client's recovery from a missed connected event using live traffic events.
    if (!this.vpnRunning && (this.vpnStatus === 'connecting' || this.vpnStatus === 'switching'
      || this.vpnStatus === 'awaiting_auth')
      && (up > 0 || down > 0 || totalUp > 0 || totalDown > 0)) {
      this.setStatus('connected:running', true, this.requestedProfileId);
      return;
    }
    this.notify();
  }

  isBusy(): boolean {
    return this.vpnStatus === 'connecting' || this.vpnStatus === 'switching'
      || this.vpnStatus === 'disconnecting' || this.vpnStatus === 'awaiting_auth';
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
}
