import { PayloadTransfer } from '../model/PayloadModels';

// 单条 payload 传输行（文件页）。
// 用子组件 + @Prop：进度/状态变化时必定重渲染（@Builder 值参数不变时会跳过重建，
// ForEach 稳定 key 场景下会表现为「进度条不动」）。
// 注意：成员名不要与通用属性同名（direction/size 会与 CustomComponent 基类冲突），故用 payloadXxx 前缀。
@Component
export struct PayloadRow {
  @Prop transferId: number = 0;
  @Prop fileName: string = '';
  @Prop payloadDirection: string = 'receive';
  @Prop payloadState: string = 'started';
  @Prop payloadSize: number = 0;
  @Prop bytesDone: number = 0;
  @Prop settled: boolean = false;
  onSave: (p: PayloadTransfer) => void = () => {
  };
  onDiscard: (p: PayloadTransfer) => void = () => {
  };
  onCancel: (p: PayloadTransfer) => void = () => {
  };
  // 点击行 → 打开「文件详情」弹窗（属性 + 另存为/丢弃/取消），由 Index 渲染
  onOpen: (transferId: number) => void = () => {
  };

  private isActive(): boolean {
    return this.payloadState === 'started' || this.payloadState === 'progress';
  }

  private isPendingSave(): boolean {
    return this.payloadDirection === 'receive' && this.payloadState === 'finished' && !this.settled;
  }

  private percent(): number {
    if (this.payloadSize <= 0) {
      return 0;
    }
    const pct: number = Math.floor(this.bytesDone * 100 / this.payloadSize);
    return pct > 100 ? 100 : pct;
  }

  private snapshot(): PayloadTransfer {
    const item: PayloadTransfer = {
      transferId: this.transferId,
      deviceId: '',
      direction: this.payloadDirection === 'send' ? 'send' : 'receive',
      state: this.payloadState === 'progress' ? 'progress' : (this.payloadState === 'started' ? 'started'
        : (this.payloadState === 'finished' ? 'finished' : (this.payloadState === 'cancelled' ? 'cancelled' : 'failed'))),
      fileName: this.fileName,
      size: this.payloadSize,
      bytesDone: this.bytesDone,
      filePath: '',
      settled: this.settled
    };
    return item;
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.fileName.length > 0 ? this.fileName : `#${this.transferId}`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.isActive()) {
          Text(this.payloadDirection === 'receive' ? $r('app.string.files_receiving') : $r('app.string.files_sending'))
            .fontSize(10)
            .fontColor($r('app.color.accent_text'))
        } else if (this.payloadState === 'finished') {
          Text(this.settled ? $r('app.string.files_saved') : $r('app.string.files_finished'))
            .fontSize(10)
            .fontColor(this.settled ? $r('app.color.dot_connected') : $r('app.color.accent_text'))
        } else if (this.payloadState === 'cancelled') {
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

      if (this.isActive()) {
        Progress({ value: this.percent(), total: 100, type: ProgressType.Linear })
          .width('100%')
          .color($r('app.color.accent'))
          .backgroundColor($r('app.color.input_bg'))
        Text(`${this.percent()}% · ${this.bytesDone} / ${this.payloadSize > 0 ? this.payloadSize : '?'}`)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .width('100%')
      }

      if (this.isActive() || this.isPendingSave()) {
        Row({ space: 8 }) {
          if (this.isPendingSave()) {
            Button($r('app.string.files_action_save'))
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.accent'))
              .borderRadius(8)
              .onClick(() => {
                this.onSave(this.snapshot());
              })
            Button($r('app.string.files_action_discard'))
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.danger_bg'))
              .fontColor($r('app.color.danger_text'))
              .borderRadius(8)
              .onClick(() => {
                this.onDiscard(this.snapshot());
              })
          }
          if (this.isActive()) {
            Button($r('app.string.files_action_cancel'))
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.input_bg'))
              .fontColor($r('app.color.text_secondary'))
              .borderRadius(8)
              .onClick(() => {
                this.onCancel(this.snapshot());
              })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    // 行高加高（用户 2026-09-17 要求"行的高度加"）：上下内边距 8→14vp，行距更舒展
    .padding({ top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
    // 点击整行 → 打开「文件详情」弹窗（属性 + 另存为/丢弃/取消）
    .onClick(() => {
      this.onOpen(this.transferId);
    })
  }
}

