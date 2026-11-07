// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 设备详情弹窗（已记住/离线设备查看用）。
//
// 形态沿用本工程既有弹层范式（PairConfirmDialog）：**纯 UI 组件**，状态由页面持有，
// 文案由页面用 resText 算好传入（组件不依赖 Context）。
// 层次：渲染在页面根 Stack（`.zIndex(1000)`），平板下也覆盖全屏（不随 contentPanel 被侧栏裁切）。
//
// 行为：点遮罩或「关闭」→ onClose；卡片本身吞掉点击（不冒泡到遮罩）。

@Component
export struct DeviceInfoDialog {
  /** 设备显示名 */
  @Prop deviceName: string = '';
  /** 设备 ID（= 证书 CN） */
  @Prop deviceId: string = '';
  /** 已本地化的「设备 ID」标签 */
  @Prop deviceIdLabel: string = '';
  /** 已配对（决定状态 chip 文案与配色） */
  @Prop paired: boolean = false;
  @Prop pairedLabel: string = '';
  @Prop unpairedLabel: string = '';
  @Prop offlineLabel: string = '';
  @Prop closeLabel: string = '';
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Column({ space: 14 }) {
        Text(this.deviceName)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Column({ space: 6 }) {
          Text(this.deviceIdLabel)
            .fontSize(11)
            .fontColor($r('app.color.text_muted'))
            .width('100%')
          Text(this.deviceId)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .maxLines(2)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Row({ space: 8 }) {
          Text(this.paired ? this.pairedLabel : this.unpairedLabel)
            .fontSize(10)
            .fontColor(this.paired ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(999)
            .backgroundColor($r('app.color.chip_bg'))
          Text(this.offlineLabel)
            .fontSize(10)
            .fontColor($r('app.color.text_muted'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(999)
            .backgroundColor($r('app.color.chip_bg'))
          Blank()
        }
        .width('100%')

        Button(this.closeLabel)
          .fontSize(14)
          .width('100%')
          .height(42)
          .backgroundColor($r('app.color.accent'))
          .fontColor(Color.White)
          .borderRadius(12)
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('86%')
      .constraintSize({ maxWidth: 420 })
      .padding(20)
      .borderRadius(20)
      .backgroundColor($r('app.color.dialog_bg'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Start)
      // 吞掉卡片内点击，避免冒泡到遮罩关闭
      .onClick((): void => {
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.dialog_mask'))
    .onClick((): void => {
      this.onClose();
    })
  }
}
