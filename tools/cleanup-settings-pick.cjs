// SettingsTab 收尾：删掉「选项面板」那套（现在全部走系统 Select），只保留「文本输入面板」。
const fs = require('node:fs');
const path = require('node:path');
const file = path.resolve(__dirname, '..', 'entry', 'src', 'main', 'ets', 'ui', 'neko', 'SettingsTab.ets');
let src = fs.readFileSync(file, 'utf8');

function dropBlock(startMarker, endMarker) {
  const start = src.indexOf(startMarker);
  if (start < 0) {
    return false;
  }
  const end = src.indexOf(endMarker, start);
  if (end < 0) {
    return false;
  }
  src = src.slice(0, start) + src.slice(end + endMarker.length);
  return true;
}

// 1) 选项面板分派：只留文本面板
src = src.replace(`  @Builder
  private pickSheet() {
    if (this.sheetKind === 'text') {
      this.textPanel()
    } else {
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
  }`, `  @Builder
  private pickSheet() {
    this.textPanel()
  }`);

// 2) 删 openPick 与 pickStrategy
const openPickStart = src.indexOf('  private openPick(title: string');
if (openPickStart >= 0) {
  const openPickEnd = src.indexOf('  /** DNS 策略文案', openPickStart);
  if (openPickEnd > openPickStart) {
    src = src.slice(0, openPickStart) + src.slice(openPickEnd);
  }
}
const pickStrategyStart = src.indexOf('  private pickStrategy(title: string');
if (pickStrategyStart >= 0) {
  const pickStrategyEnd = src.indexOf('  /**', pickStrategyStart + 10);
  if (pickStrategyEnd > pickStrategyStart) {
    src = src.slice(0, pickStrategyStart) + src.slice(pickStrategyEnd);
  }
}

// 3) 删 pickParam
const pickParamStart = src.indexOf('  private pickParam(): PickSheetParam {');
if (pickParamStart >= 0) {
  const pickParamEnd = src.indexOf('\n  }\n', pickParamStart);
  if (pickParamEnd > pickParamStart) {
    src = src.slice(0, pickParamStart) + src.slice(pickParamEnd + 4);
  }
}

// 4) 三态选择面板的残留状态
src = src.replace(`  /** 一个节点只能挂一个 bindSheet：用 kind 切「选项面板」与「文本面板」 */
  @Local sheetKind: string = 'pick';
`, '');
src = src.replace(`  @Local pickTitle: string = '';
  @Local pickCurrent: string = '';
  @Local pickOptions: Array<PickOption> = [];
`, '');
src = src.replace(`  private pickAction: (value: string) => void = (value: string): void => {
  };
`, '');
src = src.replace("  PickOption,\n", '');
src = src.replace("  PickSheetParam,\n", '');
src = src.replace("  PickSheetPanel,\n", '');
src = src.replace("  @Local sheetKind: string = '';\n", '');

fs.writeFileSync(file, src, 'utf8');
console.log('SETTINGS_PICK_CLEANUP done');
