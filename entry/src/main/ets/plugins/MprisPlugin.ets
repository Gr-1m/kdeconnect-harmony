import { PluginBase } from './PluginBase';

// 媒体控制插件（kdeconnect.mpris / .request）——P1 只声明能力（MSG112 §4）：
// 声明 caps 让电脑端显示 Controls 标签页并愿意回发播放状态；面板 UI 属 P2。
export class MprisPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'MPRIS';
    this.description = 'Control media players on the peer';
    this.supportedPacketTypes = ['kdeconnect.mpris'];
    this.outgoingPacketTypes = ['kdeconnect.mpris.request'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.mpris') {
      return false;
    }
    this.log('mpris state received (panel UI is P2)');
    return true;
  }
}
