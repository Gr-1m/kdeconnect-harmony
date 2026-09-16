import uiMaterial from '@ohos.arkui.uiMaterial';

// 日志 Tab：开发期排查用（对齐 iOS 端无此页；上架前评估移除或隐藏）。
@Component
export struct LogsTab {
  @Link logText: string;
  @Prop immersive: boolean = false;
  // 清空走页面层（同时清缓冲，否则下一次合并刷新会把旧行贴回来）
  onClearLogs: () => void = () => {
  };
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
            this.onClearLogs();
          })
      }
      .width('100%')
      Scroll() {
        Text(this.logText.length > 0 ? this.logText : '—')
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
