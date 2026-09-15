import { batteryInfo } from '@kit.BasicServicesKit';
import { PluginBase } from './PluginBase';

interface BatteryBody {
  currentCharge?: number;
  isCharging?: boolean;
  thresholdEvent?: number;
}

// 电量轮询间隔：电量变化没有公开订阅入口（@ohos.batteryInfo 只给静态属性），
// 故按间隔取一次值、**仅在变化时**发包；另外对端 `kdeconnect.battery.request` 会立即触发下发。
const BATTERY_POLL_MS: number = 30000;

// 电量插件（kdeconnect.battery）：双向（MSG112 §2）。
// - 收：对端电量 → 推 UI（设备行/详情页显示 xx%）
// - 发：本机电量（连接建立时 + 变化时 + 对端 request 时）
export class BatteryPlugin extends PluginBase {
  private lastCharge: number = -1;
  private lastCharging: boolean = false;
  private timerId: number = -1;

  constructor() {
    super();
    this.displayName = 'Battery';
    this.description = 'Share battery level with the peer';
    this.supportedPacketTypes = ['kdeconnect.battery', 'kdeconnect.battery.request'];
    this.outgoingPacketTypes = ['kdeconnect.battery'];
  }

  onCreate(): boolean {
    this.sendLocalBattery();
    this.timerId = setInterval(() => {
      this.pollLocalBattery();
    }, BATTERY_POLL_MS);
    return true;
  }

  onDestroy(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType === 'kdeconnect.battery.request') {
      this.sendLocalBattery();
      return true;
    }
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

  // 本机电量（@ohos.batteryInfo：无 isCharging 布尔，需按 chargingStatus 推导）
  private localBody(): BatteryBody {
    const state: number = batteryInfo.chargingStatus;
    const charging: boolean = state === batteryInfo.BatteryChargeState.ENABLE
      || state === batteryInfo.BatteryChargeState.FULL;
    const body: BatteryBody = { currentCharge: batteryInfo.batterySOC, isCharging: charging };
    return body;
  }

  sendLocalBattery(): boolean {
    const body: BatteryBody = this.localBody();
    this.lastCharge = body.currentCharge ?? -1;
    this.lastCharging = body.isCharging ?? false;
    const ok: boolean = this.send('kdeconnect.battery', body);
    this.log(ok ? `local battery sent (${this.lastCharge}%${this.lastCharging ? ' charging' : ''})`
      : 'local battery send failed');
    return ok;
  }

  private pollLocalBattery(): void {
    try {
      const body: BatteryBody = this.localBody();
      const charge: number = body.currentCharge ?? -1;
      const charging: boolean = body.isCharging ?? false;
      if (charge === this.lastCharge && charging === this.lastCharging) {
        return;
      }
      this.sendLocalBattery();
    } catch (e) {
      this.log('battery poll failed');
    }
  }
}
