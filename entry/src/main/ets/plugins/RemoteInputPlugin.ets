// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 远程输入插件（kdeconnect.mousepad.request / .keyboardstate）——阶段4 方向B / B1b。
// 设计见 devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md（字段名/类型已按 schema 核定，AtomCode MSG134）。
//
// 分层（本类是**唯一协议字段落点**）：
//   UI ──► MousepadInputPipeline（增量换算 + 合并节流，已有单测锁定）
//            └─► MousepadSink（本类实现）──► PluginBase.send('kdeconnect.mousepad.request', body)
//
// 不变量：① 滚动用 `{dx, dy, scroll:true}`（scroll 是**布尔标记**，非增量值）；
//        ② 特殊键必须 1..32（0 无效，本类拒发并记日志）；③ 不新增 caps（沿用既有声明）。
import { PluginBase } from './PluginBase';
import { MousepadInputPipeline, MousepadSink, MousepadButton } from './MousepadInput';
import { isValidSpecialKey } from './RemoteInputKeymap';

// mousepad.request body（全部可选，按需择字段；schema 核定）
interface MousepadRequestBody {
  dx?: number;
  dy?: number;
  scroll?: boolean;
  singleclick?: boolean;
  doubleclick?: boolean;
  middleclick?: boolean;
  rightclick?: boolean;
  key?: string;
  specialKey?: number;
}

// keyboardstate body（唯一字段 state，required）
interface KeyboardStateBody {
  state?: boolean;
}

// 节流窗口 ≈60Hz（高刷屏仍有余量；见设计 §4.1）
const MOUSEPAD_WINDOW_MS: number = 16;

export class RemoteInputPlugin extends PluginBase implements MousepadSink {
  // 每设备一份（PluginHost 每设备 createAll）⇒ 手势/节流状态天然按设备隔离
  private pipeline: MousepadInputPipeline;

  constructor() {
    super();
    this.displayName = 'RemoteInput';
    this.description = 'Use this device as touchpad/keyboard for the peer';
    this.supportedPacketTypes = ['kdeconnect.mousepad.keyboardstate'];
    this.outgoingPacketTypes = ['kdeconnect.mousepad.request'];
    // sink = 本类：pipeline 的输出最终由本类的 move/click/scroll/key/specialKey 组帧
    this.pipeline = new MousepadInputPipeline(this, MOUSEPAD_WINDOW_MS);
  }

  // UI 入口：拖动手势经此（tap/scroll/键盘也可经此，保证走同一条被单测覆盖的路径）
  input(): MousepadInputPipeline {
    return this.pipeline;
  }

  // ---- MousepadSink 实现（唯一字段名落点） ----

  move(dx: number, dy: number): void {
    const body: MousepadRequestBody = { dx: dx, dy: dy };
    this.sendRequest(body);
  }

  click(button: MousepadButton): void {
    const body: MousepadRequestBody = {};
    if (button === 'single') {
      body.singleclick = true;
    } else if (button === 'double') {
      body.doubleclick = true;
    } else if (button === 'middle') {
      body.middleclick = true;
    } else {
      body.rightclick = true;
    }
    this.sendRequest(body);
  }

  // 滚动：scroll 为布尔标记，dx/dy 承载增量（设计 §1.1）
  scroll(dx: number, dy: number): void {
    const body: MousepadRequestBody = { dx: dx, dy: dy, scroll: true };
    this.sendRequest(body);
  }

  key(text: string): void {
    if (text.length === 0) {
      return;
    }
    const body: MousepadRequestBody = { key: text };
    this.sendRequest(body);
  }

  // 特殊键：下标语义，0 无效 ⇒ 拒发（不变量②）
  specialKey(code: number): void {
    if (!isValidSpecialKey(code)) {
      this.log(`specialKey ${code} rejected (valid range 1..32; 0 is invalid)`);
      return;
    }
    const body: MousepadRequestBody = { specialKey: code };
    this.sendRequest(body);
  }

  // ---- 收包：对端键盘状态（只读展示） ----

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.mousepad.keyboardstate') {
      return false;
    }
    const b: KeyboardStateBody = body as KeyboardStateBody;
    const ready: boolean = b.state === true;
    // 复用 textEvent（设计 §3）：两态 'ready' | 'idle'
    this.notify('mousepadKeyboardState', ready ? 'ready' : 'idle');
    this.log(`keyboardstate: ${ready ? 'ready' : 'idle'}`);
    return true;
  }

  private sendRequest(body: MousepadRequestBody): boolean {
    return this.send('kdeconnect.mousepad.request', body);
  }
}
