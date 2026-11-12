// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! **场景契约测试（Rust 侧）**：把 `contract/scenarios/*.json` 与同目录的
//! `kcbridge.d.ts`（`EventKind` / `KcApi` 方法集）、`capabilities.v1.json`（插件能力表）互相锁死。
//!
//! 为什么现在能锁、且**不会误红**：这四个场景文件描述的是**冻结桥层的目标行为**
//! （`emit[kind, json]` / `expectCall[name, ...]` / `do[name, ...]`），
//! 其取值域完全由 `kcbridge.d.ts` 定义 ⇒ 断言「场景取值 ∈ 契约定义域」今天即可成立，
//! 不依赖 native 是否已实现冻结面（实现落地后再加「行为对齐」断言，属桥层里程碑）。

use std::collections::BTreeMap;
use std::collections::BTreeSet;

const BRIDGE_DTS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../../../../../contract/kcbridge.d.ts"
));
const CAPABILITIES: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../../../../../contract/capabilities.v1.json"
));
const SCENARIOS: [(&str, &str); 4] = [
    (
        "pairing-in",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../../../../../contract/scenarios/pairing-in.json"
        )),
    ),
    (
        "share-in",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../../../../../contract/scenarios/share-in.json"
        )),
    ),
    (
        "share-out",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../../../../../contract/scenarios/share-out.json"
        )),
    ),
    (
        "ping",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../../../../../contract/scenarios/ping.json"
        )),
    ),
];

/// 从 `export const EventKind: { ... }` 块解析 `名称: 编号`。
fn event_kinds() -> BTreeMap<i64, String> {
    let block = BRIDGE_DTS
        .split("export const EventKind")
        .nth(1)
        .and_then(|rest| rest.split("};").next())
        .expect("kcbridge.d.ts 必须有 EventKind 声明");
    let mut out = BTreeMap::new();
    for line in block.lines() {
        let line = line.trim().trim_end_matches(',');
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let (name, value) = (name.trim(), value.trim().trim_end_matches(';'));
        let name = name.trim_start_matches("readonly").trim();
        if let Ok(code) = value.parse::<i64>() {
            assert!(
                name.chars().all(|c| c.is_ascii_alphanumeric()),
                "EventKind 名称异常: {name}"
            );
            assert!(
                out.insert(code, name.to_owned()).is_none(),
                "EventKind 编号重复: {code}"
            );
        }
    }
    assert!(!out.is_empty(), "EventKind 解析为空");
    out
}

/// 从 `export interface KcApi { ... }` 块解析方法名（形如 `  methodName(`）。
fn kcapi_methods() -> BTreeSet<String> {
    let block = BRIDGE_DTS
        .split("export interface KcApi")
        .nth(1)
        .and_then(|rest| rest.split("\n}").next())
        .expect("kcbridge.d.ts 必须有 KcApi 声明");
    let mut out = BTreeSet::new();
    for line in block.lines() {
        let trimmed = line.trim();
        let Some(open) = trimmed.find('(') else {
            continue;
        };
        let name = trimmed[..open].trim();
        if !name.is_empty()
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && !name.starts_with("//")
        {
            out.insert(name.to_owned());
        }
    }
    assert!(out.len() > 5, "KcApi 方法解析过少: {out:?}");
    out
}

/// `capabilities.v1.json` 里所有插件的 incoming/outgoing packet 类型。
fn capability_types() -> BTreeSet<String> {
    let doc: serde_json::Value =
        serde_json::from_str(CAPABILITIES).expect("capabilities.v1.json 必须可解析");
    let mut out = BTreeSet::new();
    for plugin in doc["plugins"].as_array().expect("plugins[] 必须存在") {
        for key in ["incoming", "outgoing"] {
            for item in plugin[key].as_array().into_iter().flatten() {
                out.insert(item.as_str().expect("能力项必须是字符串").to_owned());
            }
        }
    }
    assert!(!out.is_empty(), "能力表解析为空");
    out
}

/// 协议层 packet 类型（非插件能力，恒存在）。
const PROTOCOL_TYPES: [&str; 2] = ["kdeconnect.identity", "kdeconnect.pair"];

#[test]
fn scenarios_are_well_formed_and_named_after_files() {
    for (name, raw) in SCENARIOS {
        let doc: serde_json::Value = serde_json::from_str(raw).expect("场景必须可解析");
        assert_eq!(
            doc["name"].as_str(),
            Some(name),
            "{name}.json 的 name 必须与文件名一致"
        );
        let steps = doc["steps"].as_array().expect("steps[] 必须存在");
        assert!(!steps.is_empty(), "{name} 的 steps 不得为空");
        for step in steps {
            let obj = step.as_object().expect("每个 step 必须是对象");
            assert_eq!(
                obj.len(),
                1,
                "{name} 的 step 必须恰好一个动作，实际={obj:?}"
            );
            let (action, args) = obj.iter().next().expect("已断言非空");
            assert!(
                matches!(action.as_str(), "do" | "emit" | "expectCall"),
                "{name} 出现未知动作 {action}"
            );
            assert!(
                !args.as_array().expect("动作参数必须是数组").is_empty(),
                "{name} 的 {action} 参数不得为空"
            );
        }
    }
}

#[test]
fn emitted_event_kinds_come_from_frozen_eventkind() {
    let kinds = event_kinds();
    for (name, raw) in SCENARIOS {
        let doc: serde_json::Value = serde_json::from_str(raw).expect("场景必须可解析");
        for step in doc["steps"].as_array().expect("steps[]") {
            let Some(emit) = step.get("emit") else {
                continue;
            };
            let args = emit.as_array().expect("emit 参数必须是数组");
            let code = args[0].as_i64().expect("emit 第一项必须是 EventKind 编号");
            assert!(
                kinds.contains_key(&code),
                "{name} 使用了 EventKind {code}，但 kcbridge.d.ts 未定义"
            );
            let payload = args[1].as_str().expect("emit 第二项必须是 JSON 字符串");
            serde_json::from_str::<serde_json::Value>(payload)
                .unwrap_or_else(|e| panic!("{name} 的 emit 载荷不是合法 JSON: {e}"));
        }
    }
}

#[test]
fn scenario_calls_come_from_frozen_kcapi() {
    let methods = kcapi_methods();
    for (name, raw) in SCENARIOS {
        let doc: serde_json::Value = serde_json::from_str(raw).expect("场景必须可解析");
        for step in doc["steps"].as_array().expect("steps[]") {
            for action in ["do", "expectCall"] {
                let Some(call) = step.get(action) else {
                    continue;
                };
                let first = call.as_array().expect("参数必须是数组")[0]
                    .as_str()
                    .expect("首个参数必须是方法名");
                assert!(
                    methods.contains(first),
                    "{name} 的 {action} 调用了 kcbridge.d.ts/KcApi 未定义的 `{first}`"
                );
            }
        }
    }
}

#[test]
fn scenario_packet_types_are_advertised_by_capabilities() {
    // 把「场景里出现的 packet type」与「能力表 advertised 的类型」交叉核对：
    // 任何一侧新增/改名而另一侧未跟 ⇒ 本测试变红。
    let mut advertised = capability_types();
    for t in PROTOCOL_TYPES {
        advertised.insert(t.to_owned());
    }
    for (name, raw) in SCENARIOS {
        for type_name in packet_types_in(raw) {
            assert!(
                advertised.contains(&type_name),
                "{name} 使用 packet type `{type_name}`，但 capabilities.v1.json 未广告"
            );
        }
    }
}

/// 从场景文本里抽出所有 `"type":"kdeconnect.*"`（含转义形态）。
fn packet_types_in(raw: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let unescaped = raw.replace("\\\"", "\"");
    let needle = "\"type\":\"";
    let mut rest = unescaped.as_str();
    while let Some(pos) = rest.find(needle) {
        rest = &rest[pos + needle.len()..];
        if let Some(end) = rest.find('"') {
            let value = &rest[..end];
            if value.starts_with("kdeconnect.") {
                out.insert(value.to_owned());
            }
            rest = &rest[end..];
        }
    }
    out
}

#[test]
fn pairing_scenario_keeps_its_golden_event_sequence() {
    let raw = SCENARIOS
        .iter()
        .find(|(name, _)| *name == "pairing-in")
        .expect("pairing-in 必须存在")
        .1;
    let doc: serde_json::Value = serde_json::from_str(raw).expect("场景必须可解析");
    let kinds: Vec<i64> = doc["steps"]
        .as_array()
        .expect("steps[]")
        .iter()
        .filter_map(|s| s.get("emit"))
        .map(|emit| {
            emit.as_array().expect("emit 数组")[0]
                .as_i64()
                .expect("kind")
        })
        .collect();
    // 参考实现（kdeconn1111 `kc-core/src/contract_tests.rs:91`）同为该序列：
    // EngineStarted(0) → DeviceVisible(3) → PairRequest(7) → DeviceUpdated(5) → Packet(9)
    assert_eq!(
        kinds,
        vec![0, 3, 7, 5, 9],
        "pairing-in 的黄金事件序列被改动"
    );
}
