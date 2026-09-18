# 接收文件的落地位置与「导出/查看」规划（DevEco Code）

> 2026-09-17。回用户提问：① 保存时看到的系统授权弹窗说明权限有；② 文件保存在哪、文件管理里怎么找；③ 规划「点击接收文件跳转文件管理」。

## 1. 现状（读码结论）

| 事实 | 代码位置 |
|---|---|
| 接收文件落在**应用沙箱**：`${filesDir}/kdeconnect/`（真机 ≈ `/data/storage/el2/base/haps/entry/files/kdeconnect/`） | `Index.ets:1962 ensureKdcDir()`、`:2090 dest` |
| 落盘由 native 执行：`native.keepPayload(transferId, dest)` | `Index.ets:2098` |
| 保存前会**申请写权限**（按扩展名映射） | `Index.ets:2091 ensureWritePermission()` / `:2113 writePermissionFor()` |
| UI 文案已写明去向：「接收的文件将保存到：应用沙箱 files/kdeconnect/」 | `files_save_path` |

## 2. 为什么在「文件管理」里看不到

**沙箱目录对系统文件管理器不可见**（三方应用沙箱是私有存储，文件管理只呈现公共目录/共享数据）。
⇒ 用户看到的「申请文件保存权限授权的系统弹窗」是**我们自己在保存前主动申请的写权限**（`ensureWritePermission`），但**写沙箱并不需要它** ⇒ 该弹窗属于**冗余**（甚至会误导"已授权=能在文件管理看到"）。

## 3. 规划（按成本/收益排序）

### P0（先纠偏，零风险）
1. **去掉冗余写权限申请**：落盘目标是沙箱 ⇒ 不再调 `ensureWritePermission`（或仅在目标为公共目录时申请）；保留失败提示即可。
2. **文案明确**：在「已接收」弹窗/文件页注明「保存在 App 私有目录，可通过下方『另存为』导出到文件管理」。

### P1（让用户能拿到文件，官方正路）
3. **「另存为…」**：给「已接收」弹窗与文件页的接收行加一个动作 ⇒ 调 `picker.DocumentViewPicker.save()`（系统保存面板，用户自选目录，如「下载」）⇒ 保存到用户选定位置后**在文件管理中可直接看到**（无需三方权限，符合平台规范）。
4. **「打开」**：`fileUri.getUriFromPath(dest)` + `startAbility`（`ohos.want.action.viewData` + `FLAG_AUTH_READ_URI_PERMISSION` + MIME）⇒ 交给系统预览/关联应用打开。

### P2（体验增强）
5. **批量导出**：弹窗内「全选另存为」（逐个走 save picker 或选择目录后批量拷贝）。
6. **历史行显示保存位置**：区分「沙箱路径 / 已导出到 xxx」。

### 明确不做（平台限制）
7. **「跳转文件管理并定位到该目录」没有公开 API**：三方应用无法寻址系统文件管理器的具体路径；因此「让用户看得到」只能通过 3/4（保存面板或系统打开）实现，不能靠"跳转文件管理"。

## 4. 依赖与风险

- 3/4 只用到 `@kit.CoreFileKit`（`picker`/`fileIo`/`fileUri`）与 `want`，均为三方可用，**不需要新增权限**；
- 与既有「自动落盘 + 已保存」流程兼容（沙箱内仍自动保存一份，导出是额外动作）；
- 需 UI 文案新增 3~4 条（`file_export`、`file_open`、`file_export_ok/failed`）。
