// SPDX-License-Identifier: GPL-2.0-or-later
// 日志存储（批3 #1，CodeArts MSG18 放行 / ARKTS_PERF_ROADMAP §4）。
//
// 背景（实测债）：日志文本原来是**页面级 @State logText** ⇒ 每次合并刷新写一次 @State 就触发
// **整页重建**。开屏/日常操作期大量日志都发生在别的页签上，这些重建纯属浪费（用户看不到日志）。
//
// 现在：缓冲与文本都收进 @Observed 的 LogStore，日志页以 @ObjectLink 绑定 ⇒ 写 text 只让
// LogsTab 这**一个**组件重建，页面其余部分（卡片/列表/面板）完全不受影响。
// 于是「日志页不可见时干脆不写状态」这类规避性补丁不再是正确性的必要条件，只作为省 CPU 的优化保留
// （见 Index.flushLog 的可见性门控）。
const MAX_KEEP: number = 200;   // 环形缓冲保留行数（便于回看；UI 只展示尾部 SHOW_LINES 行）
const SHOW_LINES: number = 50;  // UI 展示行数

@Observed
export class LogStore {
  // ⚠️ UI 唯一绑定的字段：所有写入都必须经过 append()/flush()/clear()，不要在外部直接改它。
  text: string = '';
  private buf: string[] = [];

  // 追加一行（自动打时间戳；超出上限丢最旧的）
  append(line: string): void {
    const t: string = new Date().toTimeString().substring(0, 8);
    this.buf.push(`[${t}] ${line}`);
    if (this.buf.length > MAX_KEEP) {
      this.buf.splice(0, this.buf.length - MAX_KEEP);
    }
  }

  // 把缓冲尾部合并进 text（**唯一写 text 的地方**）
  flush(): void {
    if (this.buf.length === 0) {
      return;
    }
    this.text = this.buf.slice(-SHOW_LINES).join('\n');
  }

  isEmpty(): boolean {
    return this.buf.length === 0;
  }

  clear(): void {
    this.buf = [];
    this.text = '';
  }
}
