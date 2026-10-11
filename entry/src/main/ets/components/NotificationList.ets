// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 【A2 / C4 草稿 —— 项目外草稿】目标路径：entry/src/main/ets/components/NotificationList.ets
//
// 设备详情页内的「通知」区块（设计 §6 建议形态：**不动 4 页签**、不占 6 按钮栅格）。
// 做成**独立可复用组件** ⇒ 若评审改选其它形态（页签/弹窗），本组件原样复用、逻辑层零改动。
//
// 约定：纯 UI（无业务状态、不发包）—— 列表来自页面持有的 `NotificationStore`，
// 关闭/清空经回调回抛（与 RunCommandDialog / MprisDialog 同构）。
import { NotificationItem } from '../model/NotificationModels';

// 时钟格式化（HH:mm）。放在**模块级函数**而非 struct 内（ArkUI struct 内静态成员支持不稳）。
// 注：若后续需要"相对时间"（3 分钟前），建议抽到 model/NotificationModels.ets 作纯函数
// 并进宿主逻辑测试通道（tools/arkts-logic-test.ps1）。
function formatClock(ms: number): string {
  const d: Date = new Date(ms);
  const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  return `${hh}:${mm}`;
}

@Component
export struct NotificationList {
  /** 该设备的通知（最新在前；页面用 store.listOf(deviceId) 传入） */
  @Prop items: NotificationItem[] = [];
  /** 本地关闭一条（本期唯一关闭语义：纯本地，不发包 —— 设计 §4） */
  onDismiss: (id: string) => void = () => {
  };
  /** 清空该设备全部 */
  onClearAll: () => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(`${this.items.length}`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
        Text($r('app.string.notification_count_suffix'))
          .fontSize(13)
          .fontColor($r('app.color.text_muted'))
          .margin({ left: 4 })
        Blank()
        if (this.items.length > 0) {
          Text($r('app.string.notification_clear_all'))
            .fontSize(12)
            .fontColor($r('app.color.accent_text'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor($r('app.color.chip_bg'))
            .onClick(() => {
              this.onClearAll();
            })
        }
      }
      .width('100%')

      if (this.items.length === 0) {
        Text($r('app.string.notification_empty'))
          .fontSize(12)
          .fontColor($r('app.color.text_muted'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ top: 6, bottom: 6 })
      } else {
        ForEach(this.items, (n: NotificationItem) => {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(n.appName.length > 0 ? n.appName : $r('app.string.notification_unknown_app'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(n.ticker)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(formatClock(n.timeMs))
              .fontSize(10)
              .fontColor($r('app.color.text_muted'))

            // 本地关闭（isClearable=false 时不给关闭入口，尊重对端语义）
            if (n.isClearable) {
              Text($r('app.string.notification_dismiss'))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(8)
                .backgroundColor($r('app.color.chip_bg'))
                .onClick(() => {
                  this.onDismiss(n.id);
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(12)
          .backgroundColor($r('app.color.chip_bg'))
        }, (n: NotificationItem) => `${n.deviceId}:${n.id}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
