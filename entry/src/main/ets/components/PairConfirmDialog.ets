// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 配对确认弹窗（阶段 3 / 批次 1 步骤 5a；CodeArts MSG62）。
//
// 抽离方式：**纯 UI**（自 Index.build() 的 `if (pairSession.stage === 'prompt' || 'awaiting')` 块原样搬出）。
//   · 状态**全在 `PairSession`**（stage / peerRequested / peerName / deviceId / code）⇒ 页面把它们当 props 传入；
//   · 用户动作经回调回抛：`onConfirm()` → `pairSession.confirm()`、`onCancel()` → `pairSession.cancel()`；
//   · 组件内不碰插件/网络/持久化（零风险，符合 MSG62 §5 的 Dialog 范式）。
//
// 行为保持要点（勿改）：
//   ① 设备 ID 要在弹窗里显示供核对（列表里只显示 IP:端口，用户 2026-09-14）⇒ 页面用
//      resText(settings_device_id) 算好 `deviceIdLabel` 传入；
//   ② 验证码缺失时显示占位 `-- -- -- --` 并附 `pair_code_unavailable` 说明；
//   ③ `awaiting`（等对端确认）时**不显示**确认按钮，只显示等待文案；
//   ④ 弹层底色/遮罩沿用 `dialog_bg` / `dialog_mask`（与其它弹层一致，不用毛玻璃）。

@Component
export struct PairConfirmDialog {
  /** true = 对端发起（标题/按钮文案不同） */
  @Prop peerRequested: boolean = false;
  /** 对端显示名 */
  @Prop peerName: string = '';
  /** 对端 deviceId（核对用，空则不显示该行） */
  @Prop deviceId: string = '';
  /** 已本地化的「设备 ID」标签（页面用 resText 算好，避免组件依赖 Context） */
  @Prop deviceIdLabel: string = '';
  /** 验证码（空则显示占位） */
  @Prop code: string = '';
  /** true = stage==='awaiting'（本侧已请求，等对端用户确认） */
  @Prop awaiting: boolean = false;
  /** true = stage==='prompt'（对端已请求，等本侧用户确认）⇒ 显示确认按钮 */
  @Prop canConfirm: boolean = false;
  onConfirm: () => void = () => {
  };
  onCancel: () => void = () => {
  };

  build() {
    Column() {
      Column({ space: 14 }) {
        Text(this.peerRequested
          ? $r('app.string.pair_dialog_title')
          : $r('app.string.pair_dialog_title_outgoing'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.peerName)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // ① 设备 ID 在弹窗里核对（列表里只显示 IP:端口）
        if (this.deviceId.length > 0) {
          Text(`${this.deviceIdLabel}: ${this.deviceId}`)
            .fontSize(11)
            .fontColor($r('app.color.text_muted'))
            .fontFamily('monospace')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Column({ space: 4 }) {
          Text($r('app.string.pair_dialog_code_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_muted'))
          // ② 验证码（缺失时占位 + 说明）
          Text(this.code.length > 0 ? this.code : '-- -- -- --')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent_text'))
            .fontFamily('monospace')
          if (this.code.length === 0) {
            Text($r('app.string.pair_code_unavailable'))
              .fontSize(10)
              .fontColor($r('app.color.text_muted'))
          }
        }
        Text($r('app.string.pair_dialog_hint'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        // ③ 等对端确认：只显示等待文案，不显示确认按钮
        if (this.awaiting) {
          Text($r('app.string.pair_waiting'))
            .fontSize(12)
            .fontColor($r('app.color.accent_text'))
            .textAlign(TextAlign.Center)
          Text($r('app.string.pair_waiting_hint'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        Row({ space: 10 }) {
          Button(this.peerRequested ? $r('app.string.pair_reject') : $r('app.string.action_cancel'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.danger_bg'))
            .fontColor($r('app.color.danger_text'))
            .borderRadius(12)
            .onClick(() => {
              this.onCancel();
            })
          if (this.canConfirm) {
            Button(this.peerRequested ? $r('app.string.pair_accept') : $r('app.string.pair_action'))
              .layoutWeight(1)
              .height(42)
              .fontSize(14)
              .backgroundColor($r('app.color.accent'))
              .borderRadius(12)
              .onClick(() => {
                this.onConfirm();
              })
          }
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .borderRadius(20)
      // ④ 与其它弹层一致：实底色 + 卡片自身消费点击（只有点卡外遮罩才关）
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
    // 裁决（CodeArts MSG63 §2，2026-09-26）：**遮罩不加 onClick** —— 配对是重要操作，
    // 误触取消需重新发起整个流程，代价高 ⇒ 防误触优先于"点卡外关闭"的便利。
    // （旧弹窗行为即如此；本行为模块设计 §行为保持要点 ④ 的例外，已由裁决确认。）
  }
}
