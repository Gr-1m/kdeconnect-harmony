// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// RemoteInputPlugin 单测（阶段4 方向B / B1b）——**锁定线上字段名/类型**（B0 争议的最终防线）。
//
// 做法：经 `PluginBase.bind()` 注入捕获式 sendFn ⇒ 直接观测发出去的 JSON 帧 body，
// 从而把"schema 字段名"固化为断言（AtomCode MSG134 §二 的 5 处更正由此防回退）。
import { describe, it, expect } from '@ohos/hypium';
import { RemoteInputPlugin } from '../../../main/ets/plugins/RemoteInputPlugin';
import { MousepadInputPipeline, MousepadButton } from '../../../main/ets/plugins/MousepadInput';

const DEVICE: string = 'peer1111111111111111111111111111';
const PACKET_REQUEST: string = 'kdeconnect.mousepad.request';
const PACKET_KEYBOARDSTATE: string = 'kdeconnect.mousepad.keyboardstate';

// 发送帧的 body（与实现同形的可选字段）
interface SentBody {
  dx?: number;
  dy?: number;
  scroll?: boolean;
  singleclick?: boolean;
  doubleclick?: boolean;
  middleclick?: boolean;
  rightclick?: boolean;
  key?: string;
  specialKey?: number;
}

interface SentFrame {
  id: number;
  type: string;
  body: SentBody;
}

interface UiEvent {
  kind: string;
  data: string;
}

// keyboardstate body（测试侧类型，供对象字面量获得上下文）
interface KbBody {
  state?: boolean;
}

class Capture {
  frames: SentFrame[] = [];
  raws: string[] = [];
  logs: string[] = [];
  events: UiEvent[] = [];

  lastBody(): SentBody {
    return this.frames[this.frames.length - 1].body;
  }

  countTrueBooleans(b: SentBody): number {
    let n: number = 0;
    if (b.singleclick === true) {
      n++;
    }
    if (b.doubleclick === true) {
      n++;
    }
    if (b.middleclick === true) {
      n++;
    }
    if (b.rightclick === true) {
      n++;
    }
    return n;
  }

  hasLog(needle: string): boolean {
    return this.logs.some((l: string) => l.includes(needle));
  }
}

function bound(cap: Capture): RemoteInputPlugin {
  const p: RemoteInputPlugin = new RemoteInputPlugin();
  p.bind(DEVICE, (deviceId: string, json: string): boolean => {
    cap.raws.push(json);
    cap.frames.push(JSON.parse(json) as SentFrame);
    return true;
  }, (m: string): void => {
    cap.logs.push(m);
  }, (deviceId: string, ev): void => {
    cap.events.push({ kind: ev.kind, data: ev.text ?? '' });
  });
  return p;
}

export default function remoteInputPluginTest(): void {
  describe('RemoteInputPluginTest', () => {

    // ---- 移动 / 滚动（scroll 是布尔标记 —— 设计 §1.1 的核心更正） ----

    it('TestRemoteInputPlugin_move_sendsDxDyWithoutScrollFlag', 0, () => {
      const cap: Capture = new Capture();
      bound(cap).move(3, -4);
      expect(cap.frames.length).assertEqual(1);
      expect(cap.frames[0].type).assertEqual(PACKET_REQUEST);
      expect(cap.lastBody().dx).assertEqual(3);
      expect(cap.lastBody().dy).assertEqual(-4);
      expect(cap.lastBody().scroll === true).assertFalse();
    });

    it('TestRemoteInputPlugin_scroll_isBooleanFlagWithDxDy', 0, () => {
      const cap: Capture = new Capture();
      bound(cap).scroll(0, 5);
      expect(cap.lastBody().scroll).assertTrue();
      expect(cap.lastBody().dx).assertEqual(0);
      expect(cap.lastBody().dy).assertEqual(5);
    });

    // ---- 点击：四布尔，每次只置一个 ----

    it('TestRemoteInputPlugin_click_mapsEachButtonToItsOwnBoolean', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      const buttons: MousepadButton[] = ['single', 'double', 'middle', 'right'];
      for (const b of buttons) {
        p.click(b);
      }
      expect(cap.frames.length).assertEqual(4);
      expect(cap.frames[0].body.singleclick).assertTrue();
      expect(cap.frames[1].body.doubleclick).assertTrue();
      expect(cap.frames[2].body.middleclick).assertTrue();
      expect(cap.frames[3].body.rightclick).assertTrue();
      for (const f of cap.frames) {
        expect(cap.countTrueBooleans(f.body)).assertEqual(1);
      }
    });

    // ---- 键盘 ----

    it('TestRemoteInputPlugin_key_sendsKeyField', 0, () => {
      const cap: Capture = new Capture();
      bound(cap).key('a');
      expect(cap.lastBody().key).assertEqual('a');
    });

    it('TestRemoteInputPlugin_key_emptyIsDropped', 0, () => {
      const cap: Capture = new Capture();
      bound(cap).key('');
      expect(cap.frames.length).assertEqual(0);
    });

    // ---- 特殊键：0 与越界拒发（设计 §1.3 不变量） ----

    it('TestRemoteInputPlugin_specialKey_zeroRejected', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      p.specialKey(0);
      expect(cap.frames.length).assertEqual(0);
      expect(cap.hasLog('rejected')).assertTrue();
    });

    it('TestRemoteInputPlugin_specialKey_outOfRangeRejected', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      p.specialKey(33);
      p.specialKey(-1);
      expect(cap.frames.length).assertEqual(0);
    });

    it('TestRemoteInputPlugin_specialKey_validRangeSent', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      p.specialKey(1);
      p.specialKey(32);
      expect(cap.frames.length).assertEqual(2);
      expect(cap.frames[0].body.specialKey).assertEqual(1);
      expect(cap.frames[1].body.specialKey).assertEqual(32);
    });

    // ---- 收包：keyboardstate 的 state 字段（非 visible —— 设计 §1.2 更正） ----

    it('TestRemoteInputPlugin_keyboardState_readyEmitsReadyEvent', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      const body: KbBody = { state: true };
      const handled: boolean = p.onPacketReceived(PACKET_KEYBOARDSTATE, body);
      expect(handled).assertTrue();
      expect(cap.events.length).assertEqual(1);
      expect(cap.events[0].kind).assertEqual('mousepadKeyboardState');
      expect(cap.events[0].data).assertEqual('ready');
    });

    it('TestRemoteInputPlugin_keyboardState_idleEmitsIdleEvent', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      const body: KbBody = { state: false };
      p.onPacketReceived(PACKET_KEYBOARDSTATE, body);
      expect(cap.events[0].data).assertEqual('idle');
    });

    it('TestRemoteInputPlugin_keyboardState_missingStateTreatedAsIdle', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      const empty: KbBody = {};
      const handled: boolean = p.onPacketReceived(PACKET_KEYBOARDSTATE, empty);
      expect(handled).assertTrue();
      expect(cap.events[0].data).assertEqual('idle');
    });

    it('TestRemoteInputPlugin_otherPacketTypeNotHandled', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      const other: KbBody = {};
      expect(p.onPacketReceived('kdeconnect.ping', other)).assertFalse();
      expect(cap.events.length).assertEqual(0);
    });

    // ---- 与 pipeline 的接线（B1a + B1b 贯通） ----

    it('TestRemoteInputPlugin_pipelineDragProducesMoveFrame', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      const pipe: MousepadInputPipeline = p.input();
      pipe.beginDrag();
      pipe.dragTo(7, 9, 1000);
      expect(cap.frames.length).assertEqual(1);
      expect(cap.lastBody().dx).assertEqual(7);
      expect(cap.lastBody().dy).assertEqual(9);
    });

    it('TestRemoteInputPlugin_pipelineTapProducesClickFrame', 0, () => {
      const cap: Capture = new Capture();
      const p: RemoteInputPlugin = bound(cap);
      p.input().tap('right');
      expect(cap.frames.length).assertEqual(1);
      expect(cap.lastBody().rightclick).assertTrue();
    });
  });
}
