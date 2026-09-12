import { PluginBase, SendFrameFn } from './PluginBase';
import { PluginRegistry } from './PluginRegistry';

// 插件宿主（AP-4）：按设备装载/卸载插件实例，并按 packet type 分发。
// 装载规则（能力交集，对齐 Android PluginFactory.pluginsForCapabilities）：
//   插件被装载 ⟺ (我方 outgoing ∩ 对端 incoming) 或 (我方 incoming ∩ 对端 outgoing) 非空。
//   对端 caps 为空视为「全支持」（兼容老版本对端）。
export class PluginHost {
  private registry: PluginRegistry;
  private logFn: (msg: string) => void;
  // 每设备一份实例集合（关键语义 ①）
  private perDevice: Map<string, PluginBase[]> = new Map();

  constructor(registry: PluginRegistry, logFn: (msg: string) => void) {
    this.registry = registry;
    this.logFn = logFn;
  }

  // 对端 identity 到达（或链路建立）时装载；peer caps 为空数组 → 视为全支持
  loadForDevice(deviceId: string, peerIncoming: string[], peerOutgoing: string[],
                sendFn: SendFrameFn, uiFn: (deviceId: string, kind: string, data: string) => void): void {
    this.unloadForDevice(deviceId);
    const instances: PluginBase[] = [];
    const all: PluginBase[] = this.registry.createAll();
    for (const inst of all) {
      if (!PluginHost.matches(inst, peerIncoming, peerOutgoing)) {
        continue;
      }
      inst.bind(deviceId, sendFn, this.logFn, uiFn);
      try {
        inst.onCreate();
      } catch (e) {
        this.logFn(`plugin ${inst.displayName} onCreate threw (kept for onDestroy)`);
      }
      instances.push(inst);
    }
    this.perDevice.set(deviceId, instances);
    this.logFn(`plugins loaded for ${deviceId}: ${instances.length}`);
  }

  // onDestroy 必达（关键语义 ②）
  unloadForDevice(deviceId: string): void {
    const instances: PluginBase[] | undefined = this.perDevice.get(deviceId);
    if (instances === undefined) {
      return;
    }
    for (const inst of instances) {
      try {
        inst.onDestroy();
      } catch (e) {
        this.logFn(`plugin ${inst.displayName} onDestroy threw`);
      }
    }
    this.perDevice.delete(deviceId);
  }

  unloadAll(): void {
    const ids: string[] = [];
    this.perDevice.forEach((v: PluginBase[], k: string) => {
      ids.push(k);
    });
    for (const id of ids) {
      this.unloadForDevice(id);
    }
  }

  pluginsFor(deviceId: string): PluginBase[] {
    const list: PluginBase[] | undefined = this.perDevice.get(deviceId);
    return list === undefined ? [] : list;
  }

  // 收包分发：逐个插件 try/catch 隔离（对齐 Android Device.kt 的 runCatching 语义）
  dispatch(deviceId: string, packetType: string, body: Object): boolean {
    const list: PluginBase[] | undefined = this.perDevice.get(deviceId);
    if (list === undefined) {
      return false;
    }
    for (const inst of list) {
      if (!inst.supportedPacketTypes.includes(packetType)) {
        continue;
      }
      try {
        if (inst.onPacketReceived(packetType, body)) {
          return true;
        }
      } catch (e) {
        this.logFn(`plugin ${inst.displayName} onPacketReceived threw`);
      }
    }
    return false;
  }

  private static matches(proto: PluginBase, peerIncoming: string[], peerOutgoing: string[]): boolean {
    if (peerIncoming.length === 0 && peerOutgoing.length === 0) {
      return true; // 对端未声明能力 → 视为全支持
    }
    for (const t of proto.outgoingPacketTypes) {
      if (peerIncoming.length === 0 || peerIncoming.includes(t)) {
        return true;
      }
    }
    for (const t of proto.supportedPacketTypes) {
      if (peerOutgoing.length === 0 || peerOutgoing.includes(t)) {
        return true;
      }
    }
    return false;
  }
}
