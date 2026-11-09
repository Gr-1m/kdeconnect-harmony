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

  /** JSON: {roots:string[]}; empty roots disables SFTP browsing. */
  setSftpRoots(roots: string): void;
  /** transferOffer auto-accept timeout; default 10 seconds. */
  setAutoAcceptSec(sec: number): void;
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
};
