// 「文件详情」弹窗（**S6 第 1 步**：从 `Index.ets` 抽出的独立组件，2026-09-19）。
//
// 抽离原则（三方重构须知 §3）：**行为保持** —— 只搬结构、不改语义，便于三方对比合并。
// 依赖方向：Index 负责把展示文案算好（复用既有 `fmtBytes` / `timeTextOf` / `payloadStateText`），
// 本组件只做**渲染 + 回调**；不碰插件、不持有页面状态（`@Prop` + 回调，范式同 `MprisProgress`）。
@Component
export struct PayloadDetailDialog {
  @Prop fileName: string = '';
  @Prop sizeText: string = '';
  @Prop timeText: string = '';
  @Prop stateText: string = '';
  @Prop dirText: string = '';
  onSaveAs: () => void = () => {
  };
  onDiscard: () => void = () => {
  };
  onClose: () => void = () => {
  };

  // 属性行（原 Index.infoLine 的等价渲染；组件内自持，避免反向依赖页面）
  @Builder
  attrRow(label: ResourceStr, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_muted'))
        .width(72)
      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      Column({ space: 12 }) {
        Text(this.fileName.length > 0 ? this.fileName : '—')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.attrRow($r('app.string.file_attr_size'), this.sizeText)
        this.attrRow($r('app.string.file_attr_time'), this.timeText)
        this.attrRow($r('app.string.file_attr_state'), this.stateText)
        this.attrRow($r('app.string.file_attr_dir'), this.dirText)
        Row({ space: 10 }) {
          Button($r('app.string.file_action_save_as'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.accent'))
            .borderRadius(12)
            .onClick(() => {
              this.onSaveAs();
            })
          Button($r('app.string.files_action_discard'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.danger_bg'))
            .fontColor($r('app.color.danger_text'))
            .borderRadius(12)
            .onClick(() => {
              this.onDiscard();
            })
          Button($r('app.string.action_cancel'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_secondary'))
            .borderRadius(12)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .borderRadius(20)
      .backgroundColor($r('app.color.dialog_bg'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.dialog_mask'))
    .onClick(() => {
      this.onClose();
    })
  }
}
