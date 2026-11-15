import { motion } from '@kit.MultimodalAwarenessKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 智感握姿（对齐 Neko4 的 `common/Handedness.ets`，官方最佳实践 bpta-smart-reach）：
 *   · `motion.on('operatingHandChanged')`（交互手）**最高优先**；
 *   · `motion.on('holdingHandChanged')`（握持手，含 `BOTH_HANDS_HELD`）兜底；
 *   · **双手握持 ⇒ 中间**（甲方要求：左手左边 / 右手右边 / 双手中间）；
 *   · 识别不出 / 系统能力缺失 ⇒ 恒为右手侧（与改造前布局完全一致，不做猜测）。
 *
 * 权限：`ohos.permission.DETECT_GESTURE`（system_grant，装上即用，不弹窗；module.json5 已声明）。
 * 排查：`hdc shell hilog | grep NekoBox-Reach`。
 */

export const HAND_LEFT: string = 'left';
export const HAND_RIGHT: string = 'right';
export const HAND_CENTER: string = 'center';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Reach';

@ObservedV2
export class Handedness {
  private static instance: Handedness | undefined = undefined;

  /** FAB 停靠的一侧：'left' | 'right' | 'center' */
  @Trace side: string = HAND_RIGHT;
  /** 设置里的"智感握姿"开关（默认关）。关掉后：不订阅系统服务，界面固定「按钮右、其余左」 */
  @Trace enabled: boolean = false;
  /** 设备/系统是否支持多模态感知（不支持时布局按右手侧） */
  @Trace supported: boolean = false;

  private started: boolean = false;
  private operatingSide: string = '';
  private holdingSide: string = '';
  private holdingBoth: boolean = false;
  /**
   * 订阅代号：每次 start/stop 都 +1。
   * 队列里的 `setTimeout(subscribe)` 只有代号仍相等时才执行 ⇒ **关闭后绝不可能被旧任务重新订阅**
   * （原实现：开→立刻关，stop() 已退订，但排队的 subscribe 仍会跑，等于又订上了）。
   */
  private generation: number = 0;
  /** 定时任务里用来校验的代号（0 表示当前没有待执行的订阅） */
  private pendingGeneration: number = 0;
  /** 两个事件各自的真实订阅状态：只有订阅成功才允许 off，且用于日志核对 */
  private operatingRegistered: boolean = false;
  private holdingRegistered: boolean = false;

  /**
   * 启动按钮（FAB）停靠侧：智感握姿开着就跟着手；**关掉固定右手侧**。
   * 用 getter 读 `@Trace` 字段 ⇒ 在 build 里读它会建立依赖。
   */
  get fabSide(): string {
    return this.enabled ? this.side : HAND_RIGHT;
  }

  /**
   * 其余界面（页头镜像 / 抽屉开合侧）：智感握姿开着跟着手；**关掉固定左侧**。
   * （甲方 2026-11-01："关掉时启动按钮放右手侧，剩余放左手侧"）
   */
  get uiSide(): string {
    return this.enabled ? this.side : HAND_LEFT;
  }

  static get(): Handedness {
    if (Handedness.instance === undefined) {
      Handedness.instance = new Handedness();
    }
    return Handedness.instance;
  }

  private readonly onOperating = (status: motion.OperatingHandStatus): void => {
    if (!this.enabled) {
      return;
    }
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
      this.operatingSide = HAND_LEFT;
    } else if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
      this.operatingSide = HAND_RIGHT;
    } else {
      return;
    }
    this.recompute('operating');
  };

  private readonly onHolding = (status: motion.HoldingHandStatus): void => {
    if (!this.enabled) {
      return;
    }
    if (status === motion.HoldingHandStatus.BOTH_HANDS_HELD) {
      this.holdingBoth = true;
      this.holdingSide = '';
    } else if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      this.holdingBoth = false;
      this.holdingSide = HAND_LEFT;
    } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      this.holdingBoth = false;
      this.holdingSide = HAND_RIGHT;
    } else {
      return;
    }
    this.recompute('holding');
  };

  /**
   * 交互手 > 握持手 > 右手（默认）。
   * ⚠️ 甲方 2026-11-01："启动按钮不要中间了，只保留左右手" ⇒ `BOTH_HANDS_HELD` 不再映射成 center，
   *    双手托着时沿用最近一次交互手（没有就跟握持手/默认右手）。
   */
  private recompute(source: string): void {
    if (!this.enabled) {
      return;
    }
    let next: string = HAND_RIGHT;
    if (this.operatingSide.length > 0) {
      next = this.operatingSide;
    } else if (this.holdingSide.length > 0) {
      next = this.holdingSide;
    }
    if (next === this.side) {
      return;
    }
    this.side = next;
    hilog.info(DOMAIN, TAG, 'side=%{public}s source=%{public}s', next, source);
  }

  /**
   * 设置里的"智感握姿"开关（`AppSettings.handAwareness`，**默认关**）。
   * 关掉：退订系统服务（省电、也免得跟别的手势感知抢资源）+ 作废排队任务 + 识别结果清空；
   * 布局由 `fabSide`/`uiSide` 固定成「按钮右、其余左」，不再跟手。
   * 事件回调里的 `if (!this.enabled) return;` 是第二道保险（见 onOperating/onHolding）。
   */
  setEnabled(enabled: boolean): void {
    if (enabled === this.enabled) {
      return;
    }
    this.enabled = enabled;
    if (!enabled) {
      // stop() 内部会 ++generation ⇒ 之前排队但没跑的 subscribe 任务一律作废
      this.stop();
      this.operatingSide = '';
      this.holdingSide = '';
      this.holdingBoth = false;
      this.supported = false;
      if (this.side !== HAND_RIGHT) {
        this.side = HAND_RIGHT;
      }
      hilog.info(DOMAIN, TAG, 'disabled -> fab right / ui left');
      return;
    }
    this.start();
    hilog.info(DOMAIN, TAG, 'enabled');
  }

  /**
   * 幂等启动。★ 必须延后一帧：`getRecentOperatingHandStatus()` 是**同步**接口、
   * `motion.on()` 也要走系统服务，放在启动关键路径上可能阻塞首帧（Neko4 真机踩过"卡开屏页"）。
   *
   * ⚠️ 延后任务必须带**代号**：`start()` 之后马上 `setEnabled(false)` 的序列里，旧任务不能把事件又订回来。
   */
  start(): void {
    if (this.started || !this.enabled) {
      return;
    }
    this.started = true;
    const generation: number = ++this.generation;
    this.pendingGeneration = generation;
    setTimeout(() => {
      // 三种情况都说明这条任务已过期：被 stop/disable 作废、代号被更新的任务顶替、已不在运行态
      if (generation !== this.generation || this.pendingGeneration !== generation) {
        hilog.info(DOMAIN, TAG, 'subscribe task dropped (stale generation=%{public}d)', generation);
        return;
      }
      this.pendingGeneration = 0;
      if (!this.enabled || !this.started) {
        hilog.info(DOMAIN, TAG, 'subscribe task dropped (disabled/stopped)');
        return;
      }
      this.subscribe();
    }, 0);
  }

  private subscribe(): void {
    try {
      if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
        this.supported = false;
        hilog.info(DOMAIN, TAG, 'motion syscap unavailable, keep right side');
        return;
      }
    } catch (e) {
      this.supported = false;
      return;
    }
    this.supported = true;
    try {
      const recent: motion.OperatingHandStatus = motion.getRecentOperatingHandStatus();
      if (recent === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
        this.operatingSide = HAND_LEFT;
        this.recompute('recent');
      } else if (recent === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
        this.operatingSide = HAND_RIGHT;
        this.recompute('recent');
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getRecentOperatingHandStatus failed: %{public}s', `${(e as Error).message}`);
    }
    try {
      motion.on('operatingHandChanged', this.onOperating);
      this.operatingRegistered = true;
    } catch (e) {
      this.operatingRegistered = false;
      hilog.warn(DOMAIN, TAG, 'on operatingHandChanged failed: %{public}s', `${(e as Error).message}`);
    }
    try {
      motion.on('holdingHandChanged', this.onHolding);
      this.holdingRegistered = true;
    } catch (e) {
      this.holdingRegistered = false;
      hilog.warn(DOMAIN, TAG, 'on holdingHandChanged failed: %{public}s', `${(e as Error).message}`);
    }
    hilog.info(DOMAIN, TAG, 'subscribed operating=%{public}s holding=%{public}s',
      `${this.operatingRegistered}`, `${this.holdingRegistered}`);
  }

  /**
   * 退订 + 作废所有排队任务。
   * 只有"真的订阅成功过"的事件才 off（没订上就 off 在某些实现里会抛）。
   */
  stop(): void {
    // 无论 started 是什么，都要让排队任务失效
    this.generation++;
    this.pendingGeneration = 0;
    if (!this.started && !this.operatingRegistered && !this.holdingRegistered) {
      return;
    }
    this.started = false;
    if (this.operatingRegistered) {
      try {
        motion.off('operatingHandChanged', this.onOperating);
      } catch (e) {
        // 未订阅成功时 off 会抛，忽略
      }
      this.operatingRegistered = false;
    }
    if (this.holdingRegistered) {
      try {
        motion.off('holdingHandChanged', this.onHolding);
      } catch (e) {
        // 同上
      }
      this.holdingRegistered = false;
    }
    hilog.info(DOMAIN, TAG, 'unsubscribed');
  }
}
