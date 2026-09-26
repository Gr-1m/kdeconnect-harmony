// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 远程命令弹窗（阶段 3 / 批次 1 步骤 5b；CodeArts MSG62）。
//
// 抽离方式：**纯 UI**（自 Index.build() 的 `if (this.runCommandDialogOpen)` 块原样搬出，零行为变更）。
//   · 页面保留 `runCommandDialogOpen` @State 与 `if (...)` 门控（与本项目既有弹窗一致）；
//   · 组件只接收「设备名 + 命令列表」并回调 `onPick(key)` / `onClose()`；
//   · 不发包、不持业务状态（`runCommand()` 仍留页面，因为它要发请求 + 释放卡片忙碌态）。
//
// 保留原注释里的两条坑（勿改）：
//   ① 弹层**不用毛玻璃**（BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，叠上每秒重绘会拖死主线程
//      → 实测 THREAD_BLOCK_3S/6S、点击无响应），用更实的底色 `dialog_bg` 替代；
//   ② 卡片自身消费点击（`.onClick(() => {})`），只有点**卡外遮罩**才关弹窗。

import { RunCommandEntry } from '../plugins/RunCommandPlugin';

@Component
export struct RunCommandDialog {
  /** 对端设备显示名（页面用 displayNameOf 算好传入） */
  @Prop deviceName: string = '';
  /** 对端下发的预设命令列表 */
  @Prop commands: RunCommandEntry[] = [];
  /** 点某条命令 → 页面负责请求对端执行 + 释放卡片忙碌态 + 关弹窗 */
  onPick: (key: string) => void = () => {
  };
  /** 取消 / 点遮罩 → 页面关弹窗 */
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Column({ space: 12 }) {
        Text($r('app.string.run_command_dialog_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.deviceName)
          .fontSize(12)
          .fontColor($r('app.color.text_muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.commands.length === 0) {
          Text($r('app.string.run_command_empty'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text($r('app.string.run_command_empty_hint'))
            .fontSize(11)
            .fontColor($r('app.color.text_muted'))
        } else {
          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.commands, (c: RunCommandEntry) => {
                Column({ space: 2 }) {
                  Text(c.name)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  if (c.command.length > 0) {
                    Text(c.command)
                      .fontSize(10)
                      .fontColor($r('app.color.text_muted'))
                      .fontFamily('monospace')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ left: 12, right: 12, top: 15, bottom: 15 })
                .borderRadius(12)
                .backgroundColor($r('app.color.chip_bg'))
                .onClick(() => {
                  this.onPick(c.key);
                })
              }, (c: RunCommandEntry) => c.key)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 320 })
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }
        Button($r('app.string.action_cancel'))
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(12)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('86%')
      .padding(20)
      .borderRadius(20)
      // ① 弹层不用毛玻璃（见文件头说明）
      .backgroundColor($r('app.color.dialog_bg'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Center)
      // ② 卡片自身消费点击，只有点卡外遮罩才关弹窗
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
