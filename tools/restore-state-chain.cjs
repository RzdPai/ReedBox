// One-shot, literal checked migration. The before snapshot is kept outside the project.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..', 'entry', 'src', 'main', 'ets');
function transform(rel, fn) {
  const file = path.join(root, rel);
  const before = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const after = fn(before);
  if (after === before) throw new Error(`No change: ${rel}`);
  fs.writeFileSync(file, after, 'utf8');
}
function once(text, oldText, newText) {
  if (text.split(oldText).length !== 2) throw new Error(`Nonunique anchor: ${oldText.slice(0, 100)}`);
  return text.replace(oldText, newText);
}
transform('core/AppState.ets', text => {
  const start = text.indexOf('  private lastStatusRaw:');
  const end = text.indexOf('  /** 供 UI 取一次点击反馈文本', start);
  if (start < 0 || end < 0) throw new Error('Status experiment block missing');
  text = text.slice(0, start) + `  applyVpnStatus(status: string, running: boolean, profileId: string): void {
    this.runtime.setStatus(status, running, profileId);
  }

  applyTraffic(up: number, down: number, totalUp: number, totalDown: number): void {
    this.runtime.setTraffic(up, down, totalUp, totalDown);
  }

  statusText(): string {
    return this.runtime.statusText();
  }

` + text.slice(end);
  text = once(text, '    this.connectedAt = 0;\n', '');
  text = once(text, '  setRunningProfileId,\n', '');
  text = once(text, '    this.groups = await loadGroups();\n    return id;', '    this.groups = await loadGroups();\n    this.bump();\n    return id;');
  // Explanations must describe the real notification contract instead of blaming V2.
  const revStart = text.indexOf('  /**\n   * ★ 全量失效计数器');
  const revEnd = text.indexOf('  @Trace rev:', revStart);
  if (revStart < 0 || revEnd < 0) throw new Error('Revision comment missing');
  text = text.slice(0, revStart) + '  /** Business data revision. Notify only after the complete mutation is committed. */\n' + text.slice(revEnd);
  return text;
});
transform('core/VpnIpc.ets', text => {
  text = once(text, "import BusinessError from '@ohos.base';", "import BusinessError from '@ohos.base';\nimport { BUNDLE_NAME } from 'BuildProfile';");
  text = once(text, "const APP_BUNDLE = 'com.nekobox.app.jynxen';", 'const APP_BUNDLE: string = BUNDLE_NAME;');
  text = once(text, '      // 日志通道失败不影响 VPN 流程', `      // Never use LogStore here: its publisher calls this function.
      if (err) {
        console.error('[vpn-ipc] log publish failed code=' + err.code);
      }`);
  text = once(text, `    commonEventManager.publish(VPN_EVENT_STATUS, opts, (err: BusinessError) => {
      // ignore
    });`, `    commonEventManager.publish(VPN_EVENT_STATUS, opts, (err: BusinessError) => {
      if (err) {
        console.error('[vpn-ipc] status publish failed code=' + err.code);
      }
    });`);
  text = once(text, '    vpnEventSubscriber = subscriber;', '    vpnEventSubscriber = subscriber;');
  text = once(text, '          onStatus(status, running, profileId);', `          onLog('[vpn-ipc] received status=' + status + ' running=' + running);
          onStatus(status, running, profileId);`);
  text = once(text, `    });
  }).catch((e: Object) => {
    // 订阅失败时 UI 退化为看门狗提示
  });`, `    });
    onLog('[vpn-ipc] subscriber registered receiver=' + APP_BUNDLE);
  }).catch((e: Object) => {
    onLog('[vpn-ipc] subscriber creation failed: ' + e);
  });`);
  return text;
});
transform('core/Subscriptions.ets', text => {
  text = once(text, "import connection from '@ohos.net.connection';", "import connection from '@ohos.net.connection';\nimport { VpnRuntime } from './VpnRuntime';");
  text = once(text, "AppStorage.get<boolean>('vpnRunning') ?? false", 'VpnRuntime.get().vpnRunning');
  text = once(text, "AppStorage.get<string>('vpnRunningProfileId') ?? ''", 'VpnRuntime.get().runningProfileId');
  return text;
});
transform('vpnext/VpnExtAbility.ets', text => {
  // latestRequestedProfileId already holds the Want value; Store is not initialized at this entry point.
  text = once(text, '      setPendingProfileId(this.latestRequestedProfileId);\n', '');
  text = once(text, 'setPendingProfileId, clearPendingProfileId', 'clearPendingProfileId');
  text = once(text, "import Want from '@ohos.app.ability.Want';", "import Want from '@ohos.app.ability.Want';\nimport { BUNDLE_NAME } from 'BuildProfile';");
  text = once(text, "bundleName: 'com.nekobox.app.jynxen',", 'bundleName: BUNDLE_NAME,');
  text = once(text, `    await this.showConnectedNotification(node.name, -1);
    this.startNotificationTrafficPoller();
    publishVpnStatus(\x60connected:\x24{node.name}\x60, true, pendingId);`, `    publishVpnStatus(\x60connected:\x24{node.name}\x60, true, pendingId);
    this.startNotificationTrafficPoller();
    void this.showConnectedNotification(node.name, -1);`);
  return text;
});
console.log('Restored command/event state chain and removed file/log status experiments.');
