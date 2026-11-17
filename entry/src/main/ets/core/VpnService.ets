import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import BusinessError from '@ohos.base';
import { setPendingProfileId, clearPendingProfileId, LogStore } from '../model/Store';
import { VpnRuntime } from './VpnRuntime';

/**
 * `startVpnExtensionAbility` / 隧道创建失败时的错误码 → 一句人话。
 * 远程排查时用户只会看到状态文案与 toast，原始 error code 他们看不懂；
 * 码表见 SDK `@ohos.net.vpnExtension.d.ts` 与 `VpnConnection.create` 的 throws。
 */
function startErrorText(e: Object): string {
  const err: BusinessError = e as BusinessError;
  // 用 typeof 判而不是 === undefined：BusinessError 的字段类型不是可选的，
  // 直接比 undefined 会被类型检查判成"永不成立"。
  const code: number = typeof err.code === 'number' ? err.code : 0;
  const detail: string = typeof err.message === 'string' && err.message.length > 0 ? err.message : `${e}`;
  switch (code) {
    case 201:
      return `没有网络权限（201）：${detail}`;
    case 401:
      return `启动参数不对（401）：${detail}`;
    case 16000001:
      return `系统里找不到 VPN 扩展（16000001）：安装包可能不完整，或 abilityName 不对`;
    case 16000002:
      return `扩展类型不对（16000002）：module.json5 里必须是 "type": "vpn"`;
    case 16000006:
      return `跨用户调用被拒（16000006）`;
    case 16000011:
      return `上下文不存在（16000011）：应用可能刚被系统回收，请重开后再试`;
    case 16000050:
      return `系统内部错误（16000050）：请重试，或重启手机`;
    case 16200001:
      return `调用方已被释放（16200001）：请重开应用再试`;
    case 2203001:
      return `系统拒绝了 VPN 创建（2203001）：检查用户类型/授权`;
    case 2203002:
      return `已经有一个 VPN 在运行（2203002）：先断开其它 VPN 或加速器`;
    default:
      return detail.length > 0 ? detail : `错误码 ${code}`;
  }
}

/** Original NekoBox4Harmony Want contract and serialized operations, adapted to V2 runtime state. */
function wantFor(context: common.UIAbilityContext, profileId: string = '', forceRestart: boolean = false): Want {
  const want: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: 'VpnExtAbility'
  };
  if (profileId.length > 0 || forceRestart) {
    const params: Record<string, Object> = { 'profileId': profileId, 'forceRestart': forceRestart };
    want.parameters = params;
  }
  return want;
}

export class VpnService {
  private static operation: Promise<void> = Promise.resolve();
  private static generation: number = 0;
  private static evidenceWatchdog: number = -1;
  private static timeoutWatchdog: number = -1;
  private static authHintWatchdog: number = -1;

  private static clearWatchdogs(): void {
    if (VpnService.evidenceWatchdog >= 0) {
      clearTimeout(VpnService.evidenceWatchdog);
      VpnService.evidenceWatchdog = -1;
    }
    if (VpnService.timeoutWatchdog >= 0) {
      clearTimeout(VpnService.timeoutWatchdog);
      VpnService.timeoutWatchdog = -1;
    }
    if (VpnService.authHintWatchdog >= 0) {
      clearTimeout(VpnService.authHintWatchdog);
      VpnService.authHintWatchdog = -1;
    }
  }

  static async connect(context: common.UIAbilityContext, profileId: string,
    forceRestart: boolean = false): Promise<void> {
    const state: VpnRuntime = VpnRuntime.get();
    if (state.isBusy()) {
      LogStore.addLog(`[vpn-control] duplicate start ignored status=${state.vpnStatus}`);
      return;
    }
    const generation: number = ++VpnService.generation;
    VpnService.clearWatchdogs();
    // Set the command state before the first await so a second tap cannot queue another start.
    state.beginStart(profileId, forceRestart);
    const previous: Promise<void> = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // A failed operation must not block the next request.
      }
      try {
        await setPendingProfileId(profileId);
        LogStore.addLog(`[vpn-control] start request generation=${generation} bundle=${context.abilityInfo.bundleName}`);
        await vpnExtension.startVpnExtensionAbility(wantFor(context, profileId, forceRestart));
        LogStore.addLog('[app] startVpnExtensionAbility 已调用，等待扩展回调…');
      } catch (e) {
        await clearPendingProfileId();
        const message: string = startErrorText(e as Object);
        state.setStatus(`start_failed:${message}`, false);
        throw new Error(message);
      }
      // Keep original watchdog behavior: no timeout is permitted to tear down a working tunnel.
      VpnService.evidenceWatchdog = setTimeout(() => {
        VpnService.evidenceWatchdog = -1;
        if (generation !== VpnService.generation) {
          return;
        }
        if (!state.vpnRunning && (state.vpnStatus === 'connecting' || state.vpnStatus === 'switching')) {
          if (state.upSpeed > 0 || state.downSpeed > 0 || state.totalUp > 0 || state.totalDown > 0) {
            state.setStatus('connected:running', true, profileId);
          } else {
            LogStore.addLog('[vpn-control] extension status not received after 60s');
          }
        }
      }, 60000);
      /**
       * 45s 还没等到扩展的任何回调时，写一条"可截图"的排查提示。
       * 常见真因：① 系统 VPN 授权弹窗还没出来/被划掉了；② 本应用没被信任；③ 另一个 VPN 占着唯一槽位。
       * 这段时间界面只会停在"正在建立 VPN…"，用户看到的就是"点了没反应/启动不了"。
       */
      VpnService.authHintWatchdog = setTimeout(() => {
        VpnService.authHintWatchdog = -1;
        if (generation !== VpnService.generation) {
          return;
        }
        if (!state.vpnRunning && (state.vpnStatus === 'connecting' || state.vpnStatus === 'switching'
          || state.vpnStatus === 'awaiting_auth')) {
          LogStore.addLog('[vpn-control] 45s 没有收到扩展回调：若没看到系统 VPN 授权弹窗，检查是否已有其它 VPN 在运行、'
            + '或本应用是否被系统拒绝授权（首次连接必须点"允许"）');
        }
      }, 45000);
      VpnService.timeoutWatchdog = setTimeout(() => {
        VpnService.timeoutWatchdog = -1;
        if (generation !== VpnService.generation) {
          return;
        }
        if (!state.vpnRunning && (state.vpnStatus === 'connecting' || state.vpnStatus === 'switching'
          || state.vpnStatus === 'awaiting_auth')) {
          state.setStatus('connect_failed:启动超时，未收到扩展状态，请查看日志', false);
        }
      }, 120000);
    })();
    return VpnService.operation;
  }

  static async disconnect(context: common.UIAbilityContext): Promise<void> {
    const state: VpnRuntime = VpnRuntime.get();
    if (state.vpnStatus === 'disconnecting') {
      return;
    }
    ++VpnService.generation;
    VpnService.clearWatchdogs();
    state.beginStop();
    const previous: Promise<void> = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // Continue teardown after a failed startup.
      }
      try {
        LogStore.addLog('[vpn-control] stop request');
        await vpnExtension.stopVpnExtensionAbility(wantFor(context));
      } catch (e) {
        LogStore.addLog(`[vpn-control] stop rejected: ${e}`);
        state.setStatus(`connect_failed:断开请求失败 ${e}`, state.vpnRunning, state.runningProfileId);
        throw new Error(`${e}`);
      }
      await clearPendingProfileId();
      state.setStatus('disconnected', false);
    })();
    return VpnService.operation;
  }

  static async switchTo(context: common.UIAbilityContext, profileId: string): Promise<void> {
    LogStore.addLog('[vpn-control] switch request');
    await VpnService.connect(context, profileId, true);
  }
}
