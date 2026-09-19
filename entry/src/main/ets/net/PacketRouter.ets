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
  private frameBuffers: Map<string, string> = new Map();
  private logFn: (msg: string) => void;
  private callbacks: RouterCallbacks;
  // 本侧已发起、等待对端确认的配对请求：用于区分「对端确认」与「对端请求」。
  // 值 = 发起时刻（秒）。带超时（PAIR_REQUEST_TTL_S）：请求若一直无回应，
  // 残留记录会让对端之后**任意**一次新请求命中 race 分支、跳过用户确认直接接受——
  // 绕过 AP-1 的用户裁决（安全相关，REVIEW_ARKTS_MERGED P2-1）。
  private requestedPeers: Map<string, number> = new Map();
  // 与本地配对弹窗等待时长（PAIR_TIMEOUT_MS=45s 的 UI 超时）同量级，取 60s 留裕量。
  private static readonly PAIR_REQUEST_TTL_S = 60;
  // 半帧缓冲上限（P2-3）：正常帧最大 32MiB，但坏实现对可能永远不发 '\n'——
  // 无上限时按设备无界增长。超限即丢弃该设备的整段缓冲并断开其后续帧容错
  //（非法数据本就该丢弃，native 侧同时会因帧超限关闭连接）。
  private static readonly FRAME_BUFFER_MAX = 33 * 1024 * 1024;

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
      this.requestedPeers.set(deviceId, Math.floor(Date.now() / 1000));
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
    // 帧没发出去（如链路未加密）就不能标记已配对——否则 UI 进入已配对态而对端从未收到确认
    //（对照 requestPair 的同类处理，MSG77 §3 模式）。
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
      if (last.length > PacketRouter.FRAME_BUFFER_MAX) {
        // 半帧超限：对端在持续发送无换行的数据（异常/恶意）——丢弃缓冲，防内存无界增长
        this.frameBuffers.delete(deviceId);
        this.logFn('frame buffer overflow from ' + deviceId + ' (' + last.length + ' bytes), dropped');
      } else {
        this.frameBuffers.set(deviceId, last);
      }
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
          this.logFn('pair rejected: clock skew ' + (now - ts) + 's from ' + deviceId);
          // 必须回拒绝帧（对照 Android PairingHandler）：只吞不回会让对端停在等待态直到超时。
          const reject: PairBody = { pair: false };
          this.sendFrame(deviceId, PACKET_PAIR, reject);
          return;
        }
        const requestedAt: number | undefined = this.requestedPeers.get(deviceId);
        // race 判定只认**未过期**的请求：过期残留必须走正常确认流程（否则对端任意
        // 新请求都会跳过用户确认被直接接受——安全漏洞）。
        const racePending: boolean = requestedAt !== undefined &&
          (now - requestedAt) < PacketRouter.PAIR_REQUEST_TTL_S;
        if (racePending) {
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
