// Packet 路由层：从 packetReceived 事件的原始数据中切分 NetworkPacket 帧，
// 处理基础握手包（kdeconnect.pair / identity / ping）。
// 帧约定（kdeconnect-meta protocol.md：换行分隔 JSON）：
//   发送方（本侧）组帧后自带 '\n'；接收方（本侧）按设备缓冲、按 '\n' 切分，
//   末尾不完整帧留到下次。packetReceived 的 packet 字段是原始 TLS 读数据，
//   可能含多帧或半帧，不能当单帧直接 parse。
import native from 'libkdeconnect_napi.so';

const PROTOCOL_VERSION = 8;
// Android 参考（PairingHandler）：时钟偏差超 30 分钟则拒绝配对请求。
const MAX_TIMESTAMP_DIFF_SECONDS = 1800;

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

interface PingBody {
  message?: string;
}

export class PacketRouter {
  private selfDeviceId: string;
  private selfDeviceName: string;
  private selfDeviceType: string;
  private incomingCaps: string[];
  private outgoingCaps: string[];
  private frameBuffers: Map<string, string> = new Map();
  private logFn: (msg: string) => void;
  private onPaired: ((deviceId: string) => void) | undefined;
  private onUnpaired: ((deviceId: string) => void) | undefined;

  constructor(selfDeviceId: string, selfDeviceName: string, selfDeviceType: string,
              logFn: (msg: string) => void,
              onPaired?: (deviceId: string) => void,
              onUnpaired?: (deviceId: string) => void) {
    this.selfDeviceId = selfDeviceId;
    this.selfDeviceName = selfDeviceName;
    this.selfDeviceType = selfDeviceType;
    this.incomingCaps = ['kdeconnect.ping', 'kdeconnect.identity', 'kdeconnect.pair'];
    this.outgoingCaps = ['kdeconnect.ping'];
    this.logFn = logFn;
    this.onPaired = onPaired;
    this.onUnpaired = onUnpaired;
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
    switch (pkt.type) {
      case 'kdeconnect.pair':
        this.handlePair(deviceId, pkt.body as PairBody);
        break;
      case 'kdeconnect.identity':
        this.handleIdentity(deviceId, pkt.body as IdentityBody);
        break;
      case 'kdeconnect.ping':
        this.handlePing(deviceId, pkt.body as PingBody);
        break;
      default:
        this.logFn('unhandled packet type: ' + pkt.type);
        break;
    }
  }

  // 骨架阶段自动接受配对请求（无人工确认 UI）。v8 请求必须带 timestamp（秒），
  // 时钟偏差超限按 Android 参考拒绝；接受后回 {pair:true} 并主动交换 identity。
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
      const reply: PairBody = { pair: true };
      this.sendFrame(deviceId, 'kdeconnect.pair', reply);
      this.sendIdentity(deviceId);
      this.logFn('pairing accepted with ' + deviceId);
      // 通知 UI 层（记住的设备持久化；AP-1 配对确认 UI 将在回调前加确认环节）
      if (this.onPaired !== undefined) {
        this.onPaired(deviceId);
      }
    } else {
      this.logFn('unpair request from ' + deviceId);
      if (this.onUnpaired !== undefined) {
        this.onUnpaired(deviceId);
      }
    }
  }

  private handleIdentity(deviceId: string, body: IdentityBody): void {
    this.logFn('identity from ' + deviceId + ': ' +
      (body.deviceName ?? '?') + ' v' + (body.protocolVersion ?? '?') +
      ' incoming=' + (body.incomingCapabilities?.length ?? 0) +
      ' outgoing=' + (body.outgoingCapabilities?.length ?? 0));
  }

  private handlePing(deviceId: string, body: PingBody): void {
    const reply: PingBody = { message: body.message ?? 'pong' };
    this.sendFrame(deviceId, 'kdeconnect.ping', reply);
    this.logFn('ping echoed to ' + deviceId);
  }

  private sendIdentity(deviceId: string): void {
    const body: IdentityBody = {
      deviceId: this.selfDeviceId,
      protocolVersion: PROTOCOL_VERSION,
      deviceName: this.selfDeviceName,
      deviceType: this.selfDeviceType,
      incomingCapabilities: this.incomingCaps,
      outgoingCapabilities: this.outgoingCaps
    };
    this.sendFrame(deviceId, 'kdeconnect.identity', body);
  }

  private sendFrame(deviceId: string, type: string, body: Object): void {
    const pkt: OutPacket = { id: Date.now(), type: type, body: body };
    const ok: boolean = native.sendPacket(deviceId, JSON.stringify(pkt) + '\n');
    if (!ok) {
      this.logFn('sendPacket failed (not encrypted yet?) ' + type + ' -> ' + deviceId);
    }
  }
}
