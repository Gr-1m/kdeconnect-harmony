import uiMaterial from '@ohos.arkui.uiMaterial';

@Builder
function glassCardEmpty() {
}

// 玻璃/沉浸光感卡片容器：统一各 Tab 的卡片底样式。
// 设备支持 ImmersiveMaterial 时走 systemMaterial（cardMaterial 由页面层创建注入），否则降级毛玻璃。
// 颜色走 app.color.* 资源（base=亮色 / dark=暗色），随应用深浅色模式自动切换。
// fill=true → 卡片填满父容器高度（设备 Tab 主区，与常驻侧栏等高）；默认按内容高度。
// 注：属性链不能挂在带 `{ }` 内容的自定义组件调用后面（ArkTS 报 Declaration or statement expected），
// 故高度在组件内部按 fill 分支给出。
@Component
export struct GlassCard {
  @BuilderParam content: () => void = glassCardEmpty;
  @Prop immersive: boolean = false;
  @Prop fill: boolean = false;
  cardMaterial: uiMaterial.Material | undefined = undefined;

  build() {
    if (this.fill) {
      Column() {
        this.content()
      }
      .systemMaterial(this.immersive ? this.cardMaterial : undefined)
      .width('100%')
      .height('100%')
      .padding(14)
      .borderRadius(18)
      .backgroundBlurStyle(undefined)
      .backgroundColor(this.immersive ? Color.Transparent : $r('app.color.card_bg'))
      .border(this.immersive ? { width: 0 } : { width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Start)
    } else {
      Column() {
        this.content()
      }
      .systemMaterial(this.immersive ? this.cardMaterial : undefined)
      .width('100%')
      .padding(14)
      .borderRadius(18)
      .backgroundBlurStyle(undefined)
      .backgroundColor(this.immersive ? Color.Transparent : $r('app.color.card_bg'))
      .border(this.immersive ? { width: 0 } : { width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Start)
    }
  }
}
