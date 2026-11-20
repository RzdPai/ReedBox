import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import { LogStore } from '../model/Store';

/**
 * VPN 连接的**后台保活**：连着的时候给 UI 进程挂一个"数据传递"长时任务（甲方说的"模拟下载"）。
 *
 * 为什么必须挂在 **UI 进程**：官方文档明确"调用 startVpnExtensionAbility 的应用进程退出时，系统会停止 VPN"。
 * 之前没挂长时任务，应用切后台一段时间后 UI 进程被回收 ⇒ 隧道跟着断，表现就是"后台保活差"。
 *
 * 为什么选 DATA_TRANSFER：
 *   · `TASK_KEEPING`（算力任务）在非 PC 设备上从 API 21 起要 ACL `KEEP_BACKGROUND_RUNNING_SYSTEM`，普通应用用不了；
 *   · `AUDIO_PLAYBACK` 要真的接 AVSession、`LOCATION` 要定位；
 *   · `DATA_TRANSFER` 只需要 `ohos.permission.KEEP_BACKGROUND_RUNNING`（已有）+ module.json5 里
 *     EntryAbility 的 `backgroundModes: ["dataTransfer"]`（已有）。
 *
 * ⚠️ 官方对 DATA_TRANSFER 有"持续更新进度，超过 10 分钟不更新就取消任务"的要求。
 *   本工程的目标 SDK 是 **Release 26.0.0.105**（上架用），这个版本里**没有** `updateDataTransferProgress`
 *   （那是 26.0.1 才加的，Beta SDK 里才有 —— 用它会编译不过，也不该为了它去背 beta 依赖）。
 *   所以这里用 API 12 起就有的 `updateBackgroundRunning()` 每 5 分钟续一次；
 *   如果真机上仍观察到 10 分钟被砍，下一步再做"改写长时任务通知的 live view 进度条"那条路。
 */
export class KeepAlive {
  private static active: boolean = false;
  private static heartbeat: number = -1;
  /** 续期间隔：DATA_TRANSFER 的"10 分钟不更新就取消"留一倍余量 */
  private static readonly BEAT_MS: number = 5 * 60 * 1000;

  /** 当前是否已有本应用挂着的长时任务（VPN 保活用）；订阅后台更新据此判断要不要自己再挂 */
  static isActive(): boolean {
    return KeepAlive.active;
  }

  /** 连上就挂任务；重复调用无副作用 */
  static async ensureStarted(ctx: common.UIAbilityContext | undefined): Promise<void> {
    if (KeepAlive.active || ctx === undefined) {
      return;
    }
    KeepAlive.active = true;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1004,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(ctx, ['dataTransfer'], agent);
      const notificationId: number = notification === undefined || notification === null
        ? -1 : notification.notificationId;
      LogStore.addLog(`[keepalive] 长时任务已开启(dataTransfer) notificationId=${notificationId}`);
      KeepAlive.scheduleHeartbeat(ctx);
    } catch (e) {
      KeepAlive.active = false;
      // 通知权限被拒、系统拒绝（9800005/9800006）都会走到这里：只影响保活强度，不影响 VPN 本身
      LogStore.addLog(`[keepalive] 开启长时任务失败（不影响连接）：${(e as Error).message}`);
    }
  }

  /** 断开就撤掉任务 */
  static async ensureStopped(ctx: common.UIAbilityContext | undefined): Promise<void> {
    if (KeepAlive.heartbeat >= 0) {
      clearInterval(KeepAlive.heartbeat);
      KeepAlive.heartbeat = -1;
    }
    if (!KeepAlive.active || ctx === undefined) {
      KeepAlive.active = false;
      return;
    }
    KeepAlive.active = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      LogStore.addLog('[keepalive] 长时任务已结束');
    } catch (e) {
      LogStore.addLog(`[keepalive] 结束长时任务失败（忽略）：${(e as Error).message}`);
    }
  }

  private static scheduleHeartbeat(ctx: common.UIAbilityContext): void {
    if (KeepAlive.heartbeat >= 0) {
      clearInterval(KeepAlive.heartbeat);
    }
    KeepAlive.heartbeat = setInterval(() => {
      if (!KeepAlive.active) {
        return;
      }
      // 重新下发一次同样的任务 = 更新，用来续上系统的"10 分钟没有进度"计时
      backgroundTaskManager.updateBackgroundRunning(ctx, ['dataTransfer']).then(() => {
        // 静默：这条只是续期，别把日志刷满
      }).catch((e: Error) => {
        LogStore.addLog(`[keepalive] 长时任务续期失败：${e.message}`);
      });
    }, KeepAlive.BEAT_MS);
  }
}
