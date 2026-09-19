# EXP_LESSONS — kdeconnect.systemvolume：schema 表述与 KDE 实现不一致

> 2026-09-19。登记人：DevEco（依据 CodeArts MSG20 §1）。相关：`kdeconnect-meta/schemas/kdeconnect.systemvolume.json`。

## 1. 现象

`kdeconnect.systemvolume` 的 `body.volume` 在**两份材料里"看起来"是两种量纲**：

| 材料 | 内容 | 看起来像 |
|---|---|---|
| schema 全量示例 | `"volume": 32768, "maxVolume": 65536` | 绝对刻度 |
| schema **增量**示例 | `"volume": 49` | **百分比 0-100** |
| KDE pulse 实现 | 收：`sink->setVolume(np.get<int>("volume"))`；发：`sink->volume()` + `maxVolume` | 绝对刻度 |
| KDE macOS / Windows 实现 | 同样是设备自身的绝对音量 + `maxVolume` | 绝对刻度 |
| Android 客户端 | `sendVolume(name, volume)` 直接透传（不做百分比换算） | 不表态 |

## 2. 结论（本项目的处理口径）

1. **`volume` 与 `maxVolume` 是同一把尺子，一律按绝对刻度处理**（pulse 端 `normalVolume()` 通常 65536）。
2. schema **增量示例里的 `49` 属示例误导**，不代表量纲；不信该数字，信后端实现。
3. 换算只在**一处**完成：`SystemVolumePlugin.syncRows()` 用它派生出 UI 用的百分比（`SystemSinkUi.volumePct`）。
4. 反例代价（实测）：曾按"百分比"下发 `volume: 49` ⇒ 对端按 `49/65536 ≈ 0.07%` 处理 ⇒ 听感等于静音，
   KDE 自己显示 "Audio Muted"（用户实测报障的根因）。
5. 「刻度未知不猜」：未拿到该 sink 的 `maxVolume` 时，`volumePct = -1`（UI 显示「—」并禁用滑杆），
   不做 `abs > 100 ? 100 : abs` 之类夹断猜测。

## 3. 其它同批澄清的字段（核对 KDE/Android 源码，勿凭记忆改）

- 三个字段 `volume` / `muted` / `enabled` **都是"有才读"**（KDE `np.has(...)`；
  Android `sendVolume` / `sendMute` 各自只带一个字段）⇒ **不存在"缺字段被读成 0"**。
- 带 `volume` 会**顺带取消静音**（KDE 紧随 `setVolume` 无条件 `sink->setMuted(false)`）⇒ 本地也要清 `muted`。
- `enabled` = **是否默认输出**（KDE `sink->setDefault(enabled)`；Windows/macOS 同为 `isDefault`）
  ⇒ 「选择输出设备」= 单独发 `{name, enabled: true}`（Android `sendEnable()`）；
  **调音量/静音绝不能带 `enabled`**，否则会顺带切走对端默认输出。
- 请求里**不带 `enabled:false`** 给旧默认 sink（Android 也不带）：由对端自己完成默认切换的互斥。
