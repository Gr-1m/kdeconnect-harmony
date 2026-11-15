// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// P1-3 —— 插件默认开关（`defaultEnabled` → UI 默认开关；MSG264 §1 Q2 裁决）回归。
// **零 Kit 依赖 ⇒ 宿主 bun 与设备 hypium 双跑**。
//
// 覆盖验收三条：① 默认值读取（契约镜像 + 未知键回落）② 持久化（覆盖解析/序列化只存差异）
// ③ **不影响能力广告**（关掉开关后 `outgoingCapabilities()` 不变）+ ④ 门禁真的拦住「发出」。
import { describe, it, expect } from '@ohos/hypium';
import {
  PLUGIN_DEFAULT_ENABLED, pluginKeys, pluginDefaultEnabled,
  parsePluginOverrides, serializePluginOverrides, resolvePluginEnabled,
  resolvePacketEnabled, PACKET_OWNERS
} from '../../../main/ets/common/PluginDefaults';
import { PluginRegistry } from '../../../main/ets/plugins/PluginRegistry';
import { PluginHost } from '../../../main/ets/plugins/PluginHost';
import { PluginBase, SendFrameFn } from '../../../main/ets/plugins/PluginBase';
import { PluginEvent } from '../../../main/ets/plugins/PluginEvent';

// ArkTS 严格模式：对象字面量必须有显式声明的类型（arkts-no-untyped-obj-literals）
interface FakeBatteryBody {
  level: number;
}

class FakeBattery extends PluginBase {
  sent: number = 0;

  constructor() {
    super();
    this.displayName = 'Fake Battery';
    this.supportedPacketTypes = [];
    this.outgoingPacketTypes = ['kdeconnect.battery'];
  }

  fireSend(): boolean {
    const body: FakeBatteryBody = { level: 42 };
    return this.send('kdeconnect.battery', body);
  }
}

export default function pluginDefaultsTest(): void {
  describe('PluginDefaultsTest', () => {
    // ---------- ① 默认值读取 ----------
    it('TestPluginDefaults_mirrorsContractTable', 0, () => {
      // 契约 14 项（CCR-4）：battery / connectivityreport 默认 true；sftp 默认 false
      expect(pluginKeys().length).assertEqual(14);
      expect(pluginDefaultEnabled('battery')).assertTrue();
      expect(pluginDefaultEnabled('connectivityreport')).assertTrue();
      expect(pluginDefaultEnabled('sftp')).assertFalse();
      expect(pluginDefaultEnabled('ping')).assertTrue();
      expect(pluginDefaultEnabled('share')).assertTrue();
      expect(PLUGIN_DEFAULT_ENABLED.size).assertEqual(14);
    });

    it('TestPluginDefaults_unknownKeyFallsBackEnabled', 0, () => {
      expect(pluginDefaultEnabled('brand.new.plugin')).assertTrue();
    });

    // ---------- ② 持久化（覆盖解析/序列化） ----------
    it('TestPluginOverrides_parseValidAndIgnoreBadData', 0, () => {
      const ok: Map<string, boolean> = parsePluginOverrides('{"battery":true}');
      expect(ok.size).assertEqual(1);
      expect(ok.get('battery')).assertTrue();
      // 坏 JSON / 未知键 / 非布尔 ⇒ 一律忽略，不抛
      expect(parsePluginOverrides('not json').size).assertEqual(0);
      expect(parsePluginOverrides('{"unknown":true}').size).assertEqual(0);
      expect(parsePluginOverrides('{"battery":"yes"}').size).assertEqual(0);
      expect(parsePluginOverrides('').size).assertEqual(0);
    });

    it('TestPluginOverrides_serializeKeepsOnlyDifferences', 0, () => {
      const m: Map<string, boolean> = new Map<string, boolean>();
      m.set('sftp', true);                 // 与契约默认(false)不同 ⇒ 保留
      m.set('ping', true);                 // 与契约默认(true)相同 ⇒ 丢弃
      const raw: string = serializePluginOverrides(m);
      expect(raw.includes('sftp')).assertTrue();
      expect(raw.includes('ping')).assertFalse();
    });

    it('TestPluginOverrides_resolvePrecedence', 0, () => {
      const m: Map<string, boolean> = new Map<string, boolean>();
      m.set('battery', true);
      expect(resolvePluginEnabled('battery', m)).assertTrue();     // 覆盖优先
      expect(resolvePluginEnabled('ping', m)).assertTrue();        // 无覆盖 ⇒ 契约默认
      m.set('ping', false);
      expect(resolvePluginEnabled('ping', m)).assertFalse();
      expect(resolvePluginEnabled('connectivityreport', new Map<string, boolean>())).assertTrue();
    });

    // ---------- ③ 能力广告不变 ④ 门禁真拦（按 **packet**，因插件实例↔契约键非一一对应） ----------
    it('TestPluginGate_disabledSkipsSendButCapsUnchanged', 0, () => {
      const registry: PluginRegistry = new PluginRegistry();
      registry.register('battery', (): PluginBase => new FakeBattery());
      const logs: string[] = [];
      const host: PluginHost = new PluginHost(registry, (m: string): void => {
        logs.push(m);
      });
      let delivered: number = 0;
      const sendFn: SendFrameFn = (_dev: string, _json: string): boolean => {
        delivered++;
        return true;
      };
      const uiFn = (_dev: string, _ev: PluginEvent): void => {
      };

      // ③ 能力广告与开关**无关**
      expect(registry.outgoingCapabilities().includes('kdeconnect.battery')).assertTrue();

      host.setPacketEnabledFn((pkt: string): boolean => pkt !== 'kdeconnect.battery');   // 关该 packet
      host.loadForDevice('dev1', [], [], sendFn, uiFn);
      const inst: PluginBase = host.pluginsFor('dev1')[0];
      expect((inst as FakeBattery).fireSend()).assertFalse();     // 关 ⇒ 发送被拦
      expect(delivered).assertEqual(0);
      expect(logs.some((l: string): boolean => l.includes('disabled by plugin switch'))).assertTrue();

      // ④ 重新打开 ⇒ 放行
      host.setPacketEnabledFn((): boolean => true);
      host.unloadForDevice('dev1');
      host.loadForDevice('dev1', [], [], sendFn, uiFn);
      const inst2: PluginBase = host.pluginsFor('dev1')[0];
      expect((inst2 as FakeBattery).fireSend()).assertTrue();
      expect(delivered).assertEqual(1);
      expect(registry.outgoingCapabilities().includes('kdeconnect.battery')).assertTrue();
    });

    it('TestPacketOwners_multiOwnerAnyKeyOn', 0, () => {
      // 契约：kdeconnect.mousepad.request 同属 mousepad + presenter
      const keys: string[] | undefined = PACKET_OWNERS.get('kdeconnect.mousepad.request');
      expect(keys !== undefined).assertTrue();
      expect(keys!.length).assertEqual(2);
      const onlyPresenters: Map<string, boolean> = new Map<string, boolean>();
      onlyPresenters.set('mousepad', false);       // mousepad 关
      onlyPresenters.set('presenter', true);       // presenter 开
      expect(resolvePacketEnabled('kdeconnect.mousepad.request', onlyPresenters)).assertTrue();
      const bothOff: Map<string, boolean> = new Map<string, boolean>();
      bothOff.set('mousepad', false);
      bothOff.set('presenter', false);
      expect(resolvePacketEnabled('kdeconnect.mousepad.request', bothOff)).assertFalse();
    });

    it('TestPacketOwners_defaultsAndUnknown', 0, () => {
      const none: Map<string, boolean> = new Map<string, boolean>();
      expect(resolvePacketEnabled('kdeconnect.ping', none)).assertTrue();                 // 契约默认开
      expect(resolvePacketEnabled('kdeconnect.battery', none)).assertTrue();              // CCR-4：默认开
      expect(resolvePacketEnabled('kdeconnect.sftp.request', none)).assertFalse();        // 契约默认关
      expect(resolvePacketEnabled('kdeconnect.brand.new', none)).assertTrue();            // 未登记 ⇒ 放行
    });

  });
}
