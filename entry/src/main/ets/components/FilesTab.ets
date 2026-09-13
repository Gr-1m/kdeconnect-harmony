import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlassCard } from './GlassCard';
import { PayloadRow } from './PayloadRow';
import { PayloadTransfer } from '../model/PayloadModels';

// 文件 Tab：payload 收发（发送入口 + 进度/处置）。
// 行渲染走子组件 PayloadRow（@Prop 驱动刷新），避免 @Builder 值参数/稳定 key 导致的"进度不刷新"。
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
  onSendFile: () => void = () => {
  };

  private isActive(p: PayloadTransfer): boolean {
    return p.state === 'started' || p.state === 'progress';
  }

  private isPendingSave(p: PayloadTransfer): boolean {
    return p.direction === 'receive' && p.state === 'finished' && !p.settled;
  }

  @Builder
  payloadList(prefix: string, items: PayloadTransfer[]) {
    ForEach(items, (p: PayloadTransfer) => {
      PayloadRow({
        transferId: p.transferId,
        fileName: p.fileName,
        payloadDirection: p.direction,
        payloadState: p.state,
        payloadSize: p.size,
        bytesDone: p.bytesDone,
        settled: p.settled,
        onSave: (item: PayloadTransfer): void => {
          this.onSavePayload(item);
        },
        onDiscard: (item: PayloadTransfer): void => {
          this.onDiscardPayload(item);
        },
        onCancel: (item: PayloadTransfer): void => {
          this.onCancelPayload(item);
        }
      })
    }, (p: PayloadTransfer) => `${prefix}_${p.transferId}`)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 发送文件（M2：选文件 → native.sendPayload；需已连接设备）
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 8 }) {
            Text($r('app.string.files_send_title'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Button($r('app.string.files_action_send'))
              .height(40)
              .fontSize(13)
              .backgroundColor($r('app.color.accent'))
              .borderRadius(10)
              .enabled(this.connectedCount > 0)
              .onClick(() => {
                this.onSendFile();
              })
            if (this.connectedCount === 0) {
              Text($r('app.string.files_hint_no_device'))
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // 传输中
        if (this.payloads.some((p: PayloadTransfer) => this.isActive(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_active'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('active', this.payloads.filter((p: PayloadTransfer) => this.isActive(p)))
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
              this.payloadList('pending', this.payloads.filter((p: PayloadTransfer) => this.isPendingSave(p)))
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
              this.payloadList('done',
                this.payloads.filter((p: PayloadTransfer) => !this.isActive(p) && !this.isPendingSave(p)))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 空态说明
        if (this.payloads.length === 0) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 8 }) {
              Text($r('app.string.tab_files'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
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
