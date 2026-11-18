// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// B-1 —— `EventKind`（18 项）→ `NetEvent` 解码回归（零 Kit 依赖 ⇒ 宿主 bun 与设备 hypium 双跑）。
// 契约漂移由 `tools/check-event-kinds.py`（run.sh 门禁）核对；用例按 native `net_event_json` 的真实字段构造。
import { describe, it, expect } from '@ohos/hypium';
import {
  EVENT_KIND_NAMES, EVENT_KIND_TO_TYPE, decodeEvent, setEventLogSink, droppedEvents
} from '../../../main/ets/common/EventKind';
import { NetEvent } from '../../../main/ets/common/EventShapes';

function jsonOf(obj: string): string {
  return obj;
}

export default function eventKindTest(): void {
  describe('EventKindTest', () => {
    it('TestEventKind_mirrorCoversContract18', 0, () => {
      expect(EVENT_KIND_NAMES.size).assertEqual(18);
      expect(EVENT_KIND_NAMES.get(0)).assertEqual('EngineStarted');
      expect(EVENT_KIND_NAMES.get(14)).assertEqual('Log');
      expect(EVENT_KIND_NAMES.get(15)).assertEqual('Connected');
      expect(EVENT_KIND_NAMES.get(16)).assertEqual('Disconnected');
      expect(EVENT_KIND_NAMES.get(17)).assertEqual('Error');
    });

    it('TestEventKind_mappedKindsCoverNativeKindOf', 0, () => {
      // native `kind_of` 的产出集合：3/4/7/9/15/16/17 + 10/12/13
      const expected: number[] = [3, 4, 7, 9, 10, 12, 13, 15, 16, 17];
      for (const k of expected) {
        expect(EVENT_KIND_TO_TYPE.get(k) !== undefined).assertTrue();
      }
      expect(EVENT_KIND_TO_TYPE.get(10)).assertEqual('payloadTransfer');
      expect(EVENT_KIND_TO_TYPE.get(15)).assertEqual('connected');
      expect(EVENT_KIND_TO_TYPE.get(17)).assertEqual('error');
    });

    it('TestEventKind_decodeRoundTripForEachType', 0, () => {
      expect(decodeEvent(3, jsonOf('{"type":"deviceDiscovered","deviceId":"d1"}'))?.type).assertEqual('deviceDiscovered');
      expect(decodeEvent(4, jsonOf('{"type":"deviceLost","deviceId":"d1"}'))?.type).assertEqual('deviceLost');
      expect(decodeEvent(7, jsonOf('{"type":"pairingRequest","deviceId":"d1","deviceName":"PC"}'))?.type).assertEqual('pairingRequest');
      expect(decodeEvent(9, jsonOf('{"type":"packetReceived","deviceId":"d1","packet":"{}"}'))?.type).assertEqual('packetReceived');
      expect(decodeEvent(15, jsonOf('{"type":"connected","deviceId":"d1","role":"server"}'))?.type).assertEqual('connected');
      expect(decodeEvent(16, jsonOf('{"type":"disconnected","deviceId":"d1"}'))?.type).assertEqual('disconnected');
      expect(decodeEvent(17, jsonOf('{"type":"error","errorCode":109,"errorMessage":"x"}'))?.type).assertEqual('error');
      const p: NetEvent | undefined = decodeEvent(13,
        jsonOf('{"type":"payloadTransfer","payloadTransferId":7,"payloadState":"finished","payloadSize":100,"payloadBytesDone":100}'));
      expect(p?.payloadTransferId).assertEqual(7);
      expect(p?.payloadState).assertEqual('finished');
    });

    it('TestEventKind_logKindGoesToSinkNotEvent', 0, () => {
      const seen: string[] = [];
      setEventLogSink((m: string): void => {
        seen.push(m);
      });
      const out: NetEvent | undefined = decodeEvent(14, jsonOf('{"msg":"engine log line"}'));
      expect(out === undefined).assertTrue();                       // 不作为事件转发
      expect(seen.some((l: string): boolean => l.includes('native log'))).assertTrue();
    });

    it('TestEventKind_mismatchUnknownAndBadJsonAreDropped', 0, () => {
      const seen: string[] = [];
      setEventLogSink((m: string): void => {
        seen.push(m);
      });
      // kind=15 但 type=packetReceived ⇒ 契约漂移，必须丢弃并记录
      expect(decodeEvent(15, jsonOf('{"type":"packetReceived"}')) === undefined).assertTrue();
      // 未知 kind
      expect(decodeEvent(99, jsonOf('{"type":"connected"}')) === undefined).assertTrue();
      // 无内部事件的 kind（如 0 EngineStarted）
      expect(decodeEvent(0, jsonOf('{"type":"connected"}')) === undefined).assertTrue();
      // 坏 JSON
      expect(decodeEvent(3, jsonOf('not json')) === undefined).assertTrue();
      expect(seen.some((l: string): boolean => l.includes('type mismatch'))).assertTrue();
      expect(seen.some((l: string): boolean => l.includes('no internal event mapped'))).assertTrue();
      expect(droppedEvents.size > 0).assertTrue();
    });
  });
}

