# DESIGN_BATCH2_deveco — 阶段3 批次2 接口设计（6a MPRIS / 6b Payload）

> 2026-09-26。作者 DevEco。依据 CodeArts MSG62（批次2 = 6a ~599 行 / 6b ~814 行）与 Omp MSG68 §6（"先出接口设计，替换由 Omp 执行"）。
> 设计范式**对齐 `PairSession`**（MSG62 §5）：Controller 持领域状态 + 注入回调；Dialog 用 `@Prop` + 回调。

## 0. 设计原则（与前三步一致，避免半成品/双真相）

1. **单一归属**：每块领域状态只有一个 owner（Controller），页面只持有 Controller 实例本身；
2. **状态与副作用分离**：Controller 不直接调 `getUIContext()`/picker/native，全部走注入；
3. **可观测**：Controller 用 `@Observed`，页面 `@State` 持实例，Dialog 用 `@ObjectLink`/`@Prop` 读；
4. **不变量不动**：`paired` 单写者、会话三信号、`systemvolume.sinks` 单槽过滤、MPRIS `canClaim`、`runCommand()` 留页面；
5. **行为保持**：只搬不改语义；每搬一个文件 `devecocli build`。

## 1. 6a — `state/MprisController.ets` + `components/MprisDialog.ets`

### 1.1 状态（自 Index 迁入）
```
@Observed class MprisController {
  items: MprisItem[] = [];        // 原 @State mprisItems（按设备镜像对端播放器状态）
  deviceId: string = '';          // 原 @State mprisDeviceId
  dialogOpen: boolean = false;    // 原 @State mprisDialogOpen（"打开面板"属领域动作）
  tab: number = 0;                // 原 @State mprisTab（媒体/设备）
  svSinks: SystemSinkUi[] = [];   // 原 @State svSinks（刻度已换算百分比）
  svDeviceId: string = '';        // 原 @State svDeviceId（防切换面板串数据）
}
```
⚠️ `mprisNowMs`/ticker 已随批2 下沉进 `MprisProgress` 组件 ⇒ **不需要**再迁 ✗（保持现状 ✓）。

### 1.2 方法（自 Index 迁入，共 ~23 个）
```
mprisItemOf / putMpris / setMprisList / setMprisSnapshot
mprisSnap / mprisList / mprisEmpty / mprisVol / mprisArtistLine / mprisLoopText
mediaAction / mediaSetVolume / mediaSetPosition / mediaToggleLoop / mediaToggleShuffle
mediaSelectPlayer / mediaRefresh
svSinksForCurrent / svSinkSet / svSinkToggleMute / svSinkSetDefault
```
（保留在页面：`mprisPluginOf`/`sysVolumePluginOf` 若被其它域引用则留页面；否则一并迁入并注入 `pluginsFor` 取用 ✓）

### 1.3 注入（Controller 不碰 I/O / 不在场能力）
```ts
log: (msg: string) => void = () => {};
toast: (msg: string) => void = () => {};
actionGate: (key: string, ms: number) => boolean = () => true;   // 面板开合限频
pluginFor: <T>(deviceId: string, ctor) => T | undefined = ...;    // 取 MprisPlugin / SystemVolumePlugin
requestPlayerList: (deviceId: string) => void = ...;              // 打开面板时的"主动拉一次"
requestSinks: (deviceId: string) => void = ...;
```
> 说明：`MprisProgress` 组件仍通过 props 收 `lengthMs/posMs/posAtMs/isPlaying/canSeek`（**不变** ✓）。

### 1.4 `components/MprisDialog.ets`（原 L2991 起 ~313 行 UI）
```
@ObjectLink mpris: MprisController;      // 直接读领域状态（@Observed ⇒ 字段变化只重建本组件）
onAction: (action: string) => void     // → controller.mediaAction(action)
onSetVolume: (v: number) => void
onSeek: (ms: number) => void
onToggleLoop / onToggleShuffle / onSelectPlayer(name) / onRefresh
onSetTab: (t: number) => void
onSvSink: (name: string, pct: number) => void
onSvMute: (name: string) => void
onSvSetDefault: (name: string) => void
onClose: () => void
```
⚠️ **必须保持**：`MprisProgress` 作为**子组件**使用（它的 1s ticker 只在播放中写自身 @State ✓ 别退回页面级 ticker ✗）。

## 2. 6b — `state/PayloadController.ets` + `components/ReceivedFilesDialog.ets`

### 2.1 状态（自 Index 迁入）
```
@Observed class PayloadController {
  payloads: PayloadTransfer[] = [];        // 进行中/本轮（进度行）
  history: PayloadTransfer[] = [];         // 原 @State receivedHistory（跨重启，经 PayloadHistory 持久化）
  dialogOpen: boolean = false;             // 原 @State receivedDialogOpen
  detailOpen: boolean = false;             // 原 @State payloadDetailOpen
  detailId: number = 0;                    // 原 @State payloadDetailId
  // 多选发送串行队列（原 sendQueue/sendBusyId/sendInflightJob/sendTarget/sendOk/total）一并迁入
}
```

### 2.2 方法（自 Index 迁入，共 ~16 个）
```
handlePayloadTransfer / failInflightReceives / markPayloadSettled
payloadDetail / payloadStateText / fmtBytes / sanitizeFileName
putReceivedHistory / discardPayload / cancelPayload
savePayload / saveAsPayload / exportToDownloads            ← 含"落盘 / 另存为 / 导出下载"
pumpSendQueue / onSendPayloadSettled / stageSendJob / forgetSendQueue   ← 发送队列（P3 断链清理随迁）
```
（保留在页面：`pickAndSendFile()` —— 它要 `DocumentViewPicker` + `getUIContext` ✗，且与"发送文件"卡片耦合 ✓；**或**迁入并注入 `pickFiles(): Promise<string[]>` ✓ 二选一，见 §3）

### 2.3 注入
```ts
log / toast / resText: (resId: number) => string
sendPayload: (deviceId, packetType, json, cachePath) => number   // → native.sendPayload
hostCacheDir: () => string | undefined                          // 沙箱副本目录
pickFiles: () => Promise<string[]>                              // 文档选择器（多选）
pickSaveTarget: (name: string) => Promise<string>               // 另存为（用户自选位置）
connectedIds: () => string[]                                    // 发送目标在线校验（pumpSendQueue 用）
```
⚠️ **必须保持**：①payload 终态是队列推进的唯一依据（别加 sleep ✗）；②`payloadSize>0 ∧ payloadTransferId==0` 不建条目 ✓；③`safeFileName` 单一来源（`PayloadHistory.safeFileName`）✓。

### 2.4 `components/ReceivedFilesDialog.ets`（原 L3323 起 ~84 行）
```
@ObjectLink payload: PayloadController;
onOpenDetail: (transferId: number) => void
onSave / onDiscard / onCancel: (p: PayloadTransfer) => void
onClose: () => void
```
> `PayloadDetailDialog`（步骤 2 已抽 ✓）继续复用 ✓；`PayloadRow` 不变 ✓。

## 3. 归属与边界（建议，待 CodeArts/Omp 确认）
| 问题 | 建议 |
|---|---|
| `pickAndSendFile()` 放哪 | **留页面**（UI/选择器耦合最重）✓；Controller 只提供 `enqueueFiles(paths)` ✓ ⇒ 页面选完把路径交给 Controller ✓ |
| `savePayload/saveAsPayload/exportToDownloads` | **迁入 Controller** ✓（注入 `pickSaveTarget`）⇒ 文件页/详情弹窗只调 Controller ✓ |
| `mprisPluginOf/sysVolumePluginOf` | 迁入 Controller（注入 `pluginsFor`）✓ |
| 页面保留 | 生命周期装配、`build()` 骨架、4 页签、卡片动作分发、`pickAndSendFile`、`runCommand` ✓ |

## 4. 拆分顺序与验收（每步 `devecocli build`，替换由 Omp 执行）
1. 6a-1：建 `MprisController.ets`（状态+方法+注入）→ 构建 ✓
2. 6a-2：建 `MprisDialog.ets`（UI 原样搬）→ 构建 ✓
3. 6b-1：建 `PayloadController.ets`（状态+方法+队列）→ 构建 ✓
4. 6b-2：建 `ReceivedFilesDialog.ets`（UI 原样搬）→ 构建 ✓
5. 交给 Omp 一次性替换（含页面装配与注入）→ 他跑构建 + ohemu 冒烟 + 参数级保真比对（沿用 MSG68 的方法 ✓）
**验收**：Index.ets 从 **3438 行** 降至 ~2000 行以内；`systemvolume.sinks` 单槽过滤与 MPRIS `canClaim` 等不变量保持 ✓。

## 5. 附：本机回归能力现状（如实）
- 平板（HarmonyOS）**拒绝 OpenHarmony 本地签名**（`9568257 fail to verify pkcs7`）⇒ 真机回归仍需华为侧签名（配额/正式签名）；
- 本机**无可用模拟器**（`devecocli device list` 仅见平板）⇒ ohemu 路线需在宿主侧启动并接入（`tools/verify-on-ohemu.sh`）；
- 故**批次 2 的验证依赖 Omp 的 ohemu 冒烟**，我在本机只能做构建与静态核对 ✓。

—— DevEco
