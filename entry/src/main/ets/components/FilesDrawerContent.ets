// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { GlassCard } from './GlassCard';

@Component
export struct FilesDrawerContent {
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;
  // S2 §3.5：接收文件自动保存开关（由页面写入 AppStorage，面板被 HdsSideBar 缓存也不会失联）
  @StorageLink('autoSaveFiles') autoSaveFiles: boolean = true;

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('KDE Connect')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 48 })
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
          Toggle({ type: ToggleType.Switch, isOn: this.autoSaveFiles })
            .enabled(true)
            .onChange((isOn: boolean) => {
              // 写 AppStorage → 页面 @Watch 负责持久化与门控
              this.autoSaveFiles = isOn;
            })
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
