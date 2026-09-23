# PLUGIN_ROUTE_INVENTORY — `onPluginEvent` 内联分支 → 命名方法 + `PluginEventBus` 注册清单

> 2026-09-23 由 Omp 产出（阶段 2 步骤 4 的**清单**部分；CodeArts MSG61 §3「授权先出清单不落码」）。
> 现状：`Index.ets` 的 `onPluginEvent(deviceId, ev)` 是一条 **7 分支 if-else 长链** + 1 条隐式兜底（其余 kind 只记一行日志）。
> 目标：分支抽成**命名方法**，装配期一次性注册进 `PluginEventBus`；兜底交给 `bus.setFallback(...)`（保持"绝不静默丢弃"）。

## 1. 清单（按现有 if-else 顺序）

| # | kind | 建议命名方法 | 现有行为（必须逐字保持） | 依赖的页面状态 |
|---|---|---|---|---|
| 1 | `runcommand.list` | `onRunCommandList(deviceId, ev)` | `runCommandDeviceId = deviceId`；`runCommands = commandsOf(deviceId)`；日志 `run command list <- id` | `runCommandDeviceId`、`runCommands` |
| 2 | `runcommand.output` | `onRunCommandOutput(deviceId, ev)` | 读 `ev.runOutput`；`undefined` 直接返回；toast「成功/失败 (exit=code): text」；日志 | —（toast 出口 `toastText`） |
| 3 | `clipboard.request` | `onClipboardRequest(deviceId, ev)` | toast「对端索取剪贴板，请点粘贴授权发送」；日志 | — |
| 4 | `mpris.playerList` | `onMprisPlayerList(deviceId, ev)` | `setMprisList(deviceId, ev.mprisList ?? [])` | MPRIS 镜像 |
| 5 | `mpris.playerUpdate` | `onMprisPlayerUpdate(deviceId, ev)` | `ev.mprisSnap` 非空 ⇒ `setMprisSnapshot(deviceId, snap)` | MPRIS 镜像 |
| 6 | `systemvolume.sinks` | `onSystemVolumeSinks(deviceId, ev)` | **单槽过滤**（用户 2026-09-19 裁决 / CodeArts MSG21 §3：只接受当前面板设备的推送，否则会刷空正在看的面板）⇒ 通过后 `svSinks = ev.svSinks ?? []` | `svSinks`、当前面板设备 |
| 7 | `battery` | `onBattery(deviceId, ev)` | 读 `ev.battery`；`undefined` 返回；`text = "{charge}%{⚡?}"`；按 deviceId 替换/追加 `batteryItems`；日志 | `batteryItems` |
| — | **兜底**（其他 kind） | `bus.setFallback((id, ev) => this.log(\`plugin event ${ev.kind} from ${id}\`))` | 只记日志、**绝不静默丢弃**（与 `PluginEventBus` 的默认兜底语义一致） | — |

## 2. 装配方式（实现时照此）
```ts
// 装配期（与 pairSession 回调注入同一处，router/pluginHost 就绪之后）
this.eventBus.setLog((m: string): void => { this.log(m); });
this.eventBus.setFallback((id: string, ev: PluginEvent): void => {
  this.log(`plugin event ${ev.kind} from ${id}`);     // 与现有隐式兜底逐字一致
});
this.eventBus.on('runcommand.list',     (id, ev) => this.onRunCommandList(id, ev));
this.eventBus.on('runcommand.output',   (id, ev) => this.onRunCommandOutput(id, ev));
this.eventBus.on('clipboard.request',   (id, ev) => this.onClipboardRequest(id, ev));
this.eventBus.on('mpris.playerList',    (id, ev) => this.onMprisPlayerList(id, ev));
this.eventBus.on('mpris.playerUpdate',  (id, ev) => this.onMprisPlayerUpdate(id, ev));
this.eventBus.on('systemvolume.sinks',  (id, ev) => this.onSystemVolumeSinks(id, ev));
this.eventBus.on('battery',             (id, ev) => this.onBattery(id, ev));
// 唯一入口退化为一行
private onPluginEvent(deviceId: string, ev: PluginEvent): void {
  this.eventBus.dispatch(deviceId, ev);
}
```
=> `onPluginEvent` 由 81 行缩到 3 行；页面其余逻辑零改动。

## 3. 必须保持的不变量（CodeArts MSG61 §2）
1. **`systemvolume.sinks` 的单槽过滤**不能在抽取时丢失（第 6 行"依赖的页面状态"里有说明）；
2. **`mpris` 既有裁决（`canClaim` 等）不在本次范围**（本次只做搬运，不改语义）；
3. 兜底**绝不静默丢弃**（现为记日志 ⇒ 由 `setFallback` 承接）；
4. `paired` 单一写者不变量与本次无关（本清单不触碰配对路径）。

## 4. 插件实际发出的 kind（交叉核对用）
`grep -rhoE "kind: '[A-Za-z.]+'" plugins/*.ets state/*.ets` 得：
`battery`、`mpris.playerList`、`mpris.playerUpdate`、`runcommand.output`、`systemvolume.sinks`。
其中 `runcommand.list` 与 `clipboard.request` 不在此列（它们由非字面量方式构造）——但页面**确实**处理它们 ⇒ 实现时不得漏掉这两条路由（这正是本清单的价值：把"隐式支持的 kind"显式化）。

## 5. 风险与验收
- **风险**：抽取过程中漏掉某条分支 ⇒ 该 kind 落到兜底（只记日志）=> 表现为**功能静默失效**（例如对端索取剪贴板不再提示）。
  `PluginEventBus.kinds()` 可作装配自检：启动后日志打一次 `kinds()`（7 条）即可发现漏注册。
- **验收**：`assembleHap` BUILD SUCCESSFUL；`kinds()` 输出恰为 7 条；真机回归覆盖 runcommand / clipboard / mpris / systemvolume / battery 五条链路。
- **归属**：按用户裁定（阶段 2 步骤 4 归 Omp）；本文件仅为清单，**未改任何代码**。

— Omp，2026-09-23
