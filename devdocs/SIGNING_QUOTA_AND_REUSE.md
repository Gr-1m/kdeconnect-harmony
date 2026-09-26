# SIGNING_QUOTA_AND_REUSE — 华为侧签名：配额规则 / 复用失败根因 / 一次性开通清单

> 2026-09-26。作者 DevEco。**触发场景**：本会话装机回归被 `Provision number exceeds limit` 阻塞。
> 结论先行：**华为侧签名只需一次性开通，之后可无限次本地重签；配额只被"创建/更新 provision"消耗。**

## 1. 什么耗配额、什么不耗（实测）

| 动作 | 耗配额？ | 依据 |
|---|---|---|
| 创建/更新 provision（profile）——`devecocli signature generate`、DevEco「自动签名」**重新生成**、AGC 改设备清单 | ❌ **耗** | 报错原文 `Provision number exceeds limit`；`~/.ohos/config` 下每生成一次就多一组 `default_kdeconnect-harmony_<hash>.*` |
| 用**已有** profile 本地重签 hap（`hap-sign-tool sign-app -mode localSign`） | ✅ 不耗 | `tools/sign-debug.ps1` 实测：产出 `entry-debug-signed.hap`（8769 KB），无任何云侧调用 |
| `devecocli build` / `hdc install` / 启动 / 反复跑测试 | ✅ 不耗 | 本地签名 + 设备侧校验 |

**本会话配额被烧光的直接原因**：为"提交前把 `build-profile.json5` 的 `signingConfigs` 复位成 `[]`"，我**每次构建前都 `signature generate --force`** ✗ ⇒ 每次都新建一份 provision ✗。**该做法已废止**：材料常驻本地，提交时由 Omp **只排除该 hunk**。

## 2. 现有签名"复用失败"的两个根因（已实测取证）

**取证方式**：直接读 `~/.ohos/config` 下三份 `.p7b` 的明文内容。

| 材料 | `bundle-name` | `type` | `device-ids` | 签发者 |
|---|---|---|---|---|
| `Gr1m_kdeconnect-harmony_*.p7b`（华为账号） | **`org.kde.kdeconnect.harmony`** | debug | `454D55057494E058…0000`（**仅一台**） | **华为**（developer-id 30086000717926956） |
| `openharmony\default_kdeconnect-harmony_*.p7b` | `org.kde.kdeconnect.harmony` | **release** | — | OpenHarmony |
| `~/.ohos/kdc-sign\profile-debug.p7b` | `org.kde.kdeconnect.harmony` | debug | 同上 `454D5505…` | `pki_internal`（OpenHarmony） |

1. **主因：包名不匹配** —— 现存 profile 全是**旧名** `org.kde.kdeconnect.harmony`，而当前 hap 是 `org.kde.kdeconnect`（2026-09-21 改名）⇒ 必被拒。
2. **附加原因：签发者不被真机信任** —— 我用 SDK 自带 OpenHarmony 链签的 profile，**HarmonyOS 平板拒绝**：
   `hdc install sign\entry-debug-signed.hap → code:9568257 error: fail to verify pkcs7 file`。
   （⇒ 本地零配额签名对 **OpenHarmony 模拟器/设备**有效，对 **HarmonyOS 真机**无效。）

**并发现**：现有华为 profile 授权的 UDID 是 **第三台设备**（`454D5505…`），而
- 手机 `63Q0226131002161` = `AD169E9A0B01FC59…` ✗
- 平板 `5KPBB25901205531` = `8AF6B368…` ✗
⇒ **两台的"老包名探针"方案也不可行**（授权设备不在场）⇒ 这就是选择"等配额"的原因。

## 3. 一次性开通清单（配额恢复后照此做一次，之后永久零配额）

**用户 / AGC 侧（唯一耗配额的一步）**
1. DevEco Studio → Project Structure → Signing Configs → 勾「**Automatically generate signature**」（或 AGC 建 debug profile）；
2. 参数要点：
   - `bundleName` = **`org.kde.kdeconnect`**（新名；**不要再退回老名探针** —— 最终状态本该如此，省一轮合并）；
   - `device-ids` **一次把两台都填上**：手机 `AD169E9A0B01FC59…` + 平板 `8AF6B368…`
     （取法：`hdc -t <serial> shell bm get --udid`）
   - 有效期取默认上限即可（到期才需再耗一次）。
3. 完成后 `~/.ohos/config` 会出现 `…_.p7b`（`type:debug`、issuer=华为、`bundle-name: org.kde.kdeconnect`）。

**DevEco（我）侧（零配额）**
4. 把那组材料（`.p12` / `.p7b` / 证书链）拷进 `sign/huawei/`（**gitignored**）；
5. `tools/sign-debug.ps1` 加一个 `-UseHuawei` 分支：`-keystoreFile`/`-profileFile` 指向 `sign/huawei/…`（其余流程不变）；
6. 之后所有真机回归：`tools/sign-debug.ps1 -UseHuawei all` ⇒ **零配额** ✓。

**Omp 侧**
7. `tools/sign-debug.ps1` 建议入库（**文件头须写明适用范围**：OpenHarmony 模拟器/设备可用、HarmonyOS 真机须换华为材料）；`sign/` 与 `sign/huawei/` 必须保持 gitignored ✓。

## 4. 配额恢复前的替代验证路径（若有需要）
- **ohemu 模拟器**：本地 OpenHarmony 签名对它有效 ✓（`tools/verify-on-ohemu.sh`）；本机当前**无可用模拟器**（`devecocli device list` 仅见平板/手机）⇒ 需宿主侧启动并接入；
- 模拟器网络：用户态 NAT 下 **UDP 广播到不了宿主局域网** ⇒ 用 App 的「**手动连接**」填对端 `192.168.3.4:1716` ✓（正好走已修好的输入校验）。

## 5. 当前状态
- 真机回归：**等配额**（用户 2026-09-26 决定）；
- 批次 2（6a/6b）接口设计已交付：`devdocs/DESIGN_BATCH2_deveco.md`；
- 阶段 3 批次 1 已由 Omp 接线入库（`857300c`，Index 3438 行）。
