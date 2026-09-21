// SPDX-License-Identifier: GPL-2.0-or-later
import uiMaterial from '@ohos.arkui.uiMaterial';
import { LogStore } from '../common/LogStore';

// 日志 Tab：开发期排查用（对齐 iOS 端无此页；上架前评估移除或隐藏）。
// 批3 #1：日志状态改由 @Observed LogStore 承载，这里以 @ObjectLink 绑定
// ⇒ 日志刷新只重建本组件，不再触发整页重建（清空也直接走 store，页面层只负责可见性节流）。
@Component
export struct LogsTab {
  @ObjectLink logStore: LogStore;
  @Prop immersive: boolean = false;
  cardMaterial: uiMaterial.Material | undefined = undefined;

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text($r('app.string.log_title'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button($r('app.string.logs_clear'))
          .fontSize(12)
          .height(30)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(8)
          .onClick(() => {
            // 清空直接落在 store 上（缓冲与文本都在里面，一次 clear 两样都清，
            // 不需要再经页面层转一道——那层转发是旧实现的遗留）
            this.logStore.clear();
          })
      }
      .width('100%')
      Scroll() {
        Text(this.logStore.text.length > 0 ? this.logStore.text : '—')
          .fontSize(11)
          .fontColor($r('app.color.accent_text'))
          .fontFamily('monospace')
          .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .systemMaterial(this.immersive ? this.cardMaterial : undefined)
    .width('100%')
    .layoutWeight(1)
    .padding(14)
    .borderRadius(18)
    .backgroundBlurStyle(undefined)
    .backgroundColor(this.immersive ? Color.Transparent : $r('app.color.card_bg'))
    .border(this.immersive ? { width: 0 } : { width: 1, color: $r('app.color.card_border') })
    .alignItems(HorizontalAlign.Start)
  }
}
