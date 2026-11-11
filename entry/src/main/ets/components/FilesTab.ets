// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlassCard } from './GlassCard';
import { PayloadRow } from './PayloadRow';
import { PayloadTransfer, PayloadBatch } from '../model/PayloadModels';
import { PayloadController } from '../state/PayloadController';

// 文件 Tab：payload 收发（发送入口 + 进度/处置）。
// 行渲染走子组件 PayloadRow（@Prop 驱动刷新），避免 @Builder 值参数/稳定 key 导致的"进度不刷新"。
@Component
export struct FilesTab {
  @Prop connectedCount: number = 0;
  @Prop immersive: boolean = false;
  // 【MSG217 §2.3】直读 @Observed 控制器（@ObjectLink）：payloads/batches/history 的状态变更
  // 必然驱动本组件刷新（此前用 @Prop 数组快照，实测 finished 后长时间停在 0/1·0%「接收中」）
  @ObjectLink controller: PayloadController;
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
  // 数据源一律走 controller（见上），本组件不再持有快照副本。

  private payloads(): PayloadTransfer[] {
    return this.controller.payloads;
  }

  /** 「历史记录」分区数据源：只读持久化历史（运行时条目由上面三组/批次呈现） */
  private historyItems(): PayloadTransfer[] {
    return this.controller.history;
  }

  private batchItems(b: PayloadBatch): PayloadTransfer[] {
    return this.controller.payloads.filter((p: PayloadTransfer) => b.transferIds.includes(p.transferId));
  }

  private isActive(p: PayloadTransfer): boolean {
    return p.state === 'started' || p.state === 'progress';
  }

  private isPendingSave(p: PayloadTransfer): boolean {
    return p.direction === 'receive' && p.state === 'finished' && !p.settled;
  }

  private inBatch(p: PayloadTransfer): boolean {
    for (const b of this.controller.batches) {
      if (b.transferIds.includes(p.transferId)) {
        return true;
      }
    }
    return false;
  }

  /** 只显示有内容的接收批次（按 batchId 倒序 = 最新在前） */
  private visibleBatches(): PayloadBatch[] {
    const out: PayloadBatch[] = [];
    for (const b of this.controller.batches) {
      if (b.direction !== 'receive' || b.transferIds.length === 0) {
        continue;
      }
      // 成员行都已不在（丢弃/清历史）⇒ 不显示空批头
      if (this.batchItems(b).length === 0) {
        continue;
      }
      // 已完成/未完成但零产出的批不显示（防 "0/1 · 0%" 残留）——用**派生计数**（计数器曾漂移）
      if (b.state !== 'active' && this.controller.batchCounts(b).done === 0) {
        continue;
      }
      out.push(b);
    }
    return out.sort((a: PayloadBatch, b: PayloadBatch) => b.batchId - a.batchId);
  }

  @Builder
  payloadList(prefix: string, items: PayloadTransfer[]) {
    ForEach(items, (p: PayloadTransfer) => {
      PayloadRow({
        // MSG229 §2：整对象 + @ObjectLink 绑定（原地写字段即刷新该行）
        transfer: p,
        canDisposeFn: (item: PayloadTransfer): boolean => this.controller.canDispose(item),
        timeTextFn: (item: PayloadTransfer): string => this.controller.timeTextOf(item),
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
      // MSG223 B：key 带上状态/处置位 —— 状态跃迁时强制重建该行，避免 V1 复用旧对象导致
      // 「批内行仍显示 接收中/0%」而另一处已显示 已完成
    // key 只含 前缀+实例代号：字段原地变化时**不重建**（交给 @ObjectLink），
    // 同 tid 换新实例（uid 变化）时才重建，避免复用旧子组件绑到旧对象
    }, (p: PayloadTransfer) => `${prefix}_${p.transferId}_${p.uid}`)
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
                    Text(this.controller.batchSummary(b))
                      .fontSize(12)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.controller.batchStateText(b).length > 0) {
                      Text(this.controller.batchStateText(b))
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
                    this.controller.toggleBatch(b.batchId);
                  })

                  if (!b.collapsed) {
                    this.payloadList(`batch_${b.batchId}`, this.batchItems(b))
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
        if (this.payloads().some((p: PayloadTransfer) => this.isActive(p) && !this.inBatch(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_active'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('active', this.payloads().filter((p: PayloadTransfer) => this.isActive(p) && !this.inBatch(p)))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 待处置（接收完成，等 保存/丢弃）
        if (this.payloads().some((p: PayloadTransfer) => this.isPendingSave(p) && !this.inBatch(p))) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_received'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('pending', this.payloads().filter((p: PayloadTransfer) => this.isPendingSave(p) && !this.inBatch(p)))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 历史记录（持久化条目；运行时条目由上面「接收批次 / 传输中 / 待处置」呈现）
        if (this.historyItems().filter((p: PayloadTransfer) => !this.inBatch(p)).length > 0) {
          GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
            Column({ space: 6 }) {
              Text($r('app.string.files_history'))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              this.payloadList('done',
                this.historyItems().filter((p: PayloadTransfer) => !this.inBatch(p)))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }

        // 空态说明
        if (this.payloads().length === 0 && this.historyItems().length === 0) {
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
