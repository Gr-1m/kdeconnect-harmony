// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 信任存储的**纯解析层**（T10；自 common/TrustStore.ets 逐字保真抽出）。
//
// 抽离动机（同 T1 的"抽纯函数脱离环境"套路）：解析/迁移逻辑原本是 `TrustStore` 的 private static，
// 与 `@kit.ArkData` 的 Preferences I/O 同文件 ⇒ **无法单测**。抽出后：
//   · 本文件**零 Kit 依赖** ⇒ 进宿主纯逻辑通道（tools/arkts-logic-test.ps1，秒级、无需设备）；
//   · `TrustStore` 只留 I/O（load/save 与 Preferences 交互），解析职责单一化。
//
// 语义**逐字保真**（勿改，改动即迁移行为变更）：
//   ① 新格式 `{schemaVersion, devices:[{id,name,certPem,pairedAt,paired}]}`：
//      schemaVersion 缺失 ⇒ legacy v0（告警、尽力解析）；**高于**当前版本 ⇒ 告警但**绝不整份丢弃**；
//      条目缺 id/空 id ⇒ 丢弃；其余字段逐项回落默认（name←id / certPem='' / pairedAt=0 / paired=true）；
//      JSON 损坏或 devices 非数组 ⇒ 返回空（交由重新配对修复）。
//   ② 旧格式 `[{id,name}]` ⇒ 升级为 TrustedDevice[]（certPem=''、pairedAt=0、paired=true；空 id 丢弃）。
import { TrustedDevice, TrustStoreData, TRUST_SCHEMA_VERSION } from '../model/TrustModels';

/** 新格式解析（schemaVersion 校验 + 字段级容错） */
export function parseTrustStore(raw: string): TrustedDevice[] {
  const out: TrustedDevice[] = [];
  try {
    const data: TrustStoreData = JSON.parse(raw) as TrustStoreData;
    // P3-10②：读取并校验 schemaVersion（旧实现只解析 devices，版本号完全没用上）。
    const sv: number = data.schemaVersion ?? 0;
    if (sv > TRUST_SCHEMA_VERSION) {
      console.warn(`KDC trust store schemaVersion=${sv} newer than supported ${TRUST_SCHEMA_VERSION}; parsing best-effort`);
    } else if (sv === 0) {
      console.warn('KDC trust store schemaVersion missing (legacy v0); parsing best-effort');
    }

    const list: TrustedDevice[] = data.devices;
    for (const d of list) {
      if (d.id !== undefined && d.id !== '') {
        out.push({
          id: d.id,
          name: d.name ?? d.id,
          certPem: d.certPem ?? '',
          pairedAt: d.pairedAt ?? 0,
          paired: d.paired ?? true
        });
      }
    }
  } catch (e) {
    // 结构损坏 → 返回空，交由后续迁移/重新配对修复
  }
  return out;
}

/** 旧格式 `[{id,name}]` → TrustedDevice[]（一次性迁移） */
export function migrateLegacyTrust(raw: string): TrustedDevice[] {
  const out: TrustedDevice[] = [];
  try {
    const arr: Array<Record<string, string>> = JSON.parse(raw) as Array<Record<string, string>>;
    for (const it of arr) {
      const id: string = it['id'] ?? '';
      if (id !== '') {
        out.push({ id: id, name: it['name'] ?? id, certPem: '', pairedAt: 0, paired: true });
      }
    }
  } catch (e) {
    // 旧结构损坏 → 忽略
  }
  return out;
}
