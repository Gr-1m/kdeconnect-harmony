// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { PayloadTransfer } from '../model/PayloadModels';

// 单条 payload 传输行（文件页）。
// MSG229 §2 修：行用 **@ObjectLink 绑定 @Observed 的 PayloadTransfer**，控制器原地写字段即可让本行重渲染。
// （此前用标量 @Prop + 稳定 ForEach key：ForEach 不重新执行子组件构建 ⇒ 进度/状态冻结在首帧，
//  表现为「进度一直 0%」「完成后仍显示接收中」。见 devdocs/ARKTS_GUIDE.md §4.9。）
// 注意：成员名不要与通用属性同名（direction/size 会与 CustomComponent 基类冲突），故对象字段用 transfer.xxx 访问。
@Component
export struct PayloadRow {
  @ObjectLink transfer: PayloadTransfer;
  // 完成时间文案（HH:MM 等）——用于区分同名多次接收
  timeTextFn: (p: PayloadTransfer) => string = () => '';
  onCancel: (p: PayloadTransfer) => void = () => {
  };
  // 点击行 → 打开「文件详情」弹窗（属性 + 另存为/丢弃/取消），由 Index 渲染
  onOpen: (transferId: number) => void = () => {
  };
  // B2：用户手势导出（沙箱 → 用户选的位置）
  onExport: (p: PayloadTransfer) => void = () => {
  };

  private isActive(): boolean {
    return this.transfer.state === 'started' || this.transfer.state === 'progress';
  }


  private percent(): number {
    if (this.transfer.size <= 0) {
      return 0;
    }
    const pct: number = Math.floor(this.transfer.bytesDone * 100 / this.transfer.size);
    return pct > 100 ? 100 : pct;
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.transfer.fileName.length > 0 ? this.transfer.fileName : `#${this.transfer.transferId}`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.isActive()) {
          Text(this.transfer.direction === 'receive' ? $r('app.string.files_receiving') : $r('app.string.files_sending'))
            .fontSize(10)
            .fontColor($r('app.color.accent_text'))
        } else if (this.transfer.state === 'finished') {
          // MSG229 §3.3：无可处置文件 ⇒ 文案「已结束」，与按钮显隐同一判据（canDispose）
          if (this.transfer.settled) {
            Text(this.transfer.sandboxOnly ? $r('app.string.files_saved_in_app') : $r('app.string.files_saved'))
              .fontSize(10)
              .fontColor($r('app.color.dot_connected'))
          } else {
            // 与详情弹窗/payloadStateText 同一判据：仅「启动迁移确认文件不在」才显示「已结束」
            Text(this.transfer.expired ? $r('app.string.files_ended') : $r('app.string.files_finished'))
              .fontSize(10)
              .fontColor($r('app.color.accent_text'))
          }
        } else if (this.transfer.state === 'cancelled') {
          Text($r('app.string.files_cancelled'))
            .fontSize(10)
            .fontColor($r('app.color.text_muted'))
        } else {
          Text($r('app.string.files_failed'))
            .fontSize(10)
            .fontColor($r('app.color.danger_text'))
        }
      }
      .width('100%')
      // 点「文件名 + 状态」这一行 → 打开文件详情弹窗（处置动作都在弹窗里）
      .onClick(() => {
        this.onOpen(this.transfer.transferId);
      })

      if (this.transfer.settled && this.timeTextFn(this.transfer).length > 0 && this.timeTextFn(this.transfer) !== '—') {
        Text(this.timeTextFn(this.transfer))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .width('100%')
      }

      if (this.isActive()) {
        Progress({ value: this.percent(), total: 100, type: ProgressType.Linear })
          .width('100%')
          .color($r('app.color.accent'))
          .backgroundColor($r('app.color.input_bg'))
        Text(`${this.percent()}% · ${this.transfer.bytesDone} / ${this.transfer.size > 0 ? this.transfer.size : '?'}`)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .width('100%')
      }

      if (this.transfer.settled && this.transfer.sandboxOnly && this.transfer.direction === 'receive') {
        Row({ space: 8 }) {
          Button($r('app.string.files_action_export'))
            .fontSize(12)
            .height(32)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.accent_text'))
            .borderRadius(8)
            .onClick(() => {
              this.onExport(this.transfer);
            })
        }
        .width('100%')
      }

      // MSG245 §2.1：行内**不再**放「保存/丢弃」（处置统一走详情弹窗）；
      // 仅保留进行中条目的「取消」。按钮容器**不再**用 HitTestMode.Block
      // —— Block 会把子按钮也挡掉（真机「点击无反应」的根因），改为把整行 onClick 收到头部行上。
      if (this.isActive()) {
        Row({ space: 8 }) {
          Button($r('app.string.files_action_cancel'))
            .fontSize(12)
            .height(32)
            .backgroundColor($r('app.color.input_bg'))
            .fontColor($r('app.color.text_secondary'))
            .borderRadius(8)
            .onClick(() => {
              this.onCancel(this.transfer);
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    // 行高加高（用户 2026-09-17 要求"行的高度加"）：上下内边距 8→14vp，行距更舒展
    .padding({ top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }
}
