# CCR-4: `capabilities.v1.json` 两处默认值修正（battery / connectivityreport → true）

- 日期：2026-11-15
- 提出人：AtomCode（依据用户 2026-11-15 对 P1-3 默认值的行为裁决：「保持现状（默认开）」）
- 状态：**已按用户裁决落地（2026-11-15）；待 CodeArts 复核确认**
- 影响：`contract/capabilities.v1.json`（2 行）、`common/PluginDefaults.ets` 镜像、`tools/check-plugin-defaults.py` 断言、`SettingsController` 默认值
- 关联：`MSG264`（Q2 裁决：`defaultEnabled` = UI 默认开关）、`MSG265`（Omp-ArkTS P1-3 交付与行为询问）、`MSG266`（CCR-3）

## 1. 动机

P1-3 把 `capabilities.v1.json` 的 `defaultEnabled` 落成 UI 默认开关后暴露一个**可见行为回归**：
`battery` 与 `connectivityreport` 当前默认 `false` ⇒ 默认不再向对端上报电量/网络，桌面端电量与网络指示消失。
但这两项是 0.8.x 已验证的核心功能（配对即发 + 60s 周期，真机/桌面均可见），**默认关闭不是产品意图**。

用户裁决：**保持现状（默认开）**；`sftp` 维持 `false`（未实现，Q3 已裁决不广告）。

## 2. 变更内容（纯数据值）

```diff
-    { "key": "battery", ..., "defaultEnabled": false },
-    { "key": "connectivityreport", ..., "defaultEnabled": false },
+    { "key": "battery", ..., "defaultEnabled": true },
+    { "key": "connectivityreport", ..., "defaultEnabled": true },
     { "key": "sftp", ..., "defaultEnabled": false }   // 不变
```

仓库内相关的键集合/能力广告（`incoming`/`outgoing`）**不变**；`errors.v1.json` 不变。

## 3. 兼容性

1. **纯值变化**：不新增/删除能力键，不改 packet 集合；对端感知不变（identity 广告的能力列表不变）；
2. **必须同步的三处**（否则 `check-plugin-defaults.py` 立即红）：
   - `common/PluginDefaults.ets` 的 `PLUGIN_DEFAULT_ENABLED` 两处 → `true`；
   - `PluginDefaults.test.ets` 中 battery/connectivity 的默认值断言；
   - `SettingsController` 无硬编码默认（读镜像即可），无需改；
3. 已由用户在设置里「自定义」过的覆盖项不受影响（只存与默认不同的项）。

## 4. 验收

- `tools/check-plugin-defaults.py` PASS（契约 = 镜像）；
- 宿主逻辑测试全绿（默认值断言按新值）；
- 真机：设置 → 插件开关中 `Battery` / `ConnectivityReport` 默认 `checked=true`，桌面端电量/网络正常显示；
- `hvigorw` + `run.sh` 门禁通过。

## 5. 状态记录

| 日期 | 事件 |
|---|---|
| 2026-11-15 | 用户裁决「保持现状」；本 CCR 落地 `capabilities.v1.json` 两处默认值 |
| — | 待 CodeArts 复核（数据值变更，不涉及接口形状） |
