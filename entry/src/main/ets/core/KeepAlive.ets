import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
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
 * ⚠️ DATA_TRANSFER 的软肋：官方要求"持续更新进度，超过 10 分钟不更新就**取消任务**"。
 *   本工程用的 Release SDK 26.0.0.105 里**没有**进度上报接口（`updateDataTransferProgress` 是 26.0.1 才加的），
 *   所以任务随时可能被系统回收。2026-11-26 真机日志实锤了这一点：
 *     `[keepalive] 长时任务续期失败：BusinessError 9800005 ... has not applied for a continuous task`
 *   —— 任务已经不在了，而我们只是每 5 分钟报一次错，什么都没做，等于保活悄悄失效。
 *
 * 现在的策略是**自愈**：
 *   ① 心跳从 5 分钟改成 **4 分钟**；
 *   ② 每次心跳先 `getAllContinuousTasks()` 问系统"我的任务还在吗"，不在就直接补挂；
 *   ③ `updateBackgroundRunning()` 失败（9800005 = 任务不在了）也走补挂，而不是只写日志；
 *   ④ 补挂有次数上限（避免在"系统根本不允许"的场景下无限重试刷日志）；
 *   ⑤ 外部流程（订阅后台更新等）把任务停掉时，通过 `onExternalStop()` 交回来，由这里补挂。
 */
export class KeepAlive {
  /** 用户/业务层**希望**保持后台运行（VPN 连着时为 true） */
  private static wanted: boolean = false;
  /** 当前是否已经成功挂上任务 */
  private static active: boolean = false;
  private static heartbeat: number = -1;
  /** 本轮"想要保活"期间的补挂次数（成功挂上就清零） */
  private static recoveries: number = 0;
  /** 心跳间隔：4 分钟（比官方的 10 分钟取消线留足余量） */
  private static readonly BEAT_MS: number = 4 * 60 * 1000;
  /** 一轮里最多补挂几次；超过就认命（只记一条日志，不再刷） */
  private static readonly MAX_RECOVER: number = 5;
  /** 9800005 = Continuous Task verification failed（任务没申请/已被回收） */
  private static readonly ERR_NOT_APPLIED: number = 9800005;

  /** 当前是否已有本应用挂着的长时任务（订阅后台更新据此判断要不要自己再挂） */
  static isActive(): boolean {
    return KeepAlive.active;
  }

  /** 连上就挂任务；重复调用无副作用 */
  static async ensureStarted(ctx: common.UIAbilityContext | undefined): Promise<void> {
    KeepAlive.wanted = true;
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
      KeepAlive.recoveries = 0;
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
    KeepAlive.wanted = false;
    KeepAlive.recoveries = 0;
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

  /**
   * 外部流程（`EntryAbility` 的订阅后台更新）把长时任务停掉后必须叫一下这里：
   * 一个 UIAbility 同时只能有一个长时任务，被外部停掉后我们这本地的 `active` 就是错的，
   * 后续心跳只会一直报 9800005。这里把它翻成"没挂"，若还需要保活就立刻补挂。
   */
  static onExternalStop(ctx: common.UIAbilityContext | undefined): void {
    if (!KeepAlive.active) {
      return;
    }
    KeepAlive.active = false;
    if (KeepAlive.heartbeat >= 0) {
      clearInterval(KeepAlive.heartbeat);
      KeepAlive.heartbeat = -1;
    }
    if (!KeepAlive.wanted || ctx === undefined) {
      return;
    }
    LogStore.addLog('[keepalive] 长时任务被外部流程停掉，重新申请');
    void KeepAlive.ensureStarted(ctx);
  }

  private static scheduleHeartbeat(ctx: common.UIAbilityContext): void {
    if (KeepAlive.heartbeat >= 0) {
      clearInterval(KeepAlive.heartbeat);
    }
    KeepAlive.heartbeat = setInterval((): void => {
      void KeepAlive.beat(ctx);
    }, KeepAlive.BEAT_MS);
  }

  /** 一次心跳：先问系统"任务还在吗"，在就续期，不在就补挂 */
  private static async beat(ctx: common.UIAbilityContext): Promise<void> {
    if (!KeepAlive.active || !KeepAlive.wanted) {
      return;
    }
    if (!(await KeepAlive.taskAlive(ctx))) {
      KeepAlive.recover(ctx, '系统已回收长时任务');
      return;
    }
    try {
      // 重新下发一次同样的任务 = 更新，用来续上系统的"10 分钟没有进度"计时
      await backgroundTaskManager.updateBackgroundRunning(ctx, ['dataTransfer']);
    } catch (e) {
      const code: number = (e as BusinessError).code;
      // 9800005：任务其实已经没了 ⇒ 不要只报错，直接补挂（其它错误也走同一条自愈路径）
      KeepAlive.recover(ctx, code === KeepAlive.ERR_NOT_APPLIED
        ? '任务已不在（9800005）' : `续期失败(${code})`);
    }
  }

  /** 查"本应用还有没有长时任务"；查询失败时按"还在"处理，避免无谓补挂 */
  private static async taskAlive(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(ctx);
      return tasks !== undefined && tasks !== null && tasks.length > 0;
    } catch (e) {
      return true;
    }
  }

  /** 补挂（有次数上限，避免刷日志/空转） */
  private static recover(ctx: common.UIAbilityContext, reason: string): void {
    KeepAlive.active = false;
    if (KeepAlive.heartbeat >= 0) {
      clearInterval(KeepAlive.heartbeat);
      KeepAlive.heartbeat = -1;
    }
    if (!KeepAlive.wanted) {
      return;
    }
    KeepAlive.recoveries = KeepAlive.recoveries + 1;
    if (KeepAlive.recoveries > KeepAlive.MAX_RECOVER) {
      if (KeepAlive.recoveries === KeepAlive.MAX_RECOVER + 1) {
        LogStore.addLog(`[keepalive] ${reason}；补挂次数已达上限，本次连接不再重试保活`);
      }
      return;
    }
    LogStore.addLog(`[keepalive] ${reason}，重新申请（第 ${KeepAlive.recoveries} 次）`);
    void KeepAlive.ensureStarted(ctx);
  }
}
