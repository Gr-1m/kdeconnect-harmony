// SPDX-License-Identifier: GPL-2.0-or-later
import { mprisTimeText } from '../model/MprisModels';

// 批2 根治（CodeArts MSG18 放行 / ARKTS_PERF_ROADMAP §3）：
// 媒体面板的「进度条 + 时间文本」抽成独立组件，**插值时钟（1s ticker）落在组件局部 @State**。
// 原实现 ticker 写页面级 `mprisNowMs` ⇒ 面板打开期间**每秒整页重建**；现在每秒只重建本组件。
//
// 口径与 Index 保持一致（改一处必须改两处）：
//   pos = 收包 posMs + (now - posAtMs)（播放中才累加），并夹在 [0, lengthMs]；
//   Slider 量程用**千分比**（百万毫秒量程 + step 会导致布局/刻度计算巨大）。
@Component
export struct MprisProgress {
  @Prop lengthMs: number = 0;
  @Prop posMs: number = 0;
  @Prop posAtMs: number = 0;
  @Prop isPlaying: boolean = false;
  @Prop canSeek: boolean = true;
  onSeek: (ms: number) => void = () => {
  };

  @State nowMs: number = 0;
  private timerId: number = -1;
  private dragging: boolean = false;

  aboutToAppear(): void {
    this.nowMs = Date.now();
    this.timerId = setInterval((): void => {
      // 暂停时进度不前进 ⇒ 完全不写 @State（连本组件都不重建）
      if (!this.isPlaying) {
        return;
      }
      this.nowMs = Date.now();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private displayPos(): number {
    let p: number = this.posMs;
    if (this.isPlaying) {
      const dt: number = this.nowMs > this.posAtMs ? this.nowMs - this.posAtMs : 0;
      p = this.posMs + dt;
    }
    if (this.lengthMs > 0 && p > this.lengthMs) {
      return this.lengthMs;
    }
    return p < 0 ? 0 : p;
  }

  private permille(): number {
    if (this.lengthMs <= 0) {
      return 0;
    }
    return Math.round(this.displayPos() * 1000 / this.lengthMs);
  }

  private permilleToMs(permille: number): number {
    if (this.lengthMs <= 0) {
      return 0;
    }
    return Math.round(permille * this.lengthMs / 1000);
  }

  build() {
    Row({ space: 8 }) {
      Slider({ value: this.permille(), min: 0, max: 1000, step: 1 })
        .layoutWeight(1)
        .enabled(this.canSeek && this.lengthMs > 0)
        .onChange((value: number, mode: SliderChangeMode) => {
          // 只认 Begin（用户按下）→ 标记拖动；松手（End/Click）才发 SetPosition。
          // 程序化改 value/max 也触发 onChange，若不 gate 会误发 SetPosition(1) 把对端拉回开头。
          if (mode === SliderChangeMode.Begin) {
            this.dragging = true;
            return;
          }
          if (mode === SliderChangeMode.Moving) {
            return;
          }
          if (!this.dragging) {
            return;
          }
          this.dragging = false;
          this.onSeek(this.permilleToMs(value));
        })
      Text(`${mprisTimeText(this.displayPos())} / ${mprisTimeText(this.lengthMs)}`)
        .fontSize(10)
        .fontColor($r('app.color.text_muted'))
    }
    .width('100%')
  }
}
