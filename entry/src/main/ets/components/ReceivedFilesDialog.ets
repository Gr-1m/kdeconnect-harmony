// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 已接收文件弹窗（阶段 3 / 批次 2 步骤 6b-2；CodeArts MSG62、设计见 devdocs/DESIGN_BATCH2_deveco.md）。
//
// 抽离方式：自 Index.build() 的 `if (receivedDialogOpen)` 块原样搬出（L3323–L3406）。
//   · 状态全在 `PayloadController`（@Observed）⇒ 页面 @State 持实例，本组件 @ObjectLink 读；
//   · 用户动作直接调 Controller 方法（clearReceivedHistory / fmtBytes / payloadStateText）；
//   · 组件内不碰持久化/网络（零风险，符合 Dialog 范式）。
//
// 行为保持要点（勿改）：
//   ① 弹层底色/遮罩沿用 dialog_bg / dialog_mask（与其它弹层一致，不用毛玻璃）；
//   ② 卡片自身绑一个空点击把空白区域的点击消费掉，只有点卡外遮罩才关。

import { PayloadController } from '../state/PayloadController';
import { PayloadTransfer } from '../model/PayloadModels';

@Component
export struct ReceivedFilesDialog {
  @ObjectLink payload: PayloadController;

  build() {
    Column() {
      Column({ space: 12 }) {
        Text($r('app.string.files_received_dialog_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        if (this.payload.receivedFiles().length === 0) {
          Text($r('app.string.files_received_empty'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        } else {
          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.payload.receivedFiles(), (p: PayloadTransfer) => {
                Row({ space: 10 }) {
                  Text(p.fileName)
                    .fontSize(12)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(this.payload.fmtBytes(p.size))
                    .fontSize(11)
                    .fontColor($r('app.color.text_muted'))
                  Text(this.payload.payloadStateText(p))
                    .fontSize(11)
                    .fontColor($r('app.color.accent_text'))
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 15, bottom: 15 })
                .borderRadius(12)
                .backgroundColor($r('app.color.chip_bg'))
              }, (p: PayloadTransfer) => `recv_${p.transferId}`)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 320 })
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }
        Row({ space: 10 }) {
          Button($r('app.string.files_history_clear'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.danger_bg'))
            .fontColor($r('app.color.danger_text'))
            .borderRadius(12)
            .enabled(this.payload.receivedFiles().length > 0)
            .onClick(() => {
              this.payload.clearReceivedHistory();
            })
          Button($r('app.string.action_close'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_secondary'))
            .borderRadius(12)
            .onClick(() => {
              this.payload.dialogOpen = false;
            })
        }
        .width('100%')
      }
      .width('86%')
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
      this.payload.dialogOpen = false;
    })
  }
}
