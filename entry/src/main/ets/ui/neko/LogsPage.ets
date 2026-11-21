import { hilog } from '@kit.PerformanceAnalysisKit';
import emitter from '@ohos.events.emitter';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { AppState } from '../../core/AppState';
import { CoreManager } from '../../core/CoreManager';
import { LOG_EVENT_ID, LogStore } from '../../model/Store';
import { setClipboardText } from '../../utils/ClipboardHelper';
import { PageHeader } from '../CommonUi';
import { Space, Theme } from '../Theme';

const DOMAIN: number = 0x4e4b;
const TAG: string = 'NekoBox-Logs';
/** 原版 `SendLog.getNekoLog(50 * 1024)`：只取最近 50KB；这里按行数等价控制（每行约 120 字节） */
const MAX_LINES: number = 420;

/**
 * 日志页：照 `LogcatFragment` 的语义做的。
 *
 * 原版结构（`layout_logcat` + `logcat_menu.xml`）：
 *   · 一颗大 TextView，加载最近 50KB，加载完 `doOnLayout` **自动滚到底**；
 *   · **按行着色**：含 `INFO[` / `[Info]` → 绿；含 `ERROR[` / `[Error]` / `WARN[` / `[Warning]` → 红；其余灰；
 *   · 顶栏三颗：刷新 / 发送日志 / 清空。
 * 本仓把"应用日志（LogStore）+ 内核日志（core/singbox.log 尾部）"合成同一段流（原版也是合成一份 neko log）。
 */
@ComponentV2
export struct LogsPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Event onDrawer: () => void = (): void => {
  };
  @Local app: AppState = AppState.get();
  @Local lines: Array<string> = [];
  @Local tick: number = 0;
  private scroller: Scroller = new Scroller();
  private timer: number = -1;

  aboutToAppear(): void {
    const event: emitter.InnerEvent = { eventId: LOG_EVENT_ID, priority: emitter.EventPriority.LOW };
    emitter.on(event, this.onLogEvent);
    this.reload();
    // 内核日志走文件，2s 轮询一次；应用日志靠 emitter 增量触发
    this.timer = setInterval(() => {
      this.loadCoreLog();
    }, 2000);
  }

  aboutToDisappear(): void {
    emitter.off(LOG_EVENT_ID);
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private onLogEvent = (): void => {
    this.reload();
  };

  private context(): common.UIAbilityContext | undefined {
    return this.app.uicontext();
  }

  /** 刷新：应用日志 + 内核日志尾部合成一段（对齐原版 action_refresh） */
  private reload(): void {
    const merged: Array<string> = LogStore.getLines().slice();
    const tail: Array<string> = this.readCoreTail();
    if (tail.length > 0) {
      merged.push('----- core -----');
      for (const line of tail) {
        merged.push(line);
      }
    }
    this.lines = merged.length > MAX_LINES ? merged.slice(merged.length - MAX_LINES) : merged;
    this.tick++;
    this.scrollToBottom();
  }

  /** 只补内核日志的增量（轮询用） */
  private loadCoreLog(): void {
    const tail: Array<string> = this.readCoreTail();
    if (tail.length === 0) {
      return;
    }
    const appCount: number = this.appLineCount();
    const merged: Array<string> = LogStore.getLines().slice();
    merged.push('----- core -----');
    for (const line of tail) {
      merged.push(line);
    }
    const next: Array<string> = merged.length > MAX_LINES ? merged.slice(merged.length - MAX_LINES) : merged;
    if (appCount + tail.length !== this.lines.length - 1) {
      this.lines = next;
      this.tick++;
      this.scrollToBottom();
    }
  }

  private appLineCount(): number {
    return LogStore.getLines().length;
  }

  private readCoreTail(): Array<string> {
    const ctx = this.context();
    if (ctx === undefined) {
      return [];
    }
    try {
      const path: string = CoreManager.logFilePath(ctx);
      if (!fs.accessSync(path)) {
        return [];
      }
      const content: string = fs.readTextSync(path);
      const all: Array<string> = content.split('\n');
      // 只留最后 200 行，避免整份内核日志把列表撑爆
      return all.length > 200 ? all.slice(all.length - 200) : all;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read core log failed: %{public}s', (e as Error).message);
      return [];
    }
  }

  private scrollToBottom(): void {
    // 与原版一致：内容布局完成后再滚到底
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (e as Error).message);
    }
  }

  /** 清空：应用日志缓冲 + 截断内核日志文件（对齐原版 action_clear_logcat） */
  private clearAll(): void {
    LogStore.clear();
    const ctx = this.context();
    if (ctx !== undefined) {
      try {
        CoreManager.resetLogFile(ctx);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'reset core log failed: %{public}s', (e as Error).message);
      }
    }
    this.lines = [];
    this.tick++;
    this.toast('日志已清空');
  }

  /** 发送日志（原版 SendLog.sendLog；本仓先落到剪贴板，因为应用沙箱写文件还要走文件选择器） */
  private async sendLog(): Promise<void> {
    if (this.lines.length === 0) {
      this.toast('没有可发送的日志');
      return;
    }
    try {
      await setClipboardText(this.lines.join('\n'));
      this.toast(`已复制 ${this.lines.length} 行日志`);
    } catch (e) {
      this.toast(`复制失败：${(e as Error).message}`);
    }
  }

  /** 行着色：照 `getColorForLine` 的三档（INFO 绿 / ERROR·WARN 红 / 其余灰） */
  private lineColor(line: string): ResourceColor {
    if (line.indexOf('INFO[') >= 0 || line.indexOf(' [Info]') >= 0) {
      return Theme.OK;
    }
    if (line.indexOf('ERROR[') >= 0 || line.indexOf(' [Error]') >= 0
      || line.indexOf('WARN[') >= 0 || line.indexOf(' [Warning]') >= 0) {
      return Theme.DANGER;
    }
    return Theme.TEXT_2;
  }

  @Builder
  private pageRoot() {
    Column() {
      PageHeader({
        title: '日志',
        subtitle: `${this.lines.length} 行`,
        showSearch: true,
        searchSymbol: $r('sys.symbol.arrow_clockwise'),
        showAdd: true,
        addSymbol: $r('sys.symbol.paperplane'),
        showMenu: true,
        menuSymbol: $r('sys.symbol.trash'),
        onDrawer: () => {
          this.onDrawer();
        },
        onSearch: () => {
          this.reload();
          this.toast('已刷新');
        },
        onAdd: () => {
          this.sendLog();
        },
        onMenu: () => {
          this.clearAll();
        }
      })
      List({ space: 0, scroller: this.scroller }) {
        ListItem() {
          Column({ space: 0 }) {
            ForEach(this.lines, (line: string, index: number) => {
              Text(line.length > 0 ? line : ' ')
                .fontSize(11)
                .fontFamily('HarmonyOS Sans Mono')
                .fontColor(this.lineColor(line))
                .width('100%')
                .padding({ top: 1, bottom: 1 })
                .copyOption(CopyOptions.LocalDevice)
            }, (line: string, index: number) => `log_${this.tick}_${index}_${line.length}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 6 })
        }
        // 末尾呼吸位用列表项给（padding 会连滚动视口一起裁掉，底部会露出页面底色）
        ListItem() {
          Row().width('100%').height(8)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: Space.PAGE, right: Space.PAGE })
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }

  build() {
    this.pageRoot()
  }
}
