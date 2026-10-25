// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { GlassCard } from './GlassCard';

@Component
export struct FilesDrawerContent {
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('KDE Connect')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })
      }
      .width('100%')
      .margin({ bottom: 4 })

      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text($r('app.string.file_notify_toggle'))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: true })
            .enabled(false)
            .onChange(() => {})
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .borderRadius(14)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1, color: $r('app.color.card_border') })

        Row({ space: 12 }) {
          Text($r('app.string.file_autosave_toggle'))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: false })
            .enabled(false)
            .onChange(() => {})
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .borderRadius(14)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1, color: $r('app.color.card_border') })

        Text($r('app.string.coming_soon'))
          .fontSize(12)
          .fontColor($r('app.color.text_muted'))
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.getUIContext().px2vp(this.statusBarHeightPx) + 16,
      bottom: 16
    })
    .alignItems(HorizontalAlign.Start)
  }
}
