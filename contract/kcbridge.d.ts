// Frozen bridge contract v1. Rust and ArkTS implementations must agree
// byte-for-byte with this file; changes require a CCR.
// Source: docs/kdeconnect-oh/08-interface-contract.md §2

export interface KCError extends Error {
  /** Numeric code; message starts with "KC_E<code>: ". */
  code: number;
}

export interface KcApi {
  /** Generated constant; compare at startup and fail with E109 on mismatch. */
  contractVersion(): number;

  /** First-run identity generation. Returns JSON:
   *  {deviceId, certPem, keyPkcs8Base64}. */
  generateIdentity(deviceName: string): string;

  /** Starts the engine; result arrives as engineStarted / engineInitFailed. */
  start(configJson: string): void;
  /** Idempotent. engineStopped is the last event. */
  stop(): void;

  /** Register before start. Event payload is JSON; see event kinds below. */
  setOnEvent(cb: (kind: number, eventJson: string) => void): void;

  /** Network snapshot: {ifaces:[{addr,prefix}], trusted, ssid?}. */
  networkChanged(networkJson: string): void;
  /** Re-send UDP discovery after foreground/manual refresh. */
  refreshDiscovery(): void;

  requestPair(deviceId: string): void;
  acceptPair(deviceId: string): void;
  rejectPair(deviceId: string): void;
  unpair(deviceId: string): void;
  setDeviceName(name: string): void;

  sendPacket(deviceId: string, type: string, bodyJson: string): void;
  sendFile(
    deviceId: string,
    type: string,
    bodyJson: string,
    filePath: string,
    filename: string
  ): void;

  acceptTransfer(transferId: number, destPath: string): void;
  rejectTransfer(transferId: number): void;
  cancelTransfer(transferId: number): void;

  /** CCR-3：能力集直接声明本端 incoming/outgoing（不再由 ArkTS 自拼 identity 能力表）。 */
  setCapabilities(incoming: string[], outgoing: string[]): void;

  /** CCR-3：配对待确认码（v8：双方公钥 DER 排序拼接 + SHA256 前 8 位 hex；timestamp 为对端 timestamp，秒）。 */
  getPairVerificationCode(deviceId: string, timestamp: number): string;

  /** CCR-3：对端叶证书 PEM。 */
  getPeerCertificate(deviceId: string): string;
  /** CCR-3：本端叶证书 PEM（无参，与现行导出一致）。 */
  getOwnCertificate(): string;
  /** CCR-3：写入对端信任证书（配对信任链）。 */
  setTrustedCertificate(deviceId: string, certPem: string): void;
  /** CCR-3：移除对端信任证书（解除配对）。 */
  removeTrustedCertificate(deviceId: string): void;

  /** CCR-3：手动连接（Add by IP）；host 为 IP 字面量，port 为 TCP 端口。 */
  connectToPeer(host: string, port: number): void;
  /** CCR-3：主动断开该设备连接（不解除配对）。 */
  disconnect(deviceId: string): void;

  /** JSON: {roots:string[]}; empty roots disables SFTP browsing. */
  setSftpRoots(roots: string): void;
  /** transferOffer auto-accept timeout; default 10 seconds. */
  setAutoAcceptSec(sec: number): void;
  /**
   * 接收模式（CCR-1 符号；CCR-1a 认定当前实现只支持 spool）：
   * - "spool"：先落盘，完成后 keep/discard（**当前默认，实装**）；
   * - "offer"：transferOffer 后 acceptTransfer(destPath)（**未实装**，bridge 返回 E105 + 日志）。
   */
  setAcceptMode(mode: "offer" | "spool"): void;
}

/** Event kinds (payload shape is documented in docs/kdeconnect-oh/08 §3). */
export const EventKind: {
  readonly EngineStarted: 0;
  readonly EngineInitFailed: 1;
  readonly EngineStopped: 2;
  readonly DeviceVisible: 3;
  readonly DeviceGone: 4;
  readonly DeviceUpdated: 5;
  readonly Unpaired: 6;
  readonly PairRequest: 7;
  readonly PairResult: 8;
  readonly Packet: 9;
  readonly TransferStarted: 10;
  readonly TransferOffer: 11;
  readonly TransferProgress: 12;
  readonly TransferDone: 13;
  readonly Log: 14;
  /** CCR-3a：连接建立（含设备名/角色）。 */
  readonly Connected: 15;
  /** CCR-3a：连接断开。 */
  readonly Disconnected: 16;
  /** CCR-3a：错误（按 errors.v1.json 处置）。 */
  readonly Error: 17;
};
