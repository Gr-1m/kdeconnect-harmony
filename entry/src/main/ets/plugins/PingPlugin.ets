import { PluginBase } from './PluginBase';

interface PingBody {
  message?: string;
}

// Ping 插件（kdeconnect.ping）：收到即回显（对端未给 message 时回 'pong'）。
// 插件框架的首个落地实现（注册表驱动 + 每设备实例），同时供 M2 设备详情页的「发送 ping」用。
export class PingPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'Ping';
    this.description = 'Send and receive ping between devices';
    this.supportedPacketTypes = ['kdeconnect.ping'];
    this.outgoingPacketTypes = ['kdeconnect.ping'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.ping') {
      return false;
    }
    const b: PingBody = body as PingBody;
    const reply: PingBody = { message: b.message ?? 'pong' };
    const ok: boolean = this.send('kdeconnect.ping', reply);
    this.log(ok ? 'ping echoed' : 'ping echo failed');
    return true;
  }

  // UI 主动发 ping（M2 设备详情页）
  sendPing(message: string): boolean {
    const body: PingBody = { message: message };
    return this.send('kdeconnect.ping', body);
  }
}
