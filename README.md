# ReedBox

HarmonyOS NEXT 上的 sing-box 客户端。内核是 sing-box 的 c-shared 库，在 `VpnExtensionAbility` 里进程内加载。

界面和交互参考 NekoBoxForAndroid；订阅只贡献节点，Clash 的 `proxy-groups` / `rules` 不导入，路由自己在「路由」页配。

支持的协议：Shadowsocks、VMess、VLESS、Trojan、Hysteria2、TUIC、WireGuard、SOCKS、HTTP、SSH、ShadowTLS、AnyTLS、Snell，另有链式代理。

## 构建

```bash
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物在 `entry/build/default/outputs/default/entry-default-unsigned.hap`（未签名，装机需自己在 DevEco 里配签名）。

## 说明

- 内核与协议解析沿用 [sing-box](https://github.com/SagerNet/sing-box) 与 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)，GPL-3.0。
- 目前只有手机/平板一套界面，`compatibleSdkVersion` 6.1.1(24)。
