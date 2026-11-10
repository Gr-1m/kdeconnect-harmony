// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlassCard } from './GlassCard';
import { PayloadRow } from './PayloadRow';
import { PayloadTransfer, PayloadBatch } from '../model/PayloadModels';

// 文件 Tab：payload 收发（发送入口 + 进度/处置）。
// 行渲染走子组件 PayloadRow（@Prop 驱动刷新），避免 @Builder 值参数/稳定 key 导致的"进度不刷新"。
@Component
export struct FilesTab {
  @Prop connectedCount: number = 0;
  @Prop immersive: boolean = false;
  @Prop payloads: PayloadTransfer[] = [];
  cardMaterial: uiMaterial.Material | undefined = undefined;
  onSavePayload: (p: PayloadTransfer) => void = () => {
  };
  onDiscardPayload: (p: PayloadTransfer) => void = () => {
  };
  onCancelPayload: (p: PayloadTransfer) => void = () => {
  };
  onSendFile: () => void = () => {
  };
  // 打开「已接收文件」弹窗（弹层由 Index 渲染，沿用项目现有弹层范式）
  onOpenReceivedFiles: () => void = () => {
  };
  // 点击某一行 → 打开「文件详情」弹窗（属性 + 另存为/丢弃/取消），弹层同样由 Index 渲染
  onOpenPayload: (transferId: number) => void = () => {
  };
  // B2：沙箱内文件的「导出」（用户手势）
  onExportPayload: (p: PayloadTransfer) => void = () => {
  };
  // S2 接收批次（契约 v0.2 §3）：按批折叠显示；批次内的行不再出现在下面按状态分的三组里
  @Prop batches: PayloadBatch[] = [];
  onToggleBatch: (batchId: number) => void = () => {
  };
  batchSummaryOf: (b: PayloadBatch) => string = (_b: PayloadBatch) => '';
  batchStateOf: (b: PayloadBatch) => string = (_b: PayloadBatch) => '';
  batchItemsOf: (b: PayloadBatch) => PayloadTransfer[] = (_b: PayloadBatch) => [];

  private isActive(p: PayloadTransfer): boolean {
    return p.state === 'started' || p.state === 'progress';
  }

  private isPendingSave(p: PayloadTransfer): boolean {
    return p.direction === 'receive' && p.state === 'finished' && !p.settled;
  }

  private inBatch(p: PayloadTransfer): boolean {
    for (const b of this.batches) {
      if (b.transferIds.includes(p.transferId)) {
        return true;
      }
    }
    return false;
  }

  /** 只显示有内容的接收批次（按 batchId 倒序 = 最新在前） */
  private visibleBatches(): PayloadBatch[] {
    const out: PayloadBatch[] = [];
    for (const b of this.batches) {
      if (b.direction === 'receive' && b.transferIds.length > 0) {
        out.push(b);
      }
    }
    return out.sort((a: PayloadBatch, b: PayloadBatch) => b.batchId - a.batchId);
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
        sandboxOnly: p.sandboxOnly === true,
        onExport: (item: PayloadTransfer): void => {
          this.onExportPayload(item);
        },
        onSave: (item: PayloadTransfer): void => {
          this.onSavePayload(item);
        },
        onDiscard: (item: PayloadTransfer): void => {
          this.onDiscardPayload(item);
        },
        onCancel: (item: PayloadTransfer): void => {
          this.onCancelPayload(item);
        },
        onOpen: (tid: number): void => {
          this.onOpenPayload(tid);
        }
      })
    }, (p: PayloadTransfer) => `${prefix}_${p.transferId}`)
  }

  build() {
    Column({ space: 12 }) {
        // 发送文件（M2：选文件 → native.sendPayload；需已连接设备）
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 8 }) {
            Text($r('app.string.files_send_title'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Row({ space: 8 }) {
              Button($r('app.string.files_action_send'))
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .backgroundColor($r('app.color.accent'))
                .borderRadius(10)
                .enabled(this.connectedCount > 0)
                .onClick(() => {
                  this.onSendFile();
                })
              Button($r('app.string.files_received_open'))
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(10)
                .onClick(() => {
                  this.onOpenReceivedFiles();
                })
            }
            .width('100%')
            if (this.connectedCount === 0) {
              Text($r('app.string.files_hint_no_device'))
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // 接收批次（S2）：多文件按批折叠 —— 批头 "3/5 文件 · 45% 总字节"（点批头折叠/展开）
        if (this.visibleBatches().length > 0) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_batches'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              ForEach(this.visibleBatches(), (b: PayloadBatch) => {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    if (b.collapsed) {
                      SymbolGlyph($r('sys.symbol.chevron_right'))
                        .fontSize(14)
                        .fontColor([$r('app.color.text_secondary')])
                    } else {
                      SymbolGlyph($r('sys.symbol.chevron_down'))
                        .fontSize(14)
                        .fontColor([$r('app.color.text_secondary')])
                    }
                    Text(this.batchSummaryOf(b))
                      .fontSize(12)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.batchStateOf(b).length > 0) {
                      Text(this.batchStateOf(b))
                        .fontSize(10)
                        .fontColor($r('app.color.text_muted'))
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(999)
                        .backgroundColor($r('app.color.chip_bg'))
                    }
                  }
                  .width('100%')
                  .height(34)
                  .onClick(() => {
                    this.onToggleBatch(b.batchId);
                  })

                  if (!b.collapsed) {
                    this.payloadList(`batch_${b.batchId}`, this.batchItemsOf(b))
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }, (b: PayloadBatch) => `batch_${b.batchId}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 传输中
        if (this.payloads.some((p: PayloadTransfer) => this.isActive(p) && !this.inBatch(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_active'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('active', this.payloads.filter((p: PayloadTransfer) => this.isActive(p) && !this.inBatch(p)))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 待处置（接收完成，等 保存/丢弃）
        if (this.payloads.some((p: PayloadTransfer) => this.isPendingSave(p) && !this.inBatch(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_received'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('pending', this.payloads.filter((p: PayloadTransfer) => this.isPendingSave(p) && !this.inBatch(p)))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 已处置/其它
        if (this.payloads.some((p: PayloadTransfer) => !this.isActive(p) && !this.isPendingSave(p) && !this.inBatch(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_history'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('done',
                this.payloads.filter((p: PayloadTransfer) =>
                  !this.isActive(p) && !this.isPendingSave(p) && !this.inBatch(p)))
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
}
