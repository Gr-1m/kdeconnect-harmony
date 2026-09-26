// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 通知/日志工具模块（阶段 3 / 批次 1 步骤 5c；CodeArts MSG62）。
//
// 抽离范围（自 Index.ets 原样搬出，**行为逐字保持**）：
//   log() / flushLog()（日志缓冲与节流）/ showNotice()（toast 文案映射）/ resText()（同步取本地化文案）
//
// 分层（与 PairSession / NetworkWatcher 同一套）：
//   · 本类**持有自己的状态**：LogStore（@Observed，页面把它交给 LogsTab 以 @ObjectLink 绑定）、
//     刷新定时器与 idleness 时间戳、刷新计数；页面不再自己持有这些。
//   · 与 UI 强耦合的两点**注入**：① `resText`（需要 HostContext）；② `showToast`（需要 UIContext 的 PromptAction）。
//     本类只负责"选哪条文案 + 何时弹"，具体由页面执行 ⇒ 无 Context 也能单测文案映射。
//   · `noticeKey` 是**页面渲染用的 @State**，仍留在页面；本类通过 `setNoticeKey` 回调告知（不反向持页面状态）。

import { LogStore } from './LogStore';

// 成功提示停留时间（原 Index 顶层常量，随本模块收敛到此）
export const NOTICE_MS: number = 2500;

export class NotificationHelper {
  /** 日志存储（@Observed）：页面把它直接交给 LogsTab（@ObjectLink）即可，无需中转 */
  readonly logStore: LogStore = new LogStore();

  /** 页面注入：同步取本地化文案（需要 HostContext） */
  resText: (resId: number) => string = () => '';
  /** 页面注入：真正弹 toast（需要 UIContext 的 PromptAction）；ms 已算好 */
  showToast: (message: string, ms: number) => void = () => {
  };
  /** 页面注入：同步 noticeKey（页面 @State，供卡片/状态栏渲染） */
  setNoticeKey: (key: string) => void = () => {
  };
  /** 页面注入：日志页是否可见（不可见时不 flush，只省 CPU，非正确性要求） */
  logTabVisible: () => boolean = () => false;

  private logFlushTimer: number = -1;
  private logLastFlushMs: number = 0;
  private logFlushCount: number = 0;

  // ---------- 日志 ----------

  /** 追加一行（节流合并由 flushLog 完成；节流窗口算法与原实现一致） */
  log(line: string): void {
    this.logStore.append(line);
    if (this.logFlushTimer < 0) {
      const idleMs: number = Date.now() - this.logLastFlushMs;
      const waitMs: number = idleMs >= 900 ? 100 : 900;
      this.logFlushTimer = setTimeout((): void => {
        this.logFlushTimer = -1;
        this.flushLog();
      }, waitMs);
    }
  }

  /** 合并刷新：日志页不可见时不写（批3 后写 LogStore 只重建 LogsTab，故这只是省 CPU） */
  flushLog(): void {
    if (this.logStore.isEmpty()) {
      return;
    }
    if (!this.logTabVisible()) {
      return;
    }
    this.logStore.flush();
    this.logLastFlushMs = Date.now();
    this.logFlushCount++;
    if (this.logFlushCount <= 3 || this.logFlushCount % 50 === 0) {
      console.info(`KDC logflush #${this.logFlushCount} @${Date.now()}`);
    }
  }

  /** 清空日志（缓冲 + 文本一起清） */
  clearLogs(): void {
    this.logStore.clear();
  }

  // ---------- 提示 ----------

  /**
   * 提示：用**系统 toast**（底部居中）；失败只给错误码、明细只进日志（上线口径）。
   * ⚠️ message 必须是**纯字符串**（带格式参数的 `$r(...)` 会被 PromptAction 拒绝，实测 "toast failed (4)"）
   * ⇒ 这里统一用 `resText(...id)` 拼字符串。
   */
  showNotice(key: string, detail: string, isError: boolean, dupMs: number = 0): void {
    this.setNoticeKey(key);
    let message: string = this.resText($r('app.string.connect_failed').id);
    if (key === 'connecting') {
      message = `${this.resText($r('app.string.connect_connecting').id)} ${detail}`;
    } else if (key === 'connected') {
      message = `${this.resText($r('app.string.connect_success').id)} ${detail}`;
    } else if (key === 'paired') {
      message = this.resText($r('app.string.pair_success').id);
    } else if (key === 'pairFailed') {
      message = `${this.resText($r('app.string.pair_failed').id)} ${detail}`;
    } else if (key === 'connectFailed') {
      message = `${this.resText($r('app.string.connect_failed').id)} ${detail}`;
    }
    const ms: number = dupMs > 0 ? Math.min(dupMs, 10000) : NOTICE_MS;
    try {
      this.showToast(message, ms);
      this.log(`toast: ${message}`);
    } catch (e) {
      this.log('toast failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  /** 直接给一句话的 toast（原 toastText()）：页面在无本地化需求的场景调用 */
  toast(message: string): void {
    try {
      this.showToast(message, NOTICE_MS);
    } catch (e) {
      this.log('toast failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  /** 清空提示标记（原 clearNotice()） */
  clearNotice(): void {
    this.setNoticeKey('');
  }
}
