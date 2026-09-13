import { pasteboard } from '@kit.BasicServicesKit';
import { PluginBase } from './PluginBase';

interface ClipboardBody {
  content?: string;
  timestamp?: number;
}

// 剪贴板同步插件（kdeconnect.clipboard / .connect）。
// 接收方向：把对端剪贴板内容写入系统剪贴板（桌面复制 → 手机剪贴板立即可用）。
// 发送方向：sendClipboard() 已就绪，等 M2 的 UI 入口（设备详情页/设置项）挂上即可。
export class ClipboardPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'Clipboard';
    this.description = 'Sync clipboard between devices';
    this.supportedPacketTypes = ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect'];
    this.outgoingPacketTypes = ['kdeconnect.clipboard'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.clipboard' && packetType !== 'kdeconnect.clipboard.connect') {
      return false;
    }
    const b: ClipboardBody = body as ClipboardBody;
    const content: string = b.content ?? '';
    if (content.length === 0) {
      this.log('clipboard packet without content (ignored)');
      return true;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.notify('clipboard', `${content.length}`);
      this.log(`clipboard updated from peer (${content.length} chars)`);
    } catch (e) {
      this.log('write system pasteboard failed');
    }
    return true;
  }

  // 把本机剪贴板发给对端（UI 触发；M2 接入入口）
  sendClipboard(): boolean {
    try {
      const sys: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = sys.getDataSync();
      const text: string = data.getPrimaryText();
      if (text.length === 0) {
        this.log('local clipboard empty, nothing sent');
        return false;
      }
      const body: ClipboardBody = { content: text, timestamp: Date.now() };
      const ok: boolean = this.send('kdeconnect.clipboard', body);
      this.log(ok ? `clipboard sent (${text.length} chars)` : 'clipboard send failed');
      return ok;
    } catch (e) {
      this.log('read local clipboard failed');
      return false;
    }
  }
}
