// KDE Connect 网络栈 NAPI 类型（与 cpp/net/net_types.h、MSG_TO_ATOMCODE.md §3.2 契约一致）。

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

export interface NetEventBase {
  type:
    | "deviceDiscovered"
    | "deviceLost"
    | "connected"
    | "disconnected"
    | "packetReceived"
    | "pairingRequest"
    | "error";
  deviceId?: string;
  deviceName?: string;
  deviceType?: string;
  host?: string;
  tcpPort?: number;
  role?: "server" | "client";
  packet?: string;
  errorCode?: number;
  errorMessage?: string;
}

export type NetEvent = NetEventBase;

// 注册事件回调（必须在 start 之前调用，且仅在主线程调用一次）。
export const init: (eventCallback: (event: NetEvent) => void) => void;

// 启动网络栈：UDP 发现广播 + TCP 监听 + TLS 就绪。
export const start: (config: NetConfig) => void;

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
