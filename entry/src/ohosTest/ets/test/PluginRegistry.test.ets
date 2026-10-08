// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// caps 单一来源一致性单测（TEST_COVERAGE_PLAN_20260926.md T6「caps 协商语义」的 ArkTS 半边；
// Omp MSG128 §4 点名该跨层一致性用例落在 DevEco 车道）。
//
// 锁定的不变量：
//   ① 能力事实来源唯一 —— `PluginRegistry` 汇总自各插件声明的 `supportedPacketTypes` /
//      `outgoingPacketTypes`，**无第二份硬编码清单**（对齐 docs/12「注册表驱动，禁止硬编码 switch」）；
//   ② 汇总语义 = 去重并集（同类型多插件声明只出现一次）；
//   ③ `register` 按 key 幂等；`createAll` 每次调用返回**新实例**（关键语义①：每设备一份，避免状态串扰）；
//   ④ 真实插件的声明格式良好（`kdeconnect.` 前缀、无空白、同数组内不重复）。
import { describe, it, expect } from '@ohos/hypium';
import { PluginBase } from '../../../main/ets/plugins/PluginBase';
import { PluginRegistry } from '../../../main/ets/plugins/PluginRegistry';
import { BatteryPlugin } from '../../../main/ets/plugins/BatteryPlugin';
import { ClipboardPlugin } from '../../../main/ets/plugins/ClipboardPlugin';
import { ConnectivityReportPlugin } from '../../../main/ets/plugins/ConnectivityReportPlugin';
import { FindMyPhonePlugin } from '../../../main/ets/plugins/FindMyPhonePlugin';
import { MprisPlugin } from '../../../main/ets/plugins/MprisPlugin';
import { NotificationPlugin } from '../../../main/ets/plugins/NotificationPlugin';
import { PingPlugin } from '../../../main/ets/plugins/PingPlugin';
import { RemoteInputPlugin } from '../../../main/ets/plugins/RemoteInputPlugin';
import { RunCommandPlugin } from '../../../main/ets/plugins/RunCommandPlugin';
import { SharePlugin } from '../../../main/ets/plugins/SharePlugin';
import { SystemVolumePlugin } from '../../../main/ets/plugins/SystemVolumePlugin';

const EXPECTED_REAL_PLUGIN_COUNT = 11;

// 测试替身：可控 caps 声明的插件
class FakePlugin extends PluginBase {
  constructor(incoming: string[], outgoing: string[]) {
    super();
    this.displayName = 'fake';
    this.supportedPacketTypes = incoming;
    this.outgoingPacketTypes = outgoing;
  }
}

// 独立实现的"去重并集"（用于交叉核对 PluginRegistry.aggregate，避免同源自证）
function independentUnion(plugins: PluginBase[], incoming: boolean): string[] {
  const out: string[] = [];
  for (const p of plugins) {
    const types: string[] = incoming ? p.supportedPacketTypes : p.outgoingPacketTypes;
    for (const t of types) {
      if (!out.includes(t)) {
        out.push(t);
      }
    }
  }
  return out;
}

function registerRealPlugins(reg: PluginRegistry): void {
  reg.register('battery', () => new BatteryPlugin());
  reg.register('clipboard', () => new ClipboardPlugin());
  reg.register('connectivity_report', () => new ConnectivityReportPlugin());
  reg.register('findmyphone', () => new FindMyPhonePlugin());
  reg.register('mpris', () => new MprisPlugin());
  reg.register('notification', () => new NotificationPlugin());
  reg.register('ping', () => new PingPlugin());
  reg.register('remoteinput', () => new RemoteInputPlugin());
  reg.register('runcommand', () => new RunCommandPlugin());
  reg.register('share', () => new SharePlugin());
  reg.register('systemvolume', () => new SystemVolumePlugin());
}

export default function pluginRegistryTest(): void {
  describe('PluginRegistryTest', () => {

    // ---- ② 汇总语义：去重并集 ----

    it('TestPluginRegistry_incomingCapabilities_isDedupedUnion', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      reg.register('a', () => new FakePlugin(['kdeconnect.ping', 'kdeconnect.clipboard'], []));
      reg.register('b', () => new FakePlugin(['kdeconnect.ping', 'kdeconnect.battery'], []));
      const caps: string[] = reg.incomingCapabilities();
      expect(caps.length).assertEqual(3);
      expect(caps.includes('kdeconnect.ping')).assertTrue();
      expect(caps.includes('kdeconnect.clipboard')).assertTrue();
      expect(caps.includes('kdeconnect.battery')).assertTrue();
    });

    it('TestPluginRegistry_outgoingCapabilities_isDedupedUnion', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      reg.register('a', () => new FakePlugin([], ['kdeconnect.mpris.request']));
      reg.register('b', () => new FakePlugin([], ['kdeconnect.mpris.request', 'kdeconnect.ping']));
      const caps: string[] = reg.outgoingCapabilities();
      expect(caps.length).assertEqual(2);
      expect(caps.includes('kdeconnect.mpris.request')).assertTrue();
      expect(caps.includes('kdeconnect.ping')).assertTrue();
    });

    it('TestPluginRegistry_incomingAndOutgoingAreIndependent', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      reg.register('a', () => new FakePlugin(['kdeconnect.in.only'], ['kdeconnect.out.only']));
      expect(reg.incomingCapabilities().includes('kdeconnect.out.only')).assertFalse();
      expect(reg.outgoingCapabilities().includes('kdeconnect.in.only')).assertFalse();
    });

    // ---- ③ 注册表语义 ----

    it('TestPluginRegistry_register_isIdempotentByKey', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      reg.register('dup', () => new FakePlugin(['kdeconnect.ping'], []));
      reg.register('dup', () => new FakePlugin(['kdeconnect.battery'], []));
      expect(reg.pluginKeys().length).assertEqual(1);
      expect(reg.incomingCapabilities().includes('kdeconnect.battery')).assertFalse();
    });

    it('TestPluginRegistry_pluginKeys_preserveRegistrationOrder', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      reg.register('z', () => new FakePlugin([], []));
      reg.register('a', () => new FakePlugin([], []));
      const keys: string[] = reg.pluginKeys();
      expect(keys.length).assertEqual(2);
      expect(keys[0]).assertEqual('z');
      expect(keys[1]).assertEqual('a');
    });

    it('TestPluginRegistry_createAll_returnsFreshInstancePerCall', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      reg.register('a', () => new FakePlugin(['kdeconnect.ping'], []));
      const first: PluginBase[] = reg.createAll();
      const second: PluginBase[] = reg.createAll();
      // 关键语义①：每设备一份实例，两次 createAll 不得复用同一对象
      expect(first.length).assertEqual(1);
      expect(second.length).assertEqual(1);
      expect(first[0] === second[0]).assertFalse();
    });

    // ---- ④ 真实插件声明的格式良好性（单一来源的正确性） ----

    it('TestPluginCaps_realPluginsAreWellFormed', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      registerRealPlugins(reg);
      const plugins: PluginBase[] = reg.createAll();
      expect(plugins.length).assertEqual(EXPECTED_REAL_PLUGIN_COUNT);
      for (const p of plugins) {
        for (const t of p.supportedPacketTypes.concat(p.outgoingPacketTypes)) {
          expect(t.startsWith('kdeconnect.')).assertTrue();
          expect(t === t.trim()).assertTrue();
          expect(t.includes(' ')).assertFalse();
        }
        for (const t of p.supportedPacketTypes) {
          expect(p.supportedPacketTypes.filter((x: string) => x === t).length).assertEqual(1);
        }
        for (const t of p.outgoingPacketTypes) {
          expect(p.outgoingPacketTypes.filter((x: string) => x === t).length).assertEqual(1);
        }
      }
    });

    it('TestPluginCaps_everyRealPluginDeclaresAtLeastOneCapability', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      registerRealPlugins(reg);
      for (const p of reg.createAll()) {
        expect(p.supportedPacketTypes.length + p.outgoingPacketTypes.length > 0).assertTrue();
      }
    });

    // ---- ① 单一来源：汇总结果 == 各插件声明的独立去重并集 ----

    it('TestPluginRegistry_aggregateMatchesIndependentUnion', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      registerRealPlugins(reg);
      const instances: PluginBase[] = reg.createAll();

      const expectedIn: string[] = independentUnion(instances, true);
      const expectedOut: string[] = independentUnion(instances, false);
      const gotIn: string[] = reg.incomingCapabilities();
      const gotOut: string[] = reg.outgoingCapabilities();

      expect(gotIn.length).assertEqual(expectedIn.length);
      expect(gotOut.length).assertEqual(expectedOut.length);
      for (const t of expectedIn) {
        expect(gotIn.includes(t)).assertTrue();
      }
      for (const t of expectedOut) {
        expect(gotOut.includes(t)).assertTrue();
      }
    });

    it('TestPluginRegistry_realCapsContainKnownTypes', 0, () => {
      const reg: PluginRegistry = new PluginRegistry();
      registerRealPlugins(reg);
      const gotIn: string[] = reg.incomingCapabilities();
      const gotOut: string[] = reg.outgoingCapabilities();
      // 真实内容锚点（防"汇总为空也算通过"）
      expect(gotIn.includes('kdeconnect.ping')).assertTrue();
      expect(gotIn.includes('kdeconnect.systemvolume')).assertTrue();
      expect(gotOut.includes('kdeconnect.mpris.request')).assertTrue();
      expect(gotOut.includes('kdeconnect.runcommand.request')).assertTrue();
      expect(gotIn.length > 5).assertTrue();
    });
  });
}
