import { PluginBase } from './PluginBase';

interface BatteryBody {
  currentCharge?: number;
  isCharging?: boolean;
  thresholdEvent?: number;
}

// 电量插件（kdeconnect.battery）：接收对端电量并推给 UI 展示（设备行显示 xx%）。
// 本侧电量上报（发送方向）需系统电量查询权限，M2 后期评估。
export class BatteryPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'Battery';
    this.description = 'Show peer battery level';
    this.supportedPacketTypes = ['kdeconnect.battery'];
    this.outgoingPacketTypes = [];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.battery') {
      return false;
    }
    const b: BatteryBody = body as BatteryBody;
    const charge: number = b.currentCharge ?? -1;
    if (charge < 0) {
      this.log('battery packet without currentCharge');
      return true;
    }
    const charging: boolean = b.isCharging ?? false;
    this.notify('battery', `${charge}|${charging ? '1' : '0'}`);
    return true;
  }
}
