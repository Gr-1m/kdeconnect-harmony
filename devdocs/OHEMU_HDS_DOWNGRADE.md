# ohemu HDS 降级验证

`tools/verify-on-ohemu.sh` 是临时构建期降级路径，主线保留商用 HarmonyOS HDS 实现。

## 当前覆盖

- `HdsTabs` → 标准 `Tabs`
- `HdsNavigation` → 标准 `Column`
- 删除 `barFloatingStyle`、`titleMode`、`hideBackButton`、`bindToScrollable`、`titleBar` 等 HDS 专属修饰器
- 删除 `@kit.UIDesignKit` 静态导入及设备页 HDS 配置 helper
- `HdsSideBar` / `HdsSideMenu` 当前尚未接入主线；若未来源码出现，脚本会 fail closed，不会静默构建白屏版本。接入后需增加标准 `SideBarContainer` 替换规则。

## 静态验证

2026-10-12 在 `dev/zcodeinit` 隔离 worktree 完成：

- Python 转换器成功处理当前 `Index.ets`
- 输出不再包含 `@kit.UIDesignKit`、`HdsTabs`、`HdsNavigation`、`.titleBar()`、`.bindToScrollable()`、`.barFloatingStyle()`
- 注入未来 `HdsSideBar` 标记时，转换器按预期失败且不修改源文件
- `bash -n tools/verify-on-ohemu.sh` 通过

## 尚未完成

本轮 ohemu 未连接（`hdc list targets` 为空），因此没有重复执行构建、签名、安装、启动链。设备可用后运行：

```bash
tools/verify-on-ohemu.sh
# 完成后必须还原临时降级：
tools/verify-on-ohemu.sh --revert
```
