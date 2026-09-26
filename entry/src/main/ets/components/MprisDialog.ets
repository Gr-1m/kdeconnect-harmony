// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 媒体控制面板弹窗（阶段 3 / 批次 2 步骤 6a-2；CodeArts MSG62、设计见 devdocs/DESIGN_BATCH2_deveco.md）。
//
// 抽离方式：自 Index.build() 的 `if (mprisDialogOpen)` 块原样搬出（L2991–L3303）。
//   · 状态全在 `MprisController`（@Observed）⇒ 页面 @State 持实例，本组件 @ObjectLink 读；
//   · 用户动作直接调 Controller 方法（Controller 自带注入：log/toast/actionGate/pluginsFor）；
//   · `MprisProgress` 作为子组件使用（1s ticker 在组件局部 @State，别退回页面级）；
//   · `SystemSinkRow` 作为子组件使用（不变）。
//
// 行为保持要点（勿改）：
//   ① 弹层不用毛玻璃（手机实测：BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，
//      叠上面板每秒重绘就把主线程拖死 → THREAD_BLOCK_3S/6S、点击无响应）。用更实的底色替代。
//   ② 卡片自身绑一个空点击把空白区域的点击消费掉，否则点卡片内的空白处会被外层遮罩的
//      onClick 抢走 → 弹窗被误关。空白处=只关「卡外」。
//   ③ 音量 Slider 的 onChange 在程序性改 value/max 时也会回调（面板刚打开时 length 从 -1
//      变成真实值 ⇒ 回调被当成 Click/End）→ 误发设置请求。只有先收到 Begin（真拖动才会发）
//      的这一次才算用户操作。
//   ④ 面板读数靠 @State 触发刷新；不要用 @Builder 传值，值参数不变会跳过重建。

import { MprisController } from '../state/MprisController';
import { MprisProgress } from './MprisProgress';
import { SystemSinkRow } from './SystemSinkRow';
import { mprisPlayerText } from '../model/MprisModels';
import { SystemSinkUi } from '../model/SystemVolumeModels';

@Component
export struct MprisDialog {
  @ObjectLink mpris: MprisController;
  @Prop deviceName: string = '';
  @State volDragging: boolean = false;

  build() {
    Column() {
      Column({ space: 12 }) {
        Text($r('app.string.media_dialog_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.deviceName)
          .fontSize(12)
          .fontColor($r('app.color.text_muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 两个 tab（用户 2026-09-18 要求）：0=媒体（播放器控制）1=设备（OutputDevice）
        Row({ space: 8 }) {
          Text($r('app.string.media_tab_player'))
            .fontSize(13)
            .fontWeight(this.mpris.tab === 0 ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.mpris.tab === 0 ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor(this.mpris.tab === 0 ? $r('app.color.accent_soft') : Color.Transparent)
            .onClick(() => {
              this.mpris.tab = 0;
            })
          Text($r('app.string.media_tab_devices'))
            .fontSize(13)
            .fontWeight(this.mpris.tab === 1 ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.mpris.tab === 1 ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor(this.mpris.tab === 1 ? $r('app.color.accent_soft') : Color.Transparent)
            .onClick(() => {
              this.mpris.tab = 1;
            })
        }
        .width('100%')
        if (this.mpris.tab === 0) {

        if (this.mpris.isEmpty()) {
          Text($r('app.string.media_empty'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text($r('app.string.media_empty_hint'))
            .fontSize(11)
            .fontColor($r('app.color.text_muted'))
            .textAlign(TextAlign.Center)
        } else {
          // 多播放器：横向 chips 切换（单个时隐藏）
          if (this.mpris.playerList().length > 1) {
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.mpris.playerList(), (pl: string) => {
                  Text(mprisPlayerText(pl))
                    .fontSize(11)
                    .fontColor(pl === this.mpris.snapshot().player
                      ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(999)
                    .backgroundColor(pl === this.mpris.snapshot().player
                      ? $r('app.color.accent_text') : $r('app.color.chip_bg'))
                    .onClick(() => {
                      this.mpris.selectPlayer(pl);
                    })
                }, (pl: string) => pl)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .align(Alignment.Start)
            .width('100%')
          }

          // 曲目信息（封面本期不做：对端封面要走 payload 传输，属规划 Phase 2）
          Row({ space: 12 }) {
            Column() {
              SymbolGlyph($r('sys.symbol.music_fill'))
                .fontSize(24)
                .fontColor([$r('app.color.accent_text')])
            }
            .width(56)
            .height(56)
            .borderRadius(14)
            .backgroundColor($r('app.color.chip_bg'))
            .justifyContent(FlexAlign.Center)

            Column({ space: 4 }) {
              Text(this.mpris.snapshot().title.length > 0
                ? this.mpris.snapshot().title : $r('app.string.media_unknown_track'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.mpris.artistLine())
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          // 进度：批2 根治 —— 抽成 MprisProgress 组件，插值时钟（1s）落在组件局部 @State，
          // 面板打开期间不再每秒整页重建（原来 ticker 写页面级 mprisNowMs）。
          MprisProgress({
            lengthMs: this.mpris.snapshot().length,
            posMs: this.mpris.snapshot().pos,
            posAtMs: this.mpris.snapshot().posAt,
            isPlaying: this.mpris.snapshot().isPlaying,
            canSeek: this.mpris.snapshot().canSeek,
            onSeek: (ms: number): void => {
              this.mpris.setPosition(ms);
            }
          })

          // 控制键（按 can* 置灰；播放/暂停统一发 PlayPause，由对端决定方向）
          Row({ space: 20 }) {
            Column() {
              SymbolGlyph($r('sys.symbol.backward_end_fill'))
                .fontSize(24)
                .fontColor([this.mpris.snapshot().canGoPrevious
                  ? $r('app.color.text_primary') : $r('app.color.text_muted')])
            }
            .width(46)
            .height(46)
            .borderRadius(23)
            .backgroundColor($r('app.color.chip_bg'))
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.mpris.action('previous');
            })

            Column() {
              SymbolGlyph(this.mpris.snapshot().isPlaying
                ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                .fontSize(28)
                .fontColor([$r('app.color.accent_text')])
            }
            .width(58)
            .height(58)
            .borderRadius(29)
            .backgroundColor($r('app.color.chip_bg'))
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.mpris.action('toggle');
            })

            Column() {
              SymbolGlyph($r('sys.symbol.forward_end_fill'))
                .fontSize(24)
                .fontColor([this.mpris.snapshot().canGoNext
                  ? $r('app.color.text_primary') : $r('app.color.text_muted')])
            }
            .width(46)
            .height(46)
            .borderRadius(23)
            .backgroundColor($r('app.color.chip_bg'))
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.mpris.action('next');
            })
          }

          // 音量（对端未报 volume 时禁用）
          Row({ space: 8 }) {
            SymbolGlyph(this.mpris.vol() > 0
              ? $r('sys.symbol.speaker_wave_3_fill') : $r('sys.symbol.speaker_slash_fill'))
              .fontSize(16)
              .fontColor([$r('app.color.text_secondary')])
            Slider({ value: this.mpris.vol(), min: 0, max: 100, step: 1 })
              .layoutWeight(1)
              .enabled(this.mpris.snapshot().volume >= 0)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.Begin) {
                  this.volDragging = true;
                  return;
                }
                if (mode === SliderChangeMode.Moving) {
                  return;
                }
                if (!this.volDragging) {
                  return;
                }
                this.volDragging = false;
                this.mpris.setVolume(value);
              })
            Text(`${this.mpris.vol()}`)
              .fontSize(10)
              .fontColor($r('app.color.text_muted'))
              .width(24)
          }
          .width('100%')

          // 循环（None → Track → Playlist 三态）/ 随机
          Row({ space: 10 }) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.repeat'))
                .fontSize(15)
                .fontColor([this.mpris.snapshot().loopStatus !== 'None'
                  ? $r('app.color.accent_text') : $r('app.color.text_muted')])
              Text(this.mpris.loopText())
                .fontSize(11)
                .fontColor(this.mpris.snapshot().loopStatus !== 'None'
                  ? $r('app.color.accent_text') : $r('app.color.text_muted'))
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor($r('app.color.chip_bg'))
            .onClick(() => {
              this.mpris.toggleLoop();
            })

            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.shuffle'))
                .fontSize(15)
                .fontColor([this.mpris.snapshot().shuffle
                  ? $r('app.color.accent_text') : $r('app.color.text_muted')])
              Text($r('app.string.media_shuffle'))
                .fontSize(11)
                .fontColor(this.mpris.snapshot().shuffle
                  ? $r('app.color.accent_text') : $r('app.color.text_muted'))
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor($r('app.color.chip_bg'))
            .onClick(() => {
              this.mpris.toggleShuffle();
            })
          }
          .width('100%')
        }

        } else {
          // 「设备」tab：对端音频输出设备（OutputDevice）列表 —— 每个 sink 一行，可分别调音量/静音。
          // 数据是插件推的全量快照（SystemSinkUi，刻度已换算成百分比）：UI 不做换算、不做兜底猜测，
          // 也不持有第二份状态；打开面板时只向对端请求一次列表（协议级刷新）。
          if (this.mpris.svSinksForCurrent().length === 0) {
            Text($r('app.string.media_no_output'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Text($r('app.string.media_no_output_hint'))
              .fontSize(11)
              .fontColor($r('app.color.text_muted'))
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.mpris.svSinksForCurrent(), (s: SystemSinkUi) => {
              SystemSinkRow({
                sink: s,
                onVolumeChange: (name: string, pct: number): void => {
                  this.mpris.svSinkSet(name, pct);
                },
                onToggleMute: (name: string): void => {
                  this.mpris.svSinkToggleMute(name);
                },
                onSelect: (name: string): void => {
                  this.mpris.svSinkSetDefault(name);
                }
              })
            }, (s: SystemSinkUi) => s.name)
          }
        }

        // 共用页脚（两个 tab 都是刷新/关闭）：旧实现把这两个按钮放在「媒体」tab 内部，
        // 切到「设备」tab 后就没有关闭入口了 —— 已按「tab 只切内容、页脚共用」修正。
        Row({ space: 10 }) {
          Button($r('app.string.media_refresh'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_secondary'))
            .borderRadius(12)
            .onClick(() => {
              this.mpris.panelRefresh();
            })
          Button($r('app.string.action_cancel'))
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor($r('app.color.chip_bg'))
            .fontColor($r('app.color.text_secondary'))
            .borderRadius(12)
            .onClick(() => {
              this.mpris.close();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .borderRadius(20)
      // 弹层不用毛玻璃（手机实测：BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，
      // 叠上面板每秒重绘就把主线程拖死 → THREAD_BLOCK_3S/6S、点击无响应）。用更实的底色替代。
      .backgroundColor($r('app.color.dialog_bg'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Center)
      // onClick 为同类型手势竞争（非冒泡）：卡片自身也绑一个空点击把空白区域的点击消费掉，
      // 否则点卡片内的空白处会被外层遮罩的 onClick 抢走 → 弹窗被误关。空白处=只关「卡外」。
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.dialog_mask'))
    .onClick(() => {
      this.mpris.close();
    })
  }
}
