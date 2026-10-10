// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 触控板输入节流器（阶段4 方向B / B1 的纯逻辑部分；设计见
// devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md §2 与 §5-4）。
//
// 存在理由：`PanGesture.onActionUpdate` 在真机上可达 120Hz，而每次发送都是一次 TLS 写
// （且 native 侧已有 `KDC slow plugin send` 慢调用先例）⇒ 必须**合并 + 节流**，否则刷爆通道、
// 拖慢 UI 线程。本类把"合并增量 + 按时间窗放行"抽成**不依赖时钟的纯逻辑**（nowMs 由调用方注入），
// 从而可被 hypium 单测确定性驱动。
//
// 不变量（不得回退）：
//   ① **不 sleep、不阻塞**：due() 只做时间戳比较，放行与否由调用方决定丢弃或发送；
//   ② **不丢尾帧语义**：手势结束时调用方应 `take()` 一次把残留增量发出去（take 无副作用地返回当前值）；
//   ③ 协议字段名**不在此类**（B0 未决，见设计 §0）—— 本类只产出 `{dx, dy}` 数值。
export interface MoveDelta {
  dx: number;
  dy: number;
}

// 默认窗口 16ms ≈ 60Hz（高刷屏仍有余量；低于此收益递减）
const DEFAULT_WINDOW_MS: number = 16;

export class MousepadThrottle {
  private windowMs: number;
  private pendingDx: number = 0;
  private pendingDy: number = 0;
  private hasPending: boolean = false;
  private lastFlushMs: number = 0;

  constructor(windowMs: number) {
    this.windowMs = windowMs > 0 ? windowMs : DEFAULT_WINDOW_MS;
  }

  // 累积一次移动增量（可正可负；调用方传的是"本次回调与上次之差"）
  accumulate(dx: number, dy: number): void {
    this.pendingDx += dx;
    this.pendingDy += dy;
    this.hasPending = true;
  }

  // 是否已到放行窗口。首次有增量时立即放行（低延迟，避免第一步"卡一下"）。
  due(nowMs: number): boolean {
    if (!this.hasPending) {
      return false;
    }
    if (this.lastFlushMs === 0) {
      return true;
    }
    return nowMs - this.lastFlushMs >= this.windowMs;
  }

  // 取走累积增量并重置（同时刷新窗口起点）。无残留增量时返回 {0,0}（调用方自行决定是否发）。
  take(nowMs: number): MoveDelta {
    const out: MoveDelta = { dx: this.pendingDx, dy: this.pendingDy };
    this.pendingDx = 0;
    this.pendingDy = 0;
    this.hasPending = false;
    this.lastFlushMs = nowMs;
    return out;
  }

  hasPendingDelta(): boolean {
    return this.hasPending;
  }

  // 手势取消/断链清理：丢弃残留并复位窗口（下次从"立即放行"重新开始）
  reset(): void {
    this.pendingDx = 0;
    this.pendingDy = 0;
    this.hasPending = false;
    this.lastFlushMs = 0;
  }
}
