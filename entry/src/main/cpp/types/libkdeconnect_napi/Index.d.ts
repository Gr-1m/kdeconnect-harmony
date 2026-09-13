// KDE Connect 网络栈 NAPI 类型（v2）
// 契约源：cpp/net/net_types.h；v2 变更经 ZCode（MSG36_TO_DEVECO）与 AtomCode（MSG32_TO_DEVECO）确认。
// 变更流程：ArkTS 侧提案 → 双方确认 → 本文件定稿 → native 实现复验 → CodeArts 评审（PROCESS C2/C3 门禁）。

export interface NetConfig {
  deviceId: string; // 32 hex chars（UUIDv4 去横线）
  deviceName: string; // 设备名
  deviceType: string; // "desktop" | "phone" | "tablet"
  certPem: string; // 自签证书 PEM（generateCert 产出）
  keyPem: string; // 私钥 PEM
  tcpPort: number; // 0 = 自动探测 1716–1764
}

export interface CertPair {
  certPem: string;
  keyPem: string;
}

export type NetEventType =
  | "deviceDiscovered"
  | "deviceLost"
  | "connected"
  | "disconnected"
  | "packetReceived"
  | "pairingRequest"
  | "payloadTransfer"
  | "error";

// payload 传输方向 / 状态（payloadTransfer 事件）
export type PayloadDirection = "send" | "receive";
export type PayloadState = "started" | "progress" | "finished" | "failed" | "cancelled";

export interface NetEventBase {
  type: NetEventType;
  deviceId?: string;
  deviceName?: string;
  deviceType?: string;
  host?: string;
  tcpPort?: number;
  role?: "server" | "client";
  packet?: string;
  // packetReceived 携带 payload 时也会带上 payloadTransferId（关联 payloadTransfer 事件）
  payloadTransferId?: number;
  errorCode?: number;
  errorMessage?: string;
  // --- payloadTransfer 事件字段（v2） ---
  payloadDirection?: PayloadDirection;
  payloadState?: PayloadState;
  payloadSize?: number; // 0=无 payload；-1=流式（本期不产生）
  payloadBytesDone?: number;
  payloadFileName?: string; // 对端 body.filename 原文（仅展示）
  payloadFilePath?: string; // receive: spool 落盘路径（finished 后用它）；send 为空
}

export type NetEvent = NetEventBase;

// 注册事件回调（必须在 start 之前调用，且仅在主线程调用一次）。
export const init: (eventCallback: (event: NetEvent) => void) => void;
// 拆除事件桥 + 网络栈（幂等）。ArkTS 页面重建时必须先调它：init 严格拒绝二次初始化
// （否则抛 "already initialized"、事件桥断裂）。shutdown 之后需重新 init() + start()。
export const shutdown: () => void;

// 启动网络栈：UDP 发现广播 + TCP 监听 + TLS 就绪。
// 返回 false = 启动失败（端口冲突 / UDP bind 失败 / epoll 失败）——UI 必须据此提示，
// 不能无条件显示 running（评审 F1）。字段缺失或类型错误时抛 TypeError。
export const start: (config: NetConfig) => boolean;

// 停止所有网络活动，关闭所有连接。
export const stop: () => void;

// 主动连接对端（发起 TCP → 我方=TLS server）。结果经 connected/error 事件通知。
export const connectToPeer: (host: string, port: number) => void;

// 发送 packet（JSON 字符串）。true=已排队，false=deviceId 未连接。
export const sendPacket: (deviceId: string, packetJson: string) => boolean;

// 断开对端。
export const disconnect: (deviceId: string) => void;

// 生成自签 EC P-256 证书（同步返回）。CN=deviceId，有效期 ~10 年。
export const generateCert: (deviceId: string) => CertPair;

// 能力协商单一来源（v2 定案，CodeArts MSG33 §4 指派 ArkTS 侧牵头）：
// native 持有的 incoming/outgoing capabilities 唯一入口，UDP 与 TLS 两条 identity 均取自此；
// 调用后 native 应向已建链路重发 identity（对端据此重算插件装载）。
// 未调用时沿用骨架默认：incoming=[ping, identity, pair]，outgoing=[ping]。
export const setCapabilities: (incoming: string[], outgoing: string[]) => void;

// 主动触发一次 UDP identity 广播（局域网发现，WP-2 / MSG73-MSG74）。
// 用途：网络变化（netAvailable）或用户在发现列表下拉刷新时，不必等对端下次广播。
// 无副作用（不重置栈）；native 未实现时 ArkTS 侧 try/catch 降级。
export const triggerBroadcast: () => void;

// --- payload 二进制传输（WP-1b 契约，v2） ---

// 组帧发送：native 注入 payloadSize / payloadTransferInfo.port；返回 transferId，0=失败。
// bodyJson 是完整 body 对象的 JSON（含 filename）；filePath 为沙箱内绝对路径。
export const sendPayload: (deviceId: string, packetType: string, bodyJson: string, filePath: string) => number;

// 接收完成（finished）后的处置：keepPayload 会把 spool 文件转移到 destPath（拒绝含 ".." 的路径）。
export const keepPayload: (transferId: number, destPath: string) => boolean;

// 丢弃已完成接收的 spool 文件。
export const discardPayload: (transferId: number) => boolean;

// 双向取消（关闭 payload socket，对端可见的取消信号）。
export const cancelPayload: (transferId: number) => void;

// --- 配对验证码（AP-1b 提案，待 ZCode 实现 / CodeArts 评审）---

// 取对端证书（PEM）。用于展示/指纹（AP-1b 设备详情、WP-2 钉扎 UI 前置）。
// 未握手/无对端证书时返回空串（ArkTS 侧显示占位）。
export const getPeerCertificate: (deviceId: string) => string;

// 本机证书（PEM）。与 generateCert 产出的同一份。
export const getOwnCertificate: () => string;

// 配对验证码（8 位大写 hex）。算法（KDE PairingHandler::verificationKey 等价）：
// 双方**公钥 SPKI DER** 按字节序排序拼接 → SHA256 → 前 8 位 hex 大写（v8 追加十进制 timestamp 字符串）。
// timestamp = pair 包 body.timestamp（秒）：本侧发起用自己生成的时间；对端请求用收到的包里的时间。
// 只在有 TLS 链路或已有对端证书缓存时可得，否则返回空串（UI 显示占位）。
export const getPairVerificationCode: (deviceId: string, timestamp: number) => string;

// --- 信任证书钉扎（WP-2 契约；native 内存态，持久化由 ArkTS 的 TrustStore 负责）---

// 登记受信设备证书（对端证书 PEM）。已登记设备后续连接若证书不符 →
// error 事件（errorCode=EACCES，errorMessage="certificate mismatch (device re-pair required)"）+ native 主动断链。
// 使用：配对成功后登记并持久化；App 启动时从 TrustStore 逐条回灌。
export const setTrustedCertificate: (deviceId: string, certPem: string) => void;

// 解除信任（unpair 时调用；在 TrustStore 移除之前）。
export const removeTrustedCertificate: (deviceId: string) => void;
