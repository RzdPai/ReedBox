import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { setPendingProfileId, clearPendingProfileId, LogStore } from '../model/Store';
import { VpnRuntime } from './VpnRuntime';

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

  private static clearWatchdogs(): void {
    if (VpnService.evidenceWatchdog >= 0) {
      clearTimeout(VpnService.evidenceWatchdog);
      VpnService.evidenceWatchdog = -1;
    }
    if (VpnService.timeoutWatchdog >= 0) {
      clearTimeout(VpnService.timeoutWatchdog);
      VpnService.timeoutWatchdog = -1;
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
        const message: string = e instanceof Error ? e.message : `${e}`;
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
