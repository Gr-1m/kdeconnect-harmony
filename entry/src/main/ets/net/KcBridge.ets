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
}
