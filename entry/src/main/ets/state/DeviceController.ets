// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 设备领域控制器（阶段 3 批次 4 步骤 8a；设计见 devdocs/PROJECT_ROADMAP.md）。
//
// 核心职责：native 网络事件枢纽（handleEvent）+ 设备列表维护 + 配对/信任状态管理。
//   · 状态全在 DeviceController（@Observed）⇒ 页面 @State 持实例，UI 用 @ObjectLink/@Prop 读；
//   · 副作用（插件装载/卸载、payload 清理、mpris 清账、会话状态机通知）经注入回调走页面既有实现；
//   · Context/native/PacketRouter 不在本模块内直接碰。

import { NetEvent } from 'libkdeconnect_napi.so';
import { Context } from '@kit.AbilityKit';
import { DeviceItem, RememberedDevice } from '../model/DeviceModels';
import { TrustedDevice } from '../model/TrustModels';
import { TrustStore } from '../common/TrustStore';

interface PairRequestBody {
  pair: boolean;
  timestamp?: number;
}

interface PairRequestPacket {
  id: number;
  type: string;
  body: PairRequestBody;
}

@Observed
export class DeviceController {
  connectedDevices: DeviceItem[] = [];
  discoveredDevices: DeviceItem[] = [];
  rememberedDevices: RememberedDevice[] = [];
  trustedDevices: TrustedDevice[] = [];
  selectedDeviceId: string = '';
  deviceSection: number = 0;
  trustLoaded: boolean = false;
  pendingKnown: TrustedDevice[] = [];

  log: (m: string) => void = () => {};
  showNotice: (kind: string, detail: string, isError: boolean, code: number) => void = () => {};
  toast: (m: string) => void = () => {};
  sendPacket: (deviceId: string, json: string) => boolean = () => false;
  getPairVerificationCode: (deviceId: string, timestamp: number) => string = () => '';
  getPeerCertificate: (deviceId: string) => string = () => '';
  setTrustedCertificate: (deviceId: string, certPem: string) => void = () => {};
  removeTrustedCertificate: (deviceId: string) => void = () => {};
  openPairPrompt: (deviceId: string, deviceName: string, timestamp: number, code: string) => void = () => {};
  connectToPeer: (host: string, port: number) => void = () => {};
  triggerBroadcast: () => void = () => {};
  getHostContext: () => Context | undefined = () => undefined;
  routerOnPacket: (deviceId: string, raw: string) => void = () => {};
  routerForgetPeer: (deviceId: string) => void = () => {};
  loadPluginsIfEmpty: (deviceId: string) => void = () => {};
  // 断链清账清单（接线时页面侧必须逐项承接，对应旧 Index.ets:965-976）：
  //   1. payloadController.failInflightReceives(did, 'disconnected')
  //   2. batteryItems 过滤掉该设备
  //   3. pluginHost.unloadForDevice(did)（AP-4 插件卸载）
  //   4. mprisController.forget(did)（P2 MSG132 §2 媒体面板清账）
  //   5. payloadController.forgetSendQueue(did)（P3 清发送队列）
  onDisconnectedCleanup: (deviceId: string) => void = () => {};
  // deviceLost 清账清单（接线时页面侧承接）：
  //   1. mprisController.forget(lid)（P2 MSG132 §2 媒体面板清账）
  onDeviceLostCleanup: (deviceId: string) => void = () => {};
  onErrorCleanup: (deviceId: string, errorCode: number, errorMessage: string) => void = () => {};
  onPayloadTransfer: (event: NetEvent) => void = () => {};
  pairSessionOnConnected: (deviceId: string, shownName: string) => void = () => {};
  pairSessionOnDisconnected: (deviceId: string) => void = () => {};
  pairSessionOnError: (deviceId: string, code: number, msg: string) => void = () => {};
  actionGate: (key: string, windowMs: number) => boolean = () => true;
  getDeviceName: () => string = () => '';

  handleEvent(event: NetEvent): void {
    const pktLen: number = event.packet === undefined || event.packet === null ? 0 : event.packet.length;
    console.info(`KDC event ${event.type ?? '?'} dev=${(event.deviceId ?? '').substring(0, 8)} pktLen=${pktLen}`);
    switch (event.type) {
      case 'deviceDiscovered': {
        const id: string = event.deviceId ?? '';
        if (id === '') {
          break;
        }
        const item: DeviceItem = {
          id: id,
          name: event.deviceName ?? id,
          host: event.host ?? '',
          tcpPort: event.tcpPort ?? 0,
          deviceType: '',
          online: true
        };
        const known: boolean = this.discoveredDevices.some((d: DeviceItem) => d.id === id);
        if (known) {
          const cur: DeviceItem | undefined = this.discoveredDevices.find((d: DeviceItem) => d.id === id);
          const same: boolean = cur !== undefined && cur.name === item.name && cur.host === item.host
            && cur.tcpPort === item.tcpPort && cur.online;
          if (same) {
            break;
          }
          this.discoveredDevices = this.discoveredDevices.map(
            (d: DeviceItem) => d.id === id ? item : d);
        } else {
          this.discoveredDevices = [item].concat(this.discoveredDevices);
        }
        this.log(`discovered ${id}`);
        break;
      }
      case 'connected': {
        const cid: string = event.deviceId ?? '';
        if (cid !== '') {
          const dev: DeviceItem = {
            id: cid,
            name: event.deviceName ?? cid,
            host: event.host ?? '',
            tcpPort: event.tcpPort ?? 0,
            deviceType: '',
            online: true
          };
          this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== cid);
          this.connectedDevices = this.connectedDevices.concat([dev]);
          this.rememberKnown(cid, event.deviceName ?? cid);
          this.loadPluginsIfEmpty(cid);
          this.pairSessionOnConnected(cid, event.deviceName ?? '');
        }
        this.syncSelectedDevice();
        this.log(`connected ${event.deviceId} role=${event.role}`);
        break;
      }
      case 'disconnected': {
        const did: string = event.deviceId ?? '';
        this.onDisconnectedCleanup(did);
        this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== did);
        this.pairSessionOnDisconnected(did);
        this.syncSelectedDevice();
        this.log(`disconnected ${event.deviceId}`);
        break;
      }
      case 'deviceLost': {
        const lid: string = event.deviceId ?? '';
        if (this.connectedDevices.some((d: DeviceItem) => d.id === lid)) {
          this.log(`lost ${lid} ignored (still connected)`);
          break;
        }
        const stillOnline: boolean = this.discoveredDevices.some(
          (d: DeviceItem) => d.id === lid && d.online);
        if (!stillOnline) {
          break;
        }
        this.discoveredDevices = this.discoveredDevices.map(
          (d: DeviceItem) => d.id === lid ? { id: d.id, name: d.name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: false } : d);
        this.onDeviceLostCleanup(lid);
        this.log(`lost ${event.deviceId} (kept in list as offline)`);
        break;
      }
      case 'packetReceived': {
        const raw: string = event.packet ?? '';
        if (event.deviceId !== undefined && raw.length > 1) {
          this.routerOnPacket(event.deviceId, raw);
        }
        this.log(`packet from ${event.deviceId}: ${raw.slice(0, 80)}`);
        break;
      }
      case 'pairingRequest': {
        const pid: string = event.deviceId ?? '';
        if (pid !== '') {
          const name: string = event.deviceName ?? '';
          if (name !== '') {
            this.connectedDevices = this.connectedDevices.map(
              (d: DeviceItem) => d.id === pid ? { id: d.id, name: name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: d.online } : d);
            this.discoveredDevices = this.discoveredDevices.map(
              (d: DeviceItem) => d.id === pid ? { id: d.id, name: name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: d.online } : d);
          }
          this.log(`peer identity: ${name !== '' ? name : pid}`);
        }
        break;
      }
      case 'payloadTransfer': {
        this.onPayloadTransfer(event);
        break;
      }
      case 'error': {
        const em: string = event.errorMessage ?? '';
        this.onErrorCleanup(event.deviceId ?? '', event.errorCode ?? 0, em);
        if (em.includes('rate limited')) {
          this.log('连接过于频繁，请稍后重试（rate limited）');
        } else if (em.includes('certificate mismatch')) {
          this.log('对端证书与登记不符，需重新配对（certificate mismatch）');
        } else {
          this.log(`error ${event.errorCode}: ${em}`);
        }
        this.pairSessionOnError(event.deviceId ?? '', event.errorCode ?? 0, em);
        break;
      }
      default:
        this.log(`event: ${event.type}`);
        break;
    }
  }

  handlePaired(deviceId: string): void {
    if (deviceId === '') {
      return;
    }
    const name: string = this.displayNameOf(deviceId);
    const exists: boolean = this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId);
    let peerCert: string = '';
    try {
      peerCert = this.getPeerCertificate(deviceId);
    } catch (e) {
      this.log('getPeerCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    if (exists) {
      this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        if (t.id !== deviceId) {
          return t;
        }
        const next: TrustedDevice = {
          id: t.id,
          name: name.length > 0 ? name : t.name,
          certPem: peerCert.length > 0 ? peerCert : t.certPem,
          pairedAt: t.pairedAt,
          paired: t.paired
        };
        return next;
      });
    } else {
      const entry: TrustedDevice = {
        id: deviceId,
        name: name,
        certPem: peerCert,
        pairedAt: 0,
        paired: false
      };
      this.trustedDevices = this.trustedDevices.concat([entry]);
    }
    this.setPairedFlag(deviceId, true);
    this.persistTrust();
    this.syncSelectedDevice();
    if (peerCert.length > 0) {
      try {
        this.setTrustedCertificate(deviceId, peerCert);
      } catch (e) {
        this.log('setTrustedCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      }
    }
    this.log(`paired with ${deviceId} (cert=${peerCert.length > 0 ? 'stored' : 'unavailable'})`);
  }

  handleUnpaired(deviceId: string): void {
    try {
      this.removeTrustedCertificate(deviceId);
    } catch (e) {
      this.log('removeTrustedCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    this.setPairedFlag(deviceId, false);
    this.log(`unpaired ${deviceId} (kept in remembered list)`);
  }

  setPairedFlag(deviceId: string, paired: boolean): void {
    let changed: boolean = false;
    this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      if (t.id !== deviceId || t.paired === paired) {
        return t;
      }
      changed = true;
      const next: TrustedDevice = {
        id: t.id,
        name: t.name,
        certPem: t.certPem,
        pairedAt: paired ? Date.now() : t.pairedAt,
        paired: paired
      };
      return next;
    });
    if (!changed) {
      return;
    }
    this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
      return r;
    });
    this.persistTrust();
    this.log(`state: ${deviceId} paired=${paired}`);
  }

  computePairCode(deviceId: string, timestamp: number): string {
    try {
      const code: string = this.getPairVerificationCode(deviceId, timestamp);
      if (code.length === 0) {
        return '';
      }
      const parts: string[] = [];
      for (let i = 0; i + 1 < code.length; i += 2) {
        parts.push(code.substring(i, i + 2));
      }
      return parts.join(' ');
    } catch (e) {
      this.log('getPairVerificationCode unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    }
  }

  requestPairWith(d: DeviceItem): void {
    const selfTs: number = Math.floor(Date.now() / 1000);
    const code: string = this.computePairCode(d.id, selfTs);
    this.openPairPrompt(d.id, d.name, selfTs, code);
  }

  unpairDevice(d: DeviceItem): void {
    this.log(`unpair ${d.id}`);
    const unpairBody: PairRequestBody = { pair: false };
    const unpairPkt: PairRequestPacket = { id: Date.now(), type: 'kdeconnect.pair', body: unpairBody };
    try {
      const ok: boolean = this.sendPacket(d.id, JSON.stringify(unpairPkt) + '\n');
      this.log(ok ? 'unpair sent' : 'unpair not sent (conn not encrypted?)');
    } catch (e) {
      this.log('unpair send failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    this.handleUnpaired(d.id);
    this.routerForgetPeer(d.id);
  }

  rehydrateTrust(loaded: TrustedDevice[]): void {
    this.trustedDevices = loaded;
    this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
      return r;
    });
    this.log(`trust store: ${this.trustedDevices.length} device(s)`);
    for (const t of this.trustedDevices) {
      if (t.certPem.length > 0) {
        try {
          this.setTrustedCertificate(t.id, t.certPem);
        } catch (e) {
          this.log(`pin rehydrate failed: ${t.id}`);
        }
      }
    }
    this.trustLoaded = true;
    for (const p of this.pendingKnown) {
      this.rememberKnown(p.id, p.name);
    }
    this.pendingKnown = [];
  }

  isTrusted(deviceId: string): boolean {
    return this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId && t.paired);
  }

  isPairedId(deviceId: string): boolean {
    return this.rememberedDevices.some((r: RememberedDevice) => r.id === deviceId && r.paired);
  }

  displayNameOf(deviceId: string): string {
    const conn: DeviceItem | undefined = this.connectedDevices.find((d: DeviceItem) => d.id === deviceId);
    if (conn !== undefined) {
      return conn.name;
    }
    const disc: DeviceItem | undefined = this.discoveredDevices.find((d: DeviceItem) => d.id === deviceId);
    if (disc !== undefined) {
      return disc.name;
    }
    const rem: RememberedDevice | undefined = this.rememberedDevices.find((r: RememberedDevice) => r.id === deviceId);
    if (rem !== undefined) {
      return rem.name;
    }
    return deviceId;
  }

  syncSelectedDevice(): void {
    const live: DeviceItem[] = this.connectedShown();
    if (live.length === 0) {
      if (this.selectedDeviceId.length > 0 && this.isPairedId(this.selectedDeviceId)) {
        return;
      }
      this.selectedDeviceId = '';
      return;
    }
    const stillThere: boolean = live.some((d: DeviceItem) => d.id === this.selectedDeviceId);
    if (!stillThere) {
      this.selectedDeviceId = live[0].id;
      this.deviceSection = 0;
    }
  }

  liveIds(): string[] {
    const out: string[] = [];
    for (const d of this.connectedDevices) {
      if (d.online) {
        out.push(d.id);
      }
    }
    return out;
  }

  connectedShown(): DeviceItem[] {
    const out: DeviceItem[] = [];
    for (const d of this.connectedDevices) {
      if (d.online && this.isPairedId(d.id)) {
        out.push(d);
      }
    }
    return out;
  }

  discoveredShown(): DeviceItem[] {
    const out: DeviceItem[] = [];
    for (const d of this.connectedDevices) {
      if (d.online && !this.isPairedId(d.id) && !out.some((x: DeviceItem) => x.id === d.id)) {
        out.push(d);
      }
    }
    for (const d of this.discoveredDevices) {
      if (d.online && !this.isPairedId(d.id) && !out.some((x: DeviceItem) => x.id === d.id)) {
        out.push(d);
      }
    }
    return out;
  }

  offlineKnownShown(): RememberedDevice[] {
    const live: string[] = this.liveIds();
    const out: RememberedDevice[] = [];
    for (const r of this.rememberedDevices) {
      if (!live.includes(r.id)) {
        out.push(r);
      }
    }
    return out;
  }

  rememberKnown(id: string, name: string): void {
    if (id === '') {
      return;
    }
    if (!this.trustLoaded) {
      const pending: TrustedDevice = { id: id, name: name, certPem: '', pairedAt: 0, paired: false };
      this.pendingKnown = this.pendingKnown.concat([pending]);
      return;
    }
    const existing: TrustedDevice | undefined = this.trustedDevices.find((t: TrustedDevice) => t.id === id);
    if (existing !== undefined) {
      if (name.length > 0 && existing.name !== name) {
        this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
          if (t.id !== id) {
            return t;
          }
          const next: TrustedDevice = {
            id: t.id,
            name: name,
            certPem: t.certPem,
            pairedAt: t.pairedAt,
            paired: t.paired
          };
          return next;
        });
        this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
          const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
          return r;
        });
        this.persistTrust();
      }
      return;
    }
    const entry: TrustedDevice = {
      id: id,
      name: name.length > 0 ? name : id,
      certPem: '',
      pairedAt: 0,
      paired: false
    };
    this.trustedDevices = this.trustedDevices.concat([entry]);
    this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
      return r;
    });
    this.persistTrust();
    this.log(`remember known device ${id} (connected once)`);
  }

  async persistTrust(): Promise<void> {
    const hostCtx: Context | undefined = this.getHostContext();
    if (hostCtx === undefined) {
      this.log('persist trust failed: no host context');
      return;
    }
    await TrustStore.save(hostCtx, this.trustedDevices);
  }
}
