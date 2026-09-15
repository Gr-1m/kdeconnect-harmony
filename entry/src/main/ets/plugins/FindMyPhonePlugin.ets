import { vibrator } from '@kit.SensorServiceKit';
import { PluginBase } from './PluginBase';

// 查找手机插件（kdeconnect.findmyphone.request）：**只收不发**——收到请求即振动提醒。
// 说明：HarmonyOS 三方可振动（ohos.permission.VIBRATE，normal 级）；响铃需音频资源，M2 后期再评估。
// 发送方向不用：对端 KDE 桌面收到 findmyphone.request 不会弹通知（用户 2026-09-15 实测），
// 故「查找设备」按钮改发 `kdeconnect.ping`（桌面会弹通知），见 Index.onDeviceAction。
export class FindMyPhonePlugin extends PluginBase {
  private ringing: boolean = false;

  constructor() {
    super();
    this.displayName = 'FindMyPhone';
    this.description = 'Ring/vibrate this device when requested';
    this.supportedPacketTypes = ['kdeconnect.findmyphone.request'];
    this.outgoingPacketTypes = [];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.findmyphone.request') {
      return false;
    }
    this.vibrateBurst();
    return true;
  }

  private vibrateBurst(): void {
    this.ringing = true;
    this.notify('findmyphone', 'ringing');
    this.log('find my phone: vibrating');
    const effect: vibrator.VibrateEffect = { type: 'time', duration: 4000 };
    const attribute: vibrator.VibrateAttribute = { usage: 'alarm' };
    vibrator.startVibration(effect, attribute).then(() => {
      this.log('vibration finished');
      this.ringing = false;
      this.notify('findmyphone', 'idle');
    }).catch((err: Error) => {
      this.log(`vibration failed: ${err.message}`);
      this.ringing = false;
      this.notify('findmyphone', 'failed');
    });
  }

  // onDestroy 必达：停掉进行中的振动，避免"找不到手机一直震"
  onDestroy(): void {
    if (!this.ringing) {
      return;
    }
    this.ringing = false;
    try {
      vibrator.stopVibration();
    } catch (e) {
      this.log('stopVibration failed');
    }
  }
}
