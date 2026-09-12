// Packet 路由层：从 packetReceived 事件的原始数据中切分 NetworkPacket 帧，
// 处理核心握手包（kdeconnect.pair / identity），其余 packet 交给插件宿主（AP-4）。
// 帧约定（kdeconnect-meta protocol.md：换行分隔 JSON）：
//   发送方（本侧）组帧后自带 '\n'；native 自 WP-1a 起保证「一个 packetReceived 事件 = 一个完整帧」，
//   本层仍保留「缓冲 + 按 '\n' 切分 + 尾段留待下次」的容错逻辑（两种派发粒度都正确）。
// 配对语义（AP-1）：请求不再自动接受，交由 UI 弹窗确认（用户裁决：与 iOS 一致）。
import native from 'libkdeconnect_napi.so';

const PROTOCOL_VERSION = 8;
// Android 参考（PairingHandler）：时钟偏差超 30 分钟则拒绝配对请求。
const MAX_TIMESTAMP_DIFF_SECONDS = 1800;

// 核心包类型（由本层处理，不进插件）
const PACKET_PAIR = 'kdeconnect.pair';
const PACKET_IDENTITY = 'kdeconnect.identity';

interface InPacket {
  id: number;
  type: string;
  body: Object;
}

interface OutPacket {
  id: number;
  type: string;
  body: Object;
}

interface PairBody {
  pair?: boolean;
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

// 宿主回调：配对动作、对端能力、插件分发（UI/插件层注入，net 层不依赖插件实现）
export interface RouterCallbacks {
  onPairRequest: (deviceId: string, timestamp: number) => void;
  onPaired: (deviceId: string) => void;
  onUnpaired: (deviceId: string) => void;
  onPeerCapabilities: (deviceId: string, incoming: string[], outgoing: string[]) => void;
  // 返回 true 表示某插件已处理
  onPluginPacket: (deviceId: string, packetType: string, body: Object) => boolean;
}

export class PacketRouter {
  private selfDeviceId: string;
  private selfDeviceName: string;
  private selfDeviceType: string;
  private frameBuffers: Map<string, string> = new Map();
  private logFn: (msg: string) => void;
  private callbacks: RouterCallbacks;
  // 本侧已发起、等待对端确认的配对请求：用于区分「对端确认」与「对端请求」
  private requestedPeers: Set<string> = new Set();

  constructor(selfDeviceId: string, selfDeviceName: string, selfDeviceType: string,
              logFn: (msg: string) => void, callbacks: RouterCallbacks) {
    this.selfDeviceId = selfDeviceId;
    this.selfDeviceName = selfDeviceName;
    this.selfDeviceType = selfDeviceType;
    this.logFn = logFn;
    this.callbacks = callbacks;
  }

  // ---- 供 UI 调用的配对动作 ----

  // 本侧发起配对请求（UI：已连接设备行的「配对」按钮）
  requestPair(deviceId: string): void {
    this.requestedPeers.add(deviceId);
    const body: PairBody = { pair: true, timestamp: Math.floor(Date.now() / 1000) };
    this.sendFrame(deviceId, PACKET_PAIR, body);
    this.logFn('pair request sent to ' + deviceId);
  }

  // UI 确认接受对端请求：回 {pair:true} + 重发 identity
  acceptPair(deviceId: string): void {
    const body: PairBody = { pair: true, timestamp: Math.floor(Date.now() / 1000) };
    this.sendFrame(deviceId, PACKET_PAIR, body);
    this.sendIdentity(deviceId);
    this.logFn('pairing accepted with ' + deviceId);
    this.callbacks.onPaired(deviceId);
  }

  // UI 拒绝对端请求
  rejectPair(deviceId: string): void {
    const body: PairBody = { pair: false };
    this.sendFrame(deviceId, PACKET_PAIR, body);
    this.logFn('pairing rejected for ' + deviceId);
  }

  // 断链/主动解除时清理本侧等待态与帧缓冲
  forgetPeer(deviceId: string): void {
    this.requestedPeers.delete(deviceId);
    this.frameBuffers.delete(deviceId);
  }

  // packetReceived 事件入口。raw 可能含多帧或半帧。
  onPacket(deviceId: string, raw: string): void {
    if (deviceId === '') {
      return;
    }
    const prev: string = this.frameBuffers.get(deviceId) ?? '';
    const data: string = prev + raw;
    const lines: string[] = data.split('\n');
    const last: string | undefined = lines.pop();
    if (last !== undefined) {
      this.frameBuffers.set(deviceId, last);
    }
    for (const line of lines) {
      const frame: string = line.trim();
      if (frame.length > 0) {
        this.handleFrame(deviceId, frame);
      }
    }
  }

  private handleFrame(deviceId: string, frame: string): void {
    let pkt: InPacket;
    try {
      pkt = JSON.parse(frame) as InPacket;
    } catch (e) {
      this.logFn('bad packet frame: ' + (e instanceof Error ? e.message : 'parse error'));
      return;
    }
    if (pkt.type === PACKET_PAIR) {
      this.handlePair(deviceId, pkt.body as PairBody);
      return;
    }
    if (pkt.type === PACKET_IDENTITY) {
      this.handleIdentity(deviceId, pkt.body as IdentityBody);
      return;
    }
    // 其余 packet 交插件宿主（AP-4）
    const handled: boolean = this.callbacks.onPluginPacket(deviceId, pkt.type, pkt.body);
    if (!handled) {
      this.logFn('unhandled packet type: ' + pkt.type);
    }
  }

  // AP-1：不再自动接受。区分两种 pair:true ——
  //   本侧曾发起（requestedPeers 命中）= 对端确认 → onPaired；
  //   否则 = 对端请求 → onPairRequest（UI 弹窗）。
  // v8 请求必须带 timestamp（秒），时钟偏差超限直接拒绝（Android 参考）。
  private handlePair(deviceId: string, body: PairBody): void {
    if (body.pair === true) {
      const ts: number = body.timestamp ?? -1;
      if (ts >= 0) {
        const now: number = Math.floor(Date.now() / 1000);
        if (Math.abs(ts - now) > MAX_TIMESTAMP_DIFF_SECONDS) {
          this.logFn('pair rejected: clock skew ' + (now - ts) + 's from ' + deviceId);
          return;
        }
      }
      if (this.requestedPeers.has(deviceId)) {
        this.requestedPeers.delete(deviceId);
        this.sendIdentity(deviceId);
        this.logFn('pairing confirmed by ' + deviceId);
        this.callbacks.onPaired(deviceId);
        return;
      }
      this.logFn('pair request from ' + deviceId + ' (awaiting user confirmation)');
      this.callbacks.onPairRequest(deviceId, ts);
      return;
    }
    // pair:false = 对端解除配对
    this.requestedPeers.delete(deviceId);
    this.logFn('unpair request from ' + deviceId);
    this.callbacks.onUnpaired(deviceId);
  }

  // 对端 identity：记录能力（供插件装载）并回填名称
  private handleIdentity(deviceId: string, body: IdentityBody): void {
    const incoming: string[] = body.incomingCapabilities ?? [];
    const outgoing: string[] = body.outgoingCapabilities ?? [];
    this.logFn('identity from ' + deviceId + ': ' +
      (body.deviceName ?? '?') + ' v' + (body.protocolVersion ?? '?') +
      ' incoming=' + incoming.length + ' outgoing=' + outgoing.length);
    this.callbacks.onPeerCapabilities(deviceId, incoming, outgoing);
  }

  private sendIdentity(deviceId: string): void {
    const body: IdentityBody = {
      deviceId: this.selfDeviceId,
      protocolVersion: PROTOCOL_VERSION,
      deviceName: this.selfDeviceName,
      deviceType: this.selfDeviceType,
      // 能力由 native 统一持有（d.ts setCapabilities，单一来源）；此处仅发结构占位，
      // 真实 caps 由 native 在 identity 帧内填充（见 d.ts setCapabilities 注释）。
      incomingCapabilities: ['kdeconnect.identity', 'kdeconnect.pair'],
      outgoingCapabilities: ['kdeconnect.identity', 'kdeconnect.pair']
    };
    this.sendFrame(deviceId, PACKET_IDENTITY, body);
  }

  private sendFrame(deviceId: string, type: string, body: Object): void {
    const pkt: OutPacket = { id: Date.now(), type: type, body: body };
    const ok: boolean = native.sendPacket(deviceId, JSON.stringify(pkt) + '\n');
    if (!ok) {
      this.logFn('sendPacket failed (not encrypted yet?) ' + type + ' -> ' + deviceId);
    }
  }
}
