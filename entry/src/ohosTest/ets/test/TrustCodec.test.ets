// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// T10 —— TrustStore 解析/迁移 单测（TEST_COVERAGE_PLAN_20260926.md：
// 「旧 rememberedDevices 格式一次性迁移、schemaVersion、损坏文件回退」）。
//
// 测试对象是**抽出的纯函数**（common/TrustCodec.ets，零 Kit 依赖）⇒
// **进宿主纯逻辑通道**（tools/arkts-logic-test.ps1）：秒级、无需设备/模拟器。
//
// 写法注意：ArkTS 要求对象/数组字面量有声明类型 ⇒ 统一经下方**类型化 helper** 造 JSON 串。
import { describe, it, expect } from '@ohos/hypium';
import { parseTrustStore, migrateLegacyTrust } from '../../../main/ets/common/TrustCodec';
import { TrustedDevice } from '../../../main/ets/model/TrustModels';

// 存储原始形状（仅测试用，字段全可选以构造各种"缺字段/畸形"输入）
interface RawEntry {
  id?: string;
  name?: string;
  certPem?: string;
  pairedAt?: number;
  paired?: boolean;
}

interface RawStore {
  schemaVersion?: number;
  devices?: RawEntry[];
}

// 畸形形状（devices 非数组）单独建模：ArkTS 对象字面量需接口上下文，不能用 Record 充当
interface BrokenStore {
  schemaVersion?: string;
  devices?: string;
}

function entry(id: string, name: string): RawEntry {
  const e: RawEntry = { id: id, name: name };
  return e;
}

function storeJson(sv: number, devices: RawEntry[]): string {
  const s: RawStore = { schemaVersion: sv, devices: devices };
  return JSON.stringify(s);
}

function storeNoVersionJson(devices: RawEntry[]): string {
  const s: RawStore = { devices: devices };
  return JSON.stringify(s);
}

function storeMissingDevicesJson(): string {
  const s: RawStore = { schemaVersion: 3 };
  return JSON.stringify(s);
}

function storeDevicesNotArrayJson(): string {
  const s: BrokenStore = { schemaVersion: '3', devices: 'oops' };
  return JSON.stringify(s);
}

export default function trustCodecTest(): void {
  describe('TrustStoreParseTest', () => {

    it('TestTrustCodec_parse_validStore_roundTripsFields', 0, () => {
      const one: RawEntry = { id: 'dev1', name: 'Laptop', certPem: 'PEM', pairedAt: 123, paired: true };
      const out: TrustedDevice[] = parseTrustStore(storeJson(3, [one]));
      expect(out.length).assertEqual(1);
      expect(out[0].id).assertEqual('dev1');
      expect(out[0].name).assertEqual('Laptop');
      expect(out[0].certPem).assertEqual('PEM');
      expect(out[0].pairedAt).assertEqual(123);
      expect(out[0].paired).assertTrue();
    });

    it('TestTrustCodec_parse_missingOptionalFields_getDefaults', 0, () => {
      const bare: RawEntry = { id: 'dev1' };
      const out: TrustedDevice[] = parseTrustStore(storeJson(3, [bare]));
      expect(out.length).assertEqual(1);
      expect(out[0].name).assertEqual('dev1');    // name 回落 id
      expect(out[0].certPem).assertEqual('');
      expect(out[0].pairedAt).assertEqual(0);
      expect(out[0].paired).assertTrue();          // 缺省视为已配对
    });

    it('TestTrustCodec_parse_pairedFalsePreserved', 0, () => {
      const off: RawEntry = { id: 'd', paired: false };
      expect(parseTrustStore(storeJson(3, [off]))[0].paired).assertFalse();
    });

    it('TestTrustCodec_parse_dropsEntriesWithoutId', 0, () => {
      const keep: RawEntry = { id: 'keep', name: 'k' };
      const noId: RawEntry = { name: 'no-id' };
      const emptyId: RawEntry = { id: '', name: 'empty-id' };
      const out: TrustedDevice[] = parseTrustStore(storeJson(3, [keep, noId, emptyId]));
      expect(out.length).assertEqual(1);
      expect(out[0].id).assertEqual('keep');
    });

    it('TestTrustCodec_parse_corruptJson_returnsEmpty', 0, () => {
      expect(parseTrustStore('{not json').length).assertEqual(0);
      expect(parseTrustStore('').length).assertEqual(0);
    });

    it('TestTrustCodec_parse_missingSchemaVersion_isBestEffortNotDiscarded', 0, () => {
      // legacy v0（无版本号）⇒ 告警但**仍解析**，绝不整份丢弃
      const out: TrustedDevice[] = parseTrustStore(storeNoVersionJson([entry('dev1', 'L')]));
      expect(out.length).assertEqual(1);
      expect(out[0].id).assertEqual('dev1');
    });

    it('TestTrustCodec_parse_newerSchemaVersion_isBestEffortNotDiscarded', 0, () => {
      // 高于当前版本 ⇒ 告警但**仍尽力解析可用字段**
      const out: TrustedDevice[] = parseTrustStore(storeJson(99, [entry('dev1', 'L')]));
      expect(out.length).assertEqual(1);
      expect(out[0].id).assertEqual('dev1');
    });

    it('TestTrustCodec_parse_devicesNotArray_returnsEmpty', 0, () => {
      // 结构损坏（devices 缺失 / 非数组）⇒ 空列表，交由重新配对修复
      expect(parseTrustStore(storeMissingDevicesJson()).length).assertEqual(0);
      expect(parseTrustStore(storeDevicesNotArrayJson()).length).assertEqual(0);
    });

    it('TestTrustCodec_parse_emptyDeviceList_returnsEmpty', 0, () => {
      expect(parseTrustStore(storeJson(3, [])).length).assertEqual(0);
    });
  });

  describe('TrustStoreMigrateLegacyTest', () => {

    it('TestTrustCodec_migrate_oldFormat_upgradesWithDefaults', 0, () => {
      const raw: string = JSON.stringify([entry('old1', 'Old Laptop')]);
      const out: TrustedDevice[] = migrateLegacyTrust(raw);
      expect(out.length).assertEqual(1);
      expect(out[0].id).assertEqual('old1');
      expect(out[0].name).assertEqual('Old Laptop');
      expect(out[0].certPem).assertEqual('');   // 旧格式无证书
      expect(out[0].pairedAt).assertEqual(0);
      expect(out[0].paired).assertTrue();        // 旧条目一律视为已配对
    });

    it('TestTrustCodec_migrate_missingName_fallsBackToId', 0, () => {
      const noName: RawEntry = { id: 'old1' };
      const out: TrustedDevice[] = migrateLegacyTrust(JSON.stringify([noName]));
      expect(out[0].name).assertEqual('old1');
    });

    it('TestTrustCodec_migrate_dropsEntriesWithoutId', 0, () => {
      const noId: RawEntry = { name: 'no-id' };
      const ok: RawEntry = { id: 'ok', name: 'n' };
      const emptyId: RawEntry = { id: '', name: 'e' };
      const out: TrustedDevice[] = migrateLegacyTrust(JSON.stringify([noId, ok, emptyId]));
      expect(out.length).assertEqual(1);
      expect(out[0].id).assertEqual('ok');
    });

    it('TestTrustCodec_migrate_corruptInput_returnsEmpty', 0, () => {
      expect(migrateLegacyTrust('not json').length).assertEqual(0);
      // 合法 JSON 但非数组（for..of 不可迭代）⇒ 同样安全返回空
      const notArray: RawEntry = { id: 'x' };
      expect(migrateLegacyTrust(JSON.stringify(notArray)).length).assertEqual(0);
    });

    it('TestTrustCodec_migrate_emptyArray_returnsEmpty', 0, () => {
      expect(migrateLegacyTrust('[]').length).assertEqual(0);
    });
  });
}
