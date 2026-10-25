// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later

@Component
export struct SettingsDrawerContent {
  @Prop settingsSection: number = 0;
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;
  onPickSection: (index: number) => void = (_i: number) => {};
  onClose: () => void = () => {};

  @Builder
  settingsSectionRow(index: number, label: ResourceStr, icon: Resource) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.settingsSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary')])
      Text(label)
        .fontSize(14)
        .fontColor(this.settingsSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .fontWeight(this.settingsSection === index ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_muted')])
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 15, bottom: 15 })
    .borderRadius(12)
    .backgroundColor(this.settingsSection === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.onPickSection(index);
    })
  }

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

      Scroll() {
        Column({ space: 6 }) {
          this.settingsSectionRow(1, $r('app.string.settings_drawer_info'), $r('sys.symbol.info_circle'))
          this.settingsSectionRow(2, $r('app.string.settings_drawer_about'), $r('sys.symbol.questionmark_circle'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
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
