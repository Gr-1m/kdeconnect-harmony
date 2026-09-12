import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlassCard } from './GlassCard';

// 文件 Tab：连接后收发文件（kdeconnect.share，含 payload 通道）。
// 当前为占位页：payload 传输依赖 native 侧 WP-1 与 d.ts v2 契约（AP-2），就绪后填充收发列表。
@Component
export struct FilesTab {
  @Prop connectedCount: number = 0;
  @Prop immersive: boolean = false;
  cardMaterial: uiMaterial.Material | undefined = undefined;

  build() {
    Scroll() {
      Column({ space: 12 }) {
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
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 8 }) {
            Text($r('app.string.files_received'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text($r('app.string.group_empty'))
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
            Text($r('app.string.files_save_path'))
              .fontSize(11)
              .fontColor($r('app.color.text_muted'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
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
