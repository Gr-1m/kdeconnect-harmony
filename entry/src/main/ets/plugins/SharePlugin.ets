// SPDX-License-Identifier: GPL-2.0-or-later
import { PluginBase } from './PluginBase';

interface ShareRequestBody {
  filename?: string;
  text?: string;
  url?: string;
  numberOfFiles?: number;
  totalPayloadSize?: number;
}

// 文件分享插件（kdeconnect.share.request）。
// M1 锚点：桌面 → 鸿蒙发文件。本插件声明能力（避免 KDE 采纳我方 caps 后收窄、拒发 share），
// 并在收到请求时记录/展示文件信息；二进制 payload 本体由 native 处理，进度经
// payloadTransfer 事件上报（AP-2 的文件页 UI 负责进度与「保存/丢弃」）。
export class SharePlugin extends PluginBase {
  // 最近一次收到的分享信息（供设备详情/文件页展示；仅内存，不做持久化）
  lastFileName: string = '';
  lastPayloadSize: number = 0;

  constructor() {
    super();
    this.displayName = 'Share';
    this.description = 'Send and receive files/URLs';
    this.supportedPacketTypes = ['kdeconnect.share.request'];
    this.outgoingPacketTypes = ['kdeconnect.share.request'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.share.request') {
      return false;
    }
    const b: ShareRequestBody = body as ShareRequestBody;
    if (b.filename !== undefined && b.filename.length > 0) {
      this.lastFileName = b.filename;
      this.lastPayloadSize = b.totalPayloadSize ?? 0;
      this.log(`incoming file: ${b.filename} (${this.lastPayloadSize} bytes) — payload via payloadTransfer`);
    } else if (b.url !== undefined && b.url.length > 0) {
      this.log(`incoming url: ${b.url}`);
    } else if (b.text !== undefined && b.text.length > 0) {
      this.log(`incoming text (${b.text.length} chars)`);
    } else {
      this.log('share.request without file/url/text');
    }
    return true;
  }
}
