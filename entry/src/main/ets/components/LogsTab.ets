// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import uiMaterial from '@ohos.arkui.uiMaterial';
import { LogStore } from '../common/LogStore';

// 构建计数（V1→V2 试点硬指标「重建次数不增」的取证点；每 10 次打一行，避免日志自激）
let LOGS_TAB_BUILDS: number = 0;

@ComponentV2
export struct LogsTab {
  @Require @Param logStore: LogStore;
  @Param immersive: boolean = false;
  cardMaterial: uiMaterial.Material | undefined = undefined;

  onDidBuild(): void {
    LOGS_TAB_BUILDS++;
    if (LOGS_TAB_BUILDS > 0) {
      console.info(`KDC builds logs=${LOGS_TAB_BUILDS}`);
    }
  }

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
            this.logStore.clear();
          })
      }
      .width('100%')
      Text(this.logStore.text.length > 0 ? this.logStore.text : '—')
        .fontSize(11)
        .fontColor($r('app.color.accent_text'))
        .fontFamily('monospace')
        .width('100%')
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
