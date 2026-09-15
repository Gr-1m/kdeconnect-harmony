# MPRIS 媒体控制功能规划

> 2026-09-15。CodeArts（流程总指挥）编写。
> 优先级：P2。方向 1（控制方）优先，方向 2（被控方）随后。

## 1. 背景与目标

KDE Connect 的 MPRIS 插件实现跨设备媒体控制：手机控制桌面播放器（方向 1），桌面控制手机播放器（方向 2）。当前鸿蒙版 `MprisPlugin.ets` 是 P1 占位骨架（21 行，只声明 caps），P2 需要完整实现。

**方向 1（控制方）**：接收桌面 `kdeconnect.mpris`（播放器状态），发送 `kdeconnect.mpris.request`（控制命令）。这是手机作为 remote controller 的场景，对应 Android `mpris/MprisPlugin.kt`。

**方向 2（被控方）**：接收桌面 `kdeconnect.mpris.request`（控制命令），发送 `kdeconnect.mpris`（播放器状态）。这是桌面控制手机播放器的场景，对应 Android `mprisreceiver/MprisReceiverPlugin.java`，鸿蒙侧用 `@ohos.multimedia.avsession` API。

## 2. 协议规范

### 2.1 `kdeconnect.mpris`（incoming，桌面→手机）

| body 字段 | 类型 | 说明 |
|---|---|---|
| `playerList` | string[] | 可用播放器名称列表 |
| `player` | string | 目标播放器名称 |
| `canPause` | boolean | 是否可暂停 |
| `canPlay` | boolean | 是否可播放 |
| `canGoNext` | boolean | 是否可下一曲 |
| `canGoPrevious` | boolean | 是否可上一曲 |
| `canSeek` | boolean | 是否可拖动进度 |
| `isPlaying` | boolean | 是否正在播放 |
| `loopStatus` | "None"/"Track"/"Playlist" | 循环模式 |
| `shuffle` | boolean | 随机播放 |
| `pos` | number | 当前播放位置（**毫秒**） |
| `length` | number | 曲目总长（**毫秒**） |
| `volume` | number(0-100) | 音量百分比 |
| `nowPlaying` | string | 已废弃：`Artist - Title` |
| `artist` | string | 艺术家 |
| `title` | string | 曲名 |
| `album` | string | 专辑名 |
| `albumArtUrl` | string | 专辑封面 URL |
| `supportAlbumArtPayload` | boolean | 是否支持 payload 传输封面 |
| `transferringAlbumArt` | boolean | 正在传输封面（带 payload） |

**增量更新**：`player` 包可以只包含变化的字段，不全量回发。

### 2.2 `kdeconnect.mpris.request`（outgoing，手机→桌面）

| body 字段 | 类型 | 说明 |
|---|---|---|
| `requestPlayerList` | boolean | 请求播放器列表 |
| `player` | string | 目标播放器名称 |
| `requestNowPlaying` | boolean | 请求当前播放信息 |
| `requestVolume` | boolean | 请求音量 |
| `action` | "Pause"/"Play"/"PlayPause"/"Stop"/"Next"/"Previous" | 播放控制（**首字母大写**） |
| `Seek` | number | 相对跳转（**微秒**，大写 S） |
| `SetPosition` | number | 绝对跳转（**毫秒**，大写 S） |
| `setLoopStatus` | "None"/"Track"/"Playlist" | 设置循环模式 |
| `setShuffle` | boolean | 设置随机播放 |
| `setVolume` | number(0-100) | 设置音量 |
| `albumArtUrl` | string | 请求封面 payload 传输 |

**易错点**（已验证）：
- `Seek` 是**微秒**（µs），`pos`/`length`/`SetPosition` 是**毫秒**（ms）——单位不一致
- `Seek`/`SetPosition` 首字母**大写**（小写 `seek`/`setPosition` 会被对端忽略）
- `action` 首字母**大写**（`Play` 不是 `play`）

## 3. 方向 1：控制方（手机控桌面播放器）

### 3.1 架构

```
桌面 KDE ──kdeconnect.mpris──→ MprisPlugin.ets ──notify──→ MediaControlPanel.ets (UI)
桌面 KDE ←──kdeconnect.mpris.request── MprisPlugin.ets ←──用户操作── MediaControlPanel.ets (UI)
```

### 3.2 MprisPlugin.ets 改造

**数据模型**——`MprisPlayer` 类，镜像远端播放器状态：

```typescript
class MprisPlayer {
  playerName: string = '';
  isPlaying: boolean = false;
  title: string = '';
  artist: string = '';
  album: string = '';
  albumArtUrl: string = '';
  volume: number = 0;
  length: number = 0;       // ms
  pos: number = 0;          // ms
  lastPosTime: number = 0;  // Date.now() of last pos update
  loopStatus: string = 'None';
  shuffle: boolean = false;
  canPause: boolean = false;
  canPlay: boolean = false;
  canGoNext: boolean = false;
  canGoPrevious: boolean = false;
  canSeek: boolean = false;
  supportAlbumArtPayload: boolean = false;

  // 实时进度计算：播放中则 pos + (now - lastPosTime)，否则 pos
  currentPosition(): number { ... }
}
```

**收包处理**——`onPacketReceived`：

1. 有 `transferringAlbumArt` → 处理 payload（专辑封面二进制数据），写入缓存
2. 有 `player` 字段 → 增量更新对应 `MprisPlayer`（只更新包中包含的字段），更新 `lastPosTime`
3. 有 `playerList` 字段 → 对比新旧列表：新增 player 立即 `requestPlayerStatus()`，移除的 player 清理
4. 通过 `notify('mpris.playerUpdate', JSON.stringify(player))` 推 UI 刷新

**发包方法**：

- `requestPlayerList()` → `{requestPlayerList: true}`
- `requestPlayerStatus(player)` → `{player, requestNowPlaying: true, requestVolume: true}`
- `sendAction(player, action)` → `{player, action}` （action 首字母大写）
- `sendSetVolume(player, vol)` → `{player, setVolume: vol}`
- `sendSetPosition(player, posMs)` → `{player, SetPosition: posMs}` （大写 S，毫秒）
- `sendSeek(player, deltaUs)` → `{player, Seek: deltaUs}` （大写 S，微秒）
- `sendSetLoopStatus(player, status)` → `{player, setLoopStatus: status}`
- `sendSetShuffle(player, shuffle)` → `{player, setShuffle: shuffle}`

**生命周期**：

- `onCreate()` → 发 `requestPlayerList()`
- `onDestroy()` → 清理播放器列表 + 封面缓存

### 3.3 MediaControlPanel.ets（UI）

**布局**：

- 播放器选择器（下拉/标签页）：`playerList` 有多个时显示，单个时隐藏
- 当前曲目信息：`title` / `artist` / `album` / 专辑封面（如有）
- 播放控制按钮：上一曲 / 播放暂停 / 下一曲 / 停止（按 `can*` 标志启用/禁用）
- 进度条：`currentPosition()` / `length`，可拖动（`canSeek` 时）
- 音量滑块：`volume` 0-100
- 循环模式按钮：None / Track / Playlist
- 随机播放开关

**交互**：

- 用户操作 → 调 `MprisPlugin` 对应发包方法
- `notify('mpris.playerUpdate')` → 刷新 UI
- `notify('mpris.playerList')` → 刷新播放器选择器

**UI 入口**：六按钮中的「媒体控制」按钮 → 打开 `MediaControlPanel`（可以是独立页面或弹窗）

### 3.4 专辑封面处理

桌面发 `transferringAlbumArt: true` + `payloadSize` + `payloadTransferInfo.port` → native 层接收 payload → 派发 `payloadReceived` 事件 → ArkTS 写入磁盘缓存（`cacheDir/mpris_albumart/<hash>.jpg`）→ UI 用 `Image` 组件加载本地路径。

**注意**：payload 传输依赖 native 层已有的 payload transfer 机制（`payloadTransfer` 事件），这是已验证的基础设施。

### 3.5 实现范围（方向 1）

| 组件 | 文件 | 行数估计 | 说明 |
|---|---|---|---|
| `MprisPlayer` 数据模型 | `MprisPlugin.ets` 内 | ~60 行 | 状态镜像 + `currentPosition()` |
| `MprisPlugin` 收发包逻辑 | `MprisPlugin.ets` | ~150 行 | `onPacketReceived` + 7 个发包方法 |
| `MediaControlPanel` UI | `pages/MediaControlPanel.ets` | ~200 行 | 播放器选择 + 控制面板 + 进度条 |
| Index.ets 接线 | `pages/Index.ets` | ~20 行 | 媒体控制按钮 → 打开面板 + notify 处理 |

## 4. 方向 2：被控方（桌面控手机播放器）

### 4.1 架构

```
桌面 KDE ──kdeconnect.mpris.request──→ MprisReceiverPlugin.ets ──AVSession──→ 系统/第三方播放器
桌面 KDE ←──kdeconnect.mpris── MprisReceiverPlugin.ets ←──AVSession回调── 系统/第三方播放器
```

### 4.2 AVSession API 方案

鸿蒙 `@ohos.multimedia.avsession` 是对应 Android `MediaSessionManager` 的系统 API。

**被控方（创建会话）**——不需要 `MANAGE_MEDIA_RESOURCES` 权限：

- `AVSessionManager.createAVSession()` 创建代理会话
- `avsession.setMetadata()` 设置当前曲目元数据（title/artist/album/art）
- `avsession.setAVPlaybackState()` 设置播放状态（playing/paused/position/length）
- `avsession.on('play')` / `on('pause')` / `on('next')` / `on('previous')` / `on('seek')` 接收控制命令
- 收到系统媒体控制 → 转发为 `kdeconnect.mpris.request` 给桌面？**不对**——方向 2 是桌面控制手机，所以是手机**接收** `kdeconnect.mpris.request`，然后通过 AVSession 控制本地播放器。

**正确流程**：

1. 手机创建 `AVSession`，注册为媒体控制代理
2. 桌面发 `kdeconnect.mpris.request`（`requestPlayerList` / `action` / `SetPosition` 等）
3. 手机 `MprisReceiverPlugin` 收到请求 → 通过 `AVSessionManager.getAllSessionDescriptors()` 找到活跃播放器 → `createController()` 获取控制器 → 发送对应命令
4. 播放器状态变化 → `AVSession` 回调 → 手机发 `kdeconnect.mpris` 给桌面

**权限**：`getAllSessionDescriptors()` / `createController()` 需要 `ohos.permission.MANAGE_MEDIA_RESOURCES`（system_basic 级）。普通应用无法获取此权限。

**方案 A（推荐）：创建 AVSession 代理**

不获取 `MANAGE_MEDIA_RESOURCES`，而是创建自己的 `AVSession`，将远端播放器状态映射到本地系统媒体通知。这样：
- 不需要 system_basic 权限
- 锁屏/通知栏显示媒体控制按钮
- 用户在锁屏控制 → AVSession 回调 → 转发 `kdeconnect.mpris.request` 给桌面

**但这是方向 1 的增强**（让手机锁屏也能控制桌面播放器），不是方向 2。

**方向 2 的真正含义**：桌面控制手机上的播放器。这需要 `getAllSessionDescriptors()` + `createController()`，即 `MANAGE_MEDIA_RESOURCES` 权限。普通应用无法获取。

**结论**：方向 2 在普通应用权限下**无法完整实现**。只能用方案 A（AVSession 代理）实现方向 1 的增强（锁屏控制），不能实现真正的被控方。

### 4.3 方向 2 降级方案

如果用户接受降级，方向 2 可以实现一个**有限的被控方**：

- 创建 `AVSession`，声明自己为媒体播放器
- 桌面发 `requestPlayerList` → 回报一个虚拟 player（如 "HarmonyOS Media"）
- 桌面发 `action: Play/Pause/Next/Previous` → 通过 `AVSession` 的 `play/pause/next/previous` 事件控制**系统默认播放器**（如果有的话）
- 但无法获取其他播放器的 metadata（需要 `MANAGE_MEDIA_RESOURCES`）

**建议**：方向 2 暂不实现，等权限问题解决或用户明确要求降级方案。

## 5. 实现优先级与拆分

### Phase 1：方向 1 核心（控制方）

1. **`MprisPlugin.ets` 改造**：`MprisPlayer` 数据模型 + `onPacketReceived` 收包处理 + 7 个发包方法 + `requestPlayerList` / `requestPlayerStatus`
2. **`MediaControlPanel.ets` UI**：播放器选择 + 曲目信息 + 控制按钮 + 进度条 + 音量
3. **Index.ets 接线**：媒体控制按钮 → 打开面板 + `notify` 事件处理

### Phase 2：方向 1 增强

4. **专辑封面 payload 接收**：native payload transfer → 磁盘缓存 → UI 加载
5. **AVSession 代理（方案 A）**：锁屏媒体控制通知

### Phase 3：方向 2（被控方，待权限解决）

6. **`MprisReceiverPlugin.ets`**：需要 `MANAGE_MEDIA_RESOURCES` 权限或降级方案

## 6. 跨端常量与协议约束

| 常量 | 值 | 说明 |
|---|---|---|
| packet type（incoming） | `kdeconnect.mpris` | 播放器状态 |
| packet type（outgoing） | `kdeconnect.mpris.request` | 控制请求 |
| `pos` / `length` / `SetPosition` 单位 | 毫秒（ms） | |
| `Seek` 单位 | 微秒（µs） | 注意与 pos 单位不同 |
| `action` 值 | `Pause`/`Play`/`PlayPause`/`Stop`/`Next`/`Previous` | 首字母大写 |
| `Seek` / `SetPosition` | 大写 S | 小写会被对端忽略 |
| `loopStatus` 值 | `None`/`Track`/`Playlist` | |
| `volume` 范围 | 0-100 | 百分比 |
| 增量更新 | `player` 包只含变化字段 | 不全量回发 |

## 7. Android 参考实现对照

| Android 组件 | 鸿蒙对应 | 说明 |
|---|---|---|
| `MprisPlugin.kt`（控制端） | `MprisPlugin.ets`（方向 1） | 收 `kdeconnect.mpris`，发 `kdeconnect.mpris.request` |
| `MprisPlayer`（内部类） | `MprisPlayer`（方向 1） | 远端播放器状态镜像 + `currentPosition()` |
| `MprisMediaSession.kt` | AVSession 代理（Phase 2） | 锁屏媒体通知 |
| `MprisReceiverPlugin.java`（被控端） | `MprisReceiverPlugin.ets`（方向 2，待权限） | 收 `kdeconnect.mpris.request`，发 `kdeconnect.mpris` |
| `MediaController` | `AVSessionManager.createController()` | 需要 `MANAGE_MEDIA_RESOURCES` |
| `MediaSessionManager` | `AVSessionManager.getAllSessionDescriptors()` | 需要 `MANAGE_MEDIA_RESOURCES` |
| `MediaSessionCompat` | `AVSessionManager.createAVSession()` | 不需要特殊权限 |

## 8. PluginBase 契约

`MprisPlugin` 继承 `PluginBase`，需实现：

- `supportedPacketTypes = ['kdeconnect.mpris']`（incoming caps）
- `outgoingPacketTypes = ['kdeconnect.mpris.request']`（outgoing caps）
- `onPacketReceived(packetType, body)` → 收包处理
- `onCreate()` → 初始化（发 `requestPlayerList`）
- `onDestroy()` → 清理
- `send(packetType, body)` → 发包（基类提供）
- `notify(kind, data)` → 推 UI（基类提供）

`notify` kind 约定：
- `'mpris.playerList'` → data: `JSON.stringify(playerName[])`
- `'mpris.playerUpdate'` → data: `JSON.stringify(MprisPlayer)`

## 9. 验收判据

### Phase 1（方向 1 核心）

1. KDE 桌面播放音乐 → 手机端媒体控制面板显示曲目信息（title/artist/album）
2. 手机端点击播放/暂停/上一曲/下一曲 → 桌面播放器响应
3. 手机端拖动进度条 → 桌面播放器跳转
4. 手机端调音量 → 桌面播放器音量变化
5. 多播放器场景：播放器选择器切换正常
6. `pos` 实时更新（播放中进度条持续前进）

### Phase 2（方向 1 增强）

7. 专辑封面在手机端正常显示
8. 锁屏媒体控制通知可用（AVSession 代理）

### Phase 3（方向 2，待权限）

9. 桌面端能看到手机播放器出现在播放器列表
10. 桌面端控制手机播放器播放/暂停/下一曲

## 10. 风险与注意事项

| 风险 | 影响 | 缓解 |
|---|---|---|
| `Seek` 微秒 vs `pos` 毫秒单位混淆 | 进度条跳转错误 | 代码注释标注，发包时显式转换 |
| `action` / `Seek` / `SetPosition` 大小写 | 命令被对端忽略 | 代码中使用常量，不手写字符串 |
| 增量更新只含变化字段 | UI 状态不完整 | `MprisPlayer` 维护完整状态，收包只更新存在的字段 |
| 专辑封面 payload 传输 | 依赖 native payload 机制 | Phase 2 再实现，先保证核心控制功能 |
| `MANAGE_MEDIA_RESOURCES` 权限 | 方向 2 无法完整实现 | Phase 3 降级方案或等权限解决 |
| AVSession API 在 QEMU 模拟器上的可用性 | 开发期验证困难 | 真机验证为主 |

## 11. 开工条件

- Phase 1 可立即开工（方向 1 核心功能，不依赖特殊权限）
- Phase 2 需 Phase 1 完成后开工
- Phase 3 需用户确认权限策略后开工

---

CodeArts（流程总指挥），2026-09-15
