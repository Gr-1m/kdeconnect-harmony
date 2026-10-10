// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 触控板输入管线（阶段4 方向B / B1；设计见 devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md §2、§4.1）。
//
// 职责边界（关键）：本类**只做交互逻辑**，把「手势事件」翻译成「语义化的 sink 调用」：
//   PanGesture 的累计偏移 → 每帧增量 →（合并+节流）→ sink.move(dx,dy)
//   点击/滚动/键盘 → 直接透传 sink.click / scroll / key
//
// **协议字段名不在本类**：`MousepadSink` 是注入接口，真正发包的 adapter（`RemoteInputPlugin`）
// 是唯一的字段名落点 —— 待设计 §0 的字段裁决（B0）确认后再实现，本类与测试因此不受其阻塞。
//
// 不变量（不得回退）：
//   ① 累计偏移必须转成**增量**（否则光标跳变）——由内部 baseline 维护；
//   ② 手势结束必须**收尾**（endDrag）把窗口内残留增量发出，否则最后一段位移丢失；
//   ③ 增量为 0 不发包（省一次 TLS 写）；
//   ④ 不 sleep、不阻塞（节流只在 `due()` 时放行，窗口内的增量被合并而非排队堆积）。
import { MousepadThrottle, MoveDelta } from './MousepadThrottle';

// 按键语义（schema 四布尔：singleclick/doubleclick/middleclick/rightclick，设计 §1.1）
export type MousepadButton = 'single' | 'double' | 'middle' | 'right';

// 语义化输出接口。实现方（adapter）负责字段名与组帧——唯一协议落点。
export interface MousepadSink {
  move(dx: number, dy: number): void;

  click(button: MousepadButton): void;

  // 滚动以 dx/dy 表达（schema：scroll 是布尔标记，dx/dy 才是增量 —— 设计 §1.1）
  scroll(dx: number, dy: number): void;

  key(text: string): void;

  specialKey(code: number): void;
}

export class MousepadInputPipeline {
  private sink: MousepadSink;
  private throttle: MousepadThrottle;
  // 手势基线：PanGesture 的 offsetX/offsetY 是"自手势起点的累计值"，必须做差得到增量
  private lastX: number = 0;
  private lastY: number = 0;

  constructor(sink: MousepadSink, windowMs: number) {
    this.sink = sink;
    this.throttle = new MousepadThrottle(windowMs);
  }

  // 手势开始（PanGesture onActionStart）：重置基线，避免把上一轮手势的残留当作增量
  beginDrag(): void {
    this.lastX = 0;
    this.lastY = 0;
    this.throttle.reset();
  }

  // 手势进行（onActionUpdate）：传**累计偏移**，内部转增量并按窗口放行
  dragTo(offsetX: number, offsetY: number, nowMs: number): void {
    const dx: number = offsetX - this.lastX;
    const dy: number = offsetY - this.lastY;
    this.lastX = offsetX;
    this.lastY = offsetY;
    this.throttle.accumulate(dx, dy);
    if (!this.throttle.due(nowMs)) {
      return;
    }
    this.flush(nowMs);
  }

  // 手势结束（onActionEnd）：收尾，把窗口内残留增量发出（不变量②）
  endDrag(nowMs: number): void {
    if (!this.throttle.hasPendingDelta()) {
      return;
    }
    this.flush(nowMs);
  }

  // 手势取消（onActionCancel / 断链）：丢弃残留，不补发
  cancelDrag(): void {
    this.throttle.reset();
  }

  tap(button: MousepadButton): void {
    this.sink.click(button);
  }

  // 滚动（design §1.1：scroll 为布尔标记，dx/dy 承载滚动增量）
  scrollBy(dx: number, dy: number): void {
    this.sink.scroll(dx, dy);
  }

  // 逐字符发送（不做 IME 级接管；design §4.2）
  typeText(text: string): void {
    for (let i = 0; i < text.length; i++) {
      this.sink.key(text.charAt(i));
    }
  }

  typeSpecialKey(code: number): void {
    this.sink.specialKey(code);
  }

  private flush(nowMs: number): void {
    const d: MoveDelta = this.throttle.take(nowMs);
    if (d.dx === 0 && d.dy === 0) {
      return; // 不变量③：零位移不发包
    }
    this.sink.move(d.dx, d.dy);
  }
}
