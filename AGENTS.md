# NekoBox-Ohos · AI Agent 交接说明

> 读这一篇就够了；机器级底座（工具链 / 构建 / WebDAV / MCP）在
> `C:\Users\Administrator\Desktop\RzdProject\全局记忆.md`，项目现状在
> `C:\Users\Administrator\Desktop\RzdProject\NekoBox-Ohos记忆.md`。

## 这是什么

HarmonyOS NEXT 的 sing-box 客户端（对齐 NekoBoxForAndroid）。内核 = sing-box 1.14.0 的
c-shared `.so`，进程内 `dlopen`，TUN fd 由 `VpnExtensionAbility` 直接交给内核。

- bundleName **`com.rzdpai.nekobox`**（versionName 0.1.0 / versionCode 100000）
- compatible/target **6.1.1(24)**，deviceTypes phone/tablet
- 状态管理**全 V2**、路由**只走 Navigation**、UI 组件优先 HDS —— 这三条是硬规则，别回退。

## 必须守住的边界

1. `entry/src/main/ets/{core,model,utils,vpnext}/` 里**不许出现任何 UI 代码**
   （`@Component*` / `@State` / 布局 DSL）。两套皮肤（`ui/neko`、`ui/modern`）靠这条共存。
2. `module.json5` 的 VPN 扩展 `"type": "vpn"` 不要改（本 SDK 合法值就是它）。
3. `entry/libs/arm64-v8a/libsingbox.so` 是**冻结内核产物**，不是构建产物：
   别往 `.gitignore` 里加，也别指望 assembleHap 会重新生成它。
4. CGo 导出**不要原地改签名**：要加参数就加 `*V2` 导出 + NAPI 侧 `dlsym` 回退
   （旧 `.so` + 新 NAPI 的组合会读到野指针直接崩）。
5. 订阅里的 `proxy-groups` / `rules` **永远不下发内核**；不要抄 mihomo 系（ClashBox/FlClash/TunBox）
   的订阅与配置生成代码，语义不同。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1 -Product default   # neko 皮肤
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1 -Product modern    # modern 皮肤
```

- **必须用 `D:\command-line-tools\bin\hvigorw.bat`**（它把自带 node 24 放进 PATH）。
  系统 `node hvigorw.js` 会 `MODULE_NOT_FOUND: @ohos/hvigor-ohos-plugin`。
- product 名必须是 `default`（hvigor 硬性要求有一个叫 default 的 product）+ `modern`。
- 产物在 `entry/build/<product>/outputs/default/`；拷进 `dist/` 时按产品名分开放。
- 仓库无签名配置，只能出未签名 HAP；要装机走 DevEco 自动签名（或 AGC 证书 + `hap-sign-tool`）。

## 排查

- 应用日志：`hilog | grep NekoBox-`（TAG 见各文件头：`NekoBox-Shell/Home/Nodes/Subs/Route/Settings/State/Metrics`）
- 内核日志：`<filesDir>/core/singbox.log`（「设置 → 运行日志」页可直接看尾部）
- 打开页面就白屏：先看 `NekoBox-State` 有没有"初始化失败"，再看 `NekoBox-Metrics` 的 insets 是否量到
- 常见坑清单见 `C:\Users\Administrator\Desktop\RzdProject\NekoBox-Ohos记忆.md` 的「坑」一节
