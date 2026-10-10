// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 远程输入全屏对话框（阶段4 方向B / B2+B3；设计见 devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md）。
// 入口形态按 AtomCode MSG134 §三.1 裁决：**底部第 6 个功能卡片 + 全屏对话框**
// （否"第 5 页签"：挤底栏且 syncSelectedDevice 漂移会使页签内设备归属易混淆）。
//
// 抽离方式：**纯 UI**（无业务状态、不发包）。本组件只做两件事：
//   ① 把手势/输入翻译成**语义化回调**（onPanUpdate / onTap / onScroll / onTypeText / onSpecialKey）；
//   ② 展示只读指示（设备名、对端键盘 ready/idle）。
//   ⇒ 增量换算与节流由页面侧的 `MousepadInputPipeline` 负责（已有 24 个单测锁定），
//     协议字段名由 `RemoteInputPlugin`（MousepadSink）负责 —— 本组件对协议零知识。
//
// 保留项目既有弹窗约定（见 RunCommandDialog 文件头）：
//   · 弹层**不用毛玻璃**（BACKGROUND_THICK 在弹层上会重算整屏背景模糊 → 拖死主线程）；
//   · 卡片自身消费点击，只有点**卡外遮罩**才关弹窗。
import { MousepadButton } from '../plugins/MousepadInput';
import { specialKeyCodes, specialKeyName } from '../plugins/RemoteInputKeymap';

const TAB_TOUCHPAD: number = 0;
const TAB_KEYBOARD: number = 1;

@Component
export struct RemoteInputDialog {
  /** 目标设备显示名（页面用 displayNameOf 算好传入） */
  @Prop deviceName: string = '';
  /** 对端键盘就绪指示（来自 `kdeconnect.mousepad.keyboardstate` 的 state） */
  @Prop keyboardReady: boolean = false;

  onPanBegin: () => void = () => {
  };
  onPanUpdate: (offsetX: number, offsetY: number) => void = () => {
  };
  onPanEnd: () => void = () => {
  };
  onPanCancel: () => void = () => {
  };
  onTap: (button: MousepadButton) => void = () => {
  };
  onScroll: (dx: number, dy: number) => void = () => {
  };
  onTypeText: (text: string) => void = () => {
  };
  onSpecialKey: (code: number) => void = () => {
  };
  onClose: () => void = () => {
  };

  @State tab: number = TAB_TOUCHPAD;
  // 组件内状态（与 MprisProgress 的 ticker 同类）：把「手势累计偏移」差分成增量。
  // 放在组件内而非页面，避免高频手势触发页面级重绘。
  private scrollLastX: number = 0;
  private scrollLastY: number = 0;
  // 键盘"只处理追加输入"（设计 §2 备注 2）：以文本长度差取新增字符，不处理删除/光标移动
  private lastText: string = '';
  // 特殊键下标表（一次求值，避免每次重绘重建 32 元素数组）
  private specialKeys: number[] = specialKeyCodes();

  build() {
    Column() {
      Column({ space: 12 }) {
        // ---- 头部：标题 + 设备名 + 对端键盘指示 + 关闭 ----
        Row() {
          Column({ space: 2 }) {
            Text($r('app.string.remote_input_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.deviceName)
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.keyboardReady
            ? $r('app.string.remote_input_kb_ready')
            : $r('app.string.remote_input_kb_idle'))
            .fontSize(10)
            .fontColor(this.keyboardReady ? $r('app.color.accent_text') : $r('app.color.text_muted'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor($r('app.color.chip_bg'))
        }
        .width('100%')

        // ---- 页签：触控板 / 键盘（自绘分段控件，避免 Tabs 在弹层内的高度计算） ----
        Row({ space: 8 }) {
          this.tabButton($r('app.string.remote_input_touchpad'), TAB_TOUCHPAD)
          this.tabButton($r('app.string.remote_input_keyboard'), TAB_KEYBOARD)
        }
        .width('100%')

        if (this.tab === TAB_TOUCHPAD) {
          this.touchpadArea()
        } else {
          this.keyboardArea()
        }
      }
      .width('94%')
      .height('86%')
      .padding(18)
      .borderRadius(20)
      // ① 弹层不用毛玻璃（见文件头）
      .backgroundColor($r('app.color.dialog_bg'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .alignItems(HorizontalAlign.Center)
      // ② 卡片自身消费点击，只有点卡外遮罩才关弹窗
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.dialog_mask'))
    .onClick(() => {
      this.onClose();
    })
  }

  @Builder
  tabButton(label: ResourceStr, index: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.tab === index ? $r('app.color.text_primary') : $r('app.color.text_muted'))
      .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(10)
      .backgroundColor(this.tab === index ? $r('app.color.chip_bg') : $r('app.color.card_bg'))
      .onClick(() => {
        this.tab = index;
      })
  }

  // ---- 触控板区 ----
  @Builder
  touchpadArea() {
    Column({ space: 10 }) {
      // 手势面：拖动=移动，单击=左键，双击=双击，双指点击=中键，双指滑动=滚动
      Column() {
        Text($r('app.string.remote_input_touch_hint'))
          .fontSize(11)
          .fontColor($r('app.color.text_muted'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .borderRadius(14)
      .backgroundColor($r('app.color.chip_bg'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          PanGesture({ fingers: 1, distance: 1 })
            .onActionStart(() => {
              this.onPanBegin();
            })
            .onActionUpdate((e: GestureEvent) => {
              // e.offsetX/offsetY 是"自手势起点的累计偏移" ⇒ 页面侧 pipeline 会再差分
              this.onPanUpdate(e.offsetX, e.offsetY);
            })
            .onActionEnd(() => {
              this.onPanEnd();
            })
            .onActionCancel(() => {
              this.onPanCancel();
            }),
          PanGesture({ fingers: 2, distance: 1 })
            .onActionStart(() => {
              this.scrollLastX = 0;
              this.scrollLastY = 0;
            })
            .onActionUpdate((e: GestureEvent) => {
              // 滚动需**增量**（协议：scroll 为布尔标记 + dx/dy 承载增量）⇒ 组件内做差
              const dx: number = e.offsetX - this.scrollLastX;
              const dy: number = e.offsetY - this.scrollLastY;
              this.scrollLastX = e.offsetX;
              this.scrollLastY = e.offsetY;
              this.onScroll(dx, dy);
            }),
          TapGesture({ count: 1 })
            .onAction(() => {
              this.onTap('single');
            }),
          TapGesture({ count: 2 })
            .onAction(() => {
              this.onTap('double');
            }),
          TapGesture({ count: 1, fingers: 2 })
            .onAction(() => {
              this.onTap('middle');
            })
        )
      )

      // 三个鼠标键（右键按评审 §二.5 裁决本期实现）
      Row({ space: 10 }) {
        this.mouseButton($r('app.string.remote_input_btn_left'), 'single')
        this.mouseButton($r('app.string.remote_input_btn_middle'), 'middle')
        this.mouseButton($r('app.string.remote_input_btn_right'), 'right')
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  mouseButton(label: ResourceStr, button: MousepadButton) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(40)
      .borderRadius(10)
      .backgroundColor($r('app.color.chip_bg'))
      .onClick(() => {
        this.onTap(button);
      })
  }

  // ---- 键盘区 ----
  @Builder
  keyboardArea() {
    Column({ space: 10 }) {
      TextInput({ placeholder: $r('app.string.remote_input_kb_hint') })
        .fontSize(14)
        .height(44)
        .backgroundColor($r('app.color.chip_bg'))
        .onChange((value: string) => {
          // 只发"追加"部分：新值是旧值的前缀延伸时才发新增字符（删除/光标移动不回传）
          if (value.length > this.lastText.length && value.startsWith(this.lastText)) {
            this.onTypeText(value.substring(this.lastText.length));
          }
          this.lastText = value;
        })

      Text($r('app.string.remote_input_special_keys'))
        .fontSize(12)
        .fontColor($r('app.color.text_muted'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.specialKeys, (code: number) => {
            Text(specialKeyName(code))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .height(32)
              .padding({ left: 10, right: 10 })
              .margin({ right: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor($r('app.color.chip_bg'))
              .onClick(() => {
                // 码表下标语义（1..32；0 无效）—— 非法值由插件侧拒发，这里不重复判断
                this.onSpecialKey(code);
              })
          }, (code: number) => `${code}`)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }
}
