import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlassCard } from './GlassCard';
import { PayloadTransfer } from '../model/PayloadModels';

// 文件 Tab：payload 收发（AP-2）。
// 接收侧由 native 自动落盘 spool，finished 后由用户在「保存 / 丢弃」中处置（keepPayload/discardPayload）。
// 发送侧入口（选文件）待 M2 的 share 插件接入；本页先覆盖 M1 锚点「桌面发文件 → 鸿蒙落盘」。
@Component
export struct FilesTab {
  @Prop connectedCount: number = 0;
  @Prop immersive: boolean = false;
  @Link payloads: PayloadTransfer[];
  cardMaterial: uiMaterial.Material | undefined = undefined;
  onSavePayload: (p: PayloadTransfer) => void = () => {
  };
  onDiscardPayload: (p: PayloadTransfer) => void = () => {
  };
  onCancelPayload: (p: PayloadTransfer) => void = () => {
  };

  private isActive(p: PayloadTransfer): boolean {
    return p.state === 'started' || p.state === 'progress';
  }

  private isPendingSave(p: PayloadTransfer): boolean {
    return p.direction === 'receive' && p.state === 'finished' && !p.settled;
  }

  private percentOf(p: PayloadTransfer): number {
    if (p.size <= 0) {
      return 0;
    }
    const pct: number = Math.floor(p.bytesDone * 100 / p.size);
    return pct > 100 ? 100 : pct;
  }

  @Builder
  transferRow(p: PayloadTransfer) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(p.fileName.length > 0 ? p.fileName : `#${p.transferId}`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.isActive(p)) {
          Text(p.direction === 'receive' ? $r('app.string.files_receiving') : $r('app.string.files_sending'))
            .fontSize(10)
            .fontColor($r('app.color.accent_text'))
        } else if (p.state === 'finished') {
          Text(p.settled ? $r('app.string.files_saved') : $r('app.string.files_finished'))
            .fontSize(10)
            .fontColor(p.settled ? $r('app.color.dot_connected') : $r('app.color.accent_text'))
        } else if (p.state === 'cancelled') {
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

      if (this.isActive(p)) {
        Progress({ value: this.percentOf(p), total: 100, type: ProgressType.Linear })
          .width('100%')
          .color($r('app.color.accent'))
          .backgroundColor($r('app.color.input_bg'))
        Text(`${this.percentOf(p)}%  ·  ${p.bytesDone} / ${p.size > 0 ? p.size : '?'}`)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .width('100%')
      }

      if (this.isActive(p) || this.isPendingSave(p)) {
        Row({ space: 8 }) {
          if (this.isPendingSave(p)) {
            Button($r('app.string.files_action_save'))
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.accent'))
              .borderRadius(8)
              .onClick(() => {
                this.onSavePayload(p);
              })
            Button($r('app.string.files_action_discard'))
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.danger_bg'))
              .fontColor($r('app.color.danger_text'))
              .borderRadius(8)
              .onClick(() => {
                this.onDiscardPayload(p);
              })
          }
          if (this.isActive(p)) {
            Button($r('app.string.files_action_cancel'))
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.input_bg'))
              .fontColor($r('app.color.text_secondary'))
              .borderRadius(8)
              .onClick(() => {
                this.onCancelPayload(p);
              })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 传输中
        if (this.payloads.some((p: PayloadTransfer) => this.isActive(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_active'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              ForEach(this.payloads.filter((p: PayloadTransfer) => this.isActive(p)), (p: PayloadTransfer) => {
                this.transferRow(p)
              }, (p: PayloadTransfer) => `active_${p.transferId}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 待处置（接收完成，等 保存/丢弃）
        if (this.payloads.some((p: PayloadTransfer) => this.isPendingSave(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_received'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              ForEach(this.payloads.filter((p: PayloadTransfer) => this.isPendingSave(p)), (p: PayloadTransfer) => {
                this.transferRow(p)
              }, (p: PayloadTransfer) => `pending_${p.transferId}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 已处置/其它
        if (this.payloads.some((p: PayloadTransfer) => !this.isActive(p) && !this.isPendingSave(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_history'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              ForEach(this.payloads.filter((p: PayloadTransfer) => !this.isActive(p) && !this.isPendingSave(p)),
                (p: PayloadTransfer) => {
                  this.transferRow(p)
                }, (p: PayloadTransfer) => `done_${p.transferId}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 空态说明（无任何传输时）
        if (this.payloads.length === 0) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 8 }) {
              Text($r('app.string.tab_files'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(this.connectedCount === 0
                ? $r('app.string.files_hint_no_device') : $r('app.string.files_hint_pending'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text($r('app.string.files_save_path'))
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.TopStart)
  }
}
