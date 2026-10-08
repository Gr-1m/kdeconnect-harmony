// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// T2 单测（DEVCOVERAGE 见 devdocs/TEST_COVERAGE_PLAN_20260926.md）：
//   PacketRouter 帧消费与 pair 收口 —— PROCESS §4.2 P0 清单的 ArkTS 半边。
// 约定：@ohos/hypium table-driven，命名 `Test<对象>_<场景>`（PROCESS §4.3）。
//
// 说明：PacketRouter 的发送走构造期可注入的 sendFn（生产装配不传 ⇒ 走 native）；
//       本测试注入一个"总是成功并记录帧"的假发送器，从而脱离真实 native 连接。
import { describe, it, expect } from '@ohos/hypium';
import { PacketRouter, RouterCallbacks } from '../../../main/ets/net/PacketRouter';

const SELF_ID: string = 'self0000000000000000000000000000';
const PEER_ID: string = 'peer1111111111111111111111111111';
const PACKET_PAIR: string = 'kdeconnect.pair';
const PACKET_IDENTITY: string = 'kdeconnect.identity';
const PACKET_PING: string = 'kdeconnect.ping';

interface TestPacket {
  id: number;
  type: string;
  body: Object;
}

interface PairBody {
  pair: boolean;
  timestamp?: number;
}

interface IdentityBody {
  deviceId?: string;
  deviceName?: string;
  deviceType?: string;
  protocolVersion?: number;
  incomingCapabilities?: string[];
  outgoingCapabilities?: string[];
}

interface PingBody {
  message: string;
}

class Recorder implements RouterCallbacks {
  logs: string[] = [];
  sent: string[] = [];
  pairRequests: number = 0;
  lastPairTs: number = 0;
  paired: number = 0;
  unpaired: number = 0;
  capsEvents: number = 0;
  lastIncoming: number = 0;
  lastOutgoing: number = 0;
  pluginTypes: string[] = [];
  handleTypes: string[] = [];

  onPairRequest(deviceId: string, timestamp: number): void {
    this.pairRequests++;
    this.lastPairTs = timestamp;
  }

  onPaired(deviceId: string): void {
    this.paired++;
  }

  onUnpaired(deviceId: string): void {
    this.unpaired++;
  }

  onPeerCapabilities(deviceId: string, incoming: string[], outgoing: string[]): void {
    this.capsEvents++;
    this.lastIncoming = incoming.length;
    this.lastOutgoing = outgoing.length;
  }

  onPluginPacket(deviceId: string, packetType: string, body: Object): boolean {
    this.pluginTypes.push(packetType);
    return this.handleTypes.some((t: string) => t === packetType);
  }
}

function jsonFrame(type: string, body: Object): string {
  const pkt: TestPacket = { id: 1, type: type, body: body };
  return JSON.stringify(pkt) + '\n';
}

function makeRouter(rec: Recorder): PacketRouter {
  // 假发送器：总是成功，记录帧内容（供断言"发了什么"）。
  const fakeSend: (deviceId: string, json: string) => boolean =
    (deviceId: string, json: string) => {
      rec.sent.push(json);
      return true;
    };
  return new PacketRouter(SELF_ID, 'TestPhone', 'phone',
    (msg: string) => { rec.logs.push(msg); }, rec, fakeSend);
}

function hasLog(rec: Recorder, needle: string): boolean {
  return rec.logs.some((l: string) => l.includes(needle));
}

function pairFrame(pair: boolean, ts: number): string {
  const body: PairBody = ts > 0 ? { pair: pair, timestamp: ts } : { pair: pair };
  return jsonFrame(PACKET_PAIR, body);
}

export default function packetRouterTest(): void {
  describe('PacketRouterTest', () => {

    // ---- 帧消费：缓冲 / 半包 / 非法行 ----

    it('TestPacketRouter_frameConsume_twoFramesInOneRead', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const a: IdentityBody = { deviceId: PEER_ID, protocolVersion: 8, incomingCapabilities: ['x'], outgoingCapabilities: [] };
      const b: IdentityBody = { deviceId: PEER_ID, protocolVersion: 8, incomingCapabilities: [], outgoingCapabilities: [] };
      r.onPacket(PEER_ID, jsonFrame(PACKET_IDENTITY, a) + jsonFrame(PACKET_IDENTITY, b));
      expect(rec.capsEvents).assertEqual(2);
    });

    it('TestPacketRouter_frameConsume_halfFrameBufferedUntilCompleted', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const full: string = pairFrame(true, 0);
      const cut: number = Math.floor(full.length / 2);
      r.onPacket(PEER_ID, full.substring(0, cut));
      expect(rec.paired).assertEqual(0);
      expect(rec.pairRequests).assertEqual(0);
      r.onPacket(PEER_ID, full.substring(cut));
      expect(rec.paired).assertEqual(1);
    });

    it('TestPacketRouter_frameConsume_badJsonSkippedThenContinues', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const body: IdentityBody = { deviceId: PEER_ID, protocolVersion: 8, incomingCapabilities: ['x'], outgoingCapabilities: ['y'] };
      r.onPacket(PEER_ID, '{not valid json\n' + jsonFrame(PACKET_IDENTITY, body));
      expect(hasLog(rec, 'bad packet frame')).assertTrue();
      expect(rec.capsEvents).assertEqual(1);
    });

    it('TestPacketRouter_frameConsume_blankLinesIgnored', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const body: IdentityBody = { deviceId: PEER_ID, protocolVersion: 8, incomingCapabilities: [], outgoingCapabilities: [] };
      r.onPacket(PEER_ID, '\n\n' + jsonFrame(PACKET_IDENTITY, body) + '\n\n');
      expect(rec.capsEvents).assertEqual(1);
    });

    it('TestPacketRouter_guard_emptyDeviceIdIgnored', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const body: IdentityBody = { deviceId: PEER_ID, protocolVersion: 8, incomingCapabilities: ['x'], outgoingCapabilities: [] };
      r.onPacket('', jsonFrame(PACKET_IDENTITY, body));
      expect(rec.capsEvents).assertEqual(0);
    });

    it('TestPacketRouter_forgetPeer_clearsHalfFrameBuffer', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const full: string = pairFrame(true, 0);
      const cut: number = Math.floor(full.length / 2);
      r.onPacket(PEER_ID, full.substring(0, cut));
      r.forgetPeer(PEER_ID);
      r.onPacket(PEER_ID, full.substring(cut));
      // 缓冲已被 forgetPeer 清空 ⇒ 尾部孤帧不成帧
      expect(rec.paired).assertEqual(0);
      expect(rec.pairRequests).assertEqual(0);
    });

    // ---- pair 收口 ----

    it('TestPacketRouter_pair_acceptWithoutTimestampClosesPairing', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      r.onPacket(PEER_ID, pairFrame(true, 0));
      expect(rec.paired).assertEqual(1);
      expect(rec.pairRequests).assertEqual(0);
    });

    it('TestPacketRouter_pair_requestWithTimestampAwaitsUserConfirmation', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const now: number = Math.floor(Date.now() / 1000);
      r.onPacket(PEER_ID, pairFrame(true, now));
      // v8 语义：带 timestamp = 对端新请求 ⇒ 交 UI 弹窗（不自动接受）
      expect(rec.pairRequests).assertEqual(1);
      expect(rec.lastPairTs).assertEqual(now);
      expect(rec.paired).assertEqual(0);
    });

    it('TestPacketRouter_pair_localRequestFrameCarriesTimestamp', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const now: number = Math.floor(Date.now() / 1000);
      const ok: boolean = r.requestPair(PEER_ID, now);
      expect(ok).assertTrue();
      expect(rec.sent.length).assertEqual(1);
      expect(rec.sent[0].includes('"timestamp"')).assertTrue();
    });

    it('TestPacketRouter_pair_acceptFrameMustNotCarryTimestamp', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const ok: boolean = r.acceptPair(PEER_ID);
      expect(ok).assertTrue();
      expect(rec.paired).assertEqual(1);
      // MSG77 §3 不变量：接受帧不带 timestamp（带了会被对端当"新请求"⇒ 配对循环）
      expect(rec.sent[0].includes('"timestamp"')).assertFalse();
    });

    it('TestPacketRouter_pair_raceWithPeerIsAutoAccepted', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const now: number = Math.floor(Date.now() / 1000);
      r.requestPair(PEER_ID, now);
      expect(rec.sent.length).assertEqual(1);
      // 双方同时发起：对端也发 {pair:true,timestamp} ⇒ 本侧自动送回 accept（不再弹窗）
      r.onPacket(PEER_ID, pairFrame(true, now));
      expect(rec.paired).assertEqual(1);
      expect(rec.pairRequests).assertEqual(0);
      expect(hasLog(rec, 'pair race')).assertTrue();
      expect(rec.sent.length).assertEqual(2);
    });

    it('TestPacketRouter_pair_clockSkewRejected', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const now: number = Math.floor(Date.now() / 1000);
      r.onPacket(PEER_ID, pairFrame(true, now - 3600));
      expect(rec.pairRequests).assertEqual(0);
      expect(rec.paired).assertEqual(0);
      expect(hasLog(rec, 'clock skew')).assertTrue();
      // 主动回 {pair:false}
      expect(rec.sent.length).assertEqual(1);
    });

    it('TestPacketRouter_pair_falseTriggersUnpair', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      r.onPacket(PEER_ID, pairFrame(false, 0));
      expect(rec.unpaired).assertEqual(1);
      expect(rec.paired).assertEqual(0);
    });

    // ---- identity / 插件包分发 ----

    it('TestPacketRouter_identity_recordsCapabilities', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const body: IdentityBody = {
        deviceId: PEER_ID, deviceName: 'Peer', deviceType: 'laptop', protocolVersion: 8,
        incomingCapabilities: ['kdeconnect.ping', 'kdeconnect.clipboard'], outgoingCapabilities: ['kdeconnect.mpris']
      };
      r.onPacket(PEER_ID, jsonFrame(PACKET_IDENTITY, body));
      expect(rec.capsEvents).assertEqual(1);
      expect(rec.lastIncoming).assertEqual(2);
      expect(rec.lastOutgoing).assertEqual(1);
    });

    it('TestPacketRouter_pluginPacket_handledIsNotLoggedAsUnhandled', 0, () => {
      const rec: Recorder = new Recorder();
      rec.handleTypes.push(PACKET_PING);
      const r: PacketRouter = makeRouter(rec);
      const pb: PingBody = { message: 'hi' };
      r.onPacket(PEER_ID, jsonFrame(PACKET_PING, pb));
      expect(rec.pluginTypes.length).assertEqual(1);
      expect(hasLog(rec, 'unhandled packet type')).assertFalse();
    });

    it('TestPacketRouter_pluginPacket_unhandledIsLogged', 0, () => {
      const rec: Recorder = new Recorder();
      const r: PacketRouter = makeRouter(rec);
      const empty: IdentityBody = {};
      r.onPacket(PEER_ID, jsonFrame('kdeconnect.unknown', empty));
      expect(hasLog(rec, 'unhandled packet type')).assertTrue();
    });

    it('TestPacketRouter_unpairedGatingIsNativeSide_routerStillForwards', 0, () => {
      // 边界文档化：「未配对设备只收 kdeconnect.pair，其余丢弃并 unpair」由 **native** 强制
      // （AGENTS.md 协议约束）；本层(ArkTS)不做配对闸门 ⇒ 插件包一律转发。
      // 此用例锁定该分层事实，防止未来在本层误加第二道闸门造成语义漂移。
      const rec: Recorder = new Recorder();
      rec.handleTypes.push(PACKET_PING);
      const r: PacketRouter = makeRouter(rec);
      const pb: PingBody = { message: 'from-unpaired' };
      r.onPacket(PEER_ID, jsonFrame(PACKET_PING, pb));
      expect(rec.pluginTypes.length).assertEqual(1);
    });
  });
}
