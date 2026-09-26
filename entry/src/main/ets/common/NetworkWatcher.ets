// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 局域网发现：网络变化监听（阶段 3 / 批次 1 步骤 5d；CodeArts MSG62）。
//
// 抽离原则（与 PairSession 同一套范式）：
//   · 本类**只持有自己的状态**（连接句柄 + 注册标记），不碰页面 @State；
//   · 页面能力（日志 / 限频 / 广播触发）**全部注入回调** ⇒ 可单测、与页面解耦；
//   · 行为**逐字保持**（自 Index.registerNetworkListener/unregisterNetworkListener 原样搬出，零语义变更）。
//
// 背景（历史坑，勿改）：网络抖动 / 多网卡（WiFi+蜂窝+多卡）会连发 netAvailable，
// 每次都同步调 native.triggerBroadcast() 会在主线程扎堆 —— 用户实测「手动打开 WiFi 那一瞬间 App 就卡住」。
// 故保留 3s 限频（对端周期广播 + native 侧 caps 变更重播已能覆盖发现）。

import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class NetworkWatcher {
  private conn: connection.NetConnection | undefined = undefined;
  private registered: boolean = false;

  /** 页面日志出口 */
  log: (msg: string) => void = () => {
  };
  /** 页面限频器（key, 窗口毫秒）→ 是否放行 */
  gate: (key: string, ms: number) => boolean = () => true;
  /** 触发一次 UDP identity 广播（页面内负责 probeNative 降级） */
  triggerBroadcast: () => void = () => {
  };

  /** 注册网络变化监听（幂等：已注册则直接返回） */
  register(): void {
    if (this.registered) {
      return;
    }
    try {
      const c: connection.NetConnection = connection.createNetConnection();
      c.on('netAvailable', (): void => {
        if (!this.gate('net:triggerBroadcast', 3000)) {
          return;
        }
        this.log('network available — trigger discovery broadcast');
        this.triggerBroadcast();
      });
      c.on('netLost', (): void => {
        this.log('network lost');
      });
      // 本 SDK（OpenHarmony API 26）只有 callback 形式：register(callback: AsyncCallback<void>)
      c.register((err: BusinessError): void => {
        if (err) {
          this.log(`net listener register failed: ${err.code}`);
          return;
        }
        this.conn = c;
        this.registered = true;
        this.log('net change listener registered');
      });
    } catch (e) {
      this.log('net listener failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  /** 退订（幂等；进程退出路径的异常忽略） */
  unregister(): void {
    const c: connection.NetConnection | undefined = this.conn;
    if (c === undefined || !this.registered) {
      return;
    }
    try {
      c.unregister((err: BusinessError): void => {
        if (err) {
          return;
        }
      });
    } catch (e) {
      // 忽略：进程退出路径
    }
    this.conn = undefined;
    this.registered = false;
  }

  /** 供自检/日志：当前是否已注册 */
  isRegistered(): boolean {
    return this.registered;
  }
}
