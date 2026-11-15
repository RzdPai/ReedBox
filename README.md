# NekoBox for HarmonyOS（NekoBox-Ohos）

HarmonyOS NEXT 原生 sing-box 客户端，功能对齐 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)。
内核是 **sing-box 1.14.0 的 c-shared `.so`，进程内 `dlopen`**（沙箱禁止 exec），TUN fd 直接从
`VpnExtensionAbility` 交给内核。

- bundleName `com.rzdpai.nekobox`，versionName `0.2.1`（versionCode 200001）
- compatible / targetSdkVersion `6.1.1(24)`，deviceTypes `phone` / `tablet`
- 状态管理 **全 V2**（`@ComponentV2` / `@Local` / `@Param` / `@Event` / `@Monitor` / `@ObservedV2` / `@Trace`）
- 路由 **只走 Navigation + NavPathStack**（全工程 `@ohos.router` 零命中）
- **当前只有一套界面**（用户 2026-11-01 定：先把一套做好，之后再拆皮肤）

## 信息结构（对齐 NekoBoxForAndroid / OwnBox，**不是** Clash 系）

```
☰ 配置项  ⋮                        ← 首页就是"一堆节点"，点一个就选中/连接
  全部 | 机场A(26) | 未分组(3)      ← 分组胶囊；分组只是节点的一个属性
  [VL] 香港01   1.2.3.4:443   82ms
  [SS] 日本02   5.6.7.8:8388  145ms
────────────────────────────────
● 未连接                              ( ▶ )   ← 底部状态条 + 圆形开关
```

- **没有"订阅页"**：订阅是**分组的一种类型**。`分组 → ＋ → 类型选「订阅」+ 填地址`，
  这个分组就变成一个机场订阅，更新时节点自动落进本组（`updateSubscription` 的 `SubInfo.group` 机制）。
- 添加节点全部走首页顶栏 **⋮**：`扫描二维码 / 从文本导入 / 从本地导入 / 添加 [VMess|VLESS|Shadowsocks|
  SOCKS|HTTP|Trojan|Wireguard|Hysteria2|TUIC|AnyTLS|Snell] / 添加 [链式代理] / 全部测速 / 更新全部订阅`。
- **链式代理**：编辑页只有两个选择器（前置节点 / 落地节点），保存成 `Profile.chainIds = "<前置>,<落地>"`，
  由 `ConfigBuilder.expandChain()` 展开成 sing-box 的 detour 链；链式节点本身没有 server，TLS/传输段不显示。
- 侧栏（☰ 抽屉）：配置项 / 分组 / 路由 / 设置 / 日志 / 关于。
  前两项在壳里换内容；后四项是压栈的二级页（有返回箭头）。
- 节点行右侧 **⋯**：测速 / 置顶 / 编辑 / 移动到分组 / 复制分享链接 / 删除。

> 订阅里的 `proxy-groups` / `rules` / `proxy-providers` **一律忽略**（解析后只记 warning）。
> 早期版本曾把 Clash 的 `proxy-groups` 落成分组（"节点选择 / 自动选择 / 漏网之鱼"），已改为不导入，
> 并对老数据做一次性清理（`AppState.purgeClashGroupsOnce()`，判据 = 名字白名单 + `isSelector/autoSelect`）。
> 路由只由「路由」页决定（`RouteRule[]` → `ConfigBuilder` 的 `route.rules`）。
> 不要照搬 mihomo 系客户端（ClashBox / FlClash / TunBox）的订阅与配置生成代码 —— 它们"原样落盘 YAML
> 交给内核"，本工程是"解析成节点表再生成 sing-box JSON"，两条链路不同。

## 分层（这是"将来能换皮肤"的前提）

```
entry/src/main/ets/
├── entryability/EntryAbility.ets     窗口 / 主题 / 系统栏 / 后台订阅 / VPN 事件桥
├── vpnext/VpnExtAbility.ets          :vpn 进程：建 TUN → 取 fd → 交内核（与业务无关）
├── core/                             业务层，**零 @Component**
│   ├── AppState.ets                  @ObservedV2 全局状态 + 全部 Action（UI 唯一出入口）
│   │                                  含分组/订阅分组的增删改、导入、测速、连接、设置 patch
│   ├── ConfigBuilder.ets             节点 → sing-box 1.14 配置
│   ├── Subscriptions.ets             订阅拉取 / 识别 / 落库调度（`SubInfo.group` 决定落哪个分组）
│   ├── CoreManager.ets               写配置、起停内核、URL 测速（NAPI 封装）
│   ├── VpnService.ets                启停 / 切换节点（串行化 + 看门狗）
│   └── VpnIpc.ets                    :vpn → UI 的 CommonEvent（日志 / 状态 / 流量）
├── model/  Profile.ets（Profile / ProfileGroup(type,url,autoUpdate,lastError) / AppSettings）· Store.ets · RouteRule.ets
├── utils/  LinkParser(13 协议) · Subscription(UA 链/ClashYAML/sing-box JSON) · ClashYaml · LatencyTester · …
├── ui/
│   ├── CommonUi.ets                  PageHeader / 沉浸光感菜单 HdsMenu / 点光 / 卡片 / 选择面板
│   ├── Metrics.ets                   系统栏实测（statusBar / 供压栈页用的 topInset）
│   ├── Theme.ets · Format.ets · Routes.ets
│   ├── neko/ProfilesPage.ets         ★ 首页（配置项）：节点列表 + 底部状态条 + ⋮ 导入菜单(扫码/文本/文件/添加[协议])
│   ├── neko/GroupsPage.ets           ★ 分组页：基础分组 / 订阅分组（类型选订阅）+ 更新 + 自动更新
│   ├── neko/RouteTab.ets             路由（模式 + 规则增删）
│   ├── neko/SettingsTab.ets          设置（内核/DNS/测速/外观/Geo/备份/日志/关于入口）
│   ├── neko/ProfileEditPage.ets      节点编辑（13 协议字段按协议显隐，支持"添加 [协议]"预设）
│   └── neko/LogsPage.ets · AboutPage.ets
└── pages/Bootstrap.ets               ★ 外壳：HdsNavigation(hideTitleBar) + ☰ 抽屉 + 分区切换
```

**纪律**：`core/ model/ utils/ vpnext/` 里不许出现 `@Component` / `@State` 这类 UI 代码；
UI 只读 `AppState` 的 `@Trace` 字段、只调 `AppState` 的方法。

## 页头与让位（本轮定案）

海量返工都来自"框架标题栏的几何不可控"，所以本工程：

1. **壳层不挂 HDS 标题栏**：`HdsNavigation(pathStack).hideTitleBar(true)`，只借它的 `navDestination` 路由；
   页头用 `CommonUi.PageHeader` 自绘（`☰ + 标题 + ⋮`），**在流内**，几何 100% 可控。
2. 因此页头下面的列表**不需要**任何"顶部让位魔法"（上一代为此反复了 5 轮）。
3. 压栈的二级页（路由/设置/日志/关于/节点编辑）仍用 HDS 标题栏：
   `hdsPageBar(title, level, actions, stack, showBack=true, immersive=false)` + 内容首个 ListItem
   `padding({top: Metrics.topInset})`（= 状态栏 + 56 ≈ 94）。
4. 抽屉是壳层 `Stack` 的兄弟层 + `expandSafeArea(TOP,BOTTOM)`，所以能盖住状态栏。

## 刷新机制（别改回细粒度通知）

甲方明确反馈过"改了设置后界面不刷新、要重启"。三道保险：

1. `AppState.rev`（`@Trace`）+ `bump()`：**每个写方法末尾都 bump**。
2. 列表页 `@Computed` 读状态 + `ForEach`（key 里带 `app.rev`）；**不用自定义 IDataSource + 手动 notify**。
3. 设置项"存了 ≠ 生效"：深浅色改完立刻 `UIAbilityContext.setColorMode()`。

> 代价：`ForEach` 一次性建视图，几千节点的大机场会卡。真到那步再换 LazyForEach，
> 但必须上机验收"导入/改设置后立刻刷新"。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1            # 默认 product=default
# 产物：entry\build\default\outputs\default\entry-default-unsigned.hap
```

手工命令与坑（**必须用 `hvigorw.bat`**，它把自带 node 24 放进 PATH；product 必须叫 `default`）：

```powershell
$env:DEVECO_SDK_HOME  = 'D:\command-line-tools\sdk'
$env:JAVA_HOME        = 'C:\Users\Administrator\Tools\jdk\jdk-17.0.2'
$env:PATH             = "$env:JAVA_HOME\bin;C:\Program Files\nodejs;$env:PATH"
$env:HVIGOR_USER_HOME = 'C:\Users\Administrator\Desktop\RzdProject\.buildcache\hvigor'
& 'D:\command-line-tools\bin\hvigorw.bat' --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

## 签名 / 安装

本机**没有** `com.rzdpai.nekobox` 的证书材料，仓库是无签名基线（`signingConfigs: []`），命令行只产出未签名 HAP。
装机走 DevEco 的自动签名（File → Project Structure → Signing Configs，需登录华为账号），
或 AGC 证书 + `hap-sign-tool`。**内核只有 arm64 产物 ⇒ 只能 arm64 真机，模拟器跑不了。**

## 内核

`entry/libs/arm64-v8a/libsingbox.so`（35.7 MB，sing-box 1.14.0 + OpenHarmony 补丁，冻结产物）与
`core/sing-box-1.14/`（含补丁源码）随仓库分发，克隆即可构建，不需要 Go 工具链。
CGo 导出契约：`CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion` + `CGoTest*`（URL 测速）；
NAPI 侧按 V2 优先、legacy 回退解析 —— **将来给导出加参数一律加 `*V2` 后缀，不要原地改签名**。

## 已知边界 / 待办

- **未上机验证**：`hdc list targets` 为空，当前只有**源码级 + 编译级 + 产物级**证据。
- 二级页（路由/设置/日志/关于）是从抽屉推进去的，页内**没有 ☰**（有返回箭头）；要不要让它们也出 ☰ 待定。
- 连接统计（yacd / 活动连接）、远程规则集管理、分应用代理界面尚未接（`utils/ClashApi.ets`、
  `utils/WebUiAssets.ets`、`RemoteRuleSet` 模型已就绪）。
- 应用图标仍是上游的 `layered_image`。
- 第二套皮肤：等这套稳定后再按"加 product + `buildProfileFields`"的方式加，不要复制 sourceRoots。
