// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// P0-A3 扩展审计 —— `PluginEventBus` 回归（**零 Kit 依赖，宿主 bun 与设备 hypium 双跑**）。
// 覆盖：路由命中/未命中、兜底、退订只删自身、重复注册留痕、**处理器抛异常不冒泡**（本次新增的隔离护栏）、clear。
import { describe, it, expect } from '@ohos/hypium';
import { PluginEventBus } from '../../../main/ets/state/PluginEventBus';
import { PluginEvent } from '../../../main/ets/plugins/PluginEvent';

function ev(kind: string): PluginEvent {
  const e: PluginEvent = { kind: kind };
  return e;
}

export default function pluginEventBusTest(): void {
  describe('PluginEventBusTest', () => {
    it('TestPluginEventBus_dispatch_routesToRegisteredHandler', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      const seen: string[] = [];
      bus.on('battery', (deviceId: string, e: PluginEvent): void => {
        seen.push(`${deviceId}:${e.kind}`);
      });
      const consumed: boolean = bus.dispatch('dev1', ev('battery'));
      expect(consumed).assertTrue();
      expect(seen.length).assertEqual(1);
      expect(seen[0]).assertEqual('dev1:battery');
    });

    it('TestPluginEventBus_dispatch_unknownKind_usesFallbackAndReturnsFalse', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      let fallbackHits: number = 0;
      bus.setFallback((): void => {
        fallbackHits++;
      });
      expect(bus.dispatch('dev1', ev('nope'))).assertFalse();
      expect(fallbackHits).assertEqual(1);
    });

    it('TestPluginEventBus_unsubscribe_removesOnlyOwnHandler', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      let first: number = 0;
      let second: number = 0;
      const off1: () => void = bus.on('mpris', (): void => {
        first++;
      });
      bus.on('mpris', (): void => {
        second++;
      });
      off1();                                  // 第二个处理器已覆盖第一个 ⇒ 退订不应删掉它
      bus.dispatch('dev1', ev('mpris'));
      expect(first).assertEqual(0);
      expect(second).assertEqual(1);
    });

    it('TestPluginEventBus_reregister_logsReplacement', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      const logs: string[] = [];
      bus.setLog((m: string): void => {
        logs.push(m);
      });
      bus.on('clipboard.request', (): void => {
      });
      bus.on('clipboard.request', (): void => {
      });
      expect(logs.some((l: string): boolean => l.includes('route replaced'))).assertTrue();
    });

    it('TestPluginEventBus_handlerThrow_doesNotPropagateAndIsLogged', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      const logs: string[] = [];
      bus.setLog((m: string): void => {
        logs.push(m);
      });
      bus.on('systemvolume.sinks', (): void => {
        throw new Error('boom');
      });
      let consumed: boolean = false;
      let threw: boolean = false;
      try {
        consumed = bus.dispatch('dev1', ev('systemvolume.sinks'));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();                       // 绝不冒泡（否则打断事件派发链）
      expect(consumed).assertTrue();                     // 路由上仍算「已消费」
      expect(logs.some((l: string): boolean => l.includes('handler threw'))).assertTrue();
    });

    it('TestPluginEventBus_fallbackThrow_doesNotPropagate', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      bus.setFallback((): void => {
        throw new Error('fallback boom');
      });
      let threw: boolean = false;
      try {
        bus.dispatch('dev1', ev('unhandled.kind'));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });

    it('TestPluginEventBus_kindsAndClear', 0, () => {
      const bus: PluginEventBus = new PluginEventBus();
      bus.on('a', (): void => {
      });
      bus.on('b', (): void => {
      });
      expect(bus.kinds().length).assertEqual(2);
      bus.clear();
      expect(bus.kinds().length).assertEqual(0);
      bus.clear();                                        // 幂等
      expect(bus.kinds().length).assertEqual(0);
    });
  });
}
