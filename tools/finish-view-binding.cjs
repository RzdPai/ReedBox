const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..', 'entry', 'src', 'main', 'ets', 'ui', 'neko');
function once(text, oldText, newText) {
  if (text.split(oldText).length !== 2) throw new Error(`Nonunique anchor: ${oldText.slice(0, 90)}`);
  return text.replace(oldText, newText);
}
function edit(fileName, fn) {
  const file = path.join(root, fileName);
  const before = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  fs.writeFileSync(file, fn(before), 'utf8');
}
edit('ProfilesPage.ets', text => {
  text = text.replaceAll('this.snapUp', 'this.runtimeView.up')
    .replaceAll('this.snapDown', 'this.runtimeView.down')
    .replaceAll('this.snapNodeName', 'this.runtimeView.nodeName');
  text = once(text, "Text(this.app.vpnRunning ? `${this.app.statusText()} · 点击可断开` : '点击右下开关连接')", 'Text(this.runtimeView.hint)');
  text = text.replaceAll('this.app.vpnRunning ? Theme.OK : Theme.TEXT_3', 'this.runtimeView.tint');
  text = once(text, '.backgroundColor(this.app.vpnRunning ? Theme.OK : Theme.BRAND)', '.backgroundColor(this.runtimeView.buttonColor)\n      .enabled(!this.runtimeView.busy)');
  text = once(text, `        hilog.info(DOMAIN, TAG, 'connect tap running=%{public}s', \x60\x24{this.app.vpnRunning}\x60);
        this.app.toggleConnection().catch((e: Error) => {
          this.toast(\x60操作失败：\x24{e.message}\x60);
        });`, '        this.toggleVpn();');
  text = once(text, "Text(this.snapRunning ? '已连接' : '未连接')", 'Text(this.runtimeView.text)');
  text = once(text, `  private refreshFromBar(): void {
    if (this.app.vpnRunning) {
      const target: Profile | undefined = this.current();
      if (target !== undefined) {
        this.app.reconnect().catch((e: Error) => {
          this.toast(\x60重连失败：\x24{e.message}\x60);
        });
        return;
      }
    }
    this.app.reloadData().then(() => {
      this.toast('已重新载入');
    }).catch((e: Error) => {
      this.toast(\x60载入失败：\x24{e.message}\x60);
    });
  }`, `  private async refreshFromBar(): Promise<void> {
    if (!this.beginCommand(this.runtime.vpnRunning ? 'switching' : 'reloading')) {
      return;
    }
    try {
      if (this.runtime.vpnRunning) {
        await this.app.reconnect();
      } else {
        await this.app.reloadData();
        this.toast('已重新载入');
      }
    } catch (e) {
      this.toast(\x60操作失败：\x24{(e as Error).message}\x60);
    } finally {
      this.endCommand();
    }
  }`);
  const lifecycleStart = text.indexOf('  aboutToAppear(): void {');
  const lifecycleEnd = text.indexOf('  build() {', lifecycleStart);
  if (lifecycleStart < 0 || lifecycleEnd < 0) throw new Error('Lifecycle missing');
  text = text.slice(0, lifecycleStart) + `  aboutToAppear(): void {
    if (!this.stateSubscribed) {
      this.app.subscribe(this.onBusinessChanged);
      this.runtime.subscribe(this.onRuntimeChanged);
      this.stateSubscribed = true;
    }
    this.syncBusinessView();
  }

  aboutToDisappear(): void {
    this.app.unsubscribe(this.onBusinessChanged);
    this.runtime.unsubscribe(this.onRuntimeChanged);
    this.stateSubscribed = false;
  }

  private onBusinessChanged = (): void => {
    this.syncBusinessView();
  };

  private onRuntimeChanged = (): void => {
    this.syncRuntimeView();
  };

` + text.slice(lifecycleEnd);
  text = once(text, "subtitle: this.snapProfileCount === 0 ? '还没有配置' : this.snapProfileCount + ' 个配置 · ' + this.snapGroupCount + ' 个分组',", "subtitle: this.profileCount === 0 ? '还没有配置' : `${this.profileCount} 个配置 · ${this.groupCount} 个分组`,");
  text = once(text, 'if (this.app.groups.length > 0) {', 'if (this.groupCount > 0) {');
  text = once(text, 'items: this.groupLabels(),', 'items: this.groupItems,');
  text = once(text, '            this.groupIndex = index;', '            this.selectGroup(index);');
  text = once(text, "\n            this.query = '';\n", "\n            this.setQuery('');\n");
  text = once(text, '              this.query = v;', '              this.setQuery(v);');
  text = once(text, "                this.query = '';", "                this.setQuery('');");
  text = once(text, `        if (this.selectedGroup() !== undefined) {
          ListItem() {
            this.subscriptionCard(this.selectedGroup() as ProfileGroup)
          }
        }`, `        if (this.subscriptionView.groupId.length > 0) {
          ListItem() {
            this.subscriptionCard()
          }
        }`);
  text = once(text, 'if (this.visibleProfiles.length === 0) {', 'if (this.visibleCount === 0) {');
  text = text.replaceAll('this.app.profiles.length === 0', 'this.profileCount === 0');
  const listStart = text.indexOf('          ForEach(this.visibleProfiles,');
  const listEnd = text.indexOf('\n        }\n        ListItem()', listStart);
  if (listStart < 0 || listEnd < 0) throw new Error('Profile list missing');
  text = text.slice(0, listStart) + `          LazyForEach(this.profileSource, (row: ProfileRowModel) => {
            ListItem() {
              ProfileCard({
                row: row,
                onSelect: (profile: Profile): void => { this.selectProfile(profile); },
                onEdit: (profile: Profile): void => { gotoProfileEdit(this.pathStack, profile.id); },
                onShare: (profile: Profile): void => { this.openShareMenu(profile); },
                onRemove: (profile: Profile): void => { this.removeProfile(profile); },
                onMore: (profile: Profile): void => { this.openRowMenu(profile); }
              })
            }
            .swipeAction({ end: this.swipeDelete(row.currentProfile()), edgeEffect: SwipeEdgeEffect.Spring })
          }, (row: ProfileRowModel): string => row.profileId)` + text.slice(listEnd);
  text = once(text, '  private subscriptionCard(g: ProfileGroup) {', '  private subscriptionCard() {');
  // Change only the subscription card body, not helper method parameters.
  const cardStart = text.indexOf('  private subscriptionCard()');
  const cardEnd = text.indexOf('  private expireTextOf(', cardStart);
  let card = text.slice(cardStart, cardEnd);
  card = card.replaceAll('Text(g.name)', 'Text(this.subscriptionView.name)')
    .replaceAll('this.expireTextOf(g)', 'this.subscriptionView.expiry')
    .replaceAll('this.trafficTextOf(g)', 'this.subscriptionView.traffic')
    .replaceAll('this.app.groupNodeCount(g.id)', 'this.subscriptionView.count')
    .replaceAll('this.updatedTextOf(g)', 'this.subscriptionView.updated')
    .replaceAll('g.lastError', 'this.subscriptionView.lastError');
  text = text.slice(0, cardStart) + card + text.slice(cardEnd);
  text = text.replaceAll('const list: Array<Profile> = this.visibleProfiles;', 'const list: Array<Profile> = this.profileSource.profiles();');
  text = once(text, ".height('100%')\n    .justifyContent(FlexAlign.Center)", ".height(80)\n    .justifyContent(FlexAlign.Center)");
  return text;
});
edit('GroupsPage.ets', text => {
  text = once(text, '      PageHeader({\n        subtitle:', "      PageHeader({\n        title: '分组',\n        subtitle:");
  text = once(text, 'subtitle: (this.tick >= 0 ? `` : ``) + `${this.app.groups.length} 个分组 · ${this.app.subs.length} 个订阅`,', 'subtitle: `${this.groupRows.length} 个分组 · ${this.subscriptionCount} 个订阅`,');
  text = once(text, 'if (this.app.groups.length === 0) {', 'if (this.groupRows.length === 0) {');
  text = once(text, 'ForEach(this.app.groups, (g: ProfileGroup)', 'ForEach(this.groupRows, (g: ProfileGroup)');
  text = once(text, "if (this.app.profilesOfGroup('').length > 0) {", 'if (this.ungroupedCount > 0) {');
  text = once(text, "Text(`${this.app.profilesOfGroup('').length} 个`)", 'Text(`${this.ungroupedCount} 个`)');
  return text;
});
console.log('Completed event-driven page and list bindings.');
