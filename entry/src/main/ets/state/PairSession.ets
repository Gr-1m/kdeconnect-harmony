// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 配对会话状态机（阶段 2 / R1 拆分步骤 3；CodeArts MSG55 §6、Omp MSG56 §2）。
//
// 目标（"整体逻辑"层面，而非搬家）：
//   1. **状态与副作用分离**：本类只维护"会话状态 + 定时器 + 决策"，网络发送、连接、持久化、提示
//      全部通过**注入回调**完成（sendPair / connectToPeer / onPaired / onUnpaired / onNotice / onLog）。
//      ⇒ 不再把"状态、发包、弹窗、持久化"揉在一个方法里；也便于将来单测。
//   2. **配对态写入收敛**：本类**不直接写** `paired` —— 只回调 `onPaired/onUnpaired`，
//      由页面统一走 `setPairedFlag()`（MSG50 §3 裁定：消除散落赋值）。
//   3. **可观测**：`@Observed` + 页面 `@State pairSession`、弹窗 `@ObjectLink` 读取
//      （范式同 `common/LogStore.ets`、`model/SystemVolumeModels.ets`，避免"状态变了 UI 不刷新"）。
//
// 设计约束：本文件是**行为保持**的抽取（与 Index 既有实现逐条对齐），不引入新语义。
// 接入方式见 Omp MSG56 §2：在 `refactor/arkts-codearts` 上小步提交、每步构建、不 push。

// 会话阶段：idle（无会话）/ connecting（已发起连接，等技术握手）/ awaiting（我方请求已发出，等对端回请）
// / prompt（对端请求到达，等**用户**确认验证码）
export type PairStage = 'idle' | 'connecting' | 'awaiting' | 'prompt';

// 失败码（与 Index 既有 ERR_* 一致，抽取后作为**单一来源**供页面复用）
export const ERR_OTHER: number = 0;
export const ERR_TIMEOUT: number = 1;
export const ERR_DISCONNECTED: number = 2;
export const ERR_SEND: number = 3;
export const ERR_ADDRESS: number = 4;

// 阶段超时（原为 Index 顶层常量，随状态机一起收敛到这里）
export const CONNECT_TIMEOUT_MS: number = 15000;
export const PAIR_TIMEOUT_MS: number = 45000;

@Observed
export class PairSession {
  // ---------- 可观测状态（弹窗/列表读取）----------
  stage: PairStage = 'idle';
  deviceId: string = '';
  // 与旧实现对齐的 UI 可见字段（Index 原有 sessionName / sessionTarget，弹窗与提示要用）
  peerName: string = '';
  target: string = '';
  code: string = '';              // 验证码文本（由页面计算后写入，或页面自行读取）
  peerRequested: boolean = false; // 本次是"对端发起"（弹窗文案不同）
  // 我方已发出配对请求、等待对端回请的设备（原 Index.requestedPairIds）。
  // 用于识别"双方同时发起"的 race：命中即回一个**不带 timestamp** 的接受帧。
  requestedPeers: string[] = [];

  // ---------- 注入的副作用（状态机不碰 I/O）----------
  /** 发配对帧：withTimestamp=true 表示"发起请求"，false 表示"接受"（协议要求接受帧不带 timestamp） */
  sendPair: (deviceId: string, pair: boolean, withTimestamp: boolean) => boolean = () => false;
  /** 建立到对端的链路；返回 false 表示发起失败 */
  connectToPeer: (id: string, name: string, host: string, port: number) => boolean = () => false;
  /** 配对成功（页面负责 setPairedFlag(true) + 持久化 + 成功提示） */
  onPaired: (deviceId: string) => void = () => {
  };
  /** 解除配对（页面负责 handleUnpaired → setPairedFlag(false)） */
  onUnpaired: (deviceId: string) => void = () => {
  };
  /** 用户可见提示（kind 供页面映射文案；code 为失败码；isError 决定样式）
   *  签名与 Index 既有的 `showNotice(kind, detail, isError, code)` 对齐 ⇒ 接线时可直接转发。 */
  onNotice: (kind: string, detail: string, isError: boolean, code: number) => void = () => {
  };
  /** 页面日志（保持与既有 KDC 日志同一出口） */
  onLog: (msg: string) => void = () => {
  };

  private timerId: number = -1;

  // ---------- UI 动作 ----------

  /** 发起（手动连接 / 发现页连接共用入口）。host 为空视为无地址，直接失败。 */
  start(id: string, name: string, host: string, port: number): void {
    if (this.stage === 'connecting') {
      return;   // 已在连接中，忽略重复触发（与既有实现一致）
    }
    if (host.length === 0) {
      this.failConnect('no address', ERR_ADDRESS);
      return;
    }
    this.clearTimer();
    this.deviceId = id;
    // 与旧实现对齐：sessionName（用于提示文案，name 空则退化为 host:port 或"端口探测中"）
    const portText: string = port > 0 ? `${port}` : '端口探测中';
    this.peerName = name.length > 0 ? name : `${host}:${portText}`;
    this.target = port > 0 ? `${host}:${port}` : host;
    this.stage = 'connecting';
    this.onNotice('connecting', this.target, false, 0);
    let ok: boolean = false;
    try {
      ok = this.connectToPeer(id, name, host, port);
    } catch (e) {
      this.failConnect('connectToPeer failed: ' + (e instanceof Error ? e.message : 'unknown'), ERR_OTHER);
      return;
    }
    if (!ok) {
      this.failConnect('connectToPeer false', ERR_OTHER);
      return;
    }
    this.arm(CONNECT_TIMEOUT_MS, 'connect timeout', 'connect', ERR_TIMEOUT);
  }

  /** 我方主动发起配对请求（发现页/详情页「配对」按钮） */
  requestPair(id: string, timestamp: number): boolean {
    if (id.length === 0) {
      return false;
    }
    const ok: boolean = this.sendPair(id, true, true);
    if (ok) {
      if (!this.requestedPeers.includes(id)) {
        this.requestedPeers.push(id);
      }
      this.deviceId = id;
      if (this.stage === 'idle') {
        this.stage = 'awaiting';
      }
      this.peerRequested = false;
      this.arm(PAIR_TIMEOUT_MS, 'pair not confirmed', 'pair', ERR_TIMEOUT);
    }
    this.onLog(`pair request -> ${id} ok=${ok}`);
    return ok;
  }

  /** 用户在弹窗确认验证码 → 回接受帧（**不带 timestamp**：带了会被对端当成又一次请求） */
  confirm(): void {
    const id: string = this.deviceId;
    if (id.length === 0) {
      return;
    }
    const ok: boolean = this.sendPair(id, true, false);
    if (ok) {
      this.succeed();
    } else {
      this.fail('accept send failed', ERR_SEND);
    }
  }

  /** 用户取消/拒绝 */
  cancel(): void {
    const id: string = this.deviceId;
    if (id.length > 0) {
      this.sendPair(id, false, false);
    }
    this.reset();
  }

  // ---------- 事件入口（页面 handleEvent 转发）----------

  onConnected(id: string): void {
    if (this.stage === 'connecting' && (this.deviceId === id || this.deviceId === '')) {
      this.clearTimer();
      this.deviceId = id;
      this.stage = 'idle';   // 链路已建立；是否配对由后续 pair 帧决定
    }
  }

  onDisconnected(id: string): void {
    this.requestedPeers = this.requestedPeers.filter((x: string) => x !== id);
    if (id.length === 0 || this.deviceId !== id) {
      return;
    }
    if (this.stage === 'connecting') {
      this.failConnect('disconnected', ERR_DISCONNECTED);
    } else if (this.stage === 'awaiting' || this.stage === 'prompt') {
      this.fail('disconnected', ERR_DISCONNECTED);
    }
  }

  /**
   * native 错误事件。
   * **只认本会话设备**的错误；且"等对端用户操作"（awaiting/prompt）期间**不判失败** ——
   * 那时任何无关瞬时错误（链路换代抖动、另一台设备的 TLS 读失败、无 deviceId 的传输层错误）
   * 都不该把会话判死（真机实测：电脑端还没接受就先弹了「配对失败」）。
   * 会话终局只由三个明确信号决定：对端拒绝 / disconnected / 超时。
   */
  onError(id: string, code: number, msg: string): void {
    const forThisSession: boolean = id.length > 0 && this.deviceId.length > 0 && id === this.deviceId;
    if (!forThisSession) {
      return;
    }
    if (this.stage === 'connecting') {
      this.failConnect(msg.length > 0 ? msg : `error ${code}`, code);
    } else if (this.stage === 'awaiting' || this.stage === 'prompt') {
      this.onLog(`pairing session kept alive despite error (waiting for peer user): ${code} ${msg}`);
    }
  }

  /** 对端发来配对请求（router 已完成时钟偏差校验与拒绝） */
  onPeerPairRequest(id: string, timestamp: number): void {
    const race: boolean = this.requestedPeers.includes(id);
    if (race) {
      // 双方同时发起：回一个**不带 timestamp** 的接受帧，否则对端永远停在 Requested
      this.deviceId = id;
      const ok: boolean = this.sendPair(id, true, false);
      this.onLog(`pair race with ${id}: sent accept ok=${ok}`);
      if (ok) {
        this.succeed();
      }
      return;
    }
    this.deviceId = id;
    this.peerRequested = true;
    this.stage = 'prompt';
    this.onLog(`pair request from ${id} (awaiting user confirmation, ts=${timestamp})`);
  }

  /** 对端确认（{pair:true} 且不带 timestamp） */
  onPeerPaired(id: string): void {
    if (this.deviceId !== '' && this.deviceId !== id) {
      return;
    }
    this.deviceId = id;
    this.succeed();
  }

  /** 对端解除配对 */
  onPeerUnpaired(id: string): void {
    this.reset();
    this.onUnpaired(id);
  }

  // ---------- 内部 ----------

  private arm(ms: number, reason: string, stage: string, code: number): void {
    this.clearTimer();
    this.timerId = setTimeout((): void => {
      this.timerId = -1;
      if (stage === 'pair') {
        this.fail(reason, code);
      } else {
        this.failConnect(reason, code);
      }
    }, ms);
  }

  private clearTimer(): void {
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private succeed(): void {
    const id: string = this.deviceId;
    this.clearTimer();
    this.stage = 'idle';
    this.code = '';
    this.peerRequested = false;
    this.requestedPeers = this.requestedPeers.filter((x: string) => x !== id);
    this.onLog(`pairing succeeded with ${id}`);
    if (id.length > 0) {
      this.onPaired(id);
    }
  }

  /** 配对阶段失败：提示只给错误码，明细交给 onLog（与既有实现一致） */
  private fail(reason: string, code: number): void {
    const id: string = this.deviceId;
    this.clearTimer();
    this.stage = 'idle';
    this.code = '';
    this.peerRequested = false;
    if (id.length > 0) {
      this.requestedPeers = this.requestedPeers.filter((x: string) => x !== id);
    }
    this.onNotice('pairFailed', `${code}`, true, code);
    this.onLog(`pairing failed: ${reason} (code=${code})${id !== '' ? ' (' + id + ')' : ''}`);
  }

  /** 连接阶段失败（连接超时/无地址等）：与配对失败分开，提示口径不同 */
  private failConnect(reason: string, code: number): void {
    this.clearTimer();
    this.stage = 'idle';
    this.onNotice('connectFailed', `${code}`, true, code);
    this.onLog(`connect failed: ${reason} (code=${code})`);
  }

  private reset(): void {
    this.clearTimer();
    this.stage = 'idle';
    this.deviceId = '';
    this.code = '';
    this.peerRequested = false;
  }
}
