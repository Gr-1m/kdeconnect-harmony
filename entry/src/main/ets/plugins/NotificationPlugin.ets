import { PluginBase } from './PluginBase';

// 通知同步插件（kdeconnect.notification / .request）——P1 只声明能力（MSG112 §4）：
// 声明 caps 让电脑端显示 Controls 标签页；通知列表 UI 属 P2。
export class NotificationPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'Notification';
    this.description = 'Sync notifications with the peer';
    this.supportedPacketTypes = ['kdeconnect.notification'];
    this.outgoingPacketTypes = ['kdeconnect.notification.request'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.notification') {
      return false;
    }
    this.log('notification received (list UI is P2)');
    return true;
  }
}
