# 系统分享集成设计 — KDE Connect 出现在 HarmonyOS 分享面板

> 日期：2026-11-15（**2026-11-18 总指挥按官方 API 修订**：action/UTD/入口/取数/权限五处硬错误已更正，路径改为 UIAbility + skills）
> 提出人：CodeArts（用户指派）　修订：AtomCode　状态：**规划草案（修订版），待 CodeArts 复核后派单实现**
> 关联：`contract/capabilities.v1.json`（share 插件）、`entry/src/main/ets/plugins/SharePlugin.ets`、`entry/src/main/ets/state/PayloadController.ets`

---

## 1. 目标

让 KDE Connect 出现在 HarmonyOS 系统分享面板（与 QQ、微信并列），从相册/文件管理器/浏览器分享文件或文本到对端设备。

**核心体验**：
1. 相册选图 → 分享 → 面板出现 KDE Connect → 进入 app → 选设备 → 发送；
2. 无已连接设备 → toast「请先连接设备」+ 跳设备页；
3. 文本/URL 分享 → 走 `kdeconnect.share.request` 的 `text` 字段。

---

## 2. HarmonyOS 分享机制（官方口径）

| 路径 | 机制 | 有 UI | 适用场景 |
|---|---|---|---|
| **A. UIAbility + skills（本方案推荐）** | 现有 Ability 的 `skills` 加 `actions: ["ohos.want.action.sendData"]` + UTD 声明 | 有 UI（直接进 app） | 需要选设备/看进度 |
| B. ShareExtensionAbility | `extensionAbilities` + `type: "share"`，继承 **UIExtensionAbility**（嵌入式分享详情页） | **有 UI（分享面板内嵌入页）** | 想留在分享面板内完成操作 |

**选 A 的理由**：
- 分享后要**选设备 + 看传输进度**，进完整 app 更自然；
- **URI 临时读授权只在接收它的 Ability 内有效** ⇒ A 路径下复制文件与发送在同一 Ability，不需跨 Ability 传授权；
- 改动最小：`abilities[].skills` + `EntryAbility.onCreate/onNewWant` 处理；
- 若将来要「面板内小面板」，再加 ShareExtensionAbility（入口是 `onSessionCreate(want, session)` + `session.loadContent`）。

---

## 3. 实现方案（A 路径）

### 3.1 整体流程

```
用户在相册/文件管理器分享 → 系统分享面板 → 选择 KDE Connect
  → EntryAbility.onCreate / onNewWant(want)     ← 同一 Ability，URI 授权有效
  → systemShare.getSharedData(want) → SharedRecord[]
  → 立即复制文件到应用沙箱 cacheDir（授权不跨 Ability/不跨进程）
  → 写入 AppStorage('pendingShareData')
  → Index 检测：
      ├─ 有已连接设备 → 设备选择（1 台直接发）→ KcBridge.sendPayload()
      └─ 无设备 → toast + 跳设备页（分享数据保留，连接后可手动重发）
```

### 3.2 新增文件

| 文件 | 路径 | 职责 |
|---|---|---|
| `ShareIntent.ets` | `entry/src/main/ets/common/ShareIntent.ets` | 纯逻辑（零 Kit/零 native）：分享记录 → 发送意图（文件/文本/忽略）、文件名清洗、多文件上限判定 |
| `ShareTargetDialog.ets` | `entry/src/main/ets/components/ShareTargetDialog.ets` | 设备选择对话框 |

### 3.3 修改文件

| 文件 | 改动 |
|---|---|
| `entry/src/main/module.json5` | `abilities[EntryAbility].skills` 增 `sendData` + UTD（见 3.4） |
| `entry/src/main/ets/entryability/EntryAbility.ets` | `onCreate`/`onNewWant`：`getSharedData` → 复制到沙箱 → 写 AppStorage |
| `entry/src/main/ets/pages/Index.ets` | 监听 `pendingShareData` → 设备选择 → 发送 |
| `entry/src/main/resources/base/element/string.json`（+zh_CN） | 分享相关文案 |

### 3.4 module.json5 配置（官方口径）

```json5
{
  "name": "EntryAbility",
  // ... 现有字段不变 ...
  "skills": [
    {
      "actions": ["ohos.want.action.sendData"],
      "uris": [
        { "scheme": "file", "utd": "general.image", "maxFileSupported": 10 },
        { "scheme": "file", "utd": "general.text", "maxFileSupported": 1 },
        { "scheme": "file", "utd": "general.file", "maxFileSupported": 10 }
      ]
    }
  ]
}
```

关键点：
- `actions` **必须** `ohos.want.action.sendData`（`action.system.share` 不存在）；
- `uris` 用 **UTD**：`general.image`/`general.text`/`general.file`；`maxFileSupported: 0` 表示不支持该类；
- `scheme` 是预留字段（写 `"file"` 即可），**没有 `content` scheme**。

### 3.5 EntryAbility 实现（取数据 + 落地沙箱）

```typescript
import { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

private async consumeShareWant(want: Want): Promise<void> {
  try {
    const data: systemShare.SharedData = await systemShare.getSharedData(want);
    const records: systemShare.SharedRecord[] = data.getRecords();
    // 在 Ability 内立刻复制（URL/URI 授权不跨 Ability/进程）
    const copied: string[] = [];
    for (const r of records) {
      // r.uri 为分享方授权的临时 URI；按 record 的 utd/uri 复制到 cacheDir
      // 具体字段与权限边界以 S0 spike 抓到的实际 records 为准
    }
    AppStorage.setOrCreate('pendingShareData', JSON.stringify({ texts: [...], files: copied }));
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(0x0000, 'KDC-Share', 'getSharedData failed: %{public}d %{public}s', err.code, err.message);
  }
}

onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  this.consumeShareWant(want);   // 冷启动
}

onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  this.consumeShareWant(want);   // app 已在运行时的新分享
}
```

> 文本分享：`SharedRecord` 里同样携带文本内容（或 `general.text` 记录的 uri 指向文本）；判定逻辑放 `ShareIntent.ets` 便于宿主单测。

### 3.6 Index 接收逻辑

```typescript
@StorageProp('pendingShareData') pendingShareData: string = '';

watchPendingShare(): void {
  if (this.pendingShareData === '') return;
  const intent: ShareIntent = parseShareIntent(this.pendingShareData);   // 纯函数
  AppStorage.setOrCreate('pendingShareData', '');
  if (intent.files.length === 0 && intent.texts.length === 0) return;
  if (this.connectedDevices.length === 0) {
    promptAction.showToast({ message: '请先连接设备' });
    this.switchToDevicesTab();
    this.keepPendingIntent(intent);       // 保留，连接后可重发
    return;
  }
  if (this.connectedDevices.length === 1) { this.sendShareTo(this.connectedDevices[0].deviceId, intent); return; }
  this.showShareTargetDialog(intent);
}
```

### 3.7 发送

- 文件：`KcBridge.sendPayload(deviceId, 'kdeconnect.share.request', JSON.stringify({ filename }), sandboxPath)`（多文件逐条入 payload 队列，沿用 S2 批次计数）；
- 文本/URL：`KcBridge.sendPacket(deviceId, JSON.stringify({ id, type: 'kdeconnect.share.request', body: { text } }))`；
- 失败（无连接/发送失败）：toast + 记日志，**不静默丢**。

---

## 4. 关键技术点

### 4.1 URI → 沙箱（必须最先做）
- 分享 URI 只有**临时读授权**，且**不跨 Ability/进程**；
- 因此在 `EntryAbility.onCreate/onNewWant` 内、`getSharedData` 后**立即** `fileIo.openSync(uri, READ_ONLY)` + 复制到 `cacheDir/share/`，再用沙箱路径走发送；
- 复制失败 ⇒ 记录 + toast（不要拿未复制的 URI 去发送）。

### 4.2 多文件
- `SharedData.getRecords()` 返回多条记录；`maxFileSupported` 在声明里控制上限；
- 超过上限或单条复制失败 ⇒ 跳过该条并汇总提示。

### 4.3 冷启动与引擎未就绪
- 分享可能在 native `start()` 完成前到达 ⇒ 分享意图先落 AppStorage（**文件已复制到沙箱，不依赖 native**），等连接就绪后再发送；
- 不做「自动连接」，沿用现有「已连接设备」判定。

### 4.4 文本 vs 文件 vs URL
| 类型 | 判定 | 发送 |
|---|---|---|
| 文件（image/file） | 记录带 uri | 复制 → `sendPayload` |
| 纯文本/URL | 记录带文本内容 | `sendPacket` body `{text}` |

协议侧不变：`kdeconnect.share.request` 的 `filename`/`text` 字段，`SharePlugin` 已支持。

---

## 5. 权限需求

| 权限 | 用途 | 结论 |
|---|---|---|
| `ohos.permission.INTERNET` | 网络 | ✅ 已声明 |
| `WRITE_IMAGEVIDEO`/`WRITE_AUDIO` | 接收侧写入相册 | ✅ 已声明（与分享无关） |
| `READ_IMAGEVIDEO`/`READ_AUDIO` | — | **不要加**：分享方通过 want 授予临时读权限；这两个是受限权限，声明会引入上架审查风险 |

---

## 6. 实现步骤（排期建议）

| 步骤 | 内容 | Owner | 依赖 |
|---|---|---|---|
| **S0** | **spike**：只加 skills（sendData + UTD）→ 真机确认分享面板出现；再打 `getSharedData` 日志抓 records 形状（uri/utd/text/多文件） | Omp-ArkTS | 无 |
| S1 | `ShareIntent.ets` 纯逻辑 + 宿主单测（文件/文本/多文件/超限/空数据） | Omp-ArkTS | S0 |
| S2 | `EntryAbility.onCreate/onNewWant`：getSharedData → 复制沙箱 → AppStorage | Omp-ArkTS | S0、S1 |
| S3 | `Index` 接收逻辑 + `ShareTargetDialog` | Omp-ArkTS | S2 |
| S4 | 文件发送（多文件、失败提示） | Omp-ArkTS | S3 |
| S5 | 文本/URL 发送 | Omp-ArkTS | S3 |
| S6 | 无设备体验（toast + 跳页 + 保留意图） | Omp-ArkTS | S3 |
| S7 | 真机验证：相册图片 / 文件管理器文档 / 浏览器 URL 各 1 次 | 用户 | S1–S6 |

---

## 7. 风险与约束

| 风险 | 严重度 | 缓解 |
|---|---|---|
| UTD 与分享方不一致 ⇒ 面板不出现/不接收 | **High** | S0 用真机逐类验证（图片/文本/文件）；必要时补 `general.video`/`general.audio` |
| 分享 URI 复制失败（授权/格式） | Medium | 在 Ability 内尽快复制；失败记录 + toast；S0 抓真实 uri |
| 冷启动时引擎未就绪 | Medium | 意图先落 AppStorage，连接后发送；不自动连接 |
| 面板里显示名称/图标不符预期 | Low | 继承 Ability 的 label/icon，S0 截图确认 |
| 多文件格式差异 | Low | 以 S0 抓到的 records 为准实现 |

---

## 8. 验证前置（S0 必须做）

1. 加 skills 后分享面板是否出现 KDE Connect；
2. `systemShare.getSharedData(want)` 的 `SharedRecord` 实际字段（uri/utd/text/多文件顺序）；
3. 复制到沙箱是否成功（`fileIo` 打开 URI 的权限是否够）。

---

## 9. 与现有协议的关系

不改变协议：只新增一个入口。两条路径最终都走 `KcBridge.sendPayload()` / `sendPacket()`，`kdeconnect.share.request` 格式不变；分享发送的文件同样进 FilesTab 历史（沿用 `PayloadHistory`）。

---

## 10. 后续扩展

- 分享面板内嵌入式体验（ShareExtensionAbility + `onSessionStart` → `loadContent`）；
- 快捷分享：仅 1 台已连接设备时跳过选择；
- 分享目标记忆（上次设备预选）。
