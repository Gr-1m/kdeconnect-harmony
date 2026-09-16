// 插件基类（AP-4 / M2 地基）。
// 设计对齐 Android Plugin.kt（docs/12 §一）：能力声明 + 生命周期 + 收包回调；
// 但**注册表驱动**，不走 iOS 那种硬编码 switch（docs/12 的反面教材）。
// 关键语义：① 每设备一份实例（避免多设备状态串扰）；② onDestroy 必达（即使 onCreate 部分失败）。

export type SendFrameFn = (deviceId: string, packetJson: string) => boolean;

export abstract class PluginBase {
  // 展示名 / 描述（后续设备详情页与设置项使用）
  displayName: string = '';
  description: string = '';
  // 我能接收的 packet type（用于 incomingCapabilities 汇总与收包路由）
  supportedPacketTypes: string[] = [];
  // 我能发出的 packet type（用于 outgoingCapabilities 汇总）
  outgoingPacketTypes: string[] = [];

  protected deviceId: string = '';
  private logFn: (msg: string) => void = () => {
  };
  private sendFn: SendFrameFn = () => false;
  // 插件 → UI 的事件出口（kind 由插件定义，如 'battery'；data 为 JSON 字符串）
  private uiFn: (deviceId: string, kind: string, data: string) => void = () => {
  };

  // 绑定宿主能力（每设备实例化后由 PluginHost 调用）
  bind(deviceId: string, sendFn: SendFrameFn, logFn: (msg: string) => void,
       uiFn: (deviceId: string, kind: string, data: string) => void): void {
    this.deviceId = deviceId;
    this.sendFn = sendFn;
    this.logFn = logFn;
    this.uiFn = uiFn;
  }

  // 生命周期：onCreate 可失败（失败也会调用 onDestroy，保证反注册不泄漏）
  onCreate(): boolean {
    return true;
  }

  onDestroy(): void {
  }

  // 收包回调：返回 true 表示已处理（PluginHost 据此决定是否记录"未处理"）
  onPacketReceived(packetType: string, body: Object): boolean {
    return false;
  }

  protected log(msg: string): void {
    this.logFn(`[${this.displayName}] ${msg}`);
  }

  protected send(packetType: string, body: Object): boolean {
    const frame: PluginFrame = { id: Date.now(), type: packetType, body: body };
    // 探针（MSG151）：native 的 [KDC-JS-ENTRY] 抓到 JsSendPacket 阻塞 0.6~6.1 秒，而这 9 次
    // 慢调用全走**插件侧**发送路径（PluginHost 的 sendFn 直调 native.sendPacket，不经 PacketRouter）。
    // 这里补上插件链的计时，和 PacketRouter 里的 KDC slow send 合起来才是全量覆盖。
    const t0: number = Date.now();
    const ok: boolean = this.sendFn(this.deviceId, JSON.stringify(frame) + '\n');
    const dt: number = Date.now() - t0;
    if (dt > 100) {
      console.warn(`KDC slow plugin send ${dt}ms -> ${packetType} (${this.deviceId})`);
    }
    return ok;
  }

  // 向 UI 层推送插件事件（由 Index 转成 @State 展示）
  protected notify(kind: string, data: string): void {
    this.uiFn(this.deviceId, kind, data);
  }
}

// 组帧用最小结构（与 PacketRouter 的 OutPacket 同形）
export interface PluginFrame {
  id: number;
  type: string;
  body: Object;
}
