# 决策记录：底栏胶囊材质档（HDS `materialLevel`）

- 日期：2026-11-07
- 范围：`entry/src/main/ets/pages/Index.ets` 底部 `HdsTabs.barFloatingStyle.systemMaterialEffect`
- 状态：**已落地 GENTLE**，透明度不理想，作为待优化项保留（用户 2026-11-07 裁决：保留修改意见 + 记录）

## 1. 问题

暗色主题下底部悬浮胶囊出现中性「灰带」，手机比双折叠明显。此前的怀疑对象（`card_bg` 透出、`barBackgroundBlurStyle`、背景渐变层）逐一排除后仍存在。

## 2. 对照实验（ohemu 5559，HarmonyOS 7.0.0 / API 26，暗色）

实验页 `entry/src/main/ets/pages/CapsuleBarCompare.ets`（未跟踪，实验用）：同一背景、同一内容、同一图标文案，仅换底栏实现；顶部按钮切换变体与 HDS 档位。像素统计取胶囊中位色（区域 y 2540–2740，x 100–1150，中位数规避文字/图标）。

| 变体 | 中位 RGB | 亮度 | 饱和 |
|---|---|---|---|
| A 自绘（`Tabs` barHeight 0 + 毛玻璃） | 33,54,95 | 60.7 | 0.65 |
| B 标准 `Tabs` + `barFloatingStyle.systemMaterial(REGULAR)` | 39,62,106 | 69.0 | 0.63 |
| C `HdsTabs` + `ADAPTIVE` | **47,49,53** | 49.7 | **0.11** |
| C `HdsTabs` + `EXQUISITE` | 39,62,106 | 69.0 | 0.63 |
| C `HdsTabs` + `GENTLE` | 39,62,106 | 69.0 | 0.63 |
| C `HdsTabs` + `SMOOTH` | 47,49,53 | 49.7 | 0.11 |
| D 标准 `Tabs` + `CommonModifier(systemMaterial)` | 26,34,48 | 36.0 | 0.46 |

结论：

1. **灰带 = HDS `SMOOTH` 档材质**（RGB 三通道接近 → 中性灰，饱和 0.11）。
2. `ADAPTIVE` 在本机系统策略下**解析为 `SMOOTH`**，因此灰带与本机「系统材质档位」设置强相关，这也解释了手机（Strong）与双折叠（Balanced）观感不同。
3. `EXQUISITE` 与 `GENTLE` 在本机像素完全一致（39,62,106 / 0.63），都是蓝调半透明。
4. `barBackgroundBlurStyle(Regular ↔ NONE)` 在材质生效后**像素零差异**（同一帧统计完全相同）——此前「NONE 能削弱灰带」的观察不成立，应视为档位/背景差异。

截图证据（不入 git）：`~/WorkSpace2/version-shots/capsule-material-20261107/`（`x_*.jpeg` 各变体、`bar_sheet_v2.png` 对照表、`prod_dark2.jpeg` 产品页复验）。

## 3. 决定

`Index.ets` 底栏改为显式 `hdsMaterial.MaterialLevel.GENTLE`：

- 灰带消失（产品页实测中位色 **37,60,103 / 饱和 0.64**，与 GENTLE 档一致）；
- 与设备/系统档位解耦，三端观感一致。

## 4. 已知代价（待优化）

**透明度低于改动前**：GENTLE 胶囊亮度 69.0，高于 SMOOTH 的 49.7，视觉上更「实」、通透感下降。用户认可先去掉灰带，同时把这条记为后续优化项。

候选方向（未验证，勿直接改产品）：

1. 收窄材质色 alpha：`ImmersiveMaterial.materialColor` 已用 `pill_material`（暗色 `#33111A36`），可再降；
2. `materialType` 由 `ADAPTIVE` 改 `IMMERSIVE`，看是否更透；
3. 回退到 A 自绘胶囊（通透最好，但彻底放弃系统材质跟随）；
4. 双折叠 / 平板（5555/5557）复验 GENTLE 观感，确认是否需要按设备分档。

## 5. 复验方法

1. `EntryAbility.loadContent` 临时指向 `pages/CapsuleBarCompare`，`main_pages.json` 注册该页；
2. `LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim tools/sign-debug.sh` + `tools/launch-app.sh`；
3. 产品页复验：Settings → Theme → Dark，返回设备页截图，统计胶囊中位色与饱和。

注意：实验页与 `CapsuleMaterialPrototype.ets` 均为**未跟踪实验文件**，不得进入产品路由；提交前恢复 `pages/Index` 与 `main_pages.json`。
