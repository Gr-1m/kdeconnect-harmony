import { PluginBase } from './PluginBase';

// 插件注册表（AP-4）：能力 → 构造器 的 map。新增插件只需在此 register，
// 框架代码零改动（对齐 docs/12「注册表驱动，禁止硬编码 switch」）。
export type PluginFactory = () => PluginBase;

export class PluginRegistry {
  private factories: Map<string, PluginFactory> = new Map();
  private names: string[] = [];

  register(pluginKey: string, factory: PluginFactory): void {
    if (this.factories.has(pluginKey)) {
      return;
    }
    this.factories.set(pluginKey, factory);
    this.names.push(pluginKey);
  }

  pluginKeys(): string[] {
    return this.names;
  }

  // 每设备一份新实例（关键语义 ①）
  createAll(): PluginBase[] {
    const out: PluginBase[] = [];
    for (const key of this.names) {
      const factory: PluginFactory | undefined = this.factories.get(key);
      if (factory !== undefined) {
        out.push(factory());
      }
    }
    return out;
  }

  // 我方 incoming 能力汇总（去重）
  incomingCapabilities(): string[] {
    return this.aggregate(true);
  }

  // 我方 outgoing 能力汇总（去重）
  outgoingCapabilities(): string[] {
    return this.aggregate(false);
  }

  private aggregate(incoming: boolean): string[] {
    const out: string[] = [];
    for (const plugin of this.createAll()) {
      const types: string[] = incoming ? plugin.supportedPacketTypes : plugin.outgoingPacketTypes;
      for (const t of types) {
        if (!out.includes(t)) {
          out.push(t);
        }
      }
    }
    return out;
  }
}
