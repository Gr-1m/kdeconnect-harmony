// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// DeviceController 单测（AtomCode MSG133 §二.4 建议采纳；DevEco 车道）。
//
// 背景：D1 批次落地后，`ohosTest` 中 `handleEvent` 出现 0 次 —— 刚回归过的 **N2「忽略自己 deviceId」**
// （UDP 自发现唯一防线，Omp `faf3f1d` 修复）**无测试锁定**。本套件补齐这一块，兼覆盖：
//   · 事件分发（deviceDiscovered / connected / disconnected / deviceLost / packetReceived / error）
//   · 设备三态分区（已连接=paired&online / 发现=unpaired&online / 记住的设备=known offline）
//   · 配对与**证书钉扎链**（MSG114 P0）：handlePaired/handleUnpaired 对 native 钉扎的读写
//   · `setPairedFlag` 单写者 + `rememberedDevices` 镜像
//   · `rehydrateTrust` 启动重建（含 pendingKnown 冲刷）
//
// 约定：@ohos/hypium table-driven，命名 `Test<对象>_<场景>`（PROCESS §4.3）。
// 加固（AtomCode 2026-10-08）：8 处内联箭头补显式参数/返回类型（ce051d7 同型门禁风险；语义零变化）。
// 说明：本类不直接碰 native/PacketRouter —— 全部经注入回调；`getHostContext` 返回 undefined
//       使 `persistTrust()` 提前返回（不触 Preferences），故测试无持久化副作用。
import { describe, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { NetEvent } from 'libkdeconnect_napi.so';
import { DeviceController } from '../../../main/ets/state/DeviceController';
import { DeviceItem, RememberedDevice } from '../../../main/ets/model/DeviceModels';
import { TrustedDevice } from '../../../main/ets/model/TrustModels';

const SELF_ID: string = 'self0000000000000000000000000000';
const PEER_A: string = 'aaaa1111111111111111111111111111';
const PEER_B: string = 'bbbb2222222222222222222222222222';
const PEER_C: string = 'cccc3333333333333333333333333333';
const CERT_A: string = '-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----';

class Rec {
  logs: string[] = [];
  prompts: string[] = [];
  pinned: Map<string, string> = new Map();
  removed: string[] = [];
  pluginsLoaded: string[] = [];
  sessionConnected: string[] = [];
  sessionDisconnected: string[] = [];
  sessionErrors: string[] = [];
  disconnCleanup: string[] = [];
  lostCleanup: string[] = [];
  errCleanup: string[] = [];
  peerCert: string = '';
  selfId: string = SELF_ID;

  hasLog(needle: string): boolean {
    return this.logs.some((l: string): boolean => l.includes(needle));
  }
}

function harness(rec: Rec): DeviceController {
  const c: DeviceController = new DeviceController();
  c.log = (m: string): void => {
    rec.logs.push(m);
  };
  c.getSelfDeviceId = (): string => rec.selfId;
  c.getHostContext = (): Context | undefined => undefined;
  c.getPeerCertificate = (deviceId: string): string => rec.peerCert;
  c.setTrustedCertificate = (deviceId: string, certPem: string): void => {
    rec.pinned.set(deviceId, certPem);
  };
  c.removeTrustedCertificate = (deviceId: string): void => {
    rec.removed.push(deviceId);
  };
  c.loadPluginsIfEmpty = (deviceId: string): void => {
    rec.pluginsLoaded.push(deviceId);
  };
  c.pairSessionOnConnected = (deviceId: string, shownName: string): void => {
    rec.sessionConnected.push(deviceId);
  };
  c.pairSessionOnDisconnected = (deviceId: string): void => {
    rec.sessionDisconnected.push(deviceId);
  };
  c.pairSessionOnError = (deviceId: string, code: number, msg: string): void => {
    rec.sessionErrors.push(deviceId);
  };
  c.onDisconnectedCleanup = (deviceId: string): void => {
    rec.disconnCleanup.push(deviceId);
  };
  c.onDeviceLostCleanup = (deviceId: string): void => {
    rec.lostCleanup.push(deviceId);
  };
  c.onErrorCleanup = (deviceId: string, code: number, msg: string): void => {
    rec.errCleanup.push(deviceId);
  };
  c.openPairPrompt = (deviceId: string, name: string, ts: number, code: string): void => {
    rec.prompts.push(deviceId);
  };
  return c;
}

// 让 trustLoaded=true（生产对应"启动加载完成"），否则 rememberKnown 只会进 pendingKnown
function ready(rec: Rec): DeviceController {
  const c: DeviceController = harness(rec);
  const none: TrustedDevice[] = [];
  c.rehydrateTrust(none);
  return c;
}

function discovered(id: string, name: string): NetEvent {
  return { type: 'deviceDiscovered', deviceId: id, deviceName: name, host: '10.0.0.9', tcpPort: 1716 };
}

function connectedEvent(id: string, name: string): NetEvent {
  return { type: 'connected', deviceId: id, deviceName: name, host: '10.0.0.9', tcpPort: 1716, role: 'server' };
}

function trusted(id: string, name: string, certPem: string, paired: boolean): TrustedDevice {
  return { id: id, name: name, certPem: certPem, pairedAt: paired ? 1 : 0, paired: paired };
}

export default function deviceControllerTest(): void {
  describe('DeviceControllerTest', () => {

    // ---- N2 不变量：忽略自己的 deviceId（防 UDP 自发现，AGENTS 协议约束） ----

    it('TestDeviceController_deviceDiscovered_ignoresSelfDeviceId', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(discovered(SELF_ID, 'myself'));
      expect(c.discoveredDevices.length).assertEqual(0);
      expect(c.connectedDevices.length).assertEqual(0);
      expect(rec.hasLog('discovered')).assertFalse();
    });

    it('TestDeviceController_deviceDiscovered_ignoresEmptyDeviceId', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(discovered('', 'nobody'));
      expect(c.discoveredDevices.length).assertEqual(0);
    });

    it('TestDeviceController_deviceDiscovered_acceptsPeerAndDedupes', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(discovered(PEER_A, 'laptop'));
      expect(c.discoveredDevices.length).assertEqual(1);
      expect(c.discoveredDevices[0].name).assertEqual('laptop');
      // 同 id 同内容重复广播 ⇒ 不新增、不加长
      c.handleEvent(discovered(PEER_A, 'laptop'));
      expect(c.discoveredDevices.length).assertEqual(1);
    });

    it('TestDeviceController_deviceDiscovered_updatesChangedName', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(discovered(PEER_A, 'old-name'));
      c.handleEvent(discovered(PEER_A, 'new-name'));
      expect(c.discoveredDevices.length).assertEqual(1);
      expect(c.discoveredDevices[0].name).assertEqual('new-name');
    });

    // ---- connected / disconnected ----

    it('TestDeviceController_connected_addsDeviceLoadsPluginsAndNotifiesSession', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      expect(c.connectedDevices.length).assertEqual(1);
      expect(rec.pluginsLoaded.length).assertEqual(1);
      expect(rec.pluginsLoaded[0]).assertEqual(PEER_A);
      expect(rec.sessionConnected.length).assertEqual(1);
      // rememberKnown：条目保留但 paired=false（未配对）
      expect(c.rememberedDevices.length).assertEqual(1);
      expect(c.rememberedDevices[0].paired).assertFalse();
    });

    it('TestDeviceController_connected_sameDeviceTwiceKeepsSingleEntry', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      expect(c.connectedDevices.length).assertEqual(1);
    });

    it('TestDeviceController_disconnected_runsCleanupRemovesAndNotifiesSession', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.handleEvent({ type: 'disconnected', deviceId: PEER_A });
      expect(rec.disconnCleanup.length).assertEqual(1);
      expect(c.connectedDevices.length).assertEqual(0);
      expect(rec.sessionDisconnected.length).assertEqual(1);
    });

    // ---- 三态分区（已连接 / 发现设备 / 记住的设备） ----

    it('TestDeviceController_threeStatePartition_isExclusive', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = harness(rec);
      const loaded: TrustedDevice[] = [trusted(PEER_A, 'paired-desktop', CERT_A, true)];
      c.rehydrateTrust(loaded);
      // A：已配对且在线 ⇒ 只属「已连接」
      c.handleEvent(connectedEvent(PEER_A, 'paired-desktop'));
      // B：在线但未配对 ⇒ 只属「发现设备」
      c.handleEvent(connectedEvent(PEER_B, 'unpaired-phone'));
      // C：记住但不在线 ⇒ 只属「记住的设备」
      c.rememberKnown(PEER_C, 'offline-laptop');

      const shown: DeviceItem[] = c.connectedShown();
      const disc: DeviceItem[] = c.discoveredShown();
      expect(shown.length).assertEqual(1);
      expect(shown[0].id).assertEqual(PEER_A);
      expect(disc.length).assertEqual(1);
      expect(disc[0].id).assertEqual(PEER_B);
      const offline = c.offlineKnownShown();
      expect(offline.some((r: RememberedDevice): boolean => r.id === PEER_C)).assertTrue();
      expect(offline.some((r: RememberedDevice): boolean => r.id === PEER_A)).assertFalse();
    });

    // ---- 配对与证书钉扎链（MSG114 P0） ----

    it('TestDeviceController_handlePaired_pinsPeerCertificateAndMarksPaired', 0, () => {
      const rec: Rec = new Rec();
      rec.peerCert = CERT_A;
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.handlePaired(PEER_A);
      expect(rec.pinned.has(PEER_A)).assertTrue();
      expect(rec.pinned.get(PEER_A)).assertEqual(CERT_A);
      const t: TrustedDevice | undefined = c.trustedDevices.find((x: TrustedDevice): boolean => x.id === PEER_A);
      expect(t !== undefined).assertTrue();
      expect(t?.certPem).assertEqual(CERT_A);
      expect(t?.paired).assertTrue();
      expect(c.rememberedDevices[0].paired).assertTrue();
    });

    it('TestDeviceController_handlePaired_skipsPinningWhenCertUnavailable', 0, () => {
      const rec: Rec = new Rec();
      rec.peerCert = '';
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.handlePaired(PEER_A);
      // 空串 ⇒ 跳过钉扎，但配对态仍成立（降级不阻塞）
      expect(rec.pinned.size).assertEqual(0);
      const t: TrustedDevice | undefined = c.trustedDevices.find((x: TrustedDevice): boolean => x.id === PEER_A);
      expect(t?.paired).assertTrue();
      expect(t?.certPem).assertEqual('');
    });

    it('TestDeviceController_handlePaired_usesDisplayNameNotRawId', 0, () => {
      const rec: Rec = new Rec();
      rec.peerCert = CERT_A;
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'my-laptop'));
      c.handlePaired(PEER_A);
      const t: TrustedDevice | undefined = c.trustedDevices.find((x: TrustedDevice): boolean => x.id === PEER_A);
      expect(t?.name).assertEqual('my-laptop');
    });

    it('TestDeviceController_handlePaired_ignoresEmptyDeviceId', 0, () => {
      const rec: Rec = new Rec();
      rec.peerCert = CERT_A;
      const c: DeviceController = ready(rec);
      c.handlePaired('');
      expect(c.trustedDevices.length).assertEqual(0);
      expect(rec.pinned.size).assertEqual(0);
    });

    it('TestDeviceController_handleUnpaired_removesPinAndKeepsEntry', 0, () => {
      const rec: Rec = new Rec();
      rec.peerCert = CERT_A;
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.handlePaired(PEER_A);
      c.handleUnpaired(PEER_A);
      expect(rec.removed.length).assertEqual(1);
      expect(rec.removed[0]).assertEqual(PEER_A);
      const t: TrustedDevice | undefined = c.trustedDevices.find((x: TrustedDevice): boolean => x.id === PEER_A);
      // 条目保留（用户需求 3），仅置 paired=false
      expect(t !== undefined).assertTrue();
      expect(t?.paired).assertFalse();
    });

    it('TestDeviceController_setPairedFlag_isSingleWriterAndMirrorsRemembered', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.setPairedFlag(PEER_A, true);
      expect(c.trustedDevices[0].paired).assertTrue();
      expect(c.rememberedDevices[0].paired).assertTrue();
      c.setPairedFlag(PEER_A, false);
      expect(c.trustedDevices[0].paired).assertFalse();
      expect(c.rememberedDevices[0].paired).assertFalse();
      // 幂等：重复置同值不产生新状态、不报错
      c.setPairedFlag(PEER_A, false);
      expect(c.trustedDevices[0].paired).assertFalse();
    });

    // ---- error 事件 ----

    it('TestDeviceController_error_forwardsToCleanupAndPairSession', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent({ type: 'error', deviceId: PEER_A, errorCode: 5, errorMessage: 'handshake failed' });
      expect(rec.errCleanup.length).assertEqual(1);
      expect(rec.sessionErrors.length).assertEqual(1);
      expect(rec.hasLog('handshake failed')).assertTrue();
    });

    it('TestDeviceController_error_rateLimitedIsLocalizedInLog', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent({ type: 'error', deviceId: PEER_A, errorCode: 0, errorMessage: 'rate limited' });
      expect(rec.hasLog('rate limited')).assertTrue();
    });

    // ---- deviceLost ----

    it('TestDeviceController_deviceLost_ignoredWhileStillConnected', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(connectedEvent(PEER_A, 'desktop'));
      c.handleEvent({ type: 'deviceLost', deviceId: PEER_A });
      expect(c.connectedDevices.length).assertEqual(1);
      expect(rec.lostCleanup.length).assertEqual(0);
    });

    it('TestDeviceController_deviceLost_marksDiscoveredOfflineAndCleansUp', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(discovered(PEER_A, 'laptop'));
      c.handleEvent({ type: 'deviceLost', deviceId: PEER_A });
      // 保留条目、置 offline（灰显），不再删除
      expect(c.discoveredDevices.length).assertEqual(1);
      expect(c.discoveredDevices[0].online).assertFalse();
      expect(rec.lostCleanup.length).assertEqual(1);
    });

    // ---- rehydrateTrust（启动重建 + pendingKnown 冲刷） ----

    it('TestDeviceController_rehydrateTrust_pinsAllStoredCertsAndFlushesPendingKnown', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = harness(rec);
      // 加载完成前先来了一条 connected ⇒ 进 pendingKnown
      c.handleEvent(connectedEvent(PEER_B, 'early-peer'));
      expect(c.trustedDevices.length).assertEqual(0);

      const loaded: TrustedDevice[] = [
        trusted(PEER_A, 'desktop', CERT_A, true),
        trusted(PEER_C, 'no-cert-peer', '', false)
      ];
      c.rehydrateTrust(loaded);

      expect(c.trustedDevices.length).assertEqual(3);
      expect(c.trustLoaded).assertTrue();
      // 仅对 certPem 非空者钉扎
      expect(rec.pinned.has(PEER_A)).assertTrue();
      expect(rec.pinned.has(PEER_C)).assertFalse();
      // pendingKnown 已冲刷 ⇒ B 已并入（不丢早到设备）
      expect(c.trustedDevices.some((t: TrustedDevice): boolean => t.id === PEER_B)).assertTrue();
    });

    // ---- pairingRequest（TLS 层 identity 帧；AtomCode MSG134 §一.2 P2 建议） ----

    it('TestDeviceController_pairingRequest_updatesNameInBothLists', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      c.handleEvent(discovered(PEER_A, 'old-name'));
      c.handleEvent(connectedEvent(PEER_A, 'old-name'));
      c.handleEvent({ type: 'pairingRequest', deviceId: PEER_A, deviceName: 'new-name' });
      expect(c.connectedDevices[0].name).assertEqual('new-name');
      expect(c.discoveredDevices[0].name).assertEqual('new-name');
    });

    it('TestDeviceController_pairingRequest_doesNotAutoPairNorCreateEntries', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      // AP-1：pairingRequest 只是 identity 帧 ⇒ **不得**自动回发 pair（由 UI 弹窗确认）
      c.handleEvent({ type: 'pairingRequest', deviceId: PEER_A, deviceName: 'peer' });
      expect(rec.prompts.length).assertEqual(0);
      expect(c.connectedDevices.length).assertEqual(0);
      expect(c.discoveredDevices.length).assertEqual(0);
      // 空名字守卫：不覆盖、不建条目
      c.handleEvent(discovered(PEER_A, 'keep-me'));
      c.handleEvent({ type: 'pairingRequest', deviceId: PEER_A, deviceName: '' });
      expect(c.discoveredDevices[0].name).assertEqual('keep-me');
    });

    // ---- packetReceived 兜底 ----

    it('TestDeviceController_packetReceived_routesOnlyNonTrivialFrames', 0, () => {
      const rec: Rec = new Rec();
      const c: DeviceController = ready(rec);
      const routed: string[] = [];
      c.routerOnPacket = (deviceId: string, raw: string): void => {
        routed.push(deviceId);
      };
      c.handleEvent({ type: 'packetReceived', deviceId: PEER_A, packet: 'x' });
      expect(routed.length).assertEqual(0);
      c.handleEvent({ type: 'packetReceived', deviceId: PEER_A, packet: '{"type":"kdeconnect.ping"}' });
      expect(routed.length).assertEqual(1);
    });
  });
}
