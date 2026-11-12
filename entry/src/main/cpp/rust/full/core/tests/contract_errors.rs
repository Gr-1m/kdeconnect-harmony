// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! **契约一致性测试（Rust 侧）**：把仓库根 `contract/errors.v1.json` 作为唯一事实源，
//! 与 `kdc_native::errors` 的码表/分级/kind/name 逐条比对。
//!
//! 存在的意义（MSG249）：此前 `errors.rs` 全是**手写常量 + 硬编码期望值**，
//! 契约 JSON 与实现可双向漂移而测试全绿。本文件用 `include_str!` 直接吃契约工件，
//! 任何一侧改动（新增/删除码、改 name、改 kind、改 disposition）都会**让测试变红**。

use kdc_native::errors::{self, Disposition};

/// 7 级上溯到仓库根：core → full → rust → cpp → main → src → entry → <repo root>
const ERRORS_JSON: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../../../../../contract/errors.v1.json"
));

/// 契约里的一条记录：`(code, name, kind, disposition)`
type Entry = (i64, String, String, String);

fn contract_entries() -> Vec<Entry> {
    let doc: serde_json::Value =
        serde_json::from_str(ERRORS_JSON).expect("contract/errors.v1.json 必须可解析");
    assert_eq!(doc["version"].as_i64(), Some(1), "契约版本应为 1");
    let codes = doc["codes"]
        .as_array()
        .expect("contract/errors.v1.json 必须有 codes[]");
    assert!(!codes.is_empty(), "契约 codes[] 不得为空");
    codes
        .iter()
        .map(|c| {
            let code = c["code"].as_i64().expect("每项必须有整数 code");
            let name = c["name"].as_str().expect("每项必须有 name").to_owned();
            let kind = c["kind"].as_str().expect("每项必须有 kind").to_owned();
            let disposition = c["disposition"]
                .as_str()
                .expect("每项必须有 disposition")
                .to_owned();
            (code, name, kind, disposition)
        })
        .collect()
}

fn disposition_of(text: &str) -> Disposition {
    match text {
        "FatalLink" => Disposition::FatalLink,
        "DropPacket" => Disposition::DropPacket,
        "Ignorable" => Disposition::Ignorable,
        "Infra" => Disposition::Infra,
        other => panic!("契约出现未知 disposition: {other}"),
    }
}

#[test]
fn code_set_matches_errors_module() {
    let mut from_contract: Vec<i32> = contract_entries()
        .into_iter()
        .map(|(code, ..)| code as i32)
        .collect();
    let mut from_module: Vec<i32> = errors::ALL_CODES.to_vec();

    let mut contract_sorted = from_contract.clone();
    contract_sorted.sort_unstable();
    let count = contract_sorted.len();
    contract_sorted.dedup();
    assert_eq!(count, contract_sorted.len(), "契约 codes[] 存在重复 code");

    from_contract.sort_unstable();
    from_module.sort_unstable();
    assert_eq!(
        from_module, from_contract,
        "errors::ALL_CODES 与 contract/errors.v1.json 的码集合必须一致"
    );
}

#[test]
fn kind_matches_is_throw() {
    for (code, name, kind, _) in contract_entries() {
        let code = code as i32;
        match kind.as_str() {
            "throw" => assert!(
                errors::is_throw(code),
                "{name}({code}) 契约 kind=throw，但 errors::is_throw=false"
            ),
            "event" => assert!(
                !errors::is_throw(code),
                "{name}({code}) 契约 kind=event，但 errors::is_throw=true"
            ),
            other => panic!("{name}({code}) 契约出现未知 kind: {other}"),
        }
    }
}

#[test]
fn disposition_matches_contract() {
    for (code, name, _, disposition) in contract_entries() {
        let code = code as i32;
        assert_eq!(
            errors::disposition(code),
            disposition_of(&disposition),
            "{name}({code}) disposition 与契约不一致"
        );
    }
}

#[test]
fn name_lookup_matches_contract() {
    for (code, name, ..) in contract_entries() {
        assert_eq!(
            errors::name(code as i32),
            name,
            "errors::name({code}) 与契约 name 不一致"
        );
    }
}

#[test]
fn every_contract_code_is_explicitly_known() {
    for (code, name, ..) in contract_entries() {
        assert!(
            errors::is_known(code as i32),
            "{name}({code}) 未被 errors::is_known 认作已知码（说明落入 disposition 的 `_ =>` 兜底）"
        );
    }
}
