// Packet 路由层：从 packetReceived 事件的原始数据中切分 NetworkPacket 帧，
// 处理核心握手包（kdeconnect.pair / identity），其余 packet 交给插件宿主（AP-4）。
// 帧约定（kdeconnect-meta protocol.md：换行分隔 JSON）：
//   发送方（本侧）组帧后自带 '\n'；native 自 WP-1a 起保证「一个 packetReceived 事件 = 一个完整帧」，
//   本层仍保留「缓冲 + 按 '\n' 切分 + 尾段留待下次」的容错逻辑（两种派发粒度都正确）。
// 配对语义（AP-1）：请求不再自动接受，交由 UI 弹窗确认（用户裁决：与 iOS 一致）。
import native from 'libkdeconnect_napi.so';

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
  // 半帧缓冲上限（**总指挥 MSG24 裁定表 #1：1 MiB**，用户认可版）：
  // 这里只缓存**控制帧**（pair/identity/plugin 包），大文件走 payload 通道、不经这里 ⇒
  // 控制帧实际大小：identity 硬限 8 KiB，最大的 plugin 控制包（mpris 快照 / systemvolume 全量）也就几 KB。
  // 1 MiB 已比任何合法控制帧大 20-100 倍，又不会让恶意对端吃光内存；
  // 用 payload 上限（32 MiB）给控制帧缓冲设限是**混淆了两个通道**，故不取 33 MiB。
  private static readonly MAX_FRAME_BUFFER: number = 1024 * 1024;
  private frameBuffers: Map<string, string> = new Map();
  private logFn: (msg: string) => void;
  private callbacks: RouterCallbacks;
  // 本侧已发起、等待对端确认的配对请求：用于区分「对端确认」与「对端请求」
  // 我方主动请求配对后、"等对端回请"的**有效期**（安全：AtomCode L-P2-2）。
  // 旧实现用 Set 且**从不清理** ⇒ 用户一次确认会在整会话内一直有效，
  // 之后任何一次来自同一设备的配对请求都会被**跳过用户确认自动接受** ✗。
  // 现在记录时刻并设上限；超期视为未请求（并顺手清理过期项）。
  private static readonly PAIR_REQUEST_TTL_MS: number = 120000;
  private requestedPeers: Map<string, number> = new Map();

  // 该设备是否处于"我方刚请求过配对"的有效窗口内（超期即清理并视为未请求 —— 安全修复 L-P2-2）
  private hasRecentPairRequest(deviceId: string): boolean {
    const at: number | undefined = this.requestedPeers.get(deviceId);
    if (at === undefined) {
      return false;
    }
    if (Date.now() - at > PacketRouter.PAIR_REQUEST_TTL_MS) {
      this.requestedPeers.delete(deviceId);
      return false;
    }
    return true;
  }

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
    // 修复（AtomCode L-P1-2）：**只有接受帧真的发出去了才回调 onPaired**。
    // 旧实现无条件 onPaired ⇒ 未加密链路/发送失败时 UI 显示"已配对"但对端从未收到，
    // 对端停在等待态直到超时（`acceptPair` 漏网，requestPair 早已按 MSG77 处理同类）。
    if (ok) {
      this.callbacks.onPaired(deviceId);
    }
    this.logFn('pairing accepted with ' + deviceId + ' ok=' + ok + (ok ? '' : ' (not marked paired: accept frame not sent)'));
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

  // packetReceived 事件入口。raw 可能含多帧或半帧。
  onPacket(deviceId: string, raw: string): void {
    if (deviceId === '') {
      return;
    }
      const prev: string = this.frameBuffers.get(deviceId) ?? '';
      // 上限保护（AtomCode L-P2-3）：超限一律丢弃该设备的半帧缓冲并留痕（等下一条完整帧重建），
      // 避免"对端只发不带换行的垃圾数据"把内存吃光。
      if (prev.length + raw.length > PacketRouter.MAX_FRAME_BUFFER) {
        this.frameBuffers.delete(deviceId);
        this.logFn(`frame buffer overflow, dropped (dev=${deviceId} len=${prev.length + raw.length})`);
        return;
      }
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

  // AP-1：不再自动接受。配对帧语义（MSG77 §3，对齐 KDE/Android v8）：
  //   {pair:true, timestamp} = **对端的新请求**（即使本侧此前也请求过）
  //   {pair:true}（无 timestamp） = 对本侧请求的**接受**
  //   {pair:false} = 解除配对
  // timestamp 为秒；时钟偏差超限直接拒绝（Android 参考）。
  private handlePair(deviceId: string, body: PairBody): void {
    if (body.pair === true) {
      if (body.timestamp !== undefined) {
        const ts: number = body.timestamp;
        const now: number = Math.floor(Date.now() / 1000);
        if (Math.abs(ts - now) > MAX_TIMESTAMP_DIFF_SECONDS) {
          // L-P2-1（AtomCode）：旧实现只 log + return ⇒ **对端停在等待态直到超时**。
          // Android 的做法是回一个拒绝帧，这里复用既有 rejectPair（发 {pair:false} + 日志）。
          this.logFn('pair rejected: clock skew ' + (now - ts) + 's from ' + deviceId);
          this.rejectPair(deviceId);
          return;
        }
        if (this.hasRecentPairRequest(deviceId)) {
          // 双方同时发起：必须回一个**不带 timestamp** 的接受帧，
          // 否则对端永远停在 Requested（表现为「单边已配对」）。
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
