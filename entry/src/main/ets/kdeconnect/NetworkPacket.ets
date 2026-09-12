/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * KDE Connect protocol: NetworkPacket.
 * Mirrors kdeconnect-android NetworkPacket.kt and
 * kdeconnect-meta/schemas/kdeconnect.json. A packet is a newline-terminated
 * JSON string: {"id","type","body"(, "payloadSize", "payloadTransferInfo")}.
 */

export class NetworkPacket {
  type: string;
  private body: Record<string, Object> = {};
  payloadSize: number = 0;
  payloadTransferInfo: Record<string, Object> = {};
  private canceled: boolean = false;

  static readonly PACKET_TYPE_IDENTITY: string = 'kdeconnect.identity';
  static readonly PACKET_TYPE_PAIR: string = 'kdeconnect.pair';
  static readonly PROTOCOL_VERSION: number = 8;
  static readonly PROTOCOL_PACKET_TYPES: string[] = [
    NetworkPacket.PACKET_TYPE_IDENTITY,
    NetworkPacket.PACKET_TYPE_PAIR
  ];

  constructor(type: string) {
    this.type = type;
  }

  cancel(): void {
    this.canceled = true;
  }

  isCanceled(): boolean {
    return this.canceled;
  }

  hasPayload(): boolean {
    return this.payloadSize !== 0;
  }

  getBody(): Record<string, Object> {
    return this.body;
  }

  has(key: string): boolean {
    return this.body[key] !== undefined;
  }

  getString(key: string, defaultValue: string = ''): string {
    const v: Object | undefined = this.body[key];
    return v === undefined ? defaultValue : (v as string);
  }

  getInt(key: string, defaultValue: number = -1): number {
    const v: Object | undefined = this.body[key];
    return v === undefined ? defaultValue : (v as number);
  }

  getBoolean(key: string, defaultValue: boolean = false): boolean {
    const v: Object | undefined = this.body[key];
    return v === undefined ? defaultValue : (v as boolean);
  }

  getStringList(key: string): string[] {
    const v: Object | undefined = this.body[key];
    return v === undefined ? [] : (v as string[]);
  }

  set(key: string, value: Object): void {
    this.body[key] = value;
  }

  serialize(): string {
    const obj: Record<string, Object> = {};
    obj['id'] = Date.now();
    obj['type'] = this.type;
    obj['body'] = this.body;
    if (this.hasPayload()) {
      obj['payloadSize'] = this.payloadSize;
      obj['payloadTransferInfo'] = this.payloadTransferInfo;
    }
    // Some JSON encoders escape '/' as '\/'; the protocol expects QJson form.
    return JSON.stringify(obj).replace(/\\\//g, '/') + '\n';
  }

  static unserialize(s: string): NetworkPacket {
    const jo: Record<string, Object> = JSON.parse(s.trim()) as Record<string, Object>;
    const np: NetworkPacket = new NetworkPacket(jo['type'] as string);
    if (jo['body'] !== undefined) {
      np.body = jo['body'] as Record<string, Object>;
    }
    if (jo['payloadSize'] !== undefined) {
      np.payloadSize = jo['payloadSize'] as number;
      np.payloadTransferInfo = (jo['payloadTransferInfo'] as Record<string, Object>) ?? {};
    }
    return np;
  }
}
