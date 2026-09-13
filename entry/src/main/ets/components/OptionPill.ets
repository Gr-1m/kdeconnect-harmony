// 可选中态选项按钮（设置页主题/语言共用）。
// 为什么用子组件而不是 @Builder：@Builder 的值参数不变时可能跳过重建，
// 导致"点击有效但高亮不跟随"；子组件的 @Prop 变化一定会触发重渲染。
@Component
export struct OptionPill {
  // 文案（i18n 资源；不变，无需装饰器）
  label: ResourceStr = '';
  // 选中态（会变化 → @Prop 保证刷新）
  @Prop active: boolean = false;
  onPick: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(this.active ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .layoutWeight(1)
      .borderRadius(10)
      .backgroundColor(this.active ? $r('app.color.accent_soft') : $r('app.color.input_bg'))
      .onClick(() => {
        this.onPick();
      })
  }
}
