# NekoBox-Ohos 连接期间发热排查报告

- 工程：`NekoBox-Ohos`（bundleName `com.rzdpai.nekobox`，versionName 0.5.57 / versionCode 500057）
- 内核：sing-box 1.14.0 c-shared `.so`（`entry/libs/arm64-v8a/libsingbox.so`，35,688,144 B，
  sha256 `9B2B983973281FB855D1993BF7895594D7EB40F2956A957160CC34D45B788D49`，冻结产物）
- 触发反馈：连接时手机发热严重；用户所用节点协议为 **Hysteria2（hy2）**，但是否为 HY2 专属问题未知
- 报告时间：2026-11-01
- **验证等级：源码级（静态阅读 + 逐行定位）。本轮没有设备、没有用户日志、没有耗电/温度采样，
  因此不宣称"已定位根因"，也不宣称"已修复"。**

---

## 1. 结论摘要

1. 连接建立后，**应用侧存在一条默认开启的 1 秒周期任务**：向本机 Clash API 拉 `/connections`，
   差分算速率、跨进程广播流量、并重发常驻通知。它是本工程里唯一在"连接期间"持续运行的定时器。
2. 该任务**有条件**：设置里 `clashApiEnabled=false`（关闭 Clash API）时根本不启动；
   隧道断开/扩展销毁时会停止。所以"发热是否随它变化"是一次干净的对照实验。
3. 该轮询**可能重叠**：周期默认 1000ms，但单次 HTTP 连接/读取超时各 1500ms，且 `setInterval`
   不等待上一次完成。接口变慢时会出现并发请求，成功返回的每轮还会再触发事件与通知更新。
4. 内核默认以 `info` 级别把日志写入文件；HY2 出站**按"新建连接"**记一条 info，
   **不是逐包日志**。大量短连接 / 高 UDP 速率时日志量会显著上升，空闲时不应夸大成主因。
5. HY2 出站的上下行带宽默认值是 **100 / 100 Mbps**，会进入 sing-box 的 `up_mbps` / `down_mbps`。
   这是协议侧带宽配置，不等于设备一直在跑 100Mbps，也不能单凭该数值断言耗电。
6. **QUIC/HY2 数据面本身的 CPU 成本无法在本仓库内证明**：完整 `sing-quic` 依赖源码不在工程副本中，
   内核又是冻结 `.so`。这部分只能靠真机采样判断。
7. 已排除：连接成功后周期重建 VPN、周期测速、周期重建配置；`urltest` 只在**分组启用 autoSelect**
   时生成（间隔 10 分钟），不是普通节点的默认行为。

**优先级建议**：先做"Clash API 开/关"与"日志级别 info/warn"两个对照实验，再做 HY2 与 TCP 型节点的
同条件对比。**不要先改协议参数或统一压低带宽**——那会同时改变性能与温度，无法归因。

---

## 2. 应用侧持续负载（可证）

### 2.1 每秒一次的流量/通知轮询

| 位置 | 内容 |
|---|---|
| `entry/src/main/ets/model/Profile.ets:213` | `speedIntervalMs: number = 1000` |
| `entry/src/main/ets/model/Profile.ets:231` | `clashApiEnabled: boolean = true`（默认开） |
| `entry/src/main/ets/vpnext/VpnExtAbility.ets:605` | 内核启动成功后 `startNotificationTrafficPoller()` |
| `entry/src/main/ets/vpnext/VpnExtAbility.ets:610-652` | 轮询实现 |
| `entry/src/main/ets/utils/TrafficStats.ets:14-40` | 每轮新建 HTTP 客户端、GET `/connections`、解析、销毁 |

单轮做的工作：

1. `http.createHttp()` 新建客户端；
2. GET `http://127.0.0.1:<clashApiPort>/connections`（连接超时 1500ms / 读取超时 1500ms）；
3. `JSON.parse` 整个响应（**响应体大小随活动连接数增长**）；
4. 差分算 `upSpeed` / `downSpeed`；
5. `publishVpnTraffic(...)` 跨进程公共事件 + 本地 `VpnRuntime` 镜像写入；
6. `showConnectedNotification(...)` 重发常驻通知（内部还会 `wantAgent.getWantAgent` 与资源读取）。

条件与生命周期：

- 关闭 Clash API（`clashApiEnabled=false`）⇒ `startNotificationTrafficPoller()` 直接 return，**不启动**；
- `onDisconnect` / `onDestroy` / `teardown` / 启动失败分支都会调用 `stopNotificationTrafficPoller()`；
- 取消用的是 `generation` 代号 + `clearInterval`，代码层面不会残留定时器。

### 2.2 轮询重叠风险（同一处的第二个问题）

```
周期 = speedIntervalMs（默认 1000ms，允许 500~10000ms）
单次请求超时 = 1500ms（连接 + 读取各 1500ms）
=> 若服务端/回环变慢，第 N 轮未结束，第 N+1 轮已经发出
```

代码里没有"上一轮未完成则跳过"的开关（没有 in-flight 标记）。这是一个**代码可证**的竞态，
但实际是否发生要看真机请求耗时；命中时的表现是 CPU/唤醒更密、通知刷新更频繁。

### 2.3 内核日志

| 位置 | 内容 |
|---|---|
| `entry/src/main/ets/model/Profile.ets:192` | `logLevel: string = 'info'`（默认） |
| `entry/src/main/ets/core/ConfigBuilder.ets:1246-1252` | 写 `log.level` / `log.output`（文件） |
| `core/sing-box-1.14/protocol/hysteria2/outbound.go:185-204` | HY2 出站每次 Dial/ListenPacket 记一条 `info` |

要点：

- 是**按连接**记，不是逐包记；
- 但"每个 UDP 目标一个 packet connection"时，UDP 业务（视频、游戏、大量 DNS）会产生较多行；
- 日志写文件本身有 I/O 成本，量级取决于连接/流数量，而不是取决于带宽；
- 日志页的 2 秒轮询**只在日志页面存在时**运行，并且会 `clearInterval`（`ui/neko/LogsPage.ets:42-53`），
  不是后台常驻定时器。

### 2.4 HY2 带宽字段

| 位置 | 内容 |
|---|---|
| `entry/src/main/ets/model/Profile.ets:69-70` | `upMbps = 100` / `downMbps = 100` |
| `entry/src/main/ets/ui/neko/ProfileEditPage.ets:62-63,435-436` | 表单默认 100，保存时兜底 100 |
| `entry/src/main/ets/core/ConfigBuilder.ets:217-239` | `>0` 才写入 `up_mbps` / `down_mbps` |
| `core/sing-box-1.14/protocol/hysteria2/outbound.go:125-155` | 传给 `hysteria2.ClientOptions.SendBPS/ReceiveBPS` |

补充事实：

- 分享链接里带 `up` / `down` / `upmbps` / `downmbps` 时，`utils/LinkParser.ets:465-468` 会解析成这两个字段；
- Clash YAML 里的 `up` / `down`（可能是 `"30 Mbps"`）由 `utils/Subscription.ets:488-492` 的
  `parseBandwidth()` 取整数部分；
- 因此"用户实际生效的带宽值"要以节点记录为准，不能假设就是 100。

---

## 3. 已排除 / 不成立的怀疑

| 怀疑 | 结论 | 依据 |
|---|---|---|
| 连接后有隐藏的周期轮询在跑 | 只有上面那条 Clash API 轮询（可关闭） | 全仓库 `setInterval(` 仅 2 处：`VpnExtAbility.ets:651`、`LogsPage.ets:42` |
| 日志页在后台持续读文件 | 不成立：页面 `aboutToDisappear` 清理定时器 | `ui/neko/LogsPage.ets:47-53` |
| 连接后周期重建 VPN / 重连 | 不成立：仅网络变化/回前台时按开关触发 | `VpnExtAbility.ets:152-190,260-281` |
| 内核在做周期测速 | 默认不成立：`urltest` 只在分组 `autoSelect` 时生成，`interval: '10m'` | `core/ConfigBuilder.ets:861-873` |
| 内核逐包写日志 | 不成立：HY2 出站按连接建立记录 | `hysteria2/outbound.go:185-204` |

---

## 4. 仍需真机验证的部分

1. **HY2 数据面成本**：QUIC/UDP/TLS 在持续吞吐、丢包重传、端口跳跃（`server_ports` + `hop_interval`）
   下的 CPU 表现。仓库不含完整 `sing-quic` 源码，内核为冻结 `.so`，静态阅读无法定量。
2. **轮询实际开销**：`/connections` 的响应体大小与请求耗时（连接数多时显著增长），
   以及是否出现 2.2 描述的并发重叠。
3. **日志写入量**：单位时间内 `singbox.log` 的增长字节数与连接/流数量的关系。
4. **用户侧配置**：实际节点的 `up/down`、是否开启端口跳跃及其间隔、是否有大流量 UDP 业务。

---

## 5. 建议的验证步骤（给后续改动者）

### 实验 A：分离应用轮询成本

同一手机、同一 HY2 节点、相近网络与前后台状态，分别测：

| 组 | 设置 |
|---|---|
| A1 | Clash API 开（默认），速率刷新 1000ms |
| A2 | Clash API 关（不启动轮询） |
| A3 | Clash API 开，速率刷新调到 5000~10000ms |

记录：扩展进程 CPU 占用、机身温度、待机耗电、`/connections` 请求耗时与响应大小。
若 A2/A3 明显低于 A1，则应用侧轮询是有意义的优化点。

### 实验 B：分离日志成本

同一连接，`logLevel` 分别 `info` 与 `warn`，记录 `singbox.log` 增长量与 CPU/温升。
若高流量但**连接数很少**且日志增长很小，则不应把文件 I/O 当主要根因。

### 实验 C：协议公平对比

同一服务器、**相同的实际吞吐**、相近流量模式与信号条件，对比 HY2 与 TCP 型（如 VLESS/Trojan）节点。
必须同时记录：传输字节数、屏幕亮灭、前后台时长、蜂窝/Wi-Fi、信号强度。
否则"HY2 更热"可能只是它跑出了更高吞吐。

### 排查命令（真机）

```bash
# 应用日志：状态与轮询相关
hdc shell hilog | grep -E "NekoBox-(State|Nodes|Logs)"

# 扩展进程是否在持续工作（PID 为 :vpn 进程）
hdc shell "ps -ef | grep com.rzdpai.nekobox"
hdc shell "top -H -p <pid>"        # 观察线程级 CPU

# 内核日志体量与增长
hdc shell "ls -l /data/app/el2/100/base/com.rzdpai.nekobox/haps/entry/files/core/"
```

---

## 6. 结论边界（重要）

- 本次只做**静态源码检查**，没有修改任何代码，没有构建，没有上传产物，没有真机复现。
- 文中"代码可证"的部分（轮询存在、可关闭、可能重叠、日志按连接记录、带宽字段传递路径）
  都有明确的行号依据；"待验证"的部分（HY2 数据面开销、轮询实际成本、日志量级）**没有**给出结论。
- 任何后续改动都应先完成第 5 节的对照实验，再决定改哪里；避免用"降带宽/换协议"这类
  同时改变性能与温度的手段去掩盖问题。

---

## 7. 外部参考（仅用于核对字段含义）

- sing-box `up_mbps` / `down_mbps` 字段说明（TCP Brutal 章节，用于确认字段语义）：
  <https://raw.githubusercontent.com/SagerNet/sing-box/refs/tags/v1.14.0/docs/configuration/shared/tcp-brutal.md>

> 说明：该文档是字段定义的旁证，**不是**本次发热问题的诊断证据，不能据此推导某台设备的温度或吞吐。
