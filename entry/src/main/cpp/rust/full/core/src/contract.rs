// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 契约版本（CCR-3 §1.3 / 阶段 B 任务卡 B-4）。
//!
//! `contract/kcbridge.d.ts` 是桥层唯一事实源；本模块把它**编译期嵌入**并做内容哈希，
//! 经 napi 导出为 `contractVersion()`。ArkTS 侧用 `EXPECTED_CONTRACT_VERSION`（由
//! `tools/gen-contract-version.py` 生成）比对，不匹配 ⇒ 拒绝 `start()`（E109 语义，不静默继续）。
//!
//! 为什么用内容哈希而不是手工版本号：契约一改，哈希自动变 ⇒ 不存在「忘了升版本」的漂移；
//! `tools/gen-contract-version.py --update` 是唯一的同步入口，`--check` 与本模块单测共同兜底。

/// 构建期嵌入的契约文本（唯一事实源：仓库根 `contract/kcbridge.d.ts`）。
pub const CONTRACT_DTS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../../../../../contract/kcbridge.d.ts"
));

/// FNV-1a 32 位（无依赖、跨语言一致；与 `tools/gen-contract-version.py` 同算法）。
pub fn contract_version_of(bytes: &[u8]) -> u32 {
    let mut hash: u32 = 0x811c_9dc5;
    for b in bytes {
        hash ^= u32::from(*b);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    hash
}

/// 期望值：由 `tools/gen-contract-version.py --update` 写入（**不要手改**）。
pub const CONTRACT_VERSION_EXPECTED: u32 = 0x34a04c39;

/// 运行期契约版本（= 嵌入契约的内容哈希）。
pub fn contract_version() -> u32 {
    contract_version_of(CONTRACT_DTS.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_is_stable() {
        // 标准测试向量（FNV-1a 32）
        assert_eq!(contract_version_of(b""), 0x811c_9dc5);
        assert_eq!(contract_version_of(b"a"), 0xe40c_292c);
        assert_eq!(contract_version_of(b"foobar"), 0xbf9c_f968);
    }

    #[test]
    fn contract_version_matches_generated_constant() {
        assert_eq!(
            contract_version(),
            CONTRACT_VERSION_EXPECTED,
            "contract/kcbridge.d.ts 已改但未同步常量：跑 `python3 tools/gen-contract-version.py --update`"
        );
    }

    #[test]
    fn embedded_contract_is_the_frozen_surface() {
        // 防「嵌入错了文件」：冻结面必须仍含 KcApi 与 EventKind 声明。
        assert!(CONTRACT_DTS.contains("export interface KcApi"));
        assert!(CONTRACT_DTS.contains("export const EventKind"));
    }
}
