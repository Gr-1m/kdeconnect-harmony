// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 插件事件总线（阶段 2 / R1 拆分步骤 4；CodeArts MSG57 §1）。
//
// 动机（评审的结构性根因②③，不是给某个分支打补丁）：
//   · 原实现把"插件事件分发"写成 `Index.onPluginEvent()` 里的**一条长 if-else 链**
//     （battery / systemvolume.sinks / mpris.playerList / mpris.playerUpdate / runcommand.output /
//      clipboard.request / … / 未知 kind 兜底）——每加一个插件事件就要改这个巨型方法，
//      "谁消费哪个 kind"无法在局部看清，也容易漏掉消费端（本会话已出现过"notify 出去消费端为 0"）。
//   · 本类把分发改成**显式路由表**：`kind → handler`，页面只在装配期注册一次；
//     未注册的 kind 走**统一兜底**（默认记一行日志，**绝不静默丢弃**），problem 可见即定位。
//
// 分层约定（与 PairSession 同一套思路）：
//   · 本类**只做分发**，不碰网络/持久化/UI 状态；处理器由页面注入；
//   · 不持有 UI 状态 ⇒ 不需要 @Observed；它是"服务"而非"可观测 store"。
//   · `on()` **返回退订函数**，调用方无需自己保存引用（避免"重复注册/忘记退订"这类状态泄漏）。

import { PluginEvent } from '../plugins/PluginEvent';

export type PluginEventHandler = (deviceId: string, ev: PluginEvent) => void;

export class PluginEventBus {
  private routes: Map<string, PluginEventHandler> = new Map();
  // 未注册 kind 的统一兜底。默认实现 = 记日志（可被页面覆盖为"更醒目的告警"）。
  private fallback: PluginEventHandler = (deviceId: string, ev: PluginEvent): void => {
    this.log(`plugin event (unhandled) ${ev.kind} from ${deviceId}`);
  };
  private log: (msg: string) => void = () => {
  };

  /** 注入页面日志出口（保持与既有 KDC 日志同一条流） */
  setLog(fn: (msg: string) => void): void {
    this.log = fn;
  }

  /** 覆盖未注册 kind 的兜底处理（例如需要弹一次提示时） */
  setFallback(handler: PluginEventHandler): void {
    this.fallback = handler;
  }

  /**
   * 注册某 kind 的处理器，返回**退订函数**。
   * 同一 kind 重复注册视为覆盖（后注册生效），并在日志里留痕以便发现装配错误。
   */
  on(kind: string, handler: PluginEventHandler): () => void {
    if (this.routes.has(kind)) {
      this.log(`plugin event route replaced: ${kind}`);
    }
    this.routes.set(kind, handler);
    return (): void => {
      // 仅当仍是同一个处理器时才删除（防止"退订旧的把新的删掉"）
      if (this.routes.get(kind) === handler) {
        this.routes.delete(kind);
      }
    };
  }

  /** 唯一入口：页面把任何插件事件原样交给它。返回 true = 已有处理器消费 */
  dispatch(deviceId: string, ev: PluginEvent): boolean {
    const h: PluginEventHandler | undefined = this.routes.get(ev.kind);
    if (h !== undefined) {
      h(deviceId, ev);
      return true;
    }
    this.fallback(deviceId, ev);
    return false;
  }

  /** 已注册的 kinds（自检、日志、测试用） */
  kinds(): string[] {
    const out: string[] = [];
    this.routes.forEach((v: PluginEventHandler, k: string): void => {
      out.push(k);
    });
    return out;
  }

  /** 清空全部路由（切换账号/重置时用；幂等） */
  clear(): void {
    this.routes.clear();
  }
}
