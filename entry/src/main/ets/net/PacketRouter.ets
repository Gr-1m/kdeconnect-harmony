// Packet 路由层：从 packetReceived 事件的原始数据中切分 NetworkPacket 帧，
// 处理核心握手包（kdeconnect.pair / identity），其余 packet 交给插件宿主（AP-4）。
// 帧约定（kdeconnect-meta protocol.md：换行分隔 JSON）：
//   发送方（本侧）组帧后自带 '\n'；native 自 WP-1a 起保证「一个 packetReceived 事件 = 一个完整帧」，
//   本层仍保留「缓冲 + 按 '\n' 切分 + 尾段留待下次」的容错逻辑（两种派发粒度都正确）。
// 配对语义（AP-1）：请求不再自动接受，交由 UI 弹窗确认（用户裁决：与 iOS 一致）。
import native from 'libkdeconnect_napi.so';

// Android 参考（PairingHandler）：时钟偏差超 30 分钟则拒绝配对请求。
const MAX_TIMESTAMP_DIFF_SECONDS = 1800;
const REQUESTED_PEER_TIMEOUT_MS = 60000;
// 半帧缓冲两级上限（合并裁定 #1 修订，2026-09-19 用户要求「留退路」）：
// - 1 MiB = 告警线：正常控制帧（identity 8KiB / mpris·sv 快照几 KB）远低于此；越线说明对端
//   行为异常或我们在收一个超大帧——**不丢弃**，记日志观察（每设备只告警一次，避免刷屏）。
// - 33 MiB = 硬限：协议单包上限 MAX_PACKET_SIZE(32MiB)+1 派生；超过只可能是「永不发换行」
//   的异常流（正常巨大帧也会在 32MiB 内以换行收尾），丢弃重建防内存吃光。
const FRAME_BUFFER_WARN_BYTES = 1048576;
const FRAME_BUFFER_HARD_LIMIT_BYTES = 33 * 1048576;

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
  // 已越过告警线的设备（warn-once 去重；缓冲回落后解除）
  private frameWarned: Set<string> = new Set();
  private logFn: (msg: string) => void;
  private callbacks: RouterCallbacks;
  private requestedPeers: Map<string, number> = new Map();

  constructor(selfDeviceId: string, selfDeviceName: string, selfDeviceType: string,
              logFn: (msg: string) => void, callbacks: RouterCallbacks) {
    this.selfDeviceId = selfDeviceId;
    this.selfDeviceName = selfDeviceName;
    this.selfDeviceType = selfDeviceType;
    this.logFn = logFn;
    this.callbacks = callbacks;
  }

  // ---- 供 UI 调用的配对动作 ----

  // 本侧发起配对请求（返回是否真的发出；MSG77 §2：发送失败不能让 UI 停在「等待对端确认」）。
  // timestamp 由 UI 传入：弹窗里显示的验证码必须用同一个值计算（native getPairVerificationCode）。
  requestPair(deviceId: string, timestamp: number): boolean {
    let ts: number = timestamp;
    if (ts <= 0) {
      ts = Math.floor(Date.now() / 1000);
    }
    const body: PairBody = { pair: true, timestamp: ts };
    const ok: boolean = this.sendFrame(deviceId, PACKET_PAIR, body);
    if (ok) {
      this.requestedPeers.set(deviceId, Date.now());
    }
    this.logFn('pair request sent to ' + deviceId + ' ok=' + ok);
    return ok;
  }

  // UI 确认接受对端请求：回 {pair:true}。
  // 注意（MSG77 §3）：接受帧**不带 timestamp** —— 带 timestamp 在 v8 里表示「新请求」，
  // 会让对端把它当成又一次请求（KDE 源码注释：accepting 双方互发会造成循环）。
  acceptPair(deviceId: string): boolean {
    const body: PairBody = { pair: true };
    const ok: boolean = this.sendFrame(deviceId, PACKET_PAIR, body);
    this.logFn('pairing accepted with ' + deviceId + ' ok=' + ok);
    if (ok) {
      this.callbacks.onPaired(deviceId);
    }
    return ok;
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

  private cleanExpiredRequestedPeers(): void {
    const now: number = Date.now();
    const expired: string[] = [];
    this.requestedPeers.forEach((ts: number, id: string) => {
      if (now - ts > REQUESTED_PEER_TIMEOUT_MS) {
        expired.push(id);
      }
    });
    for (const id of expired) {
      this.requestedPeers.delete(id);
      this.logFn('requestedPeers expired: ' + id);
    }
  }

  // packetReceived 事件入口。raw 可能含多帧或半帧。
  onPacket(deviceId: string, raw: string): void {
    if (deviceId === '') {
      return;
    }
    const prev: string = this.frameBuffers.get(deviceId) ?? '';
    const data: string = prev + raw;
    if (data.length > FRAME_BUFFER_HARD_LIMIT_BYTES) {
      this.logFn('frame buffer overflow for ' + deviceId + ': ' + data.length + ' bytes, discarding');
      this.frameBuffers.delete(deviceId);
      this.frameWarned.delete(deviceId);
      return;
    }
    if (data.length > FRAME_BUFFER_WARN_BYTES && !this.frameWarned.has(deviceId)) {
      // 退路（用户 2026-09-19）：超 1MiB 不再丢弃——放行继续凑帧，只告警一次留痕，
      // 直到该设备的缓冲回到告警线以下才重新武装。
      this.frameWarned.add(deviceId);
      this.logFn('frame buffer large for ' + deviceId + ': ' + data.length + ' bytes (continuing, warn-once)');
    }
    const lines: string[] = data.split('\n');
    const last: string | undefined = lines.pop();
    if (last !== undefined) {
      if (last.length <= FRAME_BUFFER_WARN_BYTES) {
        this.frameWarned.delete(deviceId);
      }
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

  // AP-1：不再自动接受。配对帧语义（MSG77 §3，对齐 KDE/Android v8）：
  //   {pair:true, timestamp} = **对端的新请求**（即使本侧此前也请求过）
  //   {pair:true}（无 timestamp） = 对本侧请求的**接受**
  //   {pair:false} = 解除配对
  // timestamp 为秒；时钟偏差超限直接拒绝（Android 参考）。
  private handlePair(deviceId: string, body: PairBody): void {
    this.cleanExpiredRequestedPeers();
    if (body.pair === true) {
      if (body.timestamp !== undefined) {
        const ts: number = body.timestamp;
        const now: number = Math.floor(Date.now() / 1000);
        if (Math.abs(ts - now) > MAX_TIMESTAMP_DIFF_SECONDS) {
          this.logFn('pair rejected: clock skew ' + (now - ts) + 's from ' + deviceId);
          const reject: PairBody = { pair: false };
          this.sendFrame(deviceId, PACKET_PAIR, reject);
          return;
        }
        if (this.requestedPeers.has(deviceId)) {
          this.requestedPeers.delete(deviceId);
          const accept: PairBody = { pair: true };
          const ok: boolean = this.sendFrame(deviceId, PACKET_PAIR, accept);
          this.logFn('pair race with ' + deviceId + ': sent accept ok=' + ok);
          this.callbacks.onPaired(deviceId);
          return;
        }
        this.logFn('pair request from ' + deviceId + ' (awaiting user confirmation)');
        this.callbacks.onPairRequest(deviceId, ts);
        return;
      }
      // 无 timestamp = 对本侧请求的接受
      this.requestedPeers.delete(deviceId);
      this.logFn('pairing confirmed by ' + deviceId);
      this.callbacks.onPaired(deviceId);
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

  private sendFrame(deviceId: string, type: string, body: Object): boolean {
    const pkt: OutPacket = { id: Date.now(), type: type, body: body };
    // 诊断（只打日志，不改逻辑）：配对帧的**发送**方向也进 hilog，便于与对端帧对时序。
    // 用户报告「配对成功后不显示已连接」时，靠这条区分「谁先发 pair:false」。
    if (type === 'kdeconnect.pair') {
      console.info(`KDC pair OUT -> ${deviceId}: ${JSON.stringify(body)}`);
    }
    const t0: number = Date.now();
    const ok: boolean = native.sendPacket(deviceId, JSON.stringify(pkt) + '\n');
    const dt: number = Date.now() - t0;
    // 主线程是否被 native 发包阻塞的量化证据（用户报「媒体面板连点卡死」时先看这条）
    if (dt > 100) {
      console.warn(`KDC slow send ${dt}ms -> ${type} (${deviceId})`);
    }
    if (!ok) {
      this.logFn('sendPacket failed (not encrypted yet?) ' + type + ' -> ' + deviceId);
    }
    return ok;
  }
}
