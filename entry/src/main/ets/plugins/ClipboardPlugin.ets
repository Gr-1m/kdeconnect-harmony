import { pasteboard } from '@kit.BasicServicesKit';
import { PluginBase } from './PluginBase';

interface ClipboardBody {
  content?: string;
  timestamp?: number;
}

// 剪贴板同步插件（kdeconnect.clipboard / .connect）——双向（MSG112 §1）。
// - 收 `kdeconnect.clipboard`：对端剪贴板内容 → 写入系统剪贴板（桌面复制 → 手机立即可用）
// - 收 `kdeconnect.clipboard.connect`：对端**索取**我方剪贴板。读取本机剪贴板需
//   `ohos.permission.READ_PASTEBOARD`（system_basic，三方应用不可声明）→ 只能提示用户
//   点 PasteButton 授权后发送，这里不自动回复。
// - 发 `kdeconnect.clipboard`：本机剪贴板内容（PasteButton 授权后）
// - 发 `kdeconnect.clipboard.connect`：**索取**对端剪贴板（timestamp=0 保证对端一定回复）
export class ClipboardPlugin extends PluginBase {
  // 本端**刚从对端写入剪贴板**的内容 + 时刻：用于 sendClipboard() 的回环抑制（AtomCode L-P1-1）。
  // 语义与 Android ClipboardPlugin 的 lastContents 一致，并按**总指挥 MSG24 裁定表 #4** 加 **2 分钟窗**
  // （对照 Android）：只在"刚同步过来的短时间内"抑制回发 —— 用户过一会儿自己复制同一段文本再发，
  // 属于真实意图，不该被永久抑制。
  private lastReceivedContent: string = '';
  private lastReceivedAtMs: number = 0;
  private static readonly LOOP_GUARD_MS: number = 120000;
  constructor() {
    super();
    this.displayName = 'Clipboard';
    this.description = 'Sync clipboard between devices';
    this.supportedPacketTypes = ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect'];
    this.outgoingPacketTypes = ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.clipboard' && packetType !== 'kdeconnect.clipboard.connect') {
      return false;
    }
    const b: ClipboardBody = body as ClipboardBody;
    const content: string = b.content ?? '';
    if (content.length === 0) {
      if (packetType === 'kdeconnect.clipboard.connect') {
        // 对端索取剪贴板：本侧无权读取 → 让 UI 提示用户点「粘贴」按钮授权发送
        this.notify('clipboard.request', '');
        this.log('peer requested clipboard (needs PasteButton authorization)');
      } else {
        this.log('clipboard packet without content (ignored)');
      }
      return true;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
      pasteboard.getSystemPasteboard().setDataSync(data);
      // 防回环（AtomCode L-P1-1 / 裁定 #4）：记下"这段内容是对端同步过来的"+时刻，
      // sendClipboard() 在**2 分钟窗内**遇到同内容即抑制 —— 否则双端互刷成死循环。
      this.lastReceivedContent = content;
      this.lastReceivedAtMs = Date.now();
      this.notify('clipboard', `${content.length}`);
      this.log(`clipboard updated from peer (${content.length} chars)`);
    } catch (e) {
      this.log('write system pasteboard failed');
    }
    return true;
  }

  // 把本机剪贴板发给对端（PasteButton 拿到临时读权限后由 UI 触发）
  sendClipboard(): boolean {
    try {
      const sys: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = sys.getDataSync();
      const text: string = data.getPrimaryText();
      if (text.length === 0) {
        this.log('local clipboard empty, nothing sent');
        return false;
      }
      if (text === this.lastReceivedContent
        && (Date.now() - this.lastReceivedAtMs) <= ClipboardPlugin.LOOP_GUARD_MS) {
        // 防回环（AtomCode L-P1-1 + 裁定 #4 的 2 分钟窗）：这段内容正是**刚**由对端同步过来的，
        // 原样发回会造成双端互刷死循环。返回 true = "已按规则处理完毕"，**不是失败**
        // —— 否则 UI 会对一次正常去重弹发送失败提示。窗外的同内容视为用户真实意图，照常发送。
        this.log('clipboard echo suppressed (loop guard: same content within 2min)');
        return true;
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

  // 索取对端剪贴板（卡片点击；对端回复 kdeconnect.clipboard → 走上面的写入分支）
  requestPeerClipboard(): boolean {
    const body: ClipboardBody = { content: '', timestamp: 0 };
    const ok: boolean = this.send('kdeconnect.clipboard.connect', body);
    this.log(ok ? 'clipboard request sent to peer' : 'clipboard request failed');
    return ok;
  }
}
