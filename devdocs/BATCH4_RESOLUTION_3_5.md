# ③⑤ 两块去向裁决 + 装配自检升回强制

> 2026-09-27。依据 AtomCode MSG119 建议2执行。

## ③ FilePortal 去向裁决：**保持现状（并入 DeviceActionController）**

**理由**：
- FilePortal 当前只有 `pickAndSendFile` + `stageSendJob` 两个方法，与设备动作紧密耦合（依赖 `getSelectedDeviceId`、`getConnectedDevices`、`getHostContext`、`payloadEnqueueSend` 等注入回调）
- 独立成文件需引入额外注入回调层（FilePortal 自己的注入回调 → DeviceActionController 的注入回调 → 页面），增加间接层无实质收益
- 文件发送是"用户对设备执行的动作"，语义上属于 DeviceActionController 的职责范围
- 若将来文件共享功能扩展（如接收端实现、目录挂载），可再评估拆分

## ⑤ TeardownRegistry 去向裁决：**保持现状（并入 DeviceController 的注入回调）**

**理由**：
- cleanup 的实现在页面侧（`onDisconnectedCleanup`/`onDeviceLostCleanup`/`onErrorCleanup`），controller 只是转发点
- 这些 cleanup 逻辑与设备状态紧密相关（需更新 `connectedDevices`、通知 `pairSession`、调 `syncSelectedDevice`），拆分后需更多注入回调来协调状态一致性
- 当前 DeviceController 的 `handleEvent` 是事件枢纽，cleanup 是 `disconnected`/`deviceLost`/`error` 三个分支的天然组成部分，拆分会割裂事件处理流程
- 独立 TeardownRegistry 的收益（减少 controller 行数）不抵成本（增加注入回调层 + 状态协调复杂度）

## 装配自检升回强制：**已实现**

**实现方式**：静态检查脚本 `tools/check-injection-contract.py`
- 解析 DeviceController.ets / DeviceActionController.ets 的注入回调声明
- 检查 Index.ets 中是否有对应的 `this.xxxController.fieldName =` 装配语句
- 任何声明但未装配的字段 → 退出码 1 + 报告
- 当前结果：24 + 22 = 46 个注入回调全部装配 ✅

**与运行时自检的关系**：
- 静态检查（本脚本）：构建前运行，覆盖"字段存在性对表"——抓缺失型缺陷（P0 类型）
- 运行时自检（Index.ets:582-586 plugin routes count）：构建后运行，覆盖"注册数量一致性"——抓运行时注册失败
- 两者互补，共同构成装配自检的强制门禁

**建议将静态检查纳入构建门禁**：
```bash
python3 tools/check-injection-contract.py && \
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap
```
