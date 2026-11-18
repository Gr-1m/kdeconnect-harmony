// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// KcBridge —— **全工程唯一的 native（`libkdeconnect_napi.so`）import 点**（P0-4/P1-1 阶段 A）。
//
// 为什么：参考库 `docs/kdeconnect-oh/06-coding-standards.md §4.1`「只有 bridge/ 允许 import native」；
// 我方此前 5 个文件直连（`Index`/`EntryAbility`/`PacketRouter`/`DeviceController`/`PayloadController`），
// 带来两个实际代价：① 这些文件的纯逻辑无法在宿主（bun）秒级回归；② native 边界散落，改契约要全仓找。
//
// 阶段边界（见 `devdocs/MAP_KCApi_PHASEA_20261114.md`）：
//   · **阶段 A（本文件现状）**：把**现有 19 个导出**按域收敛到此处，**签名与行为 100% 不变**，不改 `Index.d.ts`/napi/`contract/`；
//   · 阶段 B（CCR-3 后）：在本文件内**增补**冻结契约 `KcApi` 形态（配对/设备名原语化、`kind + JSON` 事件、
//     `contractVersion` 启动校验、错误 `KCError` 化）。映射与差异见该文档 §2；串行队列到阶段 B 再谈（§4）。
//
// 调用耗时探针（MSG262 §3.2）：`probeNative()` 只在 **>100ms** 时 `console.warn`（hilog 可见），不阻塞、不吞异常。
// 目的：把「主线程被 native 卡住」定位到具体函数，而不是靠体感。

import native from 'libkdeconnect_napi.so';
import { NetConfig, CertPair, NetEvent } from 'libkdeconnect_napi.so';
// B-1：kind→NetEvent 单映射表（纯逻辑；门禁 tools/check-event-kinds.py）
import { decodeEvent } from '../common/EventKind';

// 类型再导出：其余文件从这里取类型，不再直接 import .so
export { NetConfig, CertPair, NetEvent };

/** NAPI 同步调用计时（只记录，不干预） */
export function probeNative<T>(name: string, fn: () => T): T {
  const t0: number = Date.now();
  try {
    return fn();
  } finally {
    const dt: number = Date.now() - t0;
    if (dt > 100) {
      console.warn(`KDC slow native ${name}: ${dt}ms`);
    }
  }
}

/**
 * native 桥（阶段 A：现有 19 导出的同签名转发，按域分组）。
 * 单例语义与 native 一致：`start` 只成功一次、`setOnEvent/init` 只注册一次（阶段 B 再谈会话化）。
 */
export class KcBridge {
  // ==================== 生命周期 ====================
  static init(eventCallback: (event: NetEvent) => void): void {
    probeNative('init', (): void => {
      native.init(eventCallback);
    });
  }

  static start(config: NetConfig): boolean {
    return probeNative('start', (): boolean => native.start(config));
  }

  static stop(): void {
    probeNative('stop', (): void => {
      native.stop();
    });
  }

  static shutdown(): void {
    probeNative('shutdown', (): void => {
      native.shutdown();
    });
  }

  // ==================== 发现 / 连接 ====================
  static triggerBroadcast(): void {
    probeNative('triggerBroadcast', (): void => {
      native.triggerBroadcast();
    });
  }

  static connectToPeer(host: string, port: number): void {
    probeNative('connectToPeer', (): void => {
      native.connectToPeer(host, port);
    });
  }

  static disconnect(deviceId: string): void {
    probeNative('disconnect', (): void => {
      native.disconnect(deviceId);
    });
  }

  static setCapabilities(incoming: string[], outgoing: string[]): void {
    probeNative('setCapabilities', (): void => {
      native.setCapabilities(incoming, outgoing);
    });
  }

  // ==================== 配对 / 信任 / 证书 ====================
  static generateCert(deviceId: string): CertPair {
    return probeNative('generateCert', (): CertPair => native.generateCert(deviceId));
  }

  static getPairVerificationCode(deviceId: string, timestamp: number): string {
    return probeNative('getPairVerificationCode', (): string =>
      native.getPairVerificationCode(deviceId, timestamp));
  }

  static getPeerCertificate(deviceId: string): string {
    return probeNative('getPeerCertificate', (): string => native.getPeerCertificate(deviceId));
  }

  static getOwnCertificate(): string {
    return probeNative('getOwnCertificate', (): string => native.getOwnCertificate());
  }

  static setTrustedCertificate(deviceId: string, certPem: string): void {
    probeNative('setTrustedCertificate', (): void => {
      native.setTrustedCertificate(deviceId, certPem);
    });
  }

  static removeTrustedCertificate(deviceId: string): void {
    probeNative('removeTrustedCertificate', (): void => {
      native.removeTrustedCertificate(deviceId);
    });
  }

  // ==================== 收发包 ====================
  static sendPacket(deviceId: string, packetJson: string): boolean {
    return probeNative('sendPacket', (): boolean => native.sendPacket(deviceId, packetJson));
  }

  // ==================== 契约版本（B-4）====================

  /** 预冻结契约版本（native 由 `contract/kcbridge.d.ts` 内容哈希生成）；启动校验用 */
  static contractVersion(): number {
    return probeNative('contractVersion', (): number => native.contractVersion());
  }

  // ==================== 配对 / 设备名原语（B-2：native 侧构造协议帧）====================

  /** 我方发起配对请求（timestamp 由 UI 弹窗固定，保证两端验证码一致；对端回请走 `acceptPair`） */
  static requestPair(deviceId: string, timestamp: number): boolean {
    return probeNative('requestPair', (): boolean => native.requestPair(deviceId, timestamp));
  }

  /** 接受对端配对请求（**不带** timestamp，避免被对端当成又一次请求） */
  static acceptPair(deviceId: string): boolean {
    return probeNative('acceptPair', (): boolean => native.acceptPair(deviceId));
  }

  /** 拒绝对端配对请求 */
  static rejectPair(deviceId: string): boolean {
    return probeNative('rejectPair', (): boolean => native.rejectPair(deviceId));
  }

  /** 解除配对（native 侧**同时清信任**；本侧仍需回写本地状态） */
  static unpair(deviceId: string): boolean {
    return probeNative('unpair', (): boolean => native.unpair(deviceId));
  }

  /** 改设备名（native 更新 + 重发 identity；不再需要整体重启 native 栈） */
  static setDeviceName(name: string): boolean {
    return probeNative('setDeviceName', (): boolean => native.setDeviceName(name));
  }

  // ==================== payload（文件传输）====================
  static sendPayload(deviceId: string, packetType: string, bodyJson: string, filePath: string): number {
    return probeNative('sendPayload', (): number =>
      native.sendPayload(deviceId, packetType, bodyJson, filePath));
  }

  /** 把 native spool 落成目标文件（自动保存路径）；返回是否成功 */
  static keepPayload(transferId: number, destPath: string): boolean {
    return probeNative('keepPayload', (): boolean => native.keepPayload(transferId, destPath));
  }

  /** 丢弃 spool / 已保留副本；返回 native 是否真的删了东西 */
  static discardPayload(transferId: number): boolean {
    return probeNative('discardPayload', (): boolean => native.discardPayload(transferId));
  }

  static cancelPayload(transferId: number): void {
    probeNative('cancelPayload', (): void => {
      native.cancelPayload(transferId);
    });
  }

  // ==================== 冻结 KcApi 契约面补齐（阶段 B；CCR-3 §2.4 / §3.1 / CCR-1a） ====================

  /** 当前 deviceId（由 IdentityStore 装配时注入；`generateIdentity` 适配用，不改变身份持久化归属） */
  private static currentDeviceId: string = '';

  /** IdentityStore 注入当前 deviceId（私钥仍由 ArkTS 持有，见 CCR-3 §2.4） */
  static setCurrentDeviceId(deviceId: string): void {
    KcBridge.currentDeviceId = deviceId;
  }

  /** 首装身份生成（CCR-3 §2.4 适配：native `generateCert` + 回填 deviceId，返回 JSON） */
  static generateIdentity(deviceName: string): string {
    const id: string = KcBridge.currentDeviceId !== '' ? KcBridge.currentDeviceId : KcBridge.randomDeviceId();
    const pair: CertPair = probeNative('generateCert', (): CertPair => native.generateCert(id));
    KcBridge.currentDeviceId = id;
    return JSON.stringify({
      deviceId: id,
      deviceName: deviceName,
      certPem: pair.certPem,
      keyPkcs8Base64: pair.keyPem
    });
  }

  /** 32 hex（UUIDv4 去横线同口径；仅在 IdentityStore 未注入时临时用） */
  private static randomDeviceId(): string {
    let s: string = '';
    for (let i = 0; i < 32; i++) {
      s += Math.floor(Math.random() * 16).toString(16);
    }
    return s;
  }

  /** 重发 UDP 发现（契约名 ↔ 现有 `triggerBroadcast`，CCR-3 §3.1） */
  static refreshDiscovery(): void {
    KcBridge.triggerBroadcast();
  }

  /** 网络快照入口：native 发现层自行枚举接口（`discovery.rs broadcast_addresses`）⇒ stub E105 */
  static networkChanged(_networkJson: string): void {
    KcBridge.notImplemented('networkChanged: 发现层自行枚举接口（见 CCR-3 §2.4）');
  }

  /** 发文件（契约名 ↔ `sendPayload`；filename 并入 body，tid 由 TransferStarted 事件回填） */
  static sendFile(deviceId: string, type: string, bodyJson: string, filePath: string, filename: string): void {
    let body: string = bodyJson;
    try {
      const obj: Record<string, string> = JSON.parse(bodyJson) as Record<string, string>;
      obj['fileName'] = filename;
      body = JSON.stringify(obj);
    } catch (e) {
      body = JSON.stringify({ fileName: filename });
    }
    KcBridge.sendPayload(deviceId, type, body, filePath);
  }

  /** 接受传输（spool 模型下 = 落成目标文件；CCR-3 §3.1 名称映射） */
  static acceptTransfer(transferId: number, destPath: string): void {
    KcBridge.keepPayload(transferId, destPath);
  }

  /** 拒绝传输（spool 模型 = 丢弃 spool） */
  static rejectTransfer(transferId: number): void {
    KcBridge.discardPayload(transferId);
  }

  /** 取消传输（契约名 ↔ `cancelPayload`） */
  static cancelTransfer(transferId: number): void {
    KcBridge.cancelPayload(transferId);
  }

  /** SFTP 根目录：未实装（Q3 不广告 sftp 能力）⇒ stub E105 */
  static setSftpRoots(_rootsJson: string): void {
    KcBridge.notImplemented('setSftpRoots: SFTP 未实装（Q3 裁决不广告该能力）');
  }

  /** offer 模式自动接受超时：未实装（当前 spool-only）⇒ stub E105 */
  static setAutoAcceptSec(_sec: number): void {
    KcBridge.notImplemented('setAutoAcceptSec: offer 模式未实装（CCR-1a）');
  }

  /** 接收模式：`spool` 为当前默认（no-op 成功）；`offer` 未实装 ⇒ E105（CCR-1a） */
  static setAcceptMode(mode: string): void {
    if (mode === 'spool') {
      return;
    }
    KcBridge.notImplemented(`setAcceptMode('${mode}'): 当前只支持 spool（CCR-1a）`);
  }

  /**
   * 契约事件通道（CCR-3 §2.2）。
   * ⚠️ **进程内单次注册**（native 侧 `set_on_event` 二次调用抛 `kind bridge already initialized`）⇒
   * 与类型化 `init(cb)` 是**运行期二选一**：「并存过渡」指两条代码路径都在，但同一进程只能注册其中一条；
   * 生产切换（退类型化通道）需与 `init` 的注册点一起改（由总指挥确认后执行，MSG276 §2/§3.2）。
   */
  static setOnEvent(cb: (kind: number, eventJson: string) => void): void {
    probeNative('setOnEvent', (): void => {
      native.setOnEvent(cb);
    });
  }
  /**
   * **B-1 适配层**：把冻结契约的 kind 通道解码为类型化事件（18 行映射见 `common/EventKind.ets`）。
   * ⚠️ 内部会调用 `setOnEvent` ⇒ 同样受「进程内单次注册」约束（与 `init` 二选一）。
   * 与 `init(cb(NetEvent))` 并存过渡；解码失败的 kind 已按契约处置（`Log(14)` 入 LogStore、其余丢弃 + 日志），
   * 不会把错形状喂给控制器/插件。生产切换（退类型化通道）由总指挥单独确认后执行（MSG276 §2/§3.2）。
   */
  static setDecodedListener(eventCallback: (event: NetEvent) => void): void {
    KcBridge.setOnEvent((kind: number, json: string): void => {
      const decoded: NetEvent | undefined = decodeEvent(kind, json) as NetEvent | undefined;
      if (decoded !== undefined) {
        eventCallback(decoded);
      }
    });
  }


  /** stub 统一出口：`KC_E105` 语义（BAD_PARAM）+ 明确原因，禁止静默成功 */
  private static notImplemented(reason: string): void {
    throw new Error(`KC_E105: ${reason}`);
  }
}
